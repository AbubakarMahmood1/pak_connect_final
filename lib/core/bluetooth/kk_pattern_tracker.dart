import 'package:logging/logging.dart';

/// Tracks KK pattern attempts across handshakes with per-peer backoff.
class KKPatternTracker {
  KKPatternTracker({
    Logger? logger,
    int maxRetries = _defaultMaxRetries,
    Duration backoffDuration = _defaultBackoff,
  }) : _logger = logger ?? Logger('KKPatternTracker'),
       _maxRetries = maxRetries,
       _backoffDuration = backoffDuration;

  final Logger _logger;
  final int _maxRetries;
  final Duration _backoffDuration;

  // Shared across all instances to preserve global KK backoff behavior.
  static final Map<String, int> _kkFailureCount = {};
  static final Map<String, DateTime> _lastKKAttempt = {};

  static const int _defaultMaxRetries = 3;
  static const Duration _defaultBackoff = Duration(hours: 1);

  /// Whether KK should be attempted for the given peer key.
  bool shouldAttempt(String peerKey) {
    final lastAttempt = _lastKKAttempt[peerKey];
    if (lastAttempt != null) {
      final elapsed = DateTime.now().difference(lastAttempt);
      if (elapsed < _backoffDuration) {
        _logger.info(
          '⏳ KK backoff active: ${_backoffDuration - elapsed} remaining',
        );
        return false;
      }
    }

    final failures = _kkFailureCount[peerKey] ?? 0;
    if (failures >= _maxRetries) {
      _logger.info(
        '⚠️ Max KK retries reached ($failures/$_maxRetries) - using XX',
      );
      return false;
    }

    return true;
  }

  /// Record a KK failure for backoff and downgrade tracking.
  void recordFailure(String peerKey, String reason) {
    _kkFailureCount[peerKey] = (_kkFailureCount[peerKey] ?? 0) + 1;
    _lastKKAttempt[peerKey] = DateTime.now();

    final count = _kkFailureCount[peerKey]!;
    _logger.warning('⚠️ KK failure #$count for peer (reason: $reason)');

    if (count >= _maxRetries) {
      _logger.warning(
        '🚨 Max KK failures reached - will use XX pattern from now on',
      );
    }
  }

  /// Reset KK failure tracking after successful handshake.
  void reset(String peerKey) {
    _kkFailureCount.remove(peerKey);
    _lastKKAttempt.remove(peerKey);
    _logger.info('✅ Reset KK failure tracking for peer');
  }
}
