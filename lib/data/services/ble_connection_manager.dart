import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/models/connection_state.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../models/ble_client_connection.dart';
import '../models/ble_server_connection.dart';
import '../models/connection_limit_config.dart';
import '../exceptions/connection_exceptions.dart';
import '../repositories/contact_repository.dart';
import '../repositories/message_repository.dart';
import '../../core/utils/chat_utils.dart';

// Enum must be declared at top level
enum ConnectionMonitorState {
  idle,
  healthChecking,
  reconnecting,
}

class BLEConnectionManager {
  final _logger = Logger('BLEConnectionManager');
  final CentralManager centralManager;
  final PeripheralManager peripheralManager;

  // 🎯 Phase 2b: Multi-connection tracking
  // Client connections: We act as central, connecting TO peripherals
  final Map<String, BLEClientConnection> _clientConnections = {};

  // Server connections: We act as peripheral, others connect TO us
  final Map<String, BLEServerConnection> _serverConnections = {};

  // Connection limits (platform + power mode aware)
  late ConnectionLimitConfig _limitConfig;

  // RSSI filtering (Phase 4: Adaptive Sync Frequency - RSSI-based connection filtering)
  int _rssiThreshold = -85; // Default: Balanced mode threshold

  // For backward compatibility with existing health check logic
  // Returns first client connection's peripheral
  Peripheral? get _connectedDevice => _clientConnections.values.firstOrNull?.peripheral;
  Peripheral? _lastConnectedDevice;
  GATTCharacteristic? get _messageCharacteristic => _clientConnections.values.firstOrNull?.messageCharacteristic;
  int? get _mtuSize => _clientConnections.values.firstOrNull?.mtu;

  // Advertising control (Phase 2b: Hybrid advertising strategy)
  bool _isAdvertising = false;
  bool _shouldBeAdvertising = true; // Whether we WANT to advertise
  GATTCharacteristic? _serverMessageCharacteristic; // For incoming connections
  
  // Simplified monitoring system
  Timer? _monitoringTimer;
  bool _isMonitoring = false;
  int _monitoringInterval = 3000; // milliseconds
  int _reconnectAttempts = 0;
  bool _messageOperationInProgress = false;
  bool _pairingInProgress = false;
  bool _handshakeInProgress = false;
  bool _isReconnection = false;
  
  ConnectionMonitorState _monitorState = ConnectionMonitorState.idle;
  ChatConnectionState _connectionState = ChatConnectionState.disconnected;

  // Constants
  static const int maxReconnectAttempts = 5;
  static const int minInterval = 3000;
  static const int maxInterval = 30000;
  static const int healthCheckInterval = 5000;
  
  // Callbacks for parent service
  Function(Peripheral?)? onConnectionChanged;
  Function(GATTCharacteristic?)? onCharacteristicFound;
  Function(int?)? onMtuDetected;
  Function()? onConnectionComplete;
  Function(bool)? onMonitoringChanged;
  Function(ConnectionInfo)? onConnectionInfoChanged;
  
  BLEConnectionManager({
    required this.centralManager,
    required this.peripheralManager,
    PowerMode initialPowerMode = PowerMode.balanced,
  }) {
    _limitConfig = ConnectionLimitConfig.forPowerMode(initialPowerMode);
    _rssiThreshold = _getRssiThresholdForPowerMode(initialPowerMode);
    _logger.info('🎯 Connection limits initialized: $_limitConfig');
    _logger.info('📡 RSSI threshold: $_rssiThreshold dBm (${initialPowerMode.name} mode)');
  }
  
  // Getters - Backward compatibility
  Peripheral? get connectedDevice => _connectedDevice;
  Peripheral? get lastConnectedDevice => _lastConnectedDevice;
  GATTCharacteristic? get messageCharacteristic => _messageCharacteristic;
  int? get mtuSize => _mtuSize;
  bool get hasBleConnection => _connectedDevice != null;
  bool get isReconnection => _isReconnection;
  bool get isMonitoring => _isMonitoring;
  ChatConnectionState get connectionState => _connectionState;
  bool get isActivelyReconnecting =>
    _isMonitoring && _monitorState == ConnectionMonitorState.reconnecting;
  bool get isHealthChecking =>
    _isMonitoring && _monitorState == ConnectionMonitorState.healthChecking;
  bool get hasConnection => hasBleConnection;
  bool get _isReady => _connectionState == ChatConnectionState.ready;

