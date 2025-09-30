import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/models/connection_state.dart';

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

bool _isPeripheralMode = false;
  
  // Connection state
  Peripheral? _connectedDevice;
  Peripheral? _lastConnectedDevice;
  GATTCharacteristic? _messageCharacteristic;
  int? _mtuSize;
  
  // Simplified monitoring system
  Timer? _monitoringTimer;
  bool _isMonitoring = false;
  int _monitoringInterval = 3000; // milliseconds
  int _reconnectAttempts = 0;
  bool _messageOperationInProgress = false;
  bool _pairingInProgress = false;
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
  });
  
  // Getters
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
  void setPeripheralMode(bool isPeripheral) {
    _isPeripheralMode = isPeripheral;
    if (isPeripheral) {
      _logger.info('Connection manager set to peripheral mode - no reconnections');
      stopConnectionMonitoring();
    }
  }

  void startConnectionMonitoring() {

    if (_isPeripheralMode) {
      _logger.warning('Ignoring connection monitoring request - peripheral mode active');
      return;
    }

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
    _logger.info('Pausing health checks during pairing');
  } else {
    _logger.info('Resuming health checks after pairing');
  }
}


  Future<void> _performHealthCheck() async {
      if (_pairingInProgress) {
    _logger.info('Skipping health check - pairing in progress');
    _scheduleNextCheck();
    return;
  }

  if (_messageOperationInProgress || !hasBleConnection || _messageCharacteristic == null) {
    _scheduleNextCheck();
    return;
  }
    
    try {
      final pingData = Uint8List.fromList([0x00]);
      
      await centralManager.writeCharacteristic(
        _connectedDevice!,
        _messageCharacteristic!,
        value: pingData,
        type: GATTCharacteristicWriteType.withResponse,
      ).timeout(Duration(seconds: 3));
      
      _logger.info('Health check passed (${_monitoringInterval}ms interval)');
      
    } catch (e) {
      _logger.warning('Health check failed: $e');
      
      // Switch to reconnection mode
      _monitorState = ConnectionMonitorState.reconnecting;
      _monitoringInterval = minInterval; // Reset interval
      
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
      _logger.warning('Max reconnection attempts reached');
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
    _logger.info('Reconnect attempt $_reconnectAttempts/$maxReconnectAttempts');

    try {
      final foundDevice = await scanForSpecificDevice(timeout: Duration(seconds: 8));
      
      if (foundDevice != null) {
        _isReconnection = true;
        await connectToDevice(foundDevice);
        
        // Success - switch to health checking
        _reconnectAttempts = 0;
        _monitorState = ConnectionMonitorState.healthChecking;
        _monitoringInterval = minInterval;
        _isReconnection = false;
        _logger.info('Reconnection successful');
      }
    } catch (e) {
      _logger.warning('Reconnection failed: $e');
    }
  }

  void startHealthChecks() {
    if (!_isMonitoring) {
      startConnectionMonitoring();
    }
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
      _logger.info('Bluetooth powered on - peripheral mode or no previous device, skipping reconnection');
    }
  } else if (state == BluetoothLowEnergyState.poweredOff) {
    if (hasBleConnection) {
      _logger.info('Bluetooth powered off - preserving device for reconnection');
      _lastConnectedDevice = _connectedDevice;
    }
    clearConnectionState(keepMonitoring: false);
  }
}
  
  Future<void> connectToDevice(Peripheral device) async {
    try {
      _logger.info('Connecting to ${device.uuid}...');
      
      await Future.delayed(Duration(milliseconds: 500));
      
      await centralManager.connect(device).timeout(
        Duration(seconds: 10),
        onTimeout: () => throw Exception('Connection timeout after 10 seconds'),
      );
      
      _connectedDevice = device;
      _lastConnectedDevice = device;
      onConnectionChanged?.call(_connectedDevice);
      
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
      _messageCharacteristic = messagingService.characteristics.firstWhere(
        (char) => char.uuid == BLEConstants.messageCharacteristicUUID,
        orElse: () => throw Exception('Message characteristic not found'),
      );
      
      onCharacteristicFound?.call(_messageCharacteristic);
      
      // Enable notifications
      if (_messageCharacteristic!.properties.contains(GATTCharacteristicProperty.notify)) {
        try {
          await centralManager.setCharacteristicNotifyState(
            device, 
            _messageCharacteristic!,
            state: true,
          );
          _logger.info('Notifications enabled successfully');
          
          await Future.delayed(Duration(milliseconds: 500));
          
        } catch (e) {
          _logger.severe('CRITICAL: Failed to enable notifications: $e');
          throw Exception('Cannot enable notifications - connection unusable');
        }
      }
      
      _logger.info('BLE Connected - starting protocol setup');
      _updateConnectionState(ChatConnectionState.connecting);
      await _detectOptimalMTU();
      _logger.info('Triggering identity exchange');
      onConnectionComplete?.call();

      _isReconnection = false;
      
    } catch (e) {
      _logger.severe('Connection failed: $e');
      _isReconnection = false;
      clearConnectionState();
      rethrow;
    }
  }
  
  Future<void> _detectOptimalMTU() async {
    if (_connectedDevice == null) return;
    
    try {
      _logger.info('Attempting MTU detection...');
      
      int negotiatedMTU = 23;
      
      if (Platform.isAndroid) {
        try {
          negotiatedMTU = await centralManager.requestMTU(_connectedDevice!, mtu: 250);
          _logger.info('Successfully negotiated larger MTU: $negotiatedMTU bytes');
        } catch (e) {
          _logger.warning('MTU negotiation failed, using default 23: $e');
        }
      }
      
      final maxWriteLength = await centralManager.getMaximumWriteLength(
        _connectedDevice!,
        type: GATTCharacteristicWriteType.withResponse,
      );
      
      _mtuSize = maxWriteLength.clamp(20, negotiatedMTU - 3);
      _logger.info('✅ MTU detection successful: $_mtuSize bytes');
      
      onMtuDetected?.call(_mtuSize);
      
    } catch (e) {
      _logger.warning('❌ MTU detection completely failed: $e');
      _mtuSize = 20;
      _logger.info('Using conservative fallback MTU: $_mtuSize bytes');
      onMtuDetected?.call(_mtuSize);
    }
  }

  void setMessageOperationInProgress(bool inProgress) {
    _messageOperationInProgress = inProgress;
    if (inProgress) {
      _logger.info('Message operation started - pausing health checks');
    } else {
      _logger.info('Message operation completed - resuming health checks');
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
  
  Future<void> disconnect() async {
    stopConnectionMonitoring();
    if (_connectedDevice != null) {
      await centralManager.disconnect(_connectedDevice!);
    }
    clearConnectionState();
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
  
  void clearConnectionState({bool keepMonitoring = false}) {
    _connectedDevice = null;
    _messageCharacteristic = null;
    _mtuSize = null;
    _lastConnectedDevice = null;
    
    _reconnectAttempts = 0;
    _isReconnection = false;
    
    if (!keepMonitoring) {
      stopConnectionMonitoring();
    }
    
    onConnectionChanged?.call(null);
    onCharacteristicFound?.call(null);
    onMtuDetected?.call(null);
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