// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/discovery/batch_processor.dart';
import '../../core/security/hint_cache_manager.dart';
import '../../data/repositories/chats_repository.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/protocol_message.dart';
import '../../core/utils/chat_utils.dart';
import 'ble_connection_manager.dart';
import 'ble_message_handler.dart';
import 'ble_state_manager.dart';
import '../../data/repositories/message_repository.dart';
import '../../core/services/security_manager.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/security/background_cache_service.dart';

// Helper class to buffer messages until identity exchange completes
class _BufferedMessage {
  final Uint8List data;
  final bool isFromPeripheral;
  final Central? central;
  final GATTCharacteristic? characteristic;
  final DateTime timestamp;

  _BufferedMessage({
    required this.data,
    required this.isFromPeripheral,
    this.central,
    this.characteristic,
    required this.timestamp,
  });
}

class BLEService {
  final _logger = Logger('BLEService');

  // Initialization completer for timing fix
  final Completer<void> _initializationCompleter = Completer<void>();
  Future<void> get initializationComplete => _initializationCompleter.future;
  
  // Managers
  final CentralManager centralManager = CentralManager();
  final PeripheralManager peripheralManager = PeripheralManager();
  
  // Sub-components
  late final BLEConnectionManager _connectionManager;
  late final BLEMessageHandler _messageHandler;
  final BLEStateManager _stateManager = BLEStateManager();
  
  // Streams for UI
  StreamController<ConnectionInfo>? _connectionInfoController;
  StreamController<List<Peripheral>>? _devicesController;
  StreamController<String>? _messagesController;
  StreamController<Map<String, DiscoveredEventArgs>>? _discoveryDataController;

  
  // Discovery management
  List<Peripheral> _discoveredDevices = [];

// Peripheral mode connection tracking
Central? _connectedCentral;
GATTCharacteristic? _connectedCharacteristic;

int? _peripheralNegotiatedMTU;

// Message ID tracking for protocol ACK
String? extractedMessageId;

// Message buffering for race condition fix
final List<_BufferedMessage> _messageBuffer = [];

  bool _isDiscoveryActive = false;
  
  // Stream getters
  Stream<ConnectionInfo> get connectionInfo => _connectionInfoController!.stream;
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;
  Stream<List<Peripheral>> get discoveredDevices => _devicesController!.stream;
  Stream<String> get receivedMessages => _messagesController!.stream;
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData => _discoveryDataController!.stream;
  Central? get connectedCentral => _connectedCentral;
 