  // 🎯 Phase 2b: Multi-connection getters
  int get clientConnectionCount => _clientConnections.length;
  int get serverConnectionCount => _serverConnections.length;
  int get totalConnectionCount => clientConnectionCount + serverConnectionCount;

  bool get canAcceptClientConnection => _limitConfig.canAcceptClientConnection(
    clientConnectionCount,
    totalConnectionCount,
  );

  bool get canAcceptServerConnection => _limitConfig.canAcceptServerConnection(
    serverConnectionCount,
    totalConnectionCount,
  );

  bool get isAdvertising => _isAdvertising;
  List<BLEClientConnection> get clientConnections => _clientConnections.values.toList();
  List<BLEServerConnection> get serverConnections => _serverConnections.values.toList();

  // Legacy getter for burst scan optimization (now uses new connection tracking)
  int get activeConnectionCount => clientConnectionCount;
  bool get canAcceptMoreConnections => canAcceptClientConnection;
  List<Peripheral> get activeConnections => _clientConnections.values.map((c) => c.peripheral).toList();

  // Expose connection limits for logging
  int get maxClientConnections => _limitConfig.maxClientConnections;


  void _updateConnectionState(ChatConnectionState newState, {String? error}) {
  if (_connectionState != newState) {
    _connectionState = newState;
    
    final info = ConnectionInfo(
      state: newState,
      deviceId: _connectedDevice?.uuid.toString(),
      displayName: null, // Will be filled by state manager
      error: error,
    );
    
    onConnectionInfoChanged?.call(info);
    _logger.info('Connection state: ${newState.name}');
  }
}
  void startConnectionMonitoring() {
    if (_isMonitoring) return;
    
    _isMonitoring = true;
    _lastConnectedDevice = _connectedDevice;
    _monitorState = hasBleConnection
      ? ConnectionMonitorState.healthChecking 
      : ConnectionMonitorState.reconnecting;
    _monitoringInterval = minInterval;
    
    _scheduleNextCheck();
    onMonitoringChanged?.call(true);
    _logger.info('Monitoring started in ${_monitorState.name} mode');
  }

  void stopConnectionMonitoring() {
    _isMonitoring = false;
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _monitorState = ConnectionMonitorState.idle;
    _monitoringInterval = minInterval;
    _reconnectAttempts = 0;
    onMonitoringChanged?.call(false);
    _logger.info('Monitoring stopped');
  }

  void _scheduleNextCheck() {
    _monitoringTimer?.cancel();
    if (!_isMonitoring) return;
    
    _monitoringTimer = Timer(Duration(milliseconds: _monitoringInterval), () async {
      if (!_isMonitoring) return;
      
      switch (_monitorState) {
        case ConnectionMonitorState.healthChecking:
          await _performHealthCheck();
          break;
        case ConnectionMonitorState.reconnecting:
          await _attemptReconnection();
          break;
        case ConnectionMonitorState.idle:
          return;
      }
      
      // Exponential backoff
      _monitoringInterval = (_monitoringInterval * 1.2).round().clamp(minInterval, maxInterval);
      
      if (_isMonitoring) {
        _scheduleNextCheck();
      }
    });
  }

  void setPairingInProgress(bool inProgress) {
    _pairingInProgress = inProgress;
    if (inProgress) {
      _logger.info('⏸️ Pausing health checks during pairing');
    } else {
      _logger.info('▶️ Resuming health checks after pairing');
    }
  }

  void setHandshakeInProgress(bool inProgress) {
    _handshakeInProgress = inProgress;
    if (inProgress) {
      _logger.info('🤝 Handshake started - pausing health checks');
    } else {
      _logger.info('✅ Handshake completed - resuming health checks');
    }
  }


