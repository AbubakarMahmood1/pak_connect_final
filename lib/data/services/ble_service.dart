// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../core/bluetooth/handshake_coordinator.dart';
import '../../core/bluetooth/peripheral_initializer.dart';
import '../../core/services/hint_advertisement_service.dart';
import '../../core/services/hint_scanner_service.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/sensitive_contact_hint.dart';
import '../../domain/services/notification_service.dart';

/// Enum to track the source of scanning requests for better coordination
enum ScanningSource {
  manual,        // User-initiated scanning (DiscoveryOverlay)
  burst,         // Adaptive power manager burst scanning
  system,        // Other system-initiated scanning
}

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

  // Handshake protocol coordinator
  HandshakeCoordinator? _handshakeCoordinator;
  StreamSubscription<ConnectionPhase>? _handshakePhaseSubscription;

  // Peripheral initialization helper
  late final PeripheralInitializer _peripheralInitializer;

  // Hint system
  late final HintScannerService _hintScanner;
  final _introHintRepo = IntroHintRepository();
  final _contactRepo = ContactRepository();

  // Streams for UI
  StreamController<ConnectionInfo>? _connectionInfoController;
  StreamController<List<Peripheral>>? _devicesController;
  StreamController<String>? _messagesController;
  StreamController<Map<String, DiscoveredEventArgs>>? _discoveryDataController;
  StreamController<String>? _hintMatchController;

  // Bluetooth state monitoring
  final BluetoothStateMonitor _bluetoothStateMonitor = BluetoothStateMonitor.instance;

  
  // Discovery management
  List<Peripheral> _discoveredDevices = [];

// Peripheral mode connection tracking
Central? _connectedCentral;
GATTCharacteristic? _connectedCharacteristic;
bool _peripheralHandshakeStarted = false;  // Track if handshake initiated for this connection

int? _peripheralNegotiatedMTU;
bool _peripheralMtuReady = false;  // Track if MTU has been negotiated

// Message ID tracking for protocol ACK
String? extractedMessageId;

