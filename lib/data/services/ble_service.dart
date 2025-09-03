import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/models/connection_info.dart';
import 'ble_connection_manager.dart';
import 'ble_message_handler.dart';
import 'ble_state_manager.dart';
import '../../core/models/protocol_message.dart';

class BLEService {
  final _logger = Logger('BLEService');
  
  // Managers
  final CentralManager centralManager = CentralManager();
  final PeripheralManager peripheralManager = PeripheralManager();
  
  // Sub-components
  late final BLEConnectionManager _connectionManager;
  late final BLEMessageHandler _messageHandler;
  late final BLEStateManager _stateManager;
  
  // Streams for UI
  StreamController<ConnectionInfo>? _connectionInfoController;
  StreamController<List<Peripheral>>? _devicesController;
  StreamController<String>? _messagesController;

  
  // Discovery management
  final List<Peripheral> _discoveredDevices = [];

  // Peripheral mode connection tracking
Central? _connectedCentral;
GATTCharacteristic? _connectedCharacteristic;

int? _peripheralNegotiatedMTU;
  
  // Stream getters
  Stream<ConnectionInfo> get connectionInfo => _connectionInfoController!.stream;
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;
  Stream<List<Peripheral>> get discoveredDevices => _devicesController!.stream;
  Stream<String> get receivedMessages => _messagesController!.stream;


  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
  isConnected: false,
  isReady: false,
  statusMessage: 'Disconnected',
);
  
  // State getters (deleginitializeated)
  BluetoothLowEnergyState get state => centralManager.state;
  bool get isConnected {
  // Central mode: BLE connected + identity exchanged
  if (!_stateManager.isPeripheralMode) {
    return _connectionManager.connectedDevice != null && 
           _stateManager.otherUserName != null && 
           _stateManager.otherUserName!.isNotEmpty;
  }
  
  // Peripheral mode: has connected central + identity exchanged  
  return _connectedCentral != null && 
         _stateManager.otherUserName != null && 
         _stateManager.otherUserName!.isNotEmpty;
}
  bool get isPeripheralMode => _stateManager.isPeripheralMode;
  bool get isMonitoring => _connectionManager.isMonitoring;
  Peripheral? get connectedDevice => _connectionManager.connectedDevice;
  String? get myUserName => _stateManager.myUserName;
  String? get otherUserName => _stateManager.otherUserName;
  String? get otherDevicePersistentId => _stateManager.otherDevicePersistentId;
  String? get myPersistentId => _stateManager.myPersistentId;
  bool get isActivelyReconnecting => 
    !_stateManager.isPeripheralMode && _connectionManager.isActivelyReconnecting;

  
  Future<void> initialize() async {
    // Dispose existing controllers if they exist
    _connectionInfoController?.close();
    _devicesController?.close();
    _messagesController?.close();

    // Initialize new stream controllers
    _connectionInfoController = StreamController<ConnectionInfo>.broadcast();
    _devicesController = StreamController<List<Peripheral>>.broadcast();
    _messagesController = StreamController<String>.broadcast();


if (peripheralManager.state == BluetoothLowEnergyState.poweredOn && _stateManager.isPeripheralMode) {
  _updateConnectionInfo(isAdvertising: true, statusMessage: 'Discoverable');
} else {
  _updateConnectionInfo(statusMessage: 'Ready to scan');
}
    
    // Initialize managers
    centralManager.logLevel = Level.INFO;
    peripheralManager.logLevel = Level.INFO;
    
    // Initialize sub-components
    _connectionManager = BLEConnectionManager(
      centralManager: centralManager,
      peripheralManager: peripheralManager,
    );
    
    _messageHandler = BLEMessageHandler();
    _stateManager = BLEStateManager();
    
    // Wire up callbacks
     _connectionManager.onConnectionChanged = (device) {
  final isConnected = device != null;
  _logger.info('DEBUG: Emitting connection state: $isConnected (device: ${device?.uuid})');
  
  // Only emit for central mode - peripheral uses identity-based connection
  if (!_stateManager.isPeripheralMode) {
    _updateConnectionInfo(isConnected: isConnected);
  }
};

_connectionManager.onConnectionInfoChanged = (info) {
  _updateConnectionInfo(
    isConnected: info.deviceId != null,
    statusMessage: info.error ?? 'Connected',
  );
};

    _connectionManager.onMonitoringChanged = (isMonitoring) {
  _updateConnectionInfo(isReconnecting: isMonitoring);
};

    _connectionManager.onConnectionComplete = () async {
  _logger.info('Connection complete - performing name exchange');
  
  // CRITICAL: Stop discovery after successful connection
  try {
    await centralManager.stopDiscovery();
    _logger.info('Stopped discovery after successful connection');
  } catch (e) {
    // Ignore
  }
  
  await _performNameExchangeWithRetry();
};
    
    _connectionManager.onCharacteristicFound = (characteristic) {
      // Characteristic found, ready for messaging
    };
    
    _connectionManager.onMtuDetected = (mtu) {
      _logger.info('MTU detected: $mtu');
    };
    
    _stateManager.onNameChanged = (name) {
  _logger.info('DEBUG: Name change received: "$name" (peripheral mode: ${_stateManager.isPeripheralMode})');
  
  if (_stateManager.isPeripheralMode) {
    // Peripheral mode: only update if we have a connected central
    if (_connectedCentral != null && name != null && name.isNotEmpty) {
      _logger.info('Peripheral: Identity exchange complete with $name');
      _updateConnectionInfo(
        isConnected: true,
        isReady: true,
        otherUserName: name,
        statusMessage: 'Ready to chat',
        isAdvertising: false
      );
    } else if (name == null && _connectedCentral == null) {
      // Only clear if we're actually disconnected
      _updateConnectionInfo(
        isConnected: false,
        isReady: false,
        otherUserName: null,
        statusMessage: 'Advertising',
        isAdvertising: true
      );
    }
  } else {
    // Central mode: only update if we have an actual BLE connection
    if (_connectionManager.connectedDevice != null) {
      if (name != null && name.isNotEmpty) {
        _updateConnectionInfo(
          isConnected: true,  // Now we're fully connected
          isReady: true,
          otherUserName: name,
          statusMessage: 'Ready to chat'
        );
      } else {
        // Name cleared but still have BLE connection
        _updateConnectionInfo(
          isConnected: true,  // Still BLE connected
          isReady: false,    // But not ready for chat
          otherUserName: null,
          statusMessage: 'Exchanging names...'
        );
      }
    } else if (name == null) {
      // No BLE connection and no name - fully disconnected
      _updateConnectionInfo(
        isConnected: false,
        isReady: false,
        otherUserName: null,
        statusMessage: 'Disconnected'
      );
    }
  }
};
    
    await _stateManager.initialize();
    
    // Setup event listeners
    _setupEventListeners();
  }