  Future<void> _performHealthCheck() async {
    if (_pairingInProgress || _handshakeInProgress) {
      _logger.info('⏸️ Skipping health check - ${_pairingInProgress ? "pairing" : "handshake"} in progress');
      _scheduleNextCheck();
      return;
    }

    if (_messageOperationInProgress || !hasBleConnection || _messageCharacteristic == null) {
      _logger.fine('⏸️ Skipping health check - no active connection or message in progress');
      _scheduleNextCheck();
      return;
    }

    try {
      final pingData = Uint8List.fromList([0x00]);

      _logger.fine('💓 Sending health check ping...');

      await centralManager.writeCharacteristic(
        _connectedDevice!,
        _messageCharacteristic!,
        value: pingData,
        type: GATTCharacteristicWriteType.withResponse,
      ).timeout(Duration(seconds: 3));

      _logger.info('✅ Health check passed (interval: ${_monitoringInterval}ms)');

    } catch (e) {
      _logger.warning('❌ Health check failed: $e');

      // Switch to reconnection mode
      _monitorState = ConnectionMonitorState.reconnecting;
      _monitoringInterval = minInterval; // Reset interval

      _logger.warning('🔄 Switching to reconnection mode');

      // Force disconnect
      try {
        await centralManager.disconnect(_connectedDevice!);
      } catch (_) {}

      clearConnectionState(keepMonitoring: true);
      _isReconnection = true;
    }
  }

  Future<void> _attemptReconnection() async {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _logger.warning('❌ Max reconnection attempts reached ($_reconnectAttempts/$maxReconnectAttempts)');
      stopConnectionMonitoring();
      return;
    }

    // 🎯 RELAY-AWARE FIX: Don't disconnect if we have a viable relay connection
    if (_hasViableRelayConnection()) {
      _logger.info('🔄 Maintaining current connection for relay - not reconnecting');
      _reconnectAttempts = 0; // Reset since we're not actually failing
      _monitorState = ConnectionMonitorState.healthChecking;
      _monitoringInterval = healthCheckInterval;
      return;
    }

    _reconnectAttempts++;
    _logger.info('🔄 Reconnect attempt $_reconnectAttempts/$maxReconnectAttempts');