  ConnectionInfo? _lastEmittedConnectionInfo;

  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
  isConnected: false,
  isReady: false,
  statusMessage: 'Disconnected',
);
  
  // State getters (deleginitializeated)
  BluetoothLowEnergyState get state => centralManager.state;
  bool get isConnected {
  // FIX: Prioritize BLE connection state and add fallback for identity
  final bleConnected = !_stateManager.isPeripheralMode
    ? _connectionManager.connectedDevice != null
    : _connectedCentral != null;
    
  // Check for identity in session state first
  final hasSessionIdentity = _stateManager.otherUserName != null &&
                             _stateManager.otherUserName!.isNotEmpty;
  
  // Fallback: Check if we have persistent identity (ID) even if session name is cleared
  final hasPersistentIdentity = _stateManager.otherDevicePersistentId != null &&
                               _stateManager.otherDevicePersistentId!.isNotEmpty;
  
  // Connection is valid if BLE is connected AND we have some form of identity
  final hasIdentity = hasSessionIdentity || hasPersistentIdentity;
  final result = bleConnected && hasIdentity;
  
  _logger.info('🔍 CONNECTION STATE CHECK (FIXED):');
  _logger.info('  - Mode: ${_stateManager.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"}');
  _logger.info('  - BLE Connected: $bleConnected');
  _logger.info('  - Session Identity: $hasSessionIdentity (name: "${_stateManager.otherUserName}")');
  _logger.info('  - Persistent Identity: $hasPersistentIdentity (id: "${_stateManager.otherDevicePersistentId?.substring(0, 16)}...")');
  _logger.info('  - Combined Identity: $hasIdentity');
  _logger.info('  - Final Result: $result');
  
  return result;
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
  BLEStateManager get stateManager => _stateManager;
  BLEConnectionManager get connectionManager => _connectionManager;

  
  Future<void> initialize() async {
    // Dispose existing controllers if they exist
    _connectionInfoController?.close();
    _devicesController?.close();
    _messagesController?.close();
    _discoveryDataController?.close();

    // Initialize new stream controllers
    _connectionInfoController = StreamController<ConnectionInfo>.broadcast();
    _devicesController = StreamController<List<Peripheral>>.broadcast();
    _messagesController = StreamController<String>.broadcast();
    _discoveryDataController = StreamController<Map<String, DiscoveredEventArgs>>.broadcast();


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

    await EphemeralKeyManager.initialize(await _stateManager.getMyPersistentId());
    
    _messageHandler = BLEMessageHandler();
    BackgroundCacheService.initialize();

    // Connect message handler callbacks to state manager
    _messageHandler.onContactRequestReceived = _stateManager.handleContactRequest;
    _messageHandler.onContactAcceptReceived = _stateManager.handleContactAccept;
    _messageHandler.onContactRejectReceived = _stateManager.handleContactReject;

    await EphemeralKeyManager.initialize(await _stateManager.getMyPersistentId());
    
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
    
    await _stateManager.initialize();

_stateManager.onNameChanged = (name) {
  _logger.info('🎯 onNameChanged triggered: $name');
  _logger.info('  Current connection state: isConnected=${_currentConnectionInfo.isConnected}, isReady=${_currentConnectionInfo.isReady}');
  _logger.info('  Current mode: ${_stateManager.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"}');
  
  if (name != null && name.isNotEmpty) {
    _logger.info('  → Updating to ready state');
    _updateConnectionInfo(
      isConnected: true,
      isReady: true,
      otherUserName: name,
      statusMessage: 'Ready to chat',
    );
  } else {
    _logger.info('  → Clearing connection state');
    _updateConnectionInfo(
      isConnected: false,
      isReady: false,
      otherUserName: null,
      statusMessage: 'Disconnected',
    );
  }
};

_stateManager.onSendPairingCode = (code) async {
  if (_connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null) {
    final message = ProtocolMessage.pairingCode(code: code);
    await centralManager.writeCharacteristic(
      _connectionManager.connectedDevice!,
      _connectionManager.messageCharacteristic!,
      value: message.toBytes(),
      type: GATTCharacteristicWriteType.withResponse,
    );
    _logger.info('Sent pairing code to other device');
  } else if (isPeripheralMode && _connectedCentral != null && _connectedCharacteristic != null) {
    final message = ProtocolMessage.pairingCode(code: code);
    await peripheralManager.notifyCharacteristic(
      _connectedCentral!,
      _connectedCharacteristic!,
      value: message.toBytes(),
    );
    _logger.info('Sent pairing code via peripheral');
  }
};

_stateManager.onSendPairingVerification = (hash) async {
  if (_connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null) {
    final message = ProtocolMessage.pairingVerify(secretHash: hash);
    await centralManager.writeCharacteristic(
      _connectionManager.connectedDevice!,
      _connectionManager.messageCharacteristic!,
      value: message.toBytes(),
      type: GATTCharacteristicWriteType.withResponse,
    );
    _logger.info('Sent pairing verification to other device');
  } else if (isPeripheralMode && _connectedCentral != null && _connectedCharacteristic != null) {
    final message = ProtocolMessage.pairingVerify(secretHash: hash);
    await peripheralManager.notifyCharacteristic(
      _connectedCentral!,
      _connectedCharacteristic!,
      value: message.toBytes(),
    );
    _logger.info('Sent pairing verification via peripheral');
  }
};

_stateManager.onSendContactRequest = (publicKey, displayName) async {
  final message = ProtocolMessage.contactRequest(
    publicKey: publicKey,
    displayName: displayName,
  );
  await _sendProtocolMessage(message);
};

_stateManager.onSendContactAccept = (publicKey, displayName) async {
  final message = ProtocolMessage.contactAccept(
    publicKey: publicKey,
    displayName: displayName,
  );
  await _sendProtocolMessage(message);
};

_stateManager.onSendContactReject = () async {
  final message = ProtocolMessage.contactReject();
  await _sendProtocolMessage(message);
};

_stateManager.onSendContactStatus = (message) async {
  await _sendProtocolMessage(message);
};

// Wire crypto verification callbacks
_stateManager.onSendCryptoVerification = (message) async {
  await _sendProtocolMessage(message);
};

_stateManager.onSendCryptoVerificationResponse = (message) async {
  await _sendProtocolMessage(message);
};

// Replace asymmetric contact detection with mutual consent requirement
_stateManager.onMutualConsentRequired = (publicKey, displayName) {
  // This will be handled by the UI layer - they'll show the contact request dialog
  _handleMutualConsentRequired(publicKey, displayName);
};

_stateManager.onAsymmetricContactDetected = (publicKey, displayName) {
  // Legacy fallback - Show UI prompt to add contact
  _handleAsymmetricContact(publicKey, displayName);
};
    
    // Setup event listeners
    _setupEventListeners();

    // Complete initialization
    _initializationCompleter.complete();
  }

void _handleMutualConsentRequired(String publicKey, String displayName) {
  // This signals that mutual consent is required - the UI should show a contact request dialog
  _logger.info('📱 MUTUAL CONSENT: User needs to decide whether to send contact request to $displayName');
  
  // This will be handled by the UI layer through the state manager callbacks
  // The UI should show the outgoing contact request dialog
}

void _handleAsymmetricContact(String publicKey, String displayName) {
  // Legacy fallback for asymmetric detection
  _logger.info('Asymmetric contact detected: $displayName has us but we don\'t have them');
  
  // For now, just log it. The UI should handle this through the state manager
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
    _logger.info('🔍 CONNECTION INFO UPDATE REQUEST:');
    _logger.info('  - Input: isConnected=$isConnected, isReady=$isReady, otherUserName="$otherUserName"');
    _logger.info('  - Input: statusMessage="$statusMessage", isScanning=$isScanning, isAdvertising=$isAdvertising, isReconnecting=$isReconnecting');
    _logger.info('  - Current: isConnected=${_currentConnectionInfo.isConnected}, isReady=${_currentConnectionInfo.isReady}, otherUserName="${_currentConnectionInfo.otherUserName}"');
    
    // FIX: Only emit if there's an actual change
    final newInfo = _currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );
    
    _logger.info('  - New Info: isConnected=${newInfo.isConnected}, isReady=${newInfo.isReady}, otherUserName="${newInfo.otherUserName}"');
    
    // Check if this is a meaningful change
    if (_shouldEmitConnectionInfo(newInfo)) {
      _currentConnectionInfo = newInfo;
      _lastEmittedConnectionInfo = newInfo;
      _connectionInfoController?.add(_currentConnectionInfo);
      _logger.info('  - ✅ EMITTED: Connection info broadcast to UI');
      _logger.info('  - Final State: ${_currentConnectionInfo.isConnected}/${_currentConnectionInfo.isReady} - "${_currentConnectionInfo.statusMessage}"');
    } else {
      _logger.info('  - ❌ NOT EMITTED: No meaningful change detected');
      _logger.info('  - Emission blocked - UI will not be updated');
    }
  }

  bool _shouldEmitConnectionInfo(ConnectionInfo newInfo) {
    if (_lastEmittedConnectionInfo == null) return true;
    
    final last = _lastEmittedConnectionInfo!;
    
    // Only emit if there's a meaningful change
    return last.isConnected != newInfo.isConnected ||
           last.isReady != newInfo.isReady ||
           last.otherUserName != newInfo.otherUserName ||
           last.isScanning != newInfo.isScanning ||
           last.isAdvertising != newInfo.isAdvertising ||
           last.isReconnecting != newInfo.isReconnecting ||
           last.statusMessage != newInfo.statusMessage;
  }

  void _setupEventListeners() {
    // Central manager state changes
   centralManager.stateChanged.listen((event) async {
  _logger.info('Central BLE State changed: ${event.state}');
  
if (event.state == BluetoothLowEnergyState.poweredOff) {
  _updateConnectionInfo(isConnected: false, isReady: false, statusMessage: 'Bluetooth off');
  _stateManager.clearSessionState();
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
  _stateManager.clearSessionState();
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
_stateManager.clearSessionState();
_connectedCentral = null;
_connectedCharacteristic = null;
  }
});


peripheralManager.mtuChanged.listen((event) {
  _logger.info('Peripheral MTU changed: ${event.mtu} for ${event.central.uuid}');
  _peripheralNegotiatedMTU = event.mtu;
});

centralManager.discovered.listen((event) {
  print('🔍 DISCOVERY: Found ${event.peripheral.uuid} with RSSI: ${event.rssi}');
  
  // ✅ Use deduplication manager instead of direct list management
  DeviceDeduplicationManager.processDiscoveredDevice(event);
});

// ✅ Listen to deduplicated device stream
DeviceDeduplicationManager.uniqueDevicesStream.listen((uniqueDevices) {
  _discoveredDevices = uniqueDevices.values.map((d) => d.peripheral).toList();
  _devicesController?.add(List.from(_discoveredDevices));
});

// ✅ Cleanup stale devices periodically
Timer.periodic(Duration(minutes: 1), (timer) {
  DeviceDeduplicationManager.removeStaleDevices();
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
      _stateManager.clearSessionState();
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
        _stateManager.clearSessionState();
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

// Process all buffered messages when identity becomes available
void _processPendingMessages() {
  if (_messageBuffer.isEmpty) {
    _logger.info('🔄 BUFFER: No buffered messages to process');
    return;
  }
  
  _logger.info('🔄 BUFFER: Processing ${_messageBuffer.length} buffered messages');
  
  // Process all buffered messages
  final bufferedMessages = List<_BufferedMessage>.from(_messageBuffer);
  _messageBuffer.clear();
  
  for (final bufferedMsg in bufferedMessages) {
    _logger.info('🔄 BUFFER: Processing buffered message from ${bufferedMsg.timestamp}');
    _processMessage(
      bufferedMsg.data,
      bufferedMsg.isFromPeripheral,
      central: bufferedMsg.central,
      characteristic: bufferedMsg.characteristic,
    );
  }
  
  _logger.info('🔄 BUFFER: All buffered messages processed');
}

Future<String> getMyPublicKey() async {
  return await _stateManager.getMyPersistentId();
}
  
Future<void> _handleReceivedData(Uint8List data, {required bool isFromPeripheral, Central? central, GATTCharacteristic? characteristic}) async {
  // Handle protocol identity messages
  try {
    final protocolMessage = ProtocolMessage.fromBytes(data);

if (protocolMessage.type == ProtocolMessageType.contactStatus) {
  final payload = protocolMessage.payload;
  print('🔒 PROTOCOL DEBUG: Received contactStatus - payload: ${protocolMessage.payload}');
  if (payload.containsKey('securityLevel')) {
    await _stateManager.handleSecurityLevelSync(payload);
  } else {
    // Legacy contact status handling
    final hasAsContact = payload['hasAsContact'] as bool;
    final theirPublicKey = payload['publicKey'] as String;
    _stateManager.handleContactStatus(hasAsContact, theirPublicKey);
  }
  return;
}
    
    // Handle contact request/accept/reject/status messages first
    if (protocolMessage.type == ProtocolMessageType.contactRequest) {
      _stateManager.handleContactRequest(
        protocolMessage.contactRequestPublicKey!,
        protocolMessage.contactRequestDisplayName!,
      );
      return;
    }

    if (protocolMessage.type == ProtocolMessageType.contactAccept) {
      _stateManager.handleContactAccept(
        protocolMessage.contactAcceptPublicKey!,
        protocolMessage.contactAcceptDisplayName!,
      );
      return;
    }

    if (protocolMessage.type == ProtocolMessageType.contactReject) {
      _stateManager.handleContactReject();
      return;
    }

    if (protocolMessage.type == ProtocolMessageType.contactStatus) {
      final hasAsContact = protocolMessage.payload['hasAsContact'] as bool;
      final theirPublicKey = protocolMessage.payload['publicKey'] as String;
      _stateManager.handleContactStatus(hasAsContact, theirPublicKey);
      return;
    }
    
    if (protocolMessage.type == ProtocolMessageType.identity) {
      final publicKey = protocolMessage.identityPublicKey ?? protocolMessage.identityDeviceIdCompat!;
      final displayName = protocolMessage.identityDisplayName!;
      
      // Store identity but DON'T save as contact yet
      _stateManager.setOtherDeviceIdentity(publicKey, displayName);
      
      // Check if we already have a chat history with this person
      final myPublicKey = await _stateManager.getMyPersistentId();
      final chatId = ChatUtils.generateChatId(myPublicKey, publicKey);
      final messageRepo = MessageRepository();
      final existingMessages = await messageRepo.getMessages(chatId);
      
      // Only save contact if we have chat history
      if (existingMessages.isNotEmpty) {
        await _stateManager.saveContact(publicKey, displayName);
        _logger.info('Contact restored from existing chat history: $displayName');
      } else {
        _logger.info('Identity received but not saving contact yet: $displayName');
      }
      
      await _stateManager.initializeContactFlags();
      
      _logger.info('Identity exchange complete for $displayName');
      
      // Update last seen for tracking
      final chatsRepo = ChatsRepository();
      await chatsRepo.updateContactLastSeen(publicKey);
      await chatsRepo.storeDeviceMapping(_connectionManager.connectedDevice?.uuid.toString(), publicKey);
      
      // CRITICAL FIX: Process buffered messages now that identity is available
      _processPendingMessages();
      
      // AUTO-RESPOND in peripheral mode
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
          
          _logger.info('Auto-sent peripheral identity response');
        } catch (e) {
          _logger.warning('Failed to send auto-response identity: $e');
        }
      }
      return;
    }
    
    // Handle pairing messages
    if (protocolMessage.type == ProtocolMessageType.pairingCode) {
      final code = protocolMessage.pairingCodeValue;
      if (code != null) {
        _stateManager.handleReceivedPairingCode(code);
      }
      return;
    }
    
    if (protocolMessage.type == ProtocolMessageType.pairingVerify) {
      final hash = protocolMessage.pairingSecretHash;
      if (hash != null) {
        _stateManager.handlePairingVerification(hash);
      }
      return;
    }
    
    // Handle crypto verification messages
    if (protocolMessage.type == ProtocolMessageType.cryptoVerification) {
      final challenge = protocolMessage.cryptoVerificationChallenge;
      final testMessage = protocolMessage.cryptoVerificationTestMessage;
      if (challenge != null && testMessage != null) {
        await _stateManager.handleCryptoVerificationChallenge(challenge, testMessage);
      }
      return;
    }
    
    if (protocolMessage.type == ProtocolMessageType.cryptoVerificationResponse) {
      final challenge = protocolMessage.cryptoVerificationResponseChallenge;
      final decryptedMessage = protocolMessage.cryptoVerificationResponseDecrypted;
      final success = protocolMessage.cryptoVerificationSuccess;
      final results = protocolMessage.cryptoVerificationResults;
      if (challenge != null && decryptedMessage != null) {
        await _stateManager.handleCryptoVerificationResponse(challenge, decryptedMessage, success, results);
      }
      return;
    }
    
  } catch (e) {
    // Not a protocol message, continue to regular message processing
  }
  
  // Process regular chat messages - RACE CONDITION FIX
  if (_stateManager.otherDevicePersistentId == null) {
    // Buffer the message until identity exchange completes
    _logger.info('🔄 BUFFER: Identity not ready, buffering message');
    _messageBuffer.add(_BufferedMessage(
      data: data,
      isFromPeripheral: isFromPeripheral,
      central: central,
      characteristic: characteristic,
      timestamp: DateTime.now(),
    ));
    return;
  }

  // Process the message immediately if identity is available
  await _processMessage(data, isFromPeripheral, central: central, characteristic: characteristic);
}

Future<void> _processMessage(
  Uint8List data,
  bool isFromPeripheral, {
  Central? central,
  GATTCharacteristic? characteristic
}) async {
  String? senderPublicKey;
  if (_stateManager.otherDevicePersistentId != null) {
    senderPublicKey = _stateManager.otherDevicePersistentId;
    _logger.info('🔐 Using sender public key for decryption: ${senderPublicKey?.substring(0, 16)}...');
  } else {
    _logger.warning('🔐 No sender public key available - decryption may fail');
  }

  final content = await _messageHandler.processReceivedData(
    data,
    onMessageIdFound: (id) => extractedMessageId = id,
    senderPublicKey: senderPublicKey,
    contactRepository: _stateManager.contactRepository,
  );
  
  if (content != null) {
    _messagesController?.add(content);
    
    // IMPORTANT: Save contact on first message if not already saved
    if (_stateManager.otherDevicePersistentId != null && _stateManager.otherUserName != null) {
      final contact = await _stateManager.getContact(_stateManager.otherDevicePersistentId!);
      if (contact == null) {
        await _stateManager.contactRepository.saveContactWithSecurity(
          _stateManager.otherDevicePersistentId!, 
          _stateManager.otherUserName!,
          SecurityLevel.low
        );
        _logger.info('Contact saved on first message received: ${_stateManager.otherUserName} at low security');
      }
    }
    
    // Increment unread count
    final chatsRepo = ChatsRepository();
    if (_stateManager.otherDevicePersistentId != null) {
      final myPublicKey = await _stateManager.getMyPersistentId();
      final chatId = ChatUtils.generateChatId(myPublicKey, _stateManager.otherDevicePersistentId!);
      await chatsRepo.incrementUnreadCount(chatId);
      _logger.info('Incremented unread count for chat: $chatId');
    }
    
    // Send ACK in peripheral mode
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

    final preservedOtherPublicKey = _stateManager.otherDevicePersistentId;
  final preservedOtherName = _stateManager.otherUserName;
  final preservedTheyHaveUs = _stateManager.theyHaveUsAsContact;
  final preservedWeHaveThem = await _stateManager.weHaveThemAsContact;

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
    
  _stateManager.preserveContactRelationship(
    otherPublicKey: preservedOtherPublicKey,
    otherName: preservedOtherName,
    theyHaveUs: preservedTheyHaveUs,
    weHaveThem: preservedWeHaveThem,
  );
  
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
      
      final ephemeralKey = EphemeralKeyManager.generateMyEphemeralKey();
      final ephemeralBytes = ChatUtils.hashToBytes(ephemeralKey);

final advertisement = Advertisement(
  name: 'BLE Chat Device',
  serviceUUIDs: [BLEConstants.serviceUUID],
  manufacturerSpecificData: Platform.isIOS || Platform.isMacOS ? [] : [
    ManufacturerSpecificData(
      id: 0x2E19, // Our custom manufacturer ID
      data: ephemeralBytes,
    ),
  ],
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

    final preservedOtherPublicKey = _stateManager.otherDevicePersistentId;
  final preservedOtherName = _stateManager.otherUserName;
  final preservedTheyHaveUs = _stateManager.theyHaveUsAsContact;
  final preservedWeHaveThem = await _stateManager.weHaveThemAsContact;
  
  // Set mode
  _stateManager.setPeripheralMode(false);
  _connectionManager.setPeripheralMode(false);
  
  // Clear peripheral-specific state (but NOT encryption keys!)
  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralNegotiatedMTU = null;
  
  try {
    await peripheralManager.stopAdvertising();
    await peripheralManager.removeAllServices();
  } catch (e) {
    // Ignore
  }
  
  _updateConnectionInfo(
    isConnected: false,
    isReady: false,
    otherUserName: null,
    isAdvertising: false,
    statusMessage: 'Ready to scan'
  );

    _stateManager.preserveContactRelationship(
    otherPublicKey: preservedOtherPublicKey,
    otherName: preservedOtherName,
    theyHaveUs: preservedTheyHaveUs,
    weHaveThem: preservedWeHaveThem,
  );
  
  _logger.info('Switched to central mode');
}
  
 Future<void> startScanning() async {
  if (_stateManager.isPeripheralMode) {
    throw Exception('Cannot scan while in peripheral mode');
  }
  
  // 🔍 CHECK: Prevent double discovery
  if (_isDiscoveryActive) {
    _logger.info('🔍 Discovery already active - skipping startScanning request');
    return;
  }
  
  _discoveredDevices.clear();
  _devicesController?.add([]);
  
  _logger.info('Starting BLE scan...');
  _updateConnectionInfo(
    isScanning: true, 
    statusMessage: isConnected ? 'Ready to chat' : 'Scanning for devices...'
  );
  
  print('🔍 DEBUG: startScanning called - _isDiscoveryActive: $_isDiscoveryActive, isPeripheralMode: ${_stateManager.isPeripheralMode}');

  try {
    _isDiscoveryActive = true;
    await centralManager.startDiscovery(serviceUUIDs: [BLEConstants.serviceUUID]);
    _logger.info('🔍 Discovery started successfully');
  } catch (e) {
    _isDiscoveryActive = false;
    _updateConnectionInfo(isScanning: false);
    rethrow;
  }
}

Future<void> stopScanning() async {
  _logger.info('Stopping BLE scan...');
  
  if (_isDiscoveryActive) {
    try {
      await centralManager.stopDiscovery();
      _logger.info('🔍 Discovery stopped successfully');
    } catch (e) {
      _logger.warning('🔍 Error stopping discovery: $e');
    } finally {
      _isDiscoveryActive = false;
    }
  }
  
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
    rethrow;
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
  contactPublicKey: _stateManager.otherDevicePersistentId,
  contactRepository: _stateManager.contactRepository,
  stateManager: _stateManager,
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
    contactPublicKey: _stateManager.otherDevicePersistentId,
    contactRepository: _stateManager.contactRepository,
    stateManager: _stateManager,
  );
}

Central? _getConnectedCentral() {
  return _connectedCentral;
}

GATTCharacteristic? _getPeripheralMessageCharacteristic() {
  return _connectedCharacteristic;
}

Future<void> _sendProtocolMessage(ProtocolMessage message) async {
  if (_connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null) {
    await centralManager.writeCharacteristic(
      _connectionManager.connectedDevice!,
      _connectionManager.messageCharacteristic!,
      value: message.toBytes(),
      type: GATTCharacteristicWriteType.withResponse,
    );
  } else if (isPeripheralMode && _connectedCentral != null && _connectedCharacteristic != null) {
    await peripheralManager.notifyCharacteristic(
      _connectedCentral!,
      _connectedCharacteristic!,
      value: message.toBytes(),
    );
  }
}
  
  Future<void> _sendIdentityExchange() async {
  if (!_connectionManager.hasBleConnection || _connectionManager.messageCharacteristic == null) {
    throw Exception('Cannot send identity exchange - not properly connected');
  }
  
  try {
    // CRITICAL: Ensure username is loaded before sending
    if (_stateManager.myUserName == null || _stateManager.myUserName!.isEmpty) {
      _logger.info('Loading username before identity exchange...');
      await _stateManager.loadUserName();
    }

    if (_stateManager.myUserName == null || _stateManager.myUserName!.isEmpty) {
    _logger.info('Loading username before identity exchange...');
    await _stateManager.loadUserName();
    print('🐛 DEBUG NAME: After reload in identity exchange: "${_stateManager.myUserName}"');
  }
    
    final myPublicKey = await _stateManager.getMyPersistentId();
    final displayName = _stateManager.myUserName ?? 'User';

    print('🐛 DEBUG NAME: About to send identity with name: "$displayName"');
    
    _logger.info('Sending identity exchange:');
    _logger.info('  Public key: ${myPublicKey.substring(0, 16)}...');
    _logger.info('  Display name: $displayName');
    
    final protocolMessage = ProtocolMessage.identity(
      publicKey: myPublicKey,
      displayName: displayName,
    );

    await centralManager.writeCharacteristic(
      _connectionManager.connectedDevice!,
      _connectionManager.messageCharacteristic!,
      value: protocolMessage.toBytes(),
      type: GATTCharacteristicWriteType.withResponse,
    );
    
    _logger.info('Public key identity sent successfully with name: $displayName');
    
  } catch (e) {
    _logger.severe('Identity exchange failed: $e');
    rethrow;
  }
}

 
  // Delegated methods
  void startConnectionMonitoring() => _connectionManager.startConnectionMonitoring();
  void stopConnectionMonitoring() => _connectionManager.stopConnectionMonitoring();
  Future<void> disconnect() => _connectionManager.disconnect();
  Future<void> setMyUserName(String name) => _stateManager.setMyUserName(name);
  Future<Peripheral?> scanForSpecificDevice({Duration timeout = const Duration(seconds: 10)}) =>
    _connectionManager.scanForSpecificDevice(timeout: timeout);

  /// Get connection information with fallback to persistent storage
  /// This ensures UI can display connection info even when session state is cleared during navigation
  Future<ConnectionInfo?> getConnectionInfoWithFallback() async {
    if (!isConnected) return null;
    
    try {
      // Get identity with fallback mechanism
      final identityInfo = await _stateManager.getIdentityWithFallback();
      final displayName = identityInfo['displayName'] ?? 'Connected Device';
      final publicKey = identityInfo['publicKey'] ?? '';
      final source = identityInfo['source'] ?? 'unknown';
      
      _logger.info('🔄 CONNECTION INFO: Retrieved with fallback');
      _logger.info('  - Display name: $displayName');
      _logger.info('  - Public key: ${publicKey.isNotEmpty ? "${publicKey.substring(0, 16)}..." : "none"}');
      _logger.info('  - Source: $source');
      
      return ConnectionInfo(
        isConnected: true,
        isReady: true,
        otherUserName: displayName,
        statusMessage: source == 'repository' ? 'Connected (restored)' : 'Ready to chat',
      );
    } catch (e) {
      _logger.warning('Failed to get connection info with fallback: $e');
      return null;
    }
  }

  /// Attempt to recover identity information when BLE is connected but session state is cleared
  Future<bool> attemptIdentityRecovery() async {
    if (!isConnected) {
      _logger.info('🔄 RECOVERY: No BLE connection - cannot recover identity');
      return false;
    }
    
    if (_stateManager.otherUserName != null && _stateManager.otherUserName!.isNotEmpty) {
      _logger.info('🔄 RECOVERY: Session identity already available - no recovery needed');
      return true;
    }
    
    _logger.info('🔄 RECOVERY: Attempting identity recovery from persistent storage...');
    
    try {
      await _stateManager.recoverIdentityFromStorage();
      
      // Check if recovery was successful
      final recovered = _stateManager.otherUserName != null &&
                       _stateManager.otherUserName!.isNotEmpty;
      
      if (recovered) {
        _logger.info('✅ RECOVERY: Identity successfully recovered');
        _logger.info('  - Name: ${_stateManager.otherUserName}');
        _logger.info('  - ID: ${_stateManager.otherDevicePersistentId?.substring(0, 16)}...');
        
        // Update connection info to reflect recovered state
        _updateConnectionInfo(
          isConnected: true,
          isReady: true,
          otherUserName: _stateManager.otherUserName,
          statusMessage: 'Connected (restored)',
        );
      } else {
        _logger.warning('❌ RECOVERY: Failed to recover identity from storage');
      }
      
      return recovered;
    } catch (e) {
      _logger.severe('❌ RECOVERY: Identity recovery failed: $e');
      return false;
    }
  }
  
  void dispose() {
  // Dispose ephemeral system components
  BackgroundCacheService.dispose();
  DeviceDeduplicationManager.dispose();
  HintCacheManager.dispose();
  BatchProcessor.dispose();
  
  // Dispose existing components
  _connectionManager.dispose();
  _messageHandler.dispose();
  _stateManager.dispose();
  
  // Close all stream controllers
  _devicesController?.close();
  _messagesController?.close();
  _connectionInfoController?.close();
  _discoveryDataController?.close();
}
}