void _updateConnectionInfo({
  bool? isConnected,
  bool? isReady,
  String? otherUserName,
  String? statusMessage,
  bool? isScanning,
  bool? isAdvertising, 
  bool? isReconnecting,
}) {
  // Don't let scanning updates override connection state
  if (isScanning != null && isConnected == null && isReady == null) {
    // This is just a scanning update, preserve connection state
    _currentConnectionInfo = _currentConnectionInfo.copyWith(
      isScanning: isScanning,
      statusMessage: statusMessage ?? (_currentConnectionInfo.isConnected 
        ? (_currentConnectionInfo.isReady ? 'Ready to chat' : 'Exchanging names...') 
        : 'Disconnected'),
    );
  } else if (isConnected == false) {
    // Explicit disconnection
    _currentConnectionInfo = ConnectionInfo(
      isConnected: false,
      isReady: false,
      otherUserName: otherUserName,
      statusMessage: statusMessage ?? 'Disconnected',
      isScanning: isScanning ?? false,
      isAdvertising: isAdvertising ?? _currentConnectionInfo.isAdvertising,
      isReconnecting: isReconnecting ?? false,
    );
  } else {
    // Normal update
    _currentConnectionInfo = _currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );
  }
  
  _connectionInfoController?.add(_currentConnectionInfo);
  _logger.info('Connection info updated: ${_currentConnectionInfo.statusMessage}');
}

  void _setupEventListeners() {
    // Central manager state changes
   centralManager.stateChanged.listen((event) async {
  _logger.info('Central BLE State changed: ${event.state}');
  
if (event.state == BluetoothLowEnergyState.poweredOff) {
  _updateConnectionInfo(isConnected: false, isReady: false, statusMessage: 'Bluetooth off');
  _stateManager.clearOtherUserName();
} else if (event.state == BluetoothLowEnergyState.poweredOn) {
  if (_stateManager.isPeripheralMode) {
    _updateConnectionInfo(isAdvertising: true, statusMessage: 'Discoverable');
  } else {
    _updateConnectionInfo(statusMessage: 'Ready to scan');
  }
}
  
  // Handle state changes for reconnection
  _connectionManager.handleBluetoothStateChange(event.state);
  
  if (event.state == BluetoothLowEnergyState.unauthorized) {
    try {
      _logger.info('Requesting BLE permissions...');
      final granted = await centralManager.authorize();
      _logger.info('Permission granted: $granted');
    } catch (e) {
      _logger.warning('Permission request failed: $e');
    }
  }
});
    
    // Peripheral manager state changes
   peripheralManager.stateChanged.listen((event) async {
  _logger.info('Peripheral BLE State changed: ${event.state}');

if (event.state == BluetoothLowEnergyState.poweredOff) {
  _updateConnectionInfo(isConnected: false, isReady: false, isAdvertising: false, statusMessage: 'Bluetooth off');
  _stateManager.clearOtherUserName();
  _connectedCentral = null;
  _connectedCharacteristic = null;
}
  
  if (event.state == BluetoothLowEnergyState.unauthorized) {
    try {
      _logger.info('Requesting Peripheral BLE permissions...');
      final granted = await peripheralManager.authorize();
      _logger.info('Peripheral permission granted: $granted');
    } catch (e) {
      _logger.warning('Peripheral permission request failed: $e');
    }
  }
  
  if (event.state == BluetoothLowEnergyState.poweredOn && _stateManager.isPeripheralMode) {
  _logger.info('🔄 Bluetooth restarted in peripheral mode - restarting advertising...');
  
  _updateConnectionInfo(isAdvertising: false, statusMessage: 'Starting advertising...');
  
  await Future.delayed(Duration(milliseconds: 2000));
  
  try {
    await peripheralManager.stopAdvertising();
    await startAsPeripheral();
    _logger.info('✅ Auto-restart advertising successful!');
    
    _updateConnectionInfo(isAdvertising: true, isConnected: false, statusMessage: 'Advertising - waiting for connection');
    
  } catch (e) {
    _logger.severe('❌ Auto-restart advertising failed: $e');
    _updateConnectionInfo(isAdvertising: false, statusMessage: 'Advertising failed');
  }
}
  
  if (event.state == BluetoothLowEnergyState.poweredOff) {
_updateConnectionInfo(isConnected: false, isReady: false, isAdvertising: false, statusMessage: 'Stopped');
_stateManager.clearOtherUserName();
_connectedCentral = null;
_connectedCharacteristic = null;
  }
});


peripheralManager.mtuChanged.listen((event) {
  _logger.info('Peripheral MTU changed: ${event.mtu} for ${event.central.uuid}');
  _peripheralNegotiatedMTU = event.mtu;
});

centralManager.discovered.listen((event) {
  final device = event.peripheral;
  
  // Remove any existing entry for this device first
  _discoveredDevices.removeWhere((d) => d.uuid == device.uuid);
  
  // Add the fresh entry
  _discoveredDevices.add(device);
  
  _devicesController?.add(List.from(_discoveredDevices));
  _logger.info('Device list updated: ${_discoveredDevices.length} devices');
});
    
    // Connection state changes
centralManager.connectionStateChanged.listen((event) {
  _logger.info('Connection state: ${event.peripheral.uuid} → ${event.state}');
  
  if (event.state == ConnectionState.disconnected) {
    // Remove disconnected device from discovery list
    _discoveredDevices.removeWhere((d) => d.uuid == event.peripheral.uuid);
    _devicesController?.add(List.from(_discoveredDevices));
    
    if (_connectionManager.connectedDevice?.uuid == event.peripheral.uuid) {
      _logger.info('Our device disconnected - clearing state');
      
      _updateConnectionInfo(
        isConnected: false, 
        isReady: false, 
        otherUserName: null,  // Clear the name
        statusMessage: 'Disconnected'
      );
      
      _connectionManager.clearConnectionState(keepMonitoring: _connectionManager.isMonitoring);
      _stateManager.clearOtherUserName();
    }
  }
});

// Peripheral connection state changes (Android only)
if (Platform.isAndroid) {
  peripheralManager.connectionStateChanged.listen((event) {
    if (!_stateManager.isPeripheralMode) {
      return;  // Ignore if not in peripheral mode
    }
    
    _logger.info('Peripheral connection state: ${event.central.uuid} → ${event.state}');
    
    if (event.state == ConnectionState.connected) {
      _logger.info('Central connected to our peripheral: ${event.central.uuid}');
      _connectedCentral = event.central;
      
      _updateConnectionInfo(
        isConnected: false,  // Not ready yet
        isReady: false,
        statusMessage: 'Connected - exchanging names...',
        isAdvertising: false
      );
      
    } else if (event.state == ConnectionState.disconnected) {
      if (_connectedCentral?.uuid == event.central.uuid) {
        _logger.info('Connected central disconnected from our peripheral');
        _connectedCentral = null;
        _connectedCharacteristic = null;
        _stateManager.clearOtherUserName();
        _updateConnectionInfo(
          isConnected: false, 
          isReady: false,
          otherUserName: null,
          statusMessage: 'Advertising',
          isAdvertising: true
        );
      }
    }
  });
}
    
    // Characteristic notifications (received messages)
    centralManager.characteristicNotified.listen((event) async {
      if (event.characteristic.uuid == BLEConstants.messageCharacteristicUUID) {
        await _handleReceivedData(event.value, isFromPeripheral: false);
      }
    });
    
    // Peripheral write requests (received messages in peripheral mode)
    peripheralManager.characteristicWriteRequested.listen((event) async {
  try {
    // Set connected central if not already set
    if (_connectedCentral == null) {
      _connectedCentral = event.central;
      _logger.info('Setting connected central from write request: ${event.central.uuid}');
    }
    
    // Always update the characteristic reference
    _connectedCharacteristic = event.characteristic;
    
    await _handleReceivedData(event.request.value, isFromPeripheral: true, central: event.central, characteristic: event.characteristic);
    await peripheralManager.respondWriteRequest(event.request);
  } catch (e) {
    _logger.severe('Error handling write request: $e');
    try {
      await peripheralManager.respondWriteRequest(event.request);
    } catch (responseError) {
      _logger.severe('Failed to respond to write request: $responseError');
    }
  }
});
  }