// Message buffering for race condition fix
final List<_BufferedMessage> _messageBuffer = [];

  bool _isDiscoveryActive = false;
  ScanningSource? _currentScanningSource;
  
  // Stream getters
  Stream<ConnectionInfo> get connectionInfo => _connectionInfoController!.stream;
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;
  Stream<List<Peripheral>> get discoveredDevices => _devicesController!.stream;
  Stream<String> get receivedMessages => _messagesController!.stream;
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData => _discoveryDataController!.stream;
  Stream<String> get hintMatches => _hintMatchController!.stream;
  Central? get connectedCentral => _connectedCentral;

  // Bluetooth state monitoring getters
  Stream<BluetoothStateInfo> get bluetoothStateStream => _bluetoothStateMonitor.stateStream;
  Stream<BluetoothStatusMessage> get bluetoothMessageStream => _bluetoothStateMonitor.messageStream;
  bool get isBluetoothReady => _bluetoothStateMonitor.isBluetoothReady;
 
  ConnectionInfo? _lastEmittedConnectionInfo;

  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
  isConnected: false,
  isReady: false,
  statusMessage: 'Disconnected',
);
  
  // State getters (deleginitializeated)
  BluetoothLowEnergyState get state => centralManager.state;
  bool get isConnected {
  final bleConnected = !_stateManager.isPeripheralMode
    ? _connectionManager.connectedDevice != null
    : _connectedCentral != null;
    
  // Check for identity in session state first
  final hasSessionIdentity = _stateManager.otherUserName != null &&
                             _stateManager.otherUserName!.isNotEmpty;
  
  final hasSessionId = _stateManager.currentSessionId != null &&
                       _stateManager.currentSessionId!.isNotEmpty;
  
  // Connection is valid if BLE is connected AND we have identity
  final hasIdentity = hasSessionIdentity || hasSessionId;
  final result = bleConnected && hasIdentity;
  
  // Concise logging when connected
  if (result) {
    final sessionType = _stateManager.isPaired ? 'paired' : 'ephemeral';
    _logger.fine('💬 Connected ($sessionType): ${_stateManager.otherUserName ?? "unknown"}');
  }
  
  return result;
}
  bool get isPeripheralMode => _stateManager.isPeripheralMode;
  bool get isMonitoring => _connectionManager.isMonitoring;
  Peripheral? get connectedDevice => _connectionManager.connectedDevice;
  String? get myUserName => _stateManager.myUserName;
  String? get otherUserName => _stateManager.otherUserName;
  
  /// The currently active session ID (ephemeral pre-pairing, persistent post-pairing)
  String? get currentSessionId => _stateManager.currentSessionId;
  
  /// Get their ephemeral session ID (8 chars, changes per session)
  String? get theirEphemeralId => _stateManager.theirEphemeralId;
  
  /// Get their persistent public key (64 chars, only available after pairing)
  String? get theirPersistentKey => _stateManager.theirPersistentKey;
  
  String? get myPersistentId => _stateManager.myPersistentId;
  bool get isActivelyReconnecting =>
    !_stateManager.isPeripheralMode && _connectionManager.isActivelyReconnecting;

  /// Check if we can send messages (works for both central and peripheral modes)
  bool get canSendMessages {
    if (_stateManager.isPeripheralMode) {
      // Peripheral mode: check if central is connected and characteristic is available
      return _connectedCentral != null && _connectedCharacteristic != null;
    } else {
      // Central mode: check connection manager
      return _connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null;
    }
  }
  BLEStateManager get stateManager => _stateManager;
  BLEConnectionManager get connectionManager => _connectionManager;

  
  Future<void> initialize() async {
    // Dispose existing controllers if they exist
    _connectionInfoController?.close();
    _devicesController?.close();
    _messagesController?.close();
    _discoveryDataController?.close();
    _hintMatchController?.close();

    // Initialize new stream controllers
    _connectionInfoController = StreamController<ConnectionInfo>.broadcast();
    _devicesController = StreamController<List<Peripheral>>.broadcast();
    _messagesController = StreamController<String>.broadcast();
    _discoveryDataController = StreamController<Map<String, DiscoveredEventArgs>>.broadcast();
    _hintMatchController = StreamController<String>.broadcast();


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

    // Initialize peripheral initializer
    _peripheralInitializer = PeripheralInitializer(peripheralManager);

    // Initialize hint scanner service
    _hintScanner = HintScannerService(contactRepository: _contactRepo);
    await _hintScanner.initialize();
    _logger.info('✅ Hint scanner initialized');

    // Initialize Bluetooth state monitoring
    _logger.info('🔵 Initializing Bluetooth state monitor...');
    await _bluetoothStateMonitor.initialize(
      onBluetoothReady: _onBluetoothBecameReady,
      onBluetoothUnavailable: _onBluetoothBecameUnavailable,
      onInitializationRetry: _onBluetoothInitializationRetry,
    );
    _logger.info('✅ Bluetooth state monitor initialized');

    // Connect message handler callbacks to state manager
    _messageHandler.onContactRequestReceived = _stateManager.handleContactRequest;
    _messageHandler.onContactAcceptReceived = _stateManager.handleContactAccept;
    _messageHandler.onContactRejectReceived = _stateManager.handleContactReject;

    // Wire relay message forwarding callback
    _messageHandler.onSendRelayMessage = (protocolMessage, nextHopId) async {
      _logger.info('🔀 RELAY FORWARD: Sending relay message to ${nextHopId.length > 8 ? '${nextHopId.substring(0, 8)}...' : nextHopId}');
      await _sendProtocolMessage(protocolMessage);
    };

    await EphemeralKeyManager.initialize(await _stateManager.getMyPersistentId());
    
    // CRITICAL FIX: Initialize message handler with current node ID
    final myNodeId = await _stateManager.getMyPersistentId();
    print('🔧 BLE SERVICE: Initializing message handler with node ID: ${myNodeId.length > 16 ? '${myNodeId.substring(0, 16)}...' : myNodeId}');
    
    // Initialize the message handler with the current node ID for proper routing
    _messageHandler.setCurrentNodeId(myNodeId);
    
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
  _logger.info('Connection complete - starting handshake protocol');

  // CRITICAL: Stop discovery after successful connection
  try {
    await centralManager.stopDiscovery();
    _logger.info('Stopped discovery after successful connection');
  } catch (e) {
    // Ignore
  }

  // ✅ NEW: Use handshake protocol instead of simple name exchange
  await _performHandshake();
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

// STEP 3: Wire pairing request/accept/cancel callbacks
_stateManager.onSendPairingRequest = (message) async {
  await _sendProtocolMessage(message);
  _logger.info('📤 STEP 3: Sent pairing request');
};

_stateManager.onSendPairingAccept = (message) async {
  await _sendProtocolMessage(message);
  _logger.info('📤 STEP 3: Sent pairing accept');
};

_stateManager.onSendPairingCancel = (message) async {
  await _sendProtocolMessage(message);
  _logger.info('📤 STEP 3: Sent pairing cancel');
};

_stateManager.onSendPersistentKeyExchange = (message) async {
  await _sendProtocolMessage(message);
  _logger.info('📤 STEP 4: Sent persistent key exchange');
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
//_stateManager.onSendCryptoVerification = (message) async {
  //await _sendProtocolMessage(message);
//};

//_stateManager.onSendCryptoVerificationResponse = (message) async {
  //await _sendProtocolMessage(message);
//};

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
    _logger.fine('🔍 CONNECTION INFO UPDATE REQUEST:');
    _logger.fine('  - Input: isConnected=$isConnected, isReady=$isReady, otherUserName="$otherUserName"');
    _logger.fine('  - Input: statusMessage="$statusMessage", isScanning=$isScanning, isAdvertising=$isAdvertising, isReconnecting=$isReconnecting');
    _logger.fine('  - Current: isConnected=${_currentConnectionInfo.isConnected}, isReady=${_currentConnectionInfo.isReady}, otherUserName="${_currentConnectionInfo.otherUserName}"');
    
    final newInfo = _currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );
    
    _logger.fine('  - New Info: isConnected=${newInfo.isConnected}, isReady=${newInfo.isReady}, otherUserName="${newInfo.otherUserName}"');
    
    // Check if this is a meaningful change
    if (_shouldEmitConnectionInfo(newInfo)) {
      _currentConnectionInfo = newInfo;
      _lastEmittedConnectionInfo = newInfo;
      _connectionInfoController?.add(_currentConnectionInfo);
      _logger.fine('  - ✅ EMITTED: Connection info broadcast to UI');
      _logger.fine('  - Final State: ${_currentConnectionInfo.isConnected}/${_currentConnectionInfo.isReady} - "${_currentConnectionInfo.statusMessage}"');
    } else {
      _logger.fine('  - ❌ NOT EMITTED: No meaningful change detected');
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
  _disposeHandshakeCoordinator();
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
  _disposeHandshakeCoordinator();
  _stateManager.clearSessionState();
  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralHandshakeStarted = false;
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
_disposeHandshakeCoordinator();
_stateManager.clearSessionState();
_connectedCentral = null;
_connectedCharacteristic = null;
_peripheralHandshakeStarted = false;
  }
});


peripheralManager.mtuChanged.listen((event) {
  _logger.info('✅ Peripheral MTU changed: ${event.mtu} for ${event.central.uuid}');
  _peripheralNegotiatedMTU = event.mtu;
  _peripheralMtuReady = true;  // Signal that MTU is ready for sending
});

