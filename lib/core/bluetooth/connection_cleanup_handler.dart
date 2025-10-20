import 'dart:async';
import 'package:logging/logging.dart';

import '../../core/discovery/device_deduplication_manager.dart';

/// 🧹 REAL-TIME CONNECTION CLEANUP HANDLER
/// 
/// Handles immediate cleanup when devices disconnect.
/// Ensures no stale data remains in any tracking system.
/// 
/// Key Design Principles (from BitChat reference):
/// 1. Event-driven cleanup - triggered by disconnect callbacks
/// 2. Immediate removal from ALL tracking maps
/// 3. Proper sequencing: cleanup → notify → delay → close
/// 4. Periodic cleanup only for expired pending connections
class ConnectionCleanupHandler {
  final Logger _logger = Logger('ConnectionCleanupHandler');
  
  /// Track active connections by device ID
  final Map<String, _ConnectionInfo> _activeConnections = {};
  
  /// Track pending connections (for retry logic)
  final Map<String, _PendingConnection> _pendingConnections = {};
  
  /// Periodic cleanup timer
  Timer? _periodicCleanupTimer;
  
  /// Cleanup interval for expired pending connections
  static const _cleanupInterval = Duration(seconds: 30);
  
  /// Pending connection expiry timeout
  static const _pendingConnectionTimeout = Duration(minutes: 2);
  
  /// Delegate for cleanup notifications
  ConnectionCleanupDelegate? delegate;
  
  /// Start the cleanup handler
  void start() {
    _logger.info('🧹 Starting connection cleanup handler');
    _startPeriodicCleanup();
  }
  
  /// Stop the cleanup handler
  void stop() {
    _logger.info('🧹 Stopping connection cleanup handler');
    _periodicCleanupTimer?.cancel();
    _periodicCleanupTimer = null;
    _activeConnections.clear();
    _pendingConnections.clear();
  }
  
  /// 📥 Register a new connection
  /// 
  /// Called when a device connects (either as central or peripheral).
  void registerConnection({
    required String deviceId,
    required String deviceAddress,
    required bool isClient,
  }) {
    _logger.info('📥 Registering connection: ${_formatAddress(deviceAddress)} (${isClient ? "client" : "server"})');
    
    // Remove from pending connections (successful connection)
    _pendingConnections.remove(deviceId);
    
    // Add to active connections
    _activeConnections[deviceId] = _ConnectionInfo(
      deviceId: deviceId,
      deviceAddress: deviceAddress,
      isClient: isClient,
      connectedAt: DateTime.now(),
    );
    
    _logger.fine('🧹 Active connections: ${_activeConnections.length}');
  }
  
  /// 📤 Handle device disconnect - REAL-TIME CLEANUP
  /// 
  /// This is the critical method that ensures immediate cleanup.
  /// Called from BLE disconnect callbacks (both central and peripheral).
  /// 
  /// Cleanup sequence (BitChat pattern):
  /// 1. Remove from active connections tracking
  /// 2. Remove from device deduplication manager
  /// 3. Notify delegate for UI updates
  /// 4. Schedule GATT cleanup after delay (prevents race conditions)
  Future<void> handleDisconnect({
    required String deviceId,
    required String deviceAddress,
  }) async {
    _logger.info('📤 Handling disconnect: ${_formatAddress(deviceAddress)}');
    
    // Step 1: Remove from active connections
    final connection = _activeConnections.remove(deviceId);
    if (connection == null) {
      _logger.warning('⚠️ Disconnect for unknown device: ${_formatAddress(deviceAddress)}');
      return;
    }
    
    final duration = DateTime.now().difference(connection.connectedAt);
    _logger.info('🧹 Connection duration: ${duration.inSeconds}s');
    
    // Step 2: Remove from device deduplication manager (REAL-TIME)
    DeviceDeduplicationManager.removeDevice(deviceId);
    _logger.fine('🧹 Removed from deduplication manager');
    
    // Step 3: Notify delegate for UI updates
    delegate?.onDeviceDisconnected(deviceId, deviceAddress);
    _logger.fine('🧹 Notified delegate');
    
    // Step 4: Schedule GATT cleanup after delay (BitChat pattern: 500ms)
    // This prevents race conditions with pending BLE operations
    Future.delayed(Duration(milliseconds: 500), () {
      delegate?.onGattCleanupReady(deviceId, deviceAddress);
      _logger.fine('🧹 GATT cleanup ready');
    });
    
    _logger.info('✅ Disconnect cleanup complete: ${_formatAddress(deviceAddress)}');
    _logger.fine('🧹 Active connections: ${_activeConnections.length}');
  }
  