Future<String> getMyPublicKey() async {
  return await _stateManager.getMyPersistentId();
}
  
Future<void> _handleReceivedData(Uint8List data, {required bool isFromPeripheral, Central? central, GATTCharacteristic? characteristic}) async {
  // Handle protocol identity messages ONLY
try {
  final protocolMessage = ProtocolMessage.fromBytes(data);
  if (protocolMessage.type == ProtocolMessageType.identity) {
    final publicKey = protocolMessage.identityPublicKey ?? protocolMessage.identityDeviceIdCompat!;
  final displayName = protocolMessage.identityDisplayName!;
 
     _stateManager.setOtherDeviceIdentity(publicKey, displayName);
  await _stateManager.saveContact(publicKey, displayName);
     _logger.info('Received public key identity: $displayName (${publicKey.substring(0, 16)}...)');
    
    // AUTO-RESPOND: If we're in peripheral mode, send our identity back immediately
    if (isFromPeripheral && central != null && characteristic != null && _stateManager.myUserName != null) {
      try {
        final myPersistentId = await _stateManager.getMyPersistentId();
        
        final responseIdentity = ProtocolMessage.identity(
          publicKey: myPersistentId, 
          displayName: _stateManager.myUserName!,
        );

        await peripheralManager.notifyCharacteristic(
          central,
          characteristic,
          value: responseIdentity.toBytes(),
        );

        _logger.info('Auto-sent peripheral identity response: ${_stateManager.myUserName} ($myPersistentId)');
      } catch (e) {
        _logger.warning('Failed to send auto-response identity: $e');
      }
    }
    return;
  }
} catch (e) {
  // Not a protocol message, continue to regular message processing
}
  
  // Process regular chat messages
  String? extractedMessageId;
  final content = await _messageHandler.processReceivedData(
    data,
    onMessageIdFound: (id) => extractedMessageId = id,
  );
  
  if (content != null) {
    _messagesController?.add(content);
    
    // Send ACK using ProtocolMessage format (peripheral mode only)
    if (isFromPeripheral && central != null && characteristic != null && extractedMessageId != null) {
      try {
        final protocolAck = ProtocolMessage.ack(
          originalMessageId: extractedMessageId!,
        );
        
        await peripheralManager.notifyCharacteristic(
          central,
          characteristic,
          value: protocolAck.toBytes(),
        );
        
        _logger.info('Sent protocol ACK for message: $extractedMessageId');
      } catch (e) {
        _logger.warning('Failed to send protocol ACK: $e');
      }
    }
  }
}
  
  Future<void> startAsPeripheral() async {
    _logger.info('Starting as Peripheral (discoverable)...');

  _stateManager.setPeripheralMode(true);
  _connectionManager.setPeripheralMode(true);

  if (_connectionManager.connectedDevice != null) {
    try {
      await _connectionManager.disconnect();
    } catch (e) {
      _logger.warning('Error disconnecting during mode switch: $e');
    }
  }

  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralNegotiatedMTU = null;

    try {
      await centralManager.stopDiscovery();
    } catch (e) {
      // Ignore
    }

  _updateConnectionInfo(
    isConnected: false, 
    isReady: false, 
    otherUserName: null,
    statusMessage: 'Switching to peripheral mode...'
  );
    
    _connectionManager.clearConnectionState();
    _stateManager.clearOtherUserName();
    _discoveredDevices.clear();
    _devicesController?.add([]);
    
    try {
      await peripheralManager.removeAllServices();
      
      final messageCharacteristic = GATTCharacteristic.mutable(
        uuid: BLEConstants.messageCharacteristicUUID,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );
      
      final service = GATTService(
        uuid: BLEConstants.serviceUUID,
        isPrimary: true,
        includedServices: [],
        characteristics: [messageCharacteristic],
      );
      
      await peripheralManager.addService(service);
      
      final advertisement = Advertisement(
        name: 'BLE Chat Device',
        serviceUUIDs: [BLEConstants.serviceUUID],
      );
      
      await peripheralManager.startAdvertising(advertisement);
      _stateManager.setPeripheralMode(true);
      _connectionManager.setPeripheralMode(true); 
      _updateConnectionInfo(isAdvertising: true, statusMessage: 'Advertising - discoverable');
      _logger.info('Now advertising as discoverable device!');
    } catch (e) {
      _logger.severe('Failed to start as peripheral: $e');
      rethrow;
    }
  }
  
  Future<void> startAsCentral() async {
  _logger.info('Starting as Central (scanner)...');
  
  // CRITICAL: Set mode FIRST before any other operations
  _stateManager.setPeripheralMode(false);
  _connectionManager.setPeripheralMode(false);
  
  // Then clear peripheral state
  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralNegotiatedMTU = null;
  
  try {
    await peripheralManager.stopAdvertising();
    await peripheralManager.removeAllServices();
  } catch (e) {
    // Ignore
  }
  
  // Now clear connection info (mode is already set correctly)
  _updateConnectionInfo(
    isConnected: false,
    isReady: false,
    otherUserName: null,
    isAdvertising: false,
    statusMessage: 'Switching to scanner mode...'
  );
  
  _connectionManager.clearConnectionState();
  _stateManager.clearOtherUserName();
  _discoveredDevices.clear();
  _devicesController?.add([]);
  
  // Final state update
  _updateConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Ready to scan'
  );
  
  _logger.info('Switched to central mode');
}
  
 Future<void> startScanning() async {
  if (_stateManager.isPeripheralMode) {
    throw Exception('Cannot scan while in peripheral mode');
  }
  
  _discoveredDevices.clear();
  _devicesController?.add([]);
  
  _logger.info('Starting BLE scan...');
  // Only update scanning status, don't touch connection state
  _updateConnectionInfo(
    isScanning: true, 
    statusMessage: isConnected ? 'Ready to chat' : 'Scanning for devices...'
  );
  await centralManager.startDiscovery(serviceUUIDs: [BLEConstants.serviceUUID]);
}

