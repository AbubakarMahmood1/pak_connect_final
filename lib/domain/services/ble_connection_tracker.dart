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

  // Backoff timing (matches BitChat-style light throttling)
  static const Duration _retryDelay = Duration(seconds: 5);
  static const Duration _attemptExpiry = Duration(seconds: 12);

  bool isConnected(String address) => _connections.containsKey(address);

  /// Returns true if a new connection attempt is allowed for this address.
  bool canAttempt(String address) {
    _pruneExpiredAttempts();

    final pending = _pendingAttempts[address];
    if (pending == null) return true;
    final age = _now().difference(pending.lastAttempt);
    if (age > _attemptExpiry) {
      _pendingAttempts.remove(address);
      return true;
    }
    return age >= _retryDelay;
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
    _logger.fine(
      '🔗 Tracked connection: ${_format(address)} (${isClient ? "client" : "server"})',
    );
  }

  void removeConnection(String address) {
    final removed = _connections.remove(address);
    if (removed != null) {
      _logger.fine('🧹 Removed tracked connection: ${_format(address)}');
    }
  }

  void clear() {
    _connections.clear();
    _pendingAttempts.clear();
    _logger.fine('🧹 Cleared all tracked connections');
  }

  /// Remove stale pending attempts so the map does not grow unbounded.
  void _pruneExpiredAttempts() {
    final now = _now();
    _pendingAttempts.removeWhere(
      (_, pending) => now.difference(pending.lastAttempt) > _attemptExpiry,
    );
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