centralManager.discovered.listen((event) async {
  print('🔍 DISCOVERY: Found ${event.peripheral.uuid} with RSSI: ${event.rssi}');

  // ✅ Use deduplication manager instead of direct list management
  DeviceDeduplicationManager.processDiscoveredDevice(event);

  // Check hints if manufacturer data present
  final mfgData = event.advertisement.manufacturerSpecificData;
  if (mfgData.isNotEmpty) {
    for (final data in mfgData) {
      if (data.id == 0x2E19 && data.data.length == 15) {
        // Our hint format - check for matches
        final match = await _hintScanner.checkDevice(data.data);

        if (match.isContact) {
          _logger.info('✅ CONTACT NEARBY: ${match.contactName}');
          _hintMatchController?.add('✅ Contact nearby: ${match.contactName}');
        } else if (match.isIntro) {
          _logger.info('👋 INTRO MATCH: ${match.introHint?.displayName}');
          _hintMatchController?.add('👋 Found: ${match.introHint?.displayName} (from QR)');
        }
      }
    }
  }
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
      _disposeHandshakeCoordinator();
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

      // Note: Handshake will be initiated after first characteristic write
      // when _connectedCharacteristic becomes available

    } else if (event.state == ConnectionState.disconnected) {
      if (_connectedCentral?.uuid == event.central.uuid) {
        _logger.info('Connected central disconnected from our peripheral');
        _connectedCentral = null;
        _connectedCharacteristic = null;
        _peripheralHandshakeStarted = false;
        _disposeHandshakeCoordinator();
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

    // ✅ FIX: Start handshake AFTER characteristic is available (only once per connection)
    if (!_peripheralHandshakeStarted && _connectedCentral != null && _connectedCharacteristic != null) {
      _peripheralHandshakeStarted = true;
      _logger.info('🤝 Characteristic available - initiating handshake on peripheral side');
      // Don't await - let it run async so we can process the incoming message
      _performHandshake();
    }

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

    // ✅ FIX: Route handshake protocol messages to coordinator FIRST
    // BUT: Only if handshake is still in progress (not complete or failed)
    // This prevents legacy handlers from intercepting handshake messages
    // AND prevents completed handshakes from processing non-handshake messages
    if (_handshakeCoordinator != null && 
        _isHandshakeMessage(protocolMessage.type) &&
        !_handshakeCoordinator!.isComplete &&
        !_handshakeCoordinator!.hasFailed) {
      await _handshakeCoordinator!.handleReceivedMessage(protocolMessage);
      return;
    }

// ✅ FIX: Removed legacy contactStatus handler - now handled by handshake coordinator
// The contactStatus message is part of the handshake protocol and should not be
// intercepted here. Security level sync can be added to handshake completion callback if needed.
    
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
      final chatId = ChatUtils.generateChatId(publicKey);
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
    
    // STEP 3: Handle new pairing request/accept/cancel messages
    if (protocolMessage.type == ProtocolMessageType.pairingRequest) {
      _logger.info('📥 STEP 3: Received pairing request');
      _stateManager.handlePairingRequest(protocolMessage);
      return;
    }
    
    if (protocolMessage.type == ProtocolMessageType.pairingAccept) {
      _logger.info('📥 STEP 3: Received pairing accept');
      _stateManager.handlePairingAccept(protocolMessage);
      return;
    }
    
    if (protocolMessage.type == ProtocolMessageType.pairingCancel) {
      _logger.info('📥 STEP 3: Received pairing cancel');
      _stateManager.handlePairingCancel(protocolMessage);
      return;
    }
    
    // STEP 4: Handle persistent key exchange (for future implementation)
    if (protocolMessage.type == ProtocolMessageType.persistentKeyExchange) {
      _logger.info('📥 STEP 4: Received persistent key exchange');
      final persistentKey = protocolMessage.payload['persistentPublicKey'] as String?;
      
      if (persistentKey != null) {
        await _stateManager.handlePersistentKeyExchange(persistentKey);
      } else {
        _logger.warning('❌ Persistent key exchange missing public key');
      }
      return;
    }
    
    // Handle crypto verification messages
    if (protocolMessage.type == ProtocolMessageType.cryptoVerification) {
  final challenge = protocolMessage.cryptoVerificationChallenge;
  final testMessage = protocolMessage.cryptoVerificationTestMessage;
  if (challenge != null && testMessage != null) {
    _logger.info('🔍 VERIFICATION: Crypto challenge received but challenges disabled - ignoring');
  }
  return;
}
    
    if (protocolMessage.type == ProtocolMessageType.cryptoVerificationResponse) {
  final challenge = protocolMessage.cryptoVerificationResponseChallenge;
  final decryptedMessage = protocolMessage.cryptoVerificationResponseDecrypted;
  if (challenge != null && decryptedMessage != null) {
    _logger.info('🔍 VERIFICATION: Crypto response received but challenges disabled - ignoring');
  }
  return;
}
    
  } catch (e) {
    // Not a protocol message, continue to regular message processing
  }
  
  // Process regular chat messages - RACE CONDITION FIX
  if (_stateManager.currentSessionId == null) {
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
  if (_stateManager.currentSessionId != null) {
    senderPublicKey = _stateManager.currentSessionId!;
    final truncatedKey = senderPublicKey.length > 16 
        ? '${senderPublicKey.substring(0, 16)}...' 
        : senderPublicKey;
    _logger.info('🔐 Using sender public key for decryption: $truncatedKey');
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
  
    if (_stateManager.currentSessionId != null && _stateManager.otherUserName != null) {
      final contact = await _stateManager.getContact(_stateManager.currentSessionId!);
      if (contact == null) {
        await _stateManager.contactRepository.saveContactWithSecurity(
          _stateManager.currentSessionId!, 
          _stateManager.otherUserName!,
          SecurityLevel.low
        );
        _logger.info('Contact saved on first message received: ${_stateManager.otherUserName} at low security');
      }
    }
    
    // Trigger notification for new message
  
    if (_stateManager.currentSessionId != null && _stateManager.otherUserName != null) {
      try {
        // Parse the message to create Message entity
        final messageRepo = MessageRepository();
        // Generate chat ID from session ID
        final chatId = ChatUtils.generateChatId(_stateManager.currentSessionId!);
        final messages = await messageRepo.getMessages(chatId);
        
        // Find the most recent message (just received)
        if (messages.isNotEmpty) {
          final latestMessage = messages.first;
          
          // Show notification for received messages only
          if (!latestMessage.isFromMe) {
            await NotificationService.showMessageNotification(
              message: latestMessage,
              contactName: _stateManager.otherUserName!,
            );
          }
        }
      } catch (e) {
        _logger.warning('Failed to show message notification: $e');
        // Don't let notification errors break message reception
      }
    }
    
    // Increment unread count
    final chatsRepo = ChatsRepository();
  
    if (_stateManager.currentSessionId != null) {
      final chatId = ChatUtils.generateChatId(_stateManager.currentSessionId!);
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

    // Preserve session ID across mode switches
    final preservedOtherPublicKey = _stateManager.currentSessionId;
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
  _peripheralHandshakeStarted = false;
  _peripheralNegotiatedMTU = null;
  _peripheralMtuReady = false;  // Reset MTU ready flag

    try {
      await centralManager.stopDiscovery();
    } catch (e) {
      // Ignore
    }

  _updateConnectionInfo(
    isConnected: false,
    isReady: false,
    otherUserName: null,
    statusMessage: 'Initializing peripheral mode...'
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
      // ✅ FIX: Use safe peripheral initialization
      _logger.info('🔧 Preparing peripheral manager...');

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

      // ✅ FIX: Safely add service with proper initialization wait
      final serviceAdded = await _peripheralInitializer.safelyAddService(
        service,
        timeout: Duration(seconds: 5),
      );

      if (!serviceAdded) {
        throw Exception('Failed to add GATT service - peripheral not ready');
      }
      
      // Get intro hint (if any active QR)
      final introHint = await _introHintRepo.getMostRecentActiveHint();

      // Compute my persistent hint from my public key
      final myPublicKey = await _stateManager.getMyPersistentId();
      
      // Check if user wants to broadcast online status
      final prefs = await SharedPreferences.getInstance();
      final showOnlineStatus = prefs.getBool('show_online_status') ?? true;
      
      // If online status is disabled, don't broadcast identity hint
      final myPersistentHint = showOnlineStatus 
        ? SensitiveContactHint.compute(contactPublicKey: myPublicKey)
        : null;
      
      _logger.info('📡 Online Status: ${showOnlineStatus ? "visible" : "hidden"}');

      // Pack hints into 6-byte advertisement (optimized for BLE size limits)
      final advData = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
        ephemeralHint: myPersistentHint, // null if hidden
      );

      _logger.info('📡 Advertising: intro=${introHint?.hintHex ?? "none"}, persistent=${myPersistentHint?.hintHex ?? "hidden"}');

      // Advertisement breakdown (fits in 31-byte Android limit):
      // - Service UUID: 16 bytes (128-bit)
      // - Manufacturer ID: 2 bytes
      // - Manufacturer data: 10 bytes (compressed hints)
      // - BLE overhead: ~3 bytes
      // Total: ~31 bytes (perfect fit!)
      final advertisement = Advertisement(
        name: null,  // Removed to save space - service UUID is sufficient for discovery
        serviceUUIDs: [BLEConstants.serviceUUID],
        manufacturerSpecificData: Platform.isIOS || Platform.isMacOS ? [] : [
          ManufacturerSpecificData(
            id: 0x2E19, // Our custom manufacturer ID
            data: advData,
          ),
        ],
      );
      
      // ✅ FIX: Safely start advertising with proper initialization wait
      final advertisingStarted = await _peripheralInitializer.safelyStartAdvertising(
        advertisement,
        timeout: Duration(seconds: 5),
      );

      if (!advertisingStarted) {
        throw Exception('Failed to start advertising - peripheral not ready');
      }

      _stateManager.setPeripheralMode(true);
      _connectionManager.setPeripheralMode(true);
      _updateConnectionInfo(isAdvertising: true, statusMessage: 'Advertising - discoverable');
      _logger.info('✅ Now advertising as discoverable device!');
    } catch (e, stack) {
      _logger.severe('Failed to start as peripheral: $e', e, stack);
      _updateConnectionInfo(
        isAdvertising: false,
        statusMessage: 'Peripheral mode failed'
      );
      rethrow;
    }
  }
  
  /// Refresh advertising data (useful when preferences like online status change)
  /// Only works if already in peripheral mode and advertising
  /// [showOnlineStatus] - if provided, uses this value instead of reading from prefs
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {
    if (!_stateManager.isPeripheralMode) {
      _logger.warning('⚠️ Cannot refresh advertising - not in peripheral mode');
      return;
    }
    
    _logger.info('🔄 Refreshing advertising data...');
    
    try {
      // Stop current advertising
      await peripheralManager.stopAdvertising();
      
      // Small delay to ensure clean stop
      await Future.delayed(Duration(milliseconds: 100));
      
      // Get intro hint (if any active QR)
      final introHint = await _introHintRepo.getMostRecentActiveHint();

      // Compute my persistent hint from my public key
      final myPublicKey = await _stateManager.getMyPersistentId();
      
      // Use provided value or read from preferences
      bool shouldShowOnlineStatus;
      if (showOnlineStatus != null) {
        shouldShowOnlineStatus = showOnlineStatus;
        _logger.info('📡 Using provided online status value: $shouldShowOnlineStatus');
      } else {
        final prefs = await SharedPreferences.getInstance();
        shouldShowOnlineStatus = prefs.getBool('show_online_status') ?? true;
        _logger.info('📡 Read online status from prefs: $shouldShowOnlineStatus');
      }
      
      // If online status is disabled, don't broadcast identity hint
      final myPersistentHint = shouldShowOnlineStatus 
        ? SensitiveContactHint.compute(contactPublicKey: myPublicKey)
        : null;
      
      _logger.info('📡 Refreshed Online Status: ${shouldShowOnlineStatus ? "visible" : "hidden"}');
      _logger.info('📡 Refreshed Advertising: intro=${introHint?.hintHex ?? "none"}, persistent=${myPersistentHint?.hintHex ?? "hidden"}');

      // Pack hints into 6-byte advertisement
      final advData = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
        ephemeralHint: myPersistentHint, // null if hidden
      );

      final advertisement = Advertisement(
        name: null,
        serviceUUIDs: [BLEConstants.serviceUUID],
        manufacturerSpecificData: Platform.isIOS || Platform.isMacOS ? [] : [
          ManufacturerSpecificData(
            id: 0x2E19,
            data: advData,
          ),
        ],
      );

      // Restart advertising with new data
      final advertisingStarted = await _peripheralInitializer.safelyStartAdvertising(
        advertisement,
        timeout: Duration(seconds: 5),
      );

      if (advertisingStarted) {
        _updateConnectionInfo(isAdvertising: true, statusMessage: 'Advertising - discoverable');
        _logger.info('✅ Advertising refreshed successfully!');
      } else {
        throw Exception('Failed to restart advertising');
      }
    } catch (e, stack) {
      _logger.severe('❌ Failed to refresh advertising: $e', e, stack);
      _updateConnectionInfo(isAdvertising: false, statusMessage: 'Advertising refresh failed');
    }
  }
  
  Future<void> startAsCentral() async {
  _logger.info('Starting as Central (scanner)...');

    // Preserve session ID across mode switches
    final preservedOtherPublicKey = _stateManager.currentSessionId;
  final preservedOtherName = _stateManager.otherUserName;
  final preservedTheyHaveUs = _stateManager.theyHaveUsAsContact;
  final preservedWeHaveThem = await _stateManager.weHaveThemAsContact;
  
  // Set mode
  _stateManager.setPeripheralMode(false);
  _connectionManager.setPeripheralMode(false);
  
  // Clear peripheral-specific state (but NOT encryption keys!)
  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralHandshakeStarted = false;
  _peripheralNegotiatedMTU = null;
  _peripheralMtuReady = false;  // Reset MTU ready flag

  try {
    await peripheralManager.stopAdvertising();
  } catch (e) {
    _logger.fine('Could not stop advertising: $e');
  }

  try {
    await peripheralManager.removeAllServices();
  } catch (e) {
    _logger.fine('Could not remove services: $e');
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
  
 Future<void> startScanning({ScanningSource source = ScanningSource.system}) async {
  if (_stateManager.isPeripheralMode) {
    throw Exception('Cannot scan while in peripheral mode');
  }
  
  // 🔧 ENHANCED: Check for scanning conflicts with better logging
  if (_isDiscoveryActive) {
    final currentSource = _currentScanningSource?.name ?? 'unknown';
    final newSource = source.name;
    
    if (_currentScanningSource != source) {
      _logger.warning('🔍 Scanning conflict detected: $newSource scanning requested while $currentSource scanning is active');
      _logger.info('🔍 Coordination: Allowing $newSource to take over from $currentSource');
      
      // Allow manual scanning to interrupt burst scanning for better UX
      if (source == ScanningSource.manual && _currentScanningSource == ScanningSource.burst) {
        _logger.info('🔍 Manual scanning takes priority over burst scanning - stopping current scan');
        await stopScanning();
      } else {
        _logger.info('🔍 Discovery already active from $currentSource - skipping $newSource request');
        return;
      }
    } else {
      _logger.info('🔍 Discovery already active from same source ($currentSource) - skipping request');
      return;
    }
  }
  
  _discoveredDevices.clear();
  _devicesController?.add([]);
  _currentScanningSource = source;
  
  _logger.info('🔍 Starting ${source.name} BLE scan...');
  _updateConnectionInfo(
    isScanning: true, 
    statusMessage: isConnected ? 'Ready to chat' : 'Scanning for devices...'
  );
  
  print('🔍 DEBUG: startScanning called - source: ${source.name}, _isDiscoveryActive: $_isDiscoveryActive, isPeripheralMode: ${_stateManager.isPeripheralMode}');

  try {
    _isDiscoveryActive = true;
    await centralManager.startDiscovery(serviceUUIDs: [BLEConstants.serviceUUID]);
    _logger.info('🔍 ${source.name.toUpperCase()} discovery started successfully');
  } catch (e) {
    _isDiscoveryActive = false;
    _currentScanningSource = null;
    _updateConnectionInfo(isScanning: false);
    rethrow;
  }
}

Future<void> stopScanning() async {
  final currentSource = _currentScanningSource?.name ?? 'unknown';
  _logger.info('🔍 Stopping $currentSource BLE scan...');
  
  if (_isDiscoveryActive) {
    try {
      await centralManager.stopDiscovery();
      _logger.info('🔍 ${currentSource.toUpperCase()} discovery stopped successfully');
    } catch (e) {
      _logger.warning('🔍 Error stopping $currentSource discovery: $e');
    } finally {
      _isDiscoveryActive = false;
      _currentScanningSource = null; // 🔧 NEW: Clear scanning source
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

/// USERNAME PROPAGATION FIX: Enhanced identity re-exchange for real-time username updates
Future<void> triggerIdentityReExchange() async {
  _logger.info('🔄 USERNAME PROPAGATION: Triggering identity re-exchange for updated username');
  
  try {
    // Force reload username from storage to ensure we have the latest
    await _stateManager.loadUserName();
    
    // Re-send identity with updated username
    if (_stateManager.isPeripheralMode) {
      await _sendPeripheralIdentityExchange();
    } else {
      await _sendIdentityExchange();
    }
    
    _logger.info('✅ USERNAME PROPAGATION: Identity re-exchange completed successfully');
  } catch (e) {
    _logger.warning('❌ USERNAME PROPAGATION: Identity re-exchange failed: $e');
  }
}

/// Send identity in peripheral mode
Future<void> _sendPeripheralIdentityExchange() async {
  if (!_stateManager.isPeripheralMode || _connectedCentral == null || _connectedCharacteristic == null) {
    _logger.warning('Cannot send peripheral identity - not in peripheral mode or no central connected');
    return;
  }
  
  try {
    // CRITICAL: Ensure username is loaded before sending
    if (_stateManager.myUserName == null || _stateManager.myUserName!.isEmpty) {
      await _stateManager.loadUserName();
    }
    
    final myPublicKey = await _stateManager.getMyPersistentId();
    final displayName = _stateManager.myUserName ?? 'User';
    
    _logger.info('Sending peripheral identity re-exchange:');
    _logger.info('  Public key: ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 16)}...' : myPublicKey}');
    _logger.info('  Display name: $displayName');
    
    final protocolMessage = ProtocolMessage.identity(
      publicKey: myPublicKey,
      displayName: displayName,
    );
    
    await peripheralManager.notifyCharacteristic(
      _connectedCentral!,
      _connectedCharacteristic!,
      value: protocolMessage.toBytes(),
    );
    
    _logger.info('✅ Peripheral identity re-exchange sent successfully');
  } catch (e) {
    _logger.severe('❌ Peripheral identity re-exchange failed: $e');
    rethrow;
  }
}

/// Perform handshake protocol for connection initialization
Future<void> _performHandshake() async {
  _logger.info('🤝 Starting handshake protocol...');

  try {
    // Clean up old handshake coordinator if it exists
    _disposeHandshakeCoordinator();

    // Get BOTH ephemeral and persistent identities
    final myEphemeralId = EphemeralKeyManager.generateMyEphemeralKey();
    final myPublicKey = await _stateManager.getMyPersistentId();
    final myDisplayName = _stateManager.myUserName ?? 'User';

    _logger.info('📱 My ephemeral ID: ${myEphemeralId.length > 16 ? '${myEphemeralId.substring(0, 16)}...' : myEphemeralId}');
    _logger.info('🔒 My persistent key (not sent during handshake): ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 16)}...' : myPublicKey}');
    
    // Create handshake coordinator
    _handshakeCoordinator = HandshakeCoordinator(
      myEphemeralId: myEphemeralId,
      myPublicKey: myPublicKey,
      myDisplayName: myDisplayName,
      sendMessage: _sendHandshakeMessage,
      onHandshakeComplete: _onHandshakeComplete,
      phaseTimeout: Duration(seconds: 10),
    );

    // Listen to phase changes for UI feedback
    _handshakePhaseSubscription = _handshakeCoordinator!.phaseStream.listen((phase) async {
      _logger.info('🤝 Handshake phase: $phase');
      _updateConnectionInfo(statusMessage: _getPhaseMessage(phase));
      
      // 🔧 FIX: Disconnect on handshake failure
      if (phase == ConnectionPhase.failed || phase == ConnectionPhase.timeout) {
        _logger.warning('⚠️ Handshake failed/timeout - disconnecting BLE connection');
        // Small delay to let UI show failure message
        await Future.delayed(Duration(milliseconds: 500));
        await disconnect();
      }
    });

    // ✅ FIX: Process any buffered protocol messages that arrived before coordinator was created
    final bufferedProtocolMessages = <_BufferedMessage>[];
    for (final buffered in _messageBuffer) {
      try {
        final protocolMessage = ProtocolMessage.fromBytes(buffered.data);
        if (_isHandshakeMessage(protocolMessage.type)) {
          bufferedProtocolMessages.add(buffered);
          _logger.info('📦 Processing buffered ${protocolMessage.type} from before coordinator creation');
          await _handshakeCoordinator!.handleReceivedMessage(protocolMessage);
        }
      } catch (e) {
        // Not a protocol message, leave it in buffer for later processing
      }
    }
    // Remove processed protocol messages from buffer
    for (final processed in bufferedProtocolMessages) {
      _messageBuffer.remove(processed);
    }
    if (bufferedProtocolMessages.isNotEmpty) {
      _logger.info('✅ Processed ${bufferedProtocolMessages.length} buffered protocol message(s)');
    }

    // Start the handshake
    await _handshakeCoordinator!.startHandshake();

  } catch (e, stack) {
    _logger.severe('🚨 Handshake failed: $e', e, stack);
    _updateConnectionInfo(
      isConnected: false,
      isReady: false,
      statusMessage: 'Connection failed'
    );
  }
}

/// Send handshake protocol messages using the write queue
Future<void> _sendHandshakeMessage(ProtocolMessage message) async {
  try {
    // Use the existing queued write system to prevent concurrent writes
    await _sendProtocolMessage(message);
    _logger.fine('✅ Sent handshake message: ${message.type}');
  } catch (e) {
    _logger.severe('❌ Failed to send handshake message ${message.type}: $e');
    // Rethrow so handshake coordinator knows it failed
    rethrow;
  }
}

/// Called when handshake completes successfully
Future<void> _onHandshakeComplete(String ephemeralId, String displayName) async {
  _logger.info('🎉 Handshake complete! Connected to: $displayName');
  _logger.info('   Their ephemeral ID: ${ephemeralId.length > 16 ? '${ephemeralId.substring(0, 16)}...' : ephemeralId}');

  // STEP 3: Store their ephemeral ID (separate from persistent key)
  _stateManager.setTheirEphemeralId(ephemeralId, displayName);
  
  // Store identity in state manager (this sets display name)
  // Note: For now we use ephemeralId as publicKey until pairing completes
  _stateManager.setOtherDeviceIdentity(ephemeralId, displayName);

  // Check if we already have chat history with this ephemeral ID
  final chatId = ChatUtils.generateChatId(ephemeralId);
  final messageRepo = MessageRepository();
  final existingMessages = await messageRepo.getMessages(chatId);

  // Always save contact to ensure database integrity (foreign key constraints)
  // Note: Using ephemeral ID until pairing completes and we exchange persistent keys
  await _stateManager.saveContact(ephemeralId, displayName);
  if (existingMessages.isNotEmpty) {
    _logger.info('Contact restored from existing chat history: $displayName');
  } else {
    _logger.info('New contact saved during handshake: $displayName');
  }

  await _stateManager.initializeContactFlags();

  // Update last seen
  final chatsRepo = ChatsRepository();
  await chatsRepo.updateContactLastSeen(ephemeralId);
  await chatsRepo.storeDeviceMapping(_connectionManager.connectedDevice?.uuid.toString(), ephemeralId);

  // Process any buffered messages
  _processPendingMessages();

  // Update UI - but only if handshake didn't fail during message processing
  // Check coordinator state before final UI update
  if (_handshakeCoordinator != null && !_handshakeCoordinator!.hasFailed) {
    _updateConnectionInfo(
      isConnected: true,
      isReady: true,
      otherUserName: displayName,
      statusMessage: 'Ready to chat',
    );
  } else {
    _logger.warning('⚠️ Handshake coordinator failed during completion - skipping UI update to ready state');
  }
}

/// Dispose of handshake coordinator to prevent stale state
void _disposeHandshakeCoordinator() {
  if (_handshakeCoordinator != null) {
    _logger.info('🧹 Disposing old handshake coordinator (phase: ${_handshakeCoordinator!.currentPhase})');
    _handshakePhaseSubscription?.cancel();
    _handshakePhaseSubscription = null;
    _handshakeCoordinator!.dispose();
    _handshakeCoordinator = null;
  }
}

/// Convert connection phase to user-friendly message
String _getPhaseMessage(ConnectionPhase phase) {
  switch (phase) {
    case ConnectionPhase.bleConnected:
      return 'Connected...';
    case ConnectionPhase.readySent:
      return 'Synchronizing...';
    case ConnectionPhase.readyComplete:
      return 'Ready check complete...';
    case ConnectionPhase.identitySent:
      return 'Exchanging identities...';
    case ConnectionPhase.identityComplete:
      return 'Identity verified...';
    case ConnectionPhase.contactStatusSent:
      return 'Syncing contact status...';
    case ConnectionPhase.contactStatusComplete:
      return 'Contact status synced...';
    case ConnectionPhase.complete:
      return 'Ready to chat';
    case ConnectionPhase.timeout:
      return 'Connection timeout';
    case ConnectionPhase.failed:
      return 'Connection failed';
  }
}

/// Check if message type is part of handshake protocol (sequential, no ACKs)
bool _isHandshakeMessage(ProtocolMessageType type) {
  return type == ProtocolMessageType.connectionReady ||
         type == ProtocolMessageType.identity ||
         type == ProtocolMessageType.contactStatus;
}
  
  Future<bool> sendMessage(String message, {String? messageId, String? originalIntendedRecipient}) async {

  if (!_connectionManager.hasBleConnection || _connectionManager.messageCharacteristic == null) {
    throw Exception('Not connected to any device');
  }
  
  int mtuSize = _connectionManager.mtuSize ?? 20;
  
  // STEP 7: Get appropriate recipient ID (ephemeral or persistent)
  final recipientId = _stateManager.getRecipientId();
  final isPaired = _stateManager.isPaired;
  final idType = _stateManager.getIdType();
  
  if (recipientId != null) {
    final truncatedId = recipientId.length > 16 ? recipientId.substring(0, 16) : recipientId;
    _logger.info('📤 STEP 7: Sending message using $idType ID: $truncatedId...');
  }
  
return await _messageHandler.sendMessage(
  centralManager: centralManager,
  connectedDevice: _connectionManager.connectedDevice!,
  messageCharacteristic: _connectionManager.messageCharacteristic!,
  message: message,
  mtuSize: mtuSize,
  messageId: messageId,
  contactPublicKey: isPaired ? recipientId : null,  // STEP 7: Only for paired contacts
  recipientId: recipientId,  // STEP 7: Pass recipient ID
  useEphemeralAddressing: !isPaired,  // STEP 7: Flag for routing
  originalIntendedRecipient: originalIntendedRecipient, // Pass through for relay messages
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
  
  // 🔧 FIX: Wait for MTU negotiation before sending
  if (!_peripheralMtuReady && _peripheralNegotiatedMTU == null) {
    _logger.info('⏳ Waiting for MTU negotiation (up to 2 seconds)...');
    // Check every 50ms for faster response (40 iterations = 2 seconds max)
    for (int i = 0; i < 40; i++) {
      if (_peripheralMtuReady || _peripheralNegotiatedMTU != null) {
        _logger.info('✅ MTU ready after ${i * 50}ms wait');
        break;  // Exit immediately when ready
      }
      await Future.delayed(Duration(milliseconds: 50));
    }
    
    if (!_peripheralMtuReady && _peripheralNegotiatedMTU == null) {
      _logger.warning('⚠️ MTU negotiation timeout - proceeding with default 20 bytes');
    }
  }
  
  // Use the negotiated MTU from central connection
  int mtuSize = _peripheralNegotiatedMTU ?? 20;
  _logger.info('📡 Peripheral sending with MTU: $mtuSize bytes');
  
  // STEP 7: Get appropriate recipient ID (ephemeral or persistent)
  final recipientId = _stateManager.getRecipientId();
  final isPaired = _stateManager.isPaired;
  final idType = _stateManager.getIdType();
  
  if (recipientId != null) {
    final truncatedId = recipientId.length > 16 ? recipientId.substring(0, 16) : recipientId;
    _logger.info('📤 STEP 7 (Peripheral): Sending message using $idType ID: $truncatedId...');
  }
  
  return await _messageHandler.sendPeripheralMessage(
    peripheralManager: peripheralManager,
    connectedCentral: connectedCentral,
    messageCharacteristic: messageCharacteristic,
    message: message,
    mtuSize: mtuSize,
    messageId: messageId,
    contactPublicKey: isPaired ? recipientId : null,  // STEP 7: Only for paired contacts
    recipientId: recipientId,  // STEP 7: Pass recipient ID
    useEphemeralAddressing: !isPaired,  // STEP 7: Flag for routing
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

// BLE write queue to prevent concurrent writes that cause IllegalStateException
final List<Future<void> Function()> _writeQueue = [];
bool _isProcessingWriteQueue = false;

Future<void> _sendProtocolMessage(ProtocolMessage message) async {
  // Add write to queue to serialize operations
  final completer = Completer<void>();

  _writeQueue.add(() async {
    try {
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
      completer.complete();
    } catch (e) {
      _logger.warning('⚠️ Write failed: $e - will retry');
      // Add small delay before retry to let GATT stabilize
      await Future.delayed(Duration(milliseconds: 100));

      // Retry once
      try {
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
        completer.complete();
      } catch (retryError) {
        _logger.severe('❌ Write failed after retry: $retryError');
        completer.completeError(retryError);
      }
    }
  });

  // Process queue
  _processWriteQueue();

  return completer.future;
}

Future<void> _processWriteQueue() async {
  if (_isProcessingWriteQueue || _writeQueue.isEmpty) return;

  _isProcessingWriteQueue = true;

  while (_writeQueue.isNotEmpty) {
    final write = _writeQueue.removeAt(0);
    await write();
    // Small delay between writes to prevent GATT overload
    await Future.delayed(Duration(milliseconds: 50));
  }

  _isProcessingWriteQueue = false;
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
    _logger.info('  Public key: ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 16)}...' : myPublicKey}');
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
      _logger.info('  - Public key: ${publicKey.isNotEmpty ? publicKey.length > 16 ? '${publicKey.substring(0, 16)}...' : publicKey : "none"}');
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
        // Display session ID with safe truncation
        final sessionIdDisplay = _stateManager.currentSessionId != null
            ? (_stateManager.currentSessionId!.length > 16 
                ? '${_stateManager.currentSessionId!.substring(0, 16)}...' 
                : _stateManager.currentSessionId!)
            : 'null';
        _logger.info('  - Session ID: $sessionIdDisplay');
        _logger.info('  - Type: ${_stateManager.isPaired ? "PAIRED" : "UNPAIRED"}');
        
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

  /// Handle when Bluetooth becomes ready
  void _onBluetoothBecameReady() {
    _logger.info('🔵 Bluetooth state monitor: Bluetooth became ready');

    // Update connection info to reflect ready state
    if (_stateManager.isPeripheralMode) {
      _updateConnectionInfo(statusMessage: 'Bluetooth ready - can advertise');
    } else {
      _updateConnectionInfo(statusMessage: 'Bluetooth ready - can scan');
    }

    // If we were in an error state due to Bluetooth, clear it
    if (_currentConnectionInfo.statusMessage?.contains('Bluetooth') == true) {
      // Restart any suspended operations
      if (_stateManager.isPeripheralMode && !isConnected) {
        _logger.info('🔵 Restarting peripheral advertising after Bluetooth became ready');
        Future.delayed(Duration(milliseconds: 500), () async {
          try {
            await startAsPeripheral();
          } catch (e) {
            _logger.warning('Failed to restart peripheral mode: $e');
          }
        });
      }
    }
  }

  /// Handle when Bluetooth becomes unavailable
  void _onBluetoothBecameUnavailable() {
    _logger.warning('🔵 Bluetooth state monitor: Bluetooth became unavailable');

    // Clear all connections and reset state
    _disposeHandshakeCoordinator();
    _stateManager.clearSessionState();
    _connectedCentral = null;
    _connectedCharacteristic = null;
    _peripheralHandshakeStarted = false;

    // Update connection info with appropriate message
    _updateConnectionInfo(
      isConnected: false,
      isReady: false,
      isScanning: false,
      isAdvertising: false,
      otherUserName: null,
      statusMessage: 'Bluetooth required for mesh networking',
    );
  }

  /// Handle Bluetooth initialization retry
  void _onBluetoothInitializationRetry() {
    _logger.info('🔵 Bluetooth state monitor: Retrying initialization');

    // Update status to show we're retrying
    _updateConnectionInfo(
      statusMessage: 'Checking Bluetooth status...',
    );
  }

  /// Enhanced scanning method with Bluetooth state validation
  Future<void> startScanningWithValidation({ScanningSource source = ScanningSource.system}) async {
    // Check Bluetooth state first
    if (!_bluetoothStateMonitor.isBluetoothReady) {
      final currentState = _bluetoothStateMonitor.currentState;
      _logger.warning('🔵 Cannot start scanning - Bluetooth not ready: $currentState');

      String errorMessage;
      switch (currentState) {
        case BluetoothLowEnergyState.poweredOff:
          errorMessage = 'Please enable Bluetooth to scan for devices';
          break;
        case BluetoothLowEnergyState.unauthorized:
          errorMessage = 'Bluetooth permission required for scanning';
          break;
        case BluetoothLowEnergyState.unsupported:
          errorMessage = 'Bluetooth not supported on this device';
          break;
        default:
          errorMessage = 'Bluetooth not available for scanning';
      }

      _updateConnectionInfo(
        isScanning: false,
        statusMessage: errorMessage,
      );

      throw Exception(errorMessage);
    }

    // Proceed with normal scanning
    await startScanning(source: source);
  }

  /// Enhanced peripheral mode with Bluetooth state validation
  Future<void> startAsPeripheralWithValidation() async {
    // Check Bluetooth state first
    if (!_bluetoothStateMonitor.isBluetoothReady) {
      final currentState = _bluetoothStateMonitor.currentState;
      _logger.warning('🔵 Cannot start peripheral mode - Bluetooth not ready: $currentState');

      String errorMessage;
      switch (currentState) {
        case BluetoothLowEnergyState.poweredOff:
          errorMessage = 'Please enable Bluetooth to become discoverable';
          break;
        case BluetoothLowEnergyState.unauthorized:
          errorMessage = 'Bluetooth permission required for advertising';
          break;
        case BluetoothLowEnergyState.unsupported:
          errorMessage = 'Bluetooth advertising not supported';
          break;
        default:
          errorMessage = 'Bluetooth not available for advertising';
      }

      _updateConnectionInfo(
        isAdvertising: false,
        statusMessage: errorMessage,
      );

      throw Exception(errorMessage);
    }

    // Proceed with normal peripheral mode
    await startAsPeripheral();
  }

  // OBSOLETE: No longer needed - hints are now deterministic from public key
  // /// Get or generate my personal shared seed for hint generation
  // Future<Uint8List?> _getOrGenerateMySharedSeed(String myPublicKey) async {
  //   // Try to get existing seed
  //   var seed = await _contactRepo.getCachedSharedSeedBytes(myPublicKey);
  //
  //   if (seed == null) {
  //     // Generate new personal seed
  //     seed = SensitiveContactHint.generateSharedSeed();
  //     await _contactRepo.cacheSharedSeedBytes(myPublicKey, seed);
  //     _logger.info('Generated new personal shared seed');
  //   }
  //
  //   return seed;
  // }

  void dispose() {
  // Dispose handshake coordinator
  _handshakeCoordinator?.dispose();

  // Dispose hint scanner
  _hintScanner.dispose();

  // Dispose Bluetooth state monitor
  _bluetoothStateMonitor.dispose();

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
  _hintMatchController?.close();
}
}
