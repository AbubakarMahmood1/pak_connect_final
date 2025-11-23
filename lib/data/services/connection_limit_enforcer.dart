import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/models/ble_server_connection.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../models/ble_client_connection.dart';
import '../models/connection_limit_config.dart';

/// Isolates connection capacity logic (limits, RSSI thresholds, FIFO trimming)
class ConnectionLimitEnforcer {
  final Logger _logger;

  ConnectionLimitEnforcer({Logger? logger})
    : _logger = logger ?? Logger('ConnectionLimitEnforcer');

  /// Determine RSSI threshold for a given power mode
  int rssiThresholdForPowerMode(PowerMode mode) {
    return switch (mode) {
      PowerMode.performance => -95, // Accept all
      PowerMode.balanced => -85, // Normal
      PowerMode.powerSaver => -75, // Only good signals
      PowerMode.ultraLowPower => -65, // Only excellent signals
    };
  }

  /// Enforce client/server/total connection limits with FIFO trimming
  Future<void> enforceConnectionLimits({
    required ConnectionLimitConfig limitConfig,
    required Map<String, BLEClientConnection> clientConnections,
    required Map<String, BLEServerConnection> serverConnections,
    required CentralManager centralManager,
    required Future<void> Function() updateAdvertisingState,
    required String Function(String address) formatAddress,
  }) async {
    final clientCount = clientConnections.length;
    final serverCount = serverConnections.length;
    final totalCount = clientCount + serverCount;

    // Check client connections
    final excessClients = limitConfig.getExcessClientConnections(
      clientCount,
      totalCount,
    );

    if (excessClients > 0) {
      _logger.warning('⚠️ Excess client connections: $excessClients');
      await _disconnectOldestClients(
        count: excessClients,
        clientConnections: clientConnections,
        centralManager: centralManager,
        formatAddress: formatAddress,
      );
    }

    // Check server + total limits
    final excessServers = serverCount - limitConfig.maxServerConnections;
    final excessTotal = totalCount - limitConfig.maxTotalConnections;

    if (excessServers > 0 || excessTotal > 0) {
      final toDisconnect = [
        excessServers,
        excessTotal,
      ].reduce((a, b) => a > b ? a : b);
      _logger.warning('⚠️ Excess server connections: $toDisconnect');
      await _disconnectOldestServers(
        count: toDisconnect,
        serverConnections: serverConnections,
        formatAddress: formatAddress,
      );
      await updateAdvertisingState();
    }
  }

  /// Determine if a connect error is transient and worth retrying
  bool isTransientConnectError(Object e) {
    final s = e.toString();
    // Timeouts and Android GATT status 133/147 are classic transient failures
    return s.contains('timeout') ||
        s.contains('Connection timeout') ||
        s.contains('status=133') ||
        s.contains('status=147') ||
        s.contains('GATT 133') ||
        s.contains('133') && (s.contains('Gatt') || s.contains('GATT'));
  }

  Future<void> _disconnectOldestClients({
    required int count,
    required Map<String, BLEClientConnection> clientConnections,
    required CentralManager centralManager,
    required String Function(String) formatAddress,
  }) async {
    final sorted = clientConnections.values.toList()
      ..sort((a, b) => a.connectedAt.compareTo(b.connectedAt));

    for (int i = 0; i < count && i < sorted.length; i++) {
      final conn = sorted[i];
      _logger.info(
        '🔌 Disconnecting oldest client: ${formatAddress(conn.address)}',
      );
      try {
        await centralManager.disconnect(conn.peripheral);
        // Connection will be removed in the disconnect event handler
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to disconnect ${formatAddress(conn.address)}: $e',
        );
        clientConnections.remove(conn.address);
      }
    }
  }

  Future<void> _disconnectOldestServers({
    required int count,
    required Map<String, BLEServerConnection> serverConnections,
    required String Function(String) formatAddress,
  }) async {
    final sorted = serverConnections.values.toList()
      ..sort((a, b) => a.connectedAt.compareTo(b.connectedAt));

    for (int i = 0; i < count && i < sorted.length; i++) {
      final conn = sorted[i];
      _logger.info(
        '🔌 Disconnecting oldest server connection: ${formatAddress(conn.address)}',
      );

      // PeripheralManager doesn't expose a disconnect API for inbound links
      serverConnections.remove(conn.address);
    }
  }
}