Future<void> stopScanning() async {
  _logger.info('Stopping BLE scan...');
  await centralManager.stopDiscovery();
  // Only update scanning flag, preserve connection state
  _updateConnectionInfo(
    isScanning: false,
    statusMessage: isConnected ? 'Ready to chat' : 'Ready to scan'
  );
}
  
Future<void> connectToDevice(Peripheral device) async {
  try {
    // Stop any active discovery first
    try {
      await centralManager.stopDiscovery();
    } catch (e) {
      // Ignore
    }
    
    _updateConnectionInfo(isConnected: false, statusMessage: 'Connecting...');
    await _connectionManager.connectToDevice(device);
    
    _connectionManager.startHealthChecks();
    
    if (_connectionManager.isReconnection) {
      _logger.info('Reconnection completed - monitoring already active');
    } else {
      _logger.info('Manual connection - health checks started, no reconnection monitoring');
      _updateConnectionInfo(isReconnecting: false);
    }
  } catch (e) {
    _updateConnectionInfo(
      isConnected: false, 
      isReady: false,
      statusMessage: 'Connection failed'
    );
    throw e;
  }
}

Future<void> requestIdentityExchange() async {
  if (!_connectionManager.hasBleConnection || _connectionManager.messageCharacteristic == null) {
    _logger.warning('Cannot request identity - not connected');
    return;
  }
  
  _logger.info('Manually requesting identity exchange');
  await _sendIdentityExchange();
}