    try {
      final foundDevice = await scanForSpecificDevice(timeout: Duration(seconds: 8));

      if (foundDevice != null) {
        _logger.info('✅ Found device for reconnection');
        _isReconnection = true;
        await connectToDevice(foundDevice);

        // Success - switch to health checking
        _reconnectAttempts = 0;
        _monitorState = ConnectionMonitorState.healthChecking;
        _monitoringInterval = minInterval;
        _isReconnection = false;
        _logger.info('✅ Reconnection successful');
      } else {
        _logger.warning('⚠️ No device found for reconnection');
      }
    } catch (e) {
      _logger.warning('❌ Reconnection failed: $e');
    }
  }

  void startHealthChecks() {
    if (!_isMonitoring) {
      startConnectionMonitoring();
    }
  }

  // 🚀 ========== PHASE 2B: SIMULTANEOUS OPERATION ========== 🚀

  /// 🚀 Start mesh networking: Simultaneous central + peripheral operation
  ///
  /// This starts both roles in parallel:
  /// - Peripheral role: Start advertising our mesh service
  /// - Central role: Ready to scan and connect to other peripherals
  ///
  /// Following BitChat model: Advertising runs continuously, scanning is duty-cycled
  Future<void> startMeshNetworking() async {
    _logger.info('🚀 Starting mesh networking (simultaneous central + peripheral)');

    try {
      // Start advertising FIRST (like BitChat)
      await _startAdvertising();
      _logger.info('✅ Peripheral role active (advertising)');

      // Central role is always ready (discovery initiated by BurstScanController)
      _logger.info('✅ Central role active (ready to scan)');
      _shouldBeAdvertising = true;

      _logger.info('🎉 Mesh networking started successfully');
      _logger.info('📊 Connection limits: ${_limitConfig}');

    } catch (e) {
      _logger.severe('❌ Failed to start mesh networking: $e');
      rethrow;
    }
  }

  /// 🛑 Stop mesh networking: Stop both central and peripheral operations
  Future<void> stopMeshNetworking() async {
    _logger.info('🛑 Stopping mesh networking');

    _shouldBeAdvertising = false;

    try {
      await _stopAdvertising();
      _logger.info('✅ Mesh networking stopped');
    } catch (e) {
      _logger.warning('⚠️ Error stopping mesh networking: $e');
    }
  }

  /// 🎛️ Hybrid advertising control: Stop at connection limit, resume when below
  ///
  /// This implements the hybrid strategy:
  /// - Advertise when: Below server connection limit
  /// - Stop when: At or above server connection limit
  /// - Resume when: Server connection drops below limit
  Future<void> _updateAdvertisingState() async {
    try {
      final shouldAdvertise = _shouldBeAdvertising && canAcceptServerConnection;

      if (shouldAdvertise && !_isAdvertising) {
        // Start advertising
        _logger.info('📡 Starting advertising (server connections: $serverConnectionCount/${_limitConfig.maxServerConnections})');
        await _startAdvertising();

      } else if (!shouldAdvertise && _isAdvertising) {
        // Stop advertising (at limit or user requested stop)
        final reason = !_shouldBeAdvertising
            ? 'user requested'
            : 'reached limit: $serverConnectionCount/${_limitConfig.maxServerConnections}';
        _logger.info('🛑 Stopping advertising ($reason)');
        await _stopAdvertising();
      }
    } catch (e) {
      _logger.warning('⚠️ Advertising state update failed: $e');
    }
  }

  /// 📡 Start BLE advertising
  Future<void> _startAdvertising() async {
    if (_isAdvertising) {
      _logger.fine('📡 Already advertising, skipping');
      return;
    }

    try {
      final advertisement = Advertisement(
        name: 'PakConnect',
        serviceUUIDs: [BLEConstants.serviceUUID],
      );

      await peripheralManager.startAdvertising(advertisement);
      _isAdvertising = true;
      _logger.info('✅ Advertising started');
    } catch (e) {
      _logger.severe('❌ Failed to start advertising: $e');
      throw AdvertisingException('Failed to start advertising', e);
    }
  }

  /// 🛑 Stop BLE advertising
  Future<void> _stopAdvertising() async {
    if (!_isAdvertising) {
      _logger.fine('🛑 Not advertising, skipping');
      return;
    }

    try {
      await peripheralManager.stopAdvertising();
      _isAdvertising = false;
      _logger.info('✅ Advertising stopped');
    } catch (e) {
      _logger.warning('⚠️ Failed to stop advertising: $e');
      // Non-critical - don't throw
    }
  }

  // 🔌 ========== PHASE 2B: CONNECTION HANDLERS ========== 🔌

  /// 📥 Handle incoming connection (we're peripheral, they're central)
  ///
  /// Called when a remote central connects to our advertising peripheral
  void handleCentralConnected(Central central) {
    final address = central.uuid.toString();

    if (_serverConnections.containsKey(address)) {
      _logger.warning('⚠️ Central already connected: ${_formatAddress(address)}');
      return;
    }

    _logger.info('📥 Central connected: ${_formatAddress(address)} (server connections: ${serverConnectionCount + 1}/${_limitConfig.maxServerConnections})');

    final connection = BLEServerConnection(
      address: address,
      central: central,
      connectedAt: DateTime.now(),
    );

    _serverConnections[address] = connection;
    _logger.info('📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)');

    // Update advertising state (may need to stop if at limit)
    _updateAdvertisingState();
  }

  /// 📤 Handle incoming disconnection (central disconnected from us)
  ///
  /// Called when a remote central disconnects from our peripheral
  void handleCentralDisconnected(Central central) {
    final address = central.uuid.toString();

    final connection = _serverConnections.remove(address);
    if (connection != null) {
      final duration = connection.connectedDuration;
      _logger.info('📤 Central disconnected: ${_formatAddress(address)} (connected for: ${duration.inSeconds}s, server connections: $serverConnectionCount/${_limitConfig.maxServerConnections})');
    } else {
      _logger.warning('⚠️ Unknown central disconnected: ${_formatAddress(address)}');
    }

    _logger.info('📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)');

    // Update advertising state (may need to resume if below limit)
    _updateAdvertisingState();
  }

  /// 📝 Handle characteristic subscription (central subscribed to our notifications)
  ///
  /// Called when a remote central subscribes to our characteristic
  void handleCharacteristicSubscribed(Central central, GATTCharacteristic characteristic) {
    final address = central.uuid.toString();

    final connection = _serverConnections[address];
    if (connection != null) {
      _serverConnections[address] = connection.copyWith(
        subscribedCharacteristic: characteristic,
      );
      _logger.info('📝 Central subscribed to notifications: ${_formatAddress(address)}');
    } else {
      _logger.warning('⚠️ Subscription from unknown central: ${_formatAddress(address)}');
    }
  }

  /// 🔍 Format address for logging (first 8 chars)
  String _formatAddress(String address) {
    return address.length > 8 ? '${address.substring(0, 8)}...' : address;
  }

  // ⚡ ========== PHASE 2B: POWER MODE MANAGEMENT ========== ⚡

  /// ⚡ Handle power mode changes: Adjust connection limits and RSSI threshold
  ///
  /// Called when user changes power mode or battery level triggers auto-change
  /// Enforces new connection limits by disconnecting oldest connections
  Future<void> handlePowerModeChange(PowerMode newMode) async {
    _logger.info('⚡ Power mode changed to: ${newMode.name}');

    final oldConfig = _limitConfig;
    final oldRssiThreshold = _rssiThreshold;

    _limitConfig = ConnectionLimitConfig.forPowerMode(newMode);
    _rssiThreshold = _getRssiThresholdForPowerMode(newMode);

    _logger.info('🎯 Connection limits updated: $oldConfig → $_limitConfig');
    _logger.info('📡 RSSI threshold updated: $oldRssiThreshold dBm → $_rssiThreshold dBm');

    // Enforce new limits
    await _enforceConnectionLimits();

    // Update advertising based on new limits
    await _updateAdvertisingState();
  }

  /// Get RSSI threshold for power mode (Phase 4: BitChat pattern)
  int _getRssiThresholdForPowerMode(PowerMode mode) {
    return switch (mode) {
      PowerMode.performance => -95,      // Accept all
      PowerMode.balanced => -85,         // Normal
      PowerMode.powerSaver => -75,       // Only good signals
      PowerMode.ultraLowPower => -65,    // Only excellent signals
    };
  }

  /// 🔨 Enforce connection limits: Disconnect oldest connections
  ///
  /// Called after power mode change to bring connections within new limits
  /// Uses FIFO strategy (disconnect oldest first)
  Future<void> _enforceConnectionLimits() async {
    // Check client connections
    final excessClients = _limitConfig.getExcessClientConnections(
      clientConnectionCount,
      totalConnectionCount,
    );

    if (excessClients > 0) {
      _logger.warning('⚠️ Excess client connections: $excessClients');
      await _disconnectOldestClients(excessClients);
    }

    // Check server connections
    final excessServers = serverConnectionCount - _limitConfig.maxServerConnections;
    final excessTotal = totalConnectionCount - _limitConfig.maxTotalConnections;

    if (excessServers > 0 || excessTotal > 0) {
      final toDisconnect = [excessServers, excessTotal].reduce((a, b) => a > b ? a : b);
      _logger.warning('⚠️ Excess server connections: $toDisconnect');
      await _disconnectOldestServers(toDisconnect);
    }
  }

  /// 🔌 Disconnect oldest client connections (FIFO strategy)
  Future<void> _disconnectOldestClients(int count) async {
    final sorted = _clientConnections.values.toList()
      ..sort((a, b) => a.connectedAt.compareTo(b.connectedAt));

    for (int i = 0; i < count && i < sorted.length; i++) {
      final conn = sorted[i];
      _logger.info('🔌 Disconnecting oldest client: ${_formatAddress(conn.address)}');
      try {
        await centralManager.disconnect(conn.peripheral);
        // Connection will be removed in the disconnect event handler
      } catch (e) {
        _logger.warning('⚠️ Failed to disconnect ${_formatAddress(conn.address)}: $e');
        // Remove from map anyway
        _clientConnections.remove(conn.address);
      }
    }
  }

  /// 🔌 Disconnect oldest server connections (FIFO strategy)
  Future<void> _disconnectOldestServers(int count) async {
    final sorted = _serverConnections.values.toList()
      ..sort((a, b) => a.connectedAt.compareTo(b.connectedAt));

    for (int i = 0; i < count && i < sorted.length; i++) {
      final conn = sorted[i];
      _logger.info('🔌 Disconnecting oldest server connection: ${_formatAddress(conn.address)}');

      // Note: PeripheralManager doesn't have explicit disconnect for incoming connections
      // Platform will handle cleanup. We remove from our tracking:
      _serverConnections.remove(conn.address);
    }

    // Update advertising state after removing connections
    await _updateAdvertisingState();
  }