  /// 📋 Add pending connection attempt
  /// 
  /// Used for retry logic and rate limiting.
  /// Returns true if attempt is allowed, false if too many recent attempts.
  bool addPendingConnection(String deviceId) {
    final existing = _pendingConnections[deviceId];
    
    // Check if too many recent attempts
    if (existing != null) {
      final timeSinceLastAttempt = DateTime.now().difference(existing.lastAttempt);
      if (timeSinceLastAttempt < Duration(seconds: 5)) {
        _logger.fine('⏳ Pending connection attempt too soon: $deviceId');
        return false;
      }
    }
    
    // Add/update pending connection
    _pendingConnections[deviceId] = _PendingConnection(
      deviceId: deviceId,
      lastAttempt: DateTime.now(),
    );
    
    _logger.fine('📋 Added pending connection: $deviceId');
    return true;
  }
  
  /// 🗑️ Remove pending connection
  void removePendingConnection(String deviceId) {
    _pendingConnections.remove(deviceId);
  }
  
  /// 📊 Get active connection count
  int get activeConnectionCount => _activeConnections.length;
  
  /// 📊 Get pending connection count
  int get pendingConnectionCount => _pendingConnections.length;
  
  /// 🔄 Start periodic cleanup for expired pending connections
  /// 
  /// This is the ONLY periodic cleanup - active connections are cleaned in real-time.
  void _startPeriodicCleanup() {
    _periodicCleanupTimer?.cancel();
    
    _periodicCleanupTimer = Timer.periodic(_cleanupInterval, (_) {
      _cleanupExpiredPendingConnections();
    });
  }
  
  /// 🗑️ Clean up expired pending connections
  /// 
  /// Removes pending connections that haven't succeeded within timeout.
  /// Active connections are NOT cleaned here - they're cleaned on disconnect events.
  void _cleanupExpiredPendingConnections() {
    final now = DateTime.now();
    final expiredIds = <String>[];
    
    _pendingConnections.forEach((deviceId, pending) {
      final age = now.difference(pending.lastAttempt);
      if (age > _pendingConnectionTimeout) {
        expiredIds.add(deviceId);
      }
    });
    
    if (expiredIds.isNotEmpty) {
      for (final id in expiredIds) {
        _pendingConnections.remove(id);
      }
      _logger.info('🗑️ Cleaned up ${expiredIds.length} expired pending connections');
    }
  }
  
  /// 🔧 Format address for logging
  String _formatAddress(String address) {
    if (address.length > 8) {
      return '${address.substring(0, 8)}...';
    }
    return address;
  }
  
  /// 📊 Get debug info
  String getDebugInfo() {
    return '''
=== Connection Cleanup Handler ===
Active Connections: ${_activeConnections.length}
Pending Connections: ${_pendingConnections.length}

Active:
${_activeConnections.entries.map((e) => '  ${_formatAddress(e.value.deviceAddress)} (${e.value.isClient ? "client" : "server"}) - ${DateTime.now().difference(e.value.connectedAt).inSeconds}s').join('\n')}

Pending:
${_pendingConnections.entries.map((e) => '  ${e.key} - ${DateTime.now().difference(e.value.lastAttempt).inSeconds}s ago').join('\n')}
''';
  }
}

/// 📋 Connection information
class _ConnectionInfo {
  final String deviceId;
  final String deviceAddress;
  final bool isClient;
  final DateTime connectedAt;
  
  _ConnectionInfo({
    required this.deviceId,
    required this.deviceAddress,
    required this.isClient,
    required this.connectedAt,
  });
}

/// 📋 Pending connection information
class _PendingConnection {
  final String deviceId;
  final DateTime lastAttempt;
  
  _PendingConnection({
    required this.deviceId,
    required this.lastAttempt,
  });
}

/// 🔔 Delegate for cleanup notifications
abstract class ConnectionCleanupDelegate {
  /// Called when a device disconnects (for UI updates)
  void onDeviceDisconnected(String deviceId, String deviceAddress);
  
  /// Called when GATT cleanup is ready (after delay)
  void onGattCleanupReady(String deviceId, String deviceAddress);
}