Future<void> _performNameExchangeWithRetry() async {
  _updateConnectionInfo(statusMessage: 'Exchanging identities...');
  for (int attempt = 1; attempt <= 5; attempt++) {
    _logger.info('Name exchange attempt $attempt/5');
    
    try {
      await _sendIdentityExchange();
      
      // Wait for name exchange to complete
      for (int wait = 0; wait < 30; wait++) { // 3 seconds total
        await Future.delayed(Duration(milliseconds: 100));
        
        if (_stateManager.otherUserName != null && _stateManager.otherUserName!.isNotEmpty) {
          _logger.info('✅ Name exchange successful: ${_stateManager.otherUserName}');
          return; // Success!
        }
      }
      
      _logger.warning('❌ Name exchange attempt $attempt timed out');
      
    } catch (e) {
      _logger.warning('❌ Name exchange attempt $attempt failed: $e');
    }
    
    if (attempt < 5) {
      _logger.info('Retrying name exchange in 1.5 second...');
      await Future.delayed(Duration(milliseconds: 1500));
    }
  }
  
  _logger.severe('🚨 Name exchange failed after 5 attempts - connection incomplete');
_updateConnectionInfo(isConnected: false, isReady: false, statusMessage: 'Connection failed');
}
  
  Future<bool> sendMessage(String message, {String? messageId}) async {

  if (!_connectionManager.hasBleConnection || _connectionManager.messageCharacteristic == null) {
    throw Exception('Not connected to any device');
  }
  
  int mtuSize = _connectionManager.mtuSize ?? 20;
  
  return await _messageHandler.sendMessage(
    centralManager: centralManager,
    connectedDevice: _connectionManager.connectedDevice!,
    messageCharacteristic: _connectionManager.messageCharacteristic!,
    message: message,
    mtuSize: mtuSize,
    messageId: messageId,
    onMessageOperationChanged: (inProgress) => _connectionManager.setMessageOperationInProgress(inProgress),
  );
}

