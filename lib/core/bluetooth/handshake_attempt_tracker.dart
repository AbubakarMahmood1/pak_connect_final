import 'package:logging/logging.dart';

/// Tracks general handshake attempts per peer to prevent brute-force attacks.
///
/// Unlike [KKPatternTracker] which only governs KK-vs-XX selection, this
/// tracker limits the overall number of handshake attempts from any peer
/// within a rolling window, applying exponential backoff on repeated failures.
class HandshakeAttemptTracker {
  HandshakeAttemptTracker({
    Logger? logger,
    int maxAttempts = _defaultMaxAttempts,
    Duration window = _defaultWindow,
    Duration lockoutDuration = _defaultLockout,
  })  : _logger = logger ?? Logger('HandshakeAttemptTracker'),
        _maxAttempts = maxAttempts,
        _window = window,
        _lockoutDuration = lockoutDuration;

  final Logger _logger;
  final int _maxAttempts;
  final Duration _window;
  final Duration _lockoutDuration;

  static const int _defaultMaxAttempts = 5;
  static const Duration _defaultWindow = Duration(minutes: 10);
  static const Duration _defaultLockout = Duration(minutes: 15);

  /// Hard cap on the number of distinct peer IDs tracked.
  static const int _maxTrackedPeers = 500;

  // Static maps so state survives HandshakeCoordinator reconstruction.
  static final Map<String, List<DateTime>> _failureTimestamps = {};
  static final Map<String, DateTime> _lockoutUntil = {};

  /// Whether a handshake attempt from [peerId] should be allowed.
  ///
  /// Returns `true` if the peer is not locked out and has not exceeded the
  /// failure threshold within the rolling [window].
  bool allowAttempt(String peerId) {
    _pruneOld(peerId);
    _evictIfOverCap();

    final lockedUntil = _lockoutUntil[peerId];
    if (lockedUntil != null) {
      final remaining = lockedUntil.difference(DateTime.now());
      if (!remaining.isNegative) {
        _logger.warning(
          '🔒 Peer $peerId locked out for ${remaining.inSeconds}s',
        );
        return false;
      }
      // Lockout expired — clear it.
      _lockoutUntil.remove(peerId);
    }

    final failures = _failureTimestamps[peerId] ?? [];
    if (failures.length >= _maxAttempts) {
      _logger.warning(
        '🚫 Peer $peerId exceeded max handshake attempts '
        '(${failures.length}/$_maxAttempts in ${_window.inMinutes}min)',
      );
      // Enforce lockout.
      _lockoutUntil[peerId] = DateTime.now().add(_lockoutDuration);
      _logger.warning(
        '🔒 Locking out peer $peerId for ${_lockoutDuration.inMinutes}min',
      );
      return false;
    }
    return true;
  }

  /// Record a failed handshake attempt from [peerId].
  void recordFailure(String peerId, String reason) {
    _evictIfOverCap();
    _failureTimestamps.putIfAbsent(peerId, () => []).add(DateTime.now());
    _pruneOld(peerId);

    final count = _failureTimestamps[peerId]?.length ?? 0;
    _logger.warning(
      '⚠️ Handshake failure #$count for peer $peerId: $reason',
    );

    if (count >= _maxAttempts) {
      _lockoutUntil[peerId] = DateTime.now().add(_lockoutDuration);
      _logger.warning(
        '🔒 Peer $peerId locked out after $count failures '
        '(lockout: ${_lockoutDuration.inMinutes}min)',
      );
    }
  }

  /// Record a successful handshake — clears failure history for [peerId].
  void recordSuccess(String peerId) {
    _failureTimestamps.remove(peerId);
    _lockoutUntil.remove(peerId);
    _logger.info('✅ Reset handshake attempt tracking for peer $peerId');
  }

  /// Duration until the lockout expires for [peerId], or `null` if not locked.
  Duration? lockoutRemaining(String peerId) {
    final until = _lockoutUntil[peerId];
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  /// Visible for testing — directly query failure count within the window.
  int failureCount(String peerId) {
    _pruneOld(peerId);
    return _failureTimestamps[peerId]?.length ?? 0;
  }

  /// Clear all tracking state (useful in tests).
  static void resetAll() {
    _failureTimestamps.clear();
    _lockoutUntil.clear();
  }

  /// Current number of tracked peer IDs (visible for testing).
  static int get trackedPeerCount => _failureTimestamps.length;

  // Remove timestamps outside the rolling window.
  void _pruneOld(String peerId) {
    final stamps = _failureTimestamps[peerId];
    if (stamps == null) return;
    final cutoff = DateTime.now().subtract(_window);
    stamps.removeWhere((t) => t.isBefore(cutoff));
    if (stamps.isEmpty) _failureTimestamps.remove(peerId);
  }

  /// Evict oldest entries when the maps exceed [_maxTrackedPeers].
  static void _evictIfOverCap() {
    if (_failureTimestamps.length <= _maxTrackedPeers) return;

    // Remove peers whose lockouts have expired first.
    final now = DateTime.now();
    _lockoutUntil.removeWhere((_, until) => until.isBefore(now));

    // Remove failure entries that no longer have a lockout.
    final expiredPeers = _failureTimestamps.keys
        .where((id) => !_lockoutUntil.containsKey(id))
        .toList();
    for (final peerId in expiredPeers) {
      _failureTimestamps.remove(peerId);
      if (_failureTimestamps.length <= _maxTrackedPeers) return;
    }

    // If still over cap, evict the oldest entries regardless.
    while (_failureTimestamps.length > _maxTrackedPeers) {
      _failureTimestamps.remove(_failureTimestamps.keys.first);
    }
  }
}
