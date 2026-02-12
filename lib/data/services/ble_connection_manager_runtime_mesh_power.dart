part of 'ble_connection_manager.dart';

extension _BleConnectionManagerRuntimeMeshPower on BLEConnectionManager {
  Future<void> _runtimeStartMeshNetworking({
    Future<void> Function()? onStartAdvertising,
  }) async {
    _logger.info(
      '🚀 Starting mesh networking (simultaneous central + peripheral)',
    );

    try {
      // Start advertising FIRST (like BitChat)
      // ✅ NEW: Use callback to BLEService.startAsPeripheral() → AdvertisingManager
      if (onStartAdvertising != null) {
        _logger.info(
          '📡 Calling advertising callback (BLEService.startAsPeripheral)...',
        );
        await onStartAdvertising();
        _isAdvertising = true; // Assume success if no exception
        _logger.info(
          '✅ Peripheral role active (advertising via AdvertisingManager)',
        );
      } else {
        _logger.severe(
          '❌ No advertising callback provided - advertising will NOT start!',
        );
        throw Exception(
          'startMeshNetworking requires onStartAdvertising callback',
        );
      }

      // Central role is always ready (discovery initiated by BurstScanController)
      _logger.info('✅ Central role active (ready to scan)');
      _shouldBeAdvertising = true;

      _logger.info('🎉 Mesh networking started successfully');
      _logger.info('📊 Connection limits: $_limitConfig');
    } catch (e) {
      _logger.severe('❌ Failed to start mesh networking: $e');
      rethrow;
    }
  }

  Future<void> _runtimeStopMeshNetworking() async {
    _logger.info('🛑 Stopping mesh networking');

    _shouldBeAdvertising = false;

    try {
      await _stopAdvertising();
      _logger.info('✅ Mesh networking stopped');
    } catch (e) {
      _logger.warning('⚠️ Error stopping mesh networking: $e');
    }
  }

  Future<void> _runtimeHandlePowerModeChange(PowerMode newMode) async {
    _logger.info('⚡ Power mode changed to: ${newMode.name}');

    final oldConfig = _limitConfig;
    final oldRssiThreshold = _rssiThreshold;

    _limitConfig = ConnectionLimitConfig.forPowerMode(newMode);
    _rssiThreshold = _limitEnforcer.rssiThresholdForPowerMode(newMode);

    _logger.info('🎯 Connection limits updated: $oldConfig → $_limitConfig');
    _logger.info(
      '📡 RSSI threshold updated: $oldRssiThreshold dBm → $_rssiThreshold dBm',
    );

    await _limitEnforcer.enforceConnectionLimits(
      limitConfig: _limitConfig,
      clientConnections: _clientConnections,
      serverConnections: _serverConnections,
      centralManager: centralManager,
      updateAdvertisingState: _updateAdvertisingState,
      formatAddress: _formatAddress,
    );

    await _updateAdvertisingState();
  }

  void _runtimeHandleBluetoothStateChange(BluetoothLowEnergyState state) {
    _reconnectPolicy.handleBluetoothStateChange(
      state: state,
      hasBleConnection: hasBleConnection,
      connectedDevice: _connectedDevice,
      lastConnectedDevice: _lastConnectedDevice,
      setLastConnectedDevice: (device) => _lastConnectedDevice = device,
      setReconnectionFlag: (value) => _isReconnection = value,
      startConnectionMonitoring: startConnectionMonitoring,
      stopConnectionMonitoring: stopConnectionMonitoring,
      clearConnectionState: ({bool keepMonitoring = false}) =>
          clearConnectionState(keepMonitoring: keepMonitoring),
    );
  }
}
