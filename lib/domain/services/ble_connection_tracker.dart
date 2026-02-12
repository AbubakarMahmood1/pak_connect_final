import 'package:logging/logging.dart';

/// Centralized tracker for all BLE connections (client + server).
/// Mirrors BitChat’s “first link wins” pattern so scanners can avoid
/// initiating a second connection to the same device.
class BleConnectionTracker {
  BleConnectionTracker({Logger? logger, DateTime Function()? now})
    : _logger = logger ?? Logger('BleConnectionTracker'),
      _now = now ?? DateTime.now;

  final Logger _logger;
  final DateTime Function() _now;

  final Map<String, _TrackedConnection> _connections = {};
  final Map<String, _PendingAttempt> _pendingAttempts = {};
  final Map<String, DateTime> _disconnectCooldownUntil = {};

  // Backoff timing (matches BitChat-style light throttling)
  static const Duration _retryDelay = Duration(seconds: 5);
  static const Duration _attemptExpiry = Duration(seconds: 12);
  static const Duration _postDisconnectCooldown = Duration(seconds: 3);
  static const bool _enforcePostDisconnectCooldown = bool.fromEnvironment(
    'PAKCONNECT_BLE_ENFORCE_POST_DISCONNECT_COOLDOWN',
    defaultValue: true,
  );
  static Duration get retryDelay => _retryDelay;
  static Duration get attemptExpiry => _attemptExpiry;
  static Duration get postDisconnectCooldown => _postDisconnectCooldown;
  static bool get isPostDisconnectCooldownEnabled =>
      _enforcePostDisconnectCooldown;

  bool isConnected(String address) => _connections.containsKey(address);

  /// Returns true if a new connection attempt is allowed for this address.
  bool canAttempt(String address) {
    _pruneExpiredAttempts();
    _pruneExpiredDisconnectCooldowns();

    final pending = _pendingAttempts[address];
    if (pending != null) {
      final age = _now().difference(pending.lastAttempt);
      if (age > _attemptExpiry) {
        _pendingAttempts.remove(address);
      } else if (age < _retryDelay) {
        return false;
      }
    }

    if (!_enforcePostDisconnectCooldown) return true;

    final disconnectCooldown = disconnectCooldownRemaining(address);
    if (disconnectCooldown != null && disconnectCooldown > Duration.zero) {
      return false;
    }
    return true;
  }

  /// Record a connection attempt (call before initiating).
  void markAttempt(String address) {
    _pruneExpiredAttempts();

    final now = _now();
    final current = _pendingAttempts[address];
    final attempts =
        current == null || now.difference(current.lastAttempt) > _attemptExpiry
        ? 1
        : current.attempts + 1;
    _pendingAttempts[address] = _PendingAttempt(
      attempts: attempts,
      lastAttempt: now,
    );
    _logger.fine('⏳ Attempt $attempts for ${_format(address)}');
  }

  /// Remaining cooldown before the next allowed retry for [address].
  ///
  /// Returns:
  /// - `null` when there is no pending attempt window for the address.
  /// - `Duration.zero` when retry is currently allowed.
  Duration? retryBackoffRemaining(String address) {
    _pruneExpiredAttempts();
    final pending = _pendingAttempts[address];
    if (pending == null) return null;

    final age = _now().difference(pending.lastAttempt);
    if (age > _attemptExpiry) {
      _pendingAttempts.remove(address);
      return null;
    }
    if (age >= _retryDelay) return Duration.zero;
    return _retryDelay - age;
  }

  /// Next timestamp when retry is allowed for [address], if currently tracked.
  DateTime? nextAllowedAttemptAt(String address) {
    _pruneExpiredAttempts();
    final pending = _pendingAttempts[address];
    if (pending == null) return null;
    return pending.lastAttempt.add(_retryDelay);
  }

  /// Number of pending attempts in the current retry window for [address].
  int pendingAttemptCount(String address) {
    _pruneExpiredAttempts();
    final pending = _pendingAttempts[address];
    if (pending == null) return 0;
    return pending.attempts;
  }

  /// Clear pending entry (call on success or deliberate abandon).
  void clearAttempt(String address) {
    _pendingAttempts.remove(address);
  }

  void addConnection({
    required String address,
    required bool isClient,
    int? rssi,
  }) {
    _connections[address] = _TrackedConnection(
      address: address,
      isClient: isClient,
      rssi: rssi,
      connectedAt: DateTime.now(),
    );
    // Success: clear pending attempt tracking for this address
    _pendingAttempts.remove(address);
    _disconnectCooldownUntil.remove(address);
    _logger.fine(
      '🔗 Tracked connection: ${_format(address)} (${isClient ? "client" : "server"})',
    );
  }

  void removeConnection(String address) {
    final removed = _connections.remove(address);
    if (removed != null) {
      _logger.fine('🧹 Removed tracked connection: ${_format(address)}');
      markDisconnectCooldown(address);
    }
  }

  void clear({bool preserveDisconnectCooldowns = false}) {
    _connections.clear();
    _pendingAttempts.clear();
    if (!preserveDisconnectCooldowns) {
      _disconnectCooldownUntil.clear();
    }
    _logger.fine('🧹 Cleared all tracked connections');
  }

  /// Remove stale pending attempts so the map does not grow unbounded.
  void _pruneExpiredAttempts() {
    final now = _now();
    _pendingAttempts.removeWhere(
      (_, pending) => now.difference(pending.lastAttempt) > _attemptExpiry,
    );
  }

  void _pruneExpiredDisconnectCooldowns() {
    final now = _now();
    _disconnectCooldownUntil.removeWhere((_, until) => !now.isBefore(until));
  }

  void markDisconnectCooldown(String address, {Duration? duration}) {
    if (!_enforcePostDisconnectCooldown) return;
    final cooldown = duration ?? _postDisconnectCooldown;
    if (cooldown <= Duration.zero) {
      _disconnectCooldownUntil.remove(address);
      return;
    }

    final until = _now().add(cooldown);
    _disconnectCooldownUntil[address] = until;
    _logger.fine(
      '⏳ Disconnect cooldown started for ${_format(address)} '
      '(${cooldown.inMilliseconds}ms, until=${until.toIso8601String()})',
    );
  }

  /// Remaining post-disconnect cooldown for [address], when enabled.
  ///
  /// Returns `null` when no active cooldown exists.
  Duration? disconnectCooldownRemaining(String address) {
    if (!_enforcePostDisconnectCooldown) return null;
    _pruneExpiredDisconnectCooldowns();
    final until = _disconnectCooldownUntil[address];
    if (until == null) return null;
    final remaining = until.difference(_now());
    if (remaining <= Duration.zero) {
      _disconnectCooldownUntil.remove(address);
      return null;
    }
    return remaining;
  }

  /// Cooldown-until timestamp for [address], if active.
  DateTime? disconnectCooldownUntil(String address) {
    if (!_enforcePostDisconnectCooldown) return null;
    _pruneExpiredDisconnectCooldowns();
    return _disconnectCooldownUntil[address];
  }

  int get count => _connections.length;

  String _format(String address) =>
      address.length > 8 ? '${address.substring(0, 8)}...' : address;
}

class _TrackedConnection {
  _TrackedConnection({
    required this.address,
    required this.isClient,
    required this.connectedAt,
    this.rssi,
  });

  final String address;
  final bool isClient;
  final DateTime connectedAt;
  final int? rssi;
}

class _PendingAttempt {
  _PendingAttempt({required this.attempts, required this.lastAttempt});
  final int attempts;
  final DateTime lastAttempt;
}