void handleBluetoothStateChange(BluetoothLowEnergyState state) {
  if (state == BluetoothLowEnergyState.poweredOn) {
    if (_lastConnectedDevice != null && !hasBleConnection) {
      _logger.info('Bluetooth powered on - starting immediate reconnection');

      stopConnectionMonitoring();

      // Reduce delay for first-time connections
      Timer(Duration(milliseconds: 800), () {
        _isReconnection = true;
        startConnectionMonitoring();
      });
    } else {
      _logger.info('Bluetooth powered on - no previous device, skipping reconnection');
    }
  } else if (state == BluetoothLowEnergyState.poweredOff) {
    if (hasBleConnection) {
      _logger.info('Bluetooth powered off - preserving device for reconnection');
      _lastConnectedDevice = _connectedDevice;
    }
    clearConnectionState(keepMonitoring: false);
  }
}

  /// Connect to a BLE peripheral device
  ///
  /// Phase 4: RSSI-based connection filtering
  /// - Optional [rssi] parameter allows filtering weak signals in low power modes
  /// - Threshold varies by power mode: -95 (performance) to -65 (ultra low)
  Future<void> connectToDevice(Peripheral device, {int? rssi}) async {
    final address = device.uuid.toString();

    try {
      // Phase 4: RSSI-based connection filtering
      if (rssi != null && rssi < _rssiThreshold) {
        _logger.info(
          '📡 Skipping weak device: RSSI $rssi dBm < threshold $_rssiThreshold dBm '
          '(${_formatAddress(address)})',
        );
        return; // Silently skip weak signals
      }

      // Log RSSI if available
      if (rssi != null) {
        _logger.fine('📡 Device RSSI: $rssi dBm (threshold: $_rssiThreshold dBm)');
      }

      // Check connection limits
      if (!canAcceptClientConnection) {
        _logger.warning('⚠️ Cannot accept client connection (limit: ${_limitConfig.maxClientConnections}, current: $clientConnectionCount, total: $totalConnectionCount)');
        throw ConnectionLimitException(
          'Client connection limit reached',
          currentCount: clientConnectionCount,
          maxCount: _limitConfig.maxClientConnections,
        );
      }

      _logger.info('🔌 Connecting to ${_formatAddress(address)}...');

      await Future.delayed(Duration(milliseconds: 500));

      await centralManager.connect(device).timeout(
        Duration(seconds: 10),
        onTimeout: () => throw Exception('Connection timeout after 10 seconds'),
      );

      // Create client connection object
      var connection = BLEClientConnection(
        address: address,
        peripheral: device,
        connectedAt: DateTime.now(),
      );

      _clientConnections[address] = connection;
      _lastConnectedDevice = device;

      _logger.info('✅ Connected to ${_formatAddress(address)} (client connections: $clientConnectionCount/${_limitConfig.maxClientConnections})');
      _logger.info('📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)');

      onConnectionChanged?.call(device);
      
      // Discover GATT services with retry logic
      List<GATTService> services = [];
      GATTService? messagingService;
      
      for (int retry = 0; retry < 3; retry++) {
        try {
          _logger.info('Discovering services, attempt ${retry + 1}/3');
          services = await centralManager.discoverGATT(device);
          
          messagingService = services.firstWhere(
            (service) => service.uuid == BLEConstants.serviceUUID,
          );
          
          _logger.info('✅ Messaging service found on attempt ${retry + 1}');
          break;
          
        } catch (e) {
          _logger.warning('❌ Service discovery failed on attempt ${retry + 1}: $e');
          
          if (retry < 2) {
            await Future.delayed(Duration(milliseconds: 1000));
          } else {
            throw Exception('Messaging service not found after 3 attempts');
          }
        }
      }
      
      if (messagingService == null) {
        throw Exception('Messaging service not found after retries');
      }
      
      // Find the message characteristic
      final messageChar = messagingService.characteristics.firstWhere(
        (char) => char.uuid == BLEConstants.messageCharacteristicUUID,
        orElse: () => throw Exception('Message characteristic not found'),
      );

      // Update connection with discovered characteristic
      connection = _clientConnections[address]!.copyWith(
        messageCharacteristic: messageChar,
      );
      _clientConnections[address] = connection;

      onCharacteristicFound?.call(messageChar);
      
      // Enable notifications
      if (messageChar.properties.contains(GATTCharacteristicProperty.notify)) {
        try {
          await centralManager.setCharacteristicNotifyState(
            device,
            messageChar,
            state: true,
          );
          _logger.info('✅ Notifications enabled successfully');
          
          await Future.delayed(Duration(milliseconds: 500));
          
        } catch (e) {
          _logger.severe('CRITICAL: Failed to enable notifications: $e');
          throw Exception('Cannot enable notifications - connection unusable');
        }
      }
      
      _logger.info('🔐 BLE Connected - starting protocol setup');
      _updateConnectionState(ChatConnectionState.connecting);

      await _detectOptimalMTU(device, address);

      _logger.info('🔑 Triggering identity exchange');
      onConnectionComplete?.call();

      _isReconnection = false;

    } catch (e) {
      _logger.severe('❌ Connection failed: $e');
      _isReconnection = false;

      // Remove failed connection from map
      _clientConnections.remove(address);

      clearConnectionState();
      rethrow;
    }
  }
  
  Future<void> _detectOptimalMTU(Peripheral device, String address) async {
    try {
      _logger.info('📏 Attempting MTU detection...');

      int negotiatedMTU = 23;

      if (Platform.isAndroid) {
        try {
          negotiatedMTU = await centralManager.requestMTU(device, mtu: 250);
          _logger.info('✅ Successfully negotiated larger MTU: $negotiatedMTU bytes');
        } catch (e) {
          _logger.warning('⚠️ MTU negotiation failed, using default 23: $e');
        }
      }

      final maxWriteLength = await centralManager.getMaximumWriteLength(
        device,
        type: GATTCharacteristicWriteType.withResponse,
      );

      final mtu = maxWriteLength.clamp(20, negotiatedMTU - 3);

      // Update connection with MTU
      final connection = _clientConnections[address];
      if (connection != null) {
        _clientConnections[address] = connection.copyWith(mtu: mtu);
      }

      _logger.info('✅ MTU detection successful: $mtu bytes');

      onMtuDetected?.call(mtu);

    } catch (e) {
      _logger.warning('❌ MTU detection completely failed: $e');
      const fallbackMtu = 20;

      // Update connection with fallback MTU
      final connection = _clientConnections[address];
      if (connection != null) {
        _clientConnections[address] = connection.copyWith(mtu: fallbackMtu);
      }

      _logger.info('⚠️ Using conservative fallback MTU: $fallbackMtu bytes');
      onMtuDetected?.call(fallbackMtu);
    }
  }

  void setMessageOperationInProgress(bool inProgress) {
    _messageOperationInProgress = inProgress;
    if (inProgress) {
      _logger.fine('💬 Message operation started - pausing health checks');
    } else {
      _logger.fine('✅ Message operation completed - resuming health checks');
    }
  }
  
  Future<Peripheral?> scanForSpecificDevice({Duration timeout = const Duration(seconds: 10)}) async {
    if (centralManager.state != BluetoothLowEnergyState.poweredOn) {
      return null;
    }
    
    _logger.info('🔍 Scanning for service-advertising devices only');
    
    final completer = Completer<Peripheral?>();
    StreamSubscription? discoverySubscription;
    Timer? timeoutTimer;
    
    try {
      discoverySubscription = centralManager.discovered.listen((event) {
        _logger.info('✅ Found device advertising our service: ${event.peripheral.uuid}');
        if (!completer.isCompleted) {
          completer.complete(event.peripheral);
        }
      });
      
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          _logger.info('⏰ Service scan timeout');
          completer.complete(null);
        }
      });
      
      await Future.delayed(Duration(milliseconds: 500));
      
      await centralManager.startDiscovery(serviceUUIDs: [BLEConstants.serviceUUID]);
      
      return await completer.future;
      
    } finally {
      await centralManager.stopDiscovery();
      discoverySubscription?.cancel();
      timeoutTimer?.cancel();
    }
  }
  
  /// 🔌 Disconnect all client connections
  Future<void> disconnectAll() async {
    _logger.info('🔌 Disconnecting all connections');

    stopConnectionMonitoring();

    // Disconnect all clients
    for (final conn in _clientConnections.values.toList()) {
      try {
        _logger.info('🔌 Disconnecting client: ${_formatAddress(conn.address)}');
        await centralManager.disconnect(conn.peripheral);
      } catch (e) {
        _logger.warning('⚠️ Failed to disconnect ${_formatAddress(conn.address)}: $e');
      }
    }

    // Stop advertising to clear server connections
    await _stopAdvertising();

    clearConnectionState();
  }

  /// 🔌 Disconnect specific client connection by address
  Future<void> disconnectClient(String address) async {
    final connection = _clientConnections[address];
    if (connection == null) {
      _logger.warning('⚠️ Cannot disconnect: client not found ${_formatAddress(address)}');
      return;
    }

    try {
      _logger.info('🔌 Disconnecting client: ${_formatAddress(address)}');
      await centralManager.disconnect(connection.peripheral);
      _clientConnections.remove(address);
      _logger.info('✅ Client disconnected: ${_formatAddress(address)}');
    } catch (e) {
      _logger.warning('⚠️ Failed to disconnect ${_formatAddress(address)}: $e');
      // Remove from map anyway
      _clientConnections.remove(address);
    }
  }

  /// 🔌 Legacy disconnect method (disconnects first client for backward compatibility)
  Future<void> disconnect() async {
    if (_clientConnections.isEmpty) {
      _logger.info('🔌 No connections to disconnect');
      clearConnectionState();
      return;
    }

    final firstConnection = _clientConnections.values.first;
    await disconnectClient(firstConnection.address);
  }

  void triggerReconnection() {
    if (!_isMonitoring) {
      startConnectionMonitoring();
    } else if (_monitorState != ConnectionMonitorState.reconnecting) {
      _monitorState = ConnectionMonitorState.reconnecting;
      _monitoringInterval = minInterval;
      _scheduleNextCheck();
    }
    _logger.info('Triggering immediate reconnection...');
  }
  
  void clearConnectionState({bool keepMonitoring = false, String? contactId}) {
    _logger.info('🧹 Clearing connection state');

    // 🧹 CLEANUP: Remove orphaned ephemeral contacts immediately on disconnect
    // No need to wait for app restart - clean as we go!
    if (contactId != null) {
      _cleanupEphemeralContactIfOrphaned(contactId);
    } else {
      // Cleanup all client connections if no specific contactId
      for (final conn in _clientConnections.values) {
        _cleanupEphemeralContactIfOrphaned(conn.address);
      }
    }

    _clientConnections.clear();
    _serverConnections.clear();
    _lastConnectedDevice = null;

    _reconnectAttempts = 0;
    _isReconnection = false;

    _logger.info('📊 Connections cleared (client: 0, server: 0)');

    if (!keepMonitoring) {
      stopConnectionMonitoring();
    }

    onConnectionChanged?.call(null);
    onCharacteristicFound?.call(null);
    onMtuDetected?.call(null);
  }
  
  /// 🧹 Clean up ephemeral contact immediately if they have no chat history
  /// Called on disconnect to keep database clean without waiting for app restart
  void _cleanupEphemeralContactIfOrphaned(String contactId) async {
    try {
      _logger.info('🧹 Checking if contact needs cleanup: ${contactId.length > 8 ? '${contactId.substring(0, 8)}...' : contactId}');
      
      // Import repositories (will need to add imports at top of file)
      final contactRepo = ContactRepository();
      final messageRepo = MessageRepository();
      
      // Get contact info
      final contact = await contactRepo.getContact(contactId);
      if (contact == null) {
        _logger.fine('Contact not found - nothing to cleanup');
        return;
      }
      
      // Skip if contact is verified (paired/trusted)
      if (contact.trustStatus == TrustStatus.verified) {
        _logger.fine('Contact is verified - keeping');
        return;
      }
      
      // Check for chat history
      final chatId = ChatUtils.generateChatId(contactId);
      final messages = await messageRepo.getMessages(chatId);
      
      if (messages.isEmpty) {
        // No chat history - delete the ephemeral contact
        final deleted = await contactRepo.deleteContact(contactId);
        if (deleted) {
          _logger.info('✅ Deleted orphaned ephemeral contact: ${contact.displayName}');
        }
      } else {
        _logger.fine('Contact has ${messages.length} message(s) - keeping');
      }
    } catch (e) {
      _logger.warning('Failed to cleanup ephemeral contact: $e');
      // Non-critical failure - don't throw
    }
  }

  /// 🎯 NEW: Check if current connection can serve as relay for pending messages
  bool _hasViableRelayConnection() {
    try {
      // Must have active connection
      if (!hasConnection || _connectedDevice == null) {
        return false;
      }

      // Must have message characteristic to relay messages
      if (_messageCharacteristic == null) {
        return false;
      }

      // Connection must be ready (completed identity exchange)
      if (!_isReady) {
        return false;
      }

      _logger.info('🔄 Viable relay connection detected: ${_connectedDevice?.uuid}');
      return true;

    } catch (e) {
      _logger.warning('Error checking relay viability: $e');
      return false;
    }
  }

  void dispose() {
    stopConnectionMonitoring();
  }
}