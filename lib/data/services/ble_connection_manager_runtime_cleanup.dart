part of 'ble_connection_manager.dart';

extension _BleConnectionManagerRuntimeCleanup on BLEConnectionManager {
  void _runtimeClearConnectionState({
    bool keepMonitoring = false,
    String? contactId,
  }) {
    _logger.info('🧹 Clearing connection state');

    for (final timer in _deferredServerTeardownTimers.values) {
      timer.cancel();
    }
    _deferredServerTeardownTimers.clear();
    _deferredServerTeardown.clear();

    onCharacteristicFound?.call(null);
    onMtuDetected?.call(null);
    _healthMonitor.resetHandshakeFlags();

    if (contactId != null) {
      _cleanupEphemeralContactIfOrphaned(contactId);
    } else {
      for (final conn in _clientConnections.values) {
        _cleanupEphemeralContactIfOrphaned(conn.address);
      }
    }

    _clientConnections.clear();
    if (!keepMonitoring) {
      _serverConnections.clear();
      _connectionTracker.clear();
    } else {
      _connectionTracker.clear();
      for (final entry in _serverConnections.entries) {
        _connectionTracker.addConnection(address: entry.key, isClient: false);
      }
    }
    _peerHintsByAddress.clear();
    _blockedResponderHandshakes.clear();
    _noHintInboundDebounceUntil = null;
    _lastConnectedDevice = null;

    _isReconnection = false;

    _logger.info('📊 Connections cleared (client: 0, server: 0)');
    _updateConnectionState(ChatConnectionState.disconnected);

    if (!keepMonitoring) {
      stopConnectionMonitoring();
    }

    onConnectionChanged?.call(null);
  }

  void _runtimeCleanupEphemeralContactIfOrphaned(String contactId) async {
    await EphemeralContactCleaner.cleanup(
      contactId: contactId,
      logger: _logger,
    );
  }

  bool _runtimeHasViableRelayConnection() {
    try {
      if (!hasConnection || _connectedDevice == null) {
        return false;
      }

      if (_clientConnections.isNotEmpty &&
          (_healthMonitor.isHandshakeInProgress ||
              _healthMonitor.awaitingHandshake)) {
        _logger.fine(
          '⏸️ Treating client link as viable while handshake is in flight to avoid reconnection churn',
        );
        return true;
      }

      if (_messageCharacteristic == null) {
        return false;
      }

      if (!_isReady) {
        return false;
      }

      _logger.info(
        '🔄 Viable relay connection detected: ${_connectedDevice?.uuid}',
      );
      return true;
    } catch (e) {
      _logger.warning('Error checking relay viability: $e');
      return false;
    }
  }

  void _runtimeDispose() {
    stopConnectionMonitoring();
    _serverConnectionsController.close();
  }
}