Future<bool> sendPeripheralMessage(String message, {String? messageId}) async {
  if (!_stateManager.isPeripheralMode) {
    throw Exception('Not in peripheral mode');
  }
  
  // For peripheral mode, we need to find the connected central and characteristic
  final connectedCentral = _getConnectedCentral();
  final messageCharacteristic = _getPeripheralMessageCharacteristic();
  
  if (connectedCentral == null || messageCharacteristic == null) {
    throw Exception('No central connected or characteristic not found');
  }
  
  // Use the negotiated MTU from central connection
  int mtuSize = _peripheralNegotiatedMTU ?? 20;
  
  return await _messageHandler.sendPeripheralMessage(
    peripheralManager: peripheralManager,
    connectedCentral: connectedCentral,
    messageCharacteristic: messageCharacteristic,
    message: message,
    mtuSize: mtuSize,
    messageId: messageId,
  );
}

Central? _getConnectedCentral() {
  return _connectedCentral;
}

GATTCharacteristic? _getPeripheralMessageCharacteristic() {
  return _connectedCharacteristic;
}
  
  Future<void> _sendIdentityExchange() async {
  if (!_connectionManager.hasBleConnection || _connectionManager.messageCharacteristic == null) {
    throw Exception('Cannot send identity exchange - not properly connected');
  }
  
  try {
    final myPublicKey = await _stateManager.getMyPersistentId(); // Now returns public key
    _logger.info('Sending identity exchange with public key: ${myPublicKey.substring(0, 16)}...');
    
    final protocolMessage = ProtocolMessage.identity(
      publicKey: myPublicKey,
      displayName: _stateManager.myUserName ?? 'User',
    );

    await centralManager.writeCharacteristic(
      _connectionManager.connectedDevice!,
      _connectionManager.messageCharacteristic!,
      value: protocolMessage.toBytes(),
      type: GATTCharacteristicWriteType.withResponse,
    );
    
    _logger.info('Public key identity sent successfully');
    
  } catch (e) {
    _logger.severe('Identity exchange failed: $e');
    throw e;
  }
}
  
  // Delegated methods
  void startConnectionMonitoring() => _connectionManager.startConnectionMonitoring();
  void stopConnectionMonitoring() => _connectionManager.stopConnectionMonitoring();
  Future<void> disconnect() => _connectionManager.disconnect();
  Future<void> setMyUserName(String name) => _stateManager.setMyUserName(name);
  Future<String> getCurrentPassphrase() => _stateManager.getCurrentPassphrase();
  Future<void> setCustomPassphrase(String passphrase) => _stateManager.setCustomPassphrase(passphrase);
  Future<void> generateNewPassphrase() => _stateManager.generateNewPassphrase();
  Future<Peripheral?> scanForSpecificDevice({Duration timeout = const Duration(seconds: 10)}) =>
    _connectionManager.scanForSpecificDevice(timeout: timeout);
  
  void dispose() {
  _connectionManager.dispose();
  _messageHandler.dispose();
  _stateManager.dispose();
  _devicesController?.close();
  _messagesController?.close();
  _connectionInfoController?.close();
}
}