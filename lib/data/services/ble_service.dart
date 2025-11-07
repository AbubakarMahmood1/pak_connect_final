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
import '../../core/utils/message_fragmenter.dart';
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
import '../../core/bluetooth/advertising_manager.dart';
import '../../core/bluetooth/connection_cleanup_handler.dart';
import '../../core/services/hint_scanner_service.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../data/repositories/preferences_repository.dart'; // 🆕 For auto-connect preference
import '../../domain/services/notification_service.dart';
import '../../core/messaging/gossip_sync_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../../core/app_core.dart';
import '../../core/models/mesh_relay_models.dart';

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

  // 📡 SINGLE RESPONSIBILITY: Advertising manager (handles ALL advertising)
  late final AdvertisingManager _advertisingManager;

  // 🧹 REAL-TIME CLEANUP: Connection cleanup handler
  late final ConnectionCleanupHandler _cleanupHandler;

  // Hint system
  late final HintScannerService _hintScanner;
  final _contactRepo = ContactRepository();
  final _introHintRepo = IntroHintRepository();

  // Phase 1: Gossip sync manager for mesh message discovery
  GossipSyncManager? _gossipSyncManager;
  
  // Phase 1: Offline message queue for store-and-forward
  OfflineMessageQueue? _offlineMessageQueue;

  // Queue sync interception (MeshNetworkingService registers a handler)
  Future<bool> Function(QueueSyncMessage message, String fromNodeId)? _queueSyncMessageHandler;

  // Streams for UI
  StreamController<ConnectionInfo>? _connectionInfoController;
  StreamController<List<Peripheral>>? _devicesController;
  StreamController<String>? _messagesController;
  StreamController<Map<String, DiscoveredEventArgs>>? _discoveryDataController;
  StreamController<String>? _hintMatchController;
  StreamController<SpyModeInfo>? _spyModeDetectedController;
  StreamController<String>? _identityRevealedController;

  // Bluetooth state monitoring
  final BluetoothStateMonitor _bluetoothStateMonitor = BluetoothStateMonitor.instance;

  
  // Discovery management
  List<Peripheral> _discoveredDevices = [];

// Peripheral mode connection tracking
Central? _connectedCentral;
GATTCharacteristic? _connectedCharacteristic;

bool _peripheralHandshakeStarted = false;  // Track if handshake initiated for this connection
bool _meshNetworkingStarted = false;  // ✅ FIX: Track if mesh networking has been started at least once

int? _peripheralNegotiatedMTU;
bool _peripheralMtuReady = false;  // Track if MTU has been negotiated

// ⚠️ REMOVED: Duplicate advertising state tracker - NOW using BLEConnectionManager as single source of truth
// The _connectionManager.isAdvertising getter is the ONLY authoritative source for advertising state
// This eliminates the dual-tracker bug that caused UI to show false advertising state

// Message ID tracking for protocol ACK
String? extractedMessageId;

// Message buffering for race condition fix
final List<_BufferedMessage> _messageBuffer = [];

// Protocol message reassembler (reuse MessageFragmenter's reassembler)
final MessageReassembler _protocolMessageReassembler = MessageReassembler();

  bool _isDiscoveryActive = false;
  ScanningSource? _currentScanningSource;
  
  // Stream getters
  Stream<ConnectionInfo> get connectionInfo => _connectionInfoController!.stream;
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;
  Stream<List<Peripheral>> get discoveredDevices => _devicesController!.stream;
  Stream<String> get receivedMessages => _messagesController!.stream;
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData => _discoveryDataController!.stream;
  Stream<String> get hintMatches => _hintMatchController!.stream;
  Stream<SpyModeInfo> get spyModeDetected => _spyModeDetectedController!.stream;
  Stream<String> get identityRevealed => _identityRevealedController!.stream;
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

  void registerQueueSyncHandler(Future<bool> Function(QueueSyncMessage, String) handler) {
    _queueSyncMessageHandler = handler;
  }

  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage) async {
    final protocolMessage = ProtocolMessage.queueSync(queueMessage: queueMessage);
    await _sendProtocolMessage(protocolMessage);
  }


  Future<void> initialize() async {
    try {
      // Dispose existing controllers if they exist
      _connectionInfoController?.close();
      _devicesController?.close();
      _messagesController?.close();
      _discoveryDataController?.close();
      _hintMatchController?.close();
      _spyModeDetectedController?.close();
      _identityRevealedController?.close();

      // Initialize new stream controllers
      _connectionInfoController = StreamController<ConnectionInfo>.broadcast();
      _devicesController = StreamController<List<Peripheral>>.broadcast();
      _messagesController = StreamController<String>.broadcast();
      _discoveryDataController = StreamController<Map<String, DiscoveredEventArgs>>.broadcast();
      _hintMatchController = StreamController<String>.broadcast();
      _spyModeDetectedController = StreamController<SpyModeInfo>.broadcast();
      _identityRevealedController = StreamController<String>.broadcast();


if (peripheralManager.state == BluetoothLowEnergyState.poweredOn && _stateManager.isPeripheralMode) {
  _updateConnectionInfo(isAdvertising: true, statusMessage: 'Discoverable');
} else {
  _updateConnectionInfo(statusMessage: 'Ready to scan');
}
    
    // Initialize managers
    centralManager.logLevel = Level.INFO;
    peripheralManager.logLevel = Level.INFO;

    // Initialize sub-components
    // Phase 2b: Initialize connection manager with current power mode from burst scanning
    // Power mode is managed by BurstScanningController → AdaptivePowerManager → BatteryOptimizer
    // We start with balanced mode as safe default, BurstScanningController will update it
    _connectionManager = BLEConnectionManager(
      centralManager: centralManager,
      peripheralManager: peripheralManager,
      initialPowerMode: PowerMode.balanced,  // Safe default, updated by power manager
    );

    // Phase 2b: Power mode integration is handled by BurstScanningController
    // BurstScanningController owns AdaptivePowerManager and will call
    // _connectionManager.handlePowerModeChange(newMode) when power mode changes
    // This keeps the power management centralized in the burst scanning system

    // 🔧 FIX: EphemeralKeyManager already initialized in AppCore._initializeCoreServices()
    // No need to reinitialize here - just use the existing session key
    // await EphemeralKeyManager.initialize(await _stateManager.getMyPersistentId());

    _messageHandler = BLEMessageHandler();
    BackgroundCacheService.initialize();

    // Initialize peripheral initializer
    _peripheralInitializer = PeripheralInitializer(peripheralManager);

    // 📡 Initialize advertising manager (SINGLE RESPONSIBILITY for all advertising)
    _advertisingManager = AdvertisingManager(
      peripheralInitializer: _peripheralInitializer,
      peripheralManager: peripheralManager,
      introHintRepo: _introHintRepo,
    );
    _advertisingManager.start();
    _logger.info('✅ Advertising manager initialized');

    // 🧹 Initialize connection cleanup handler (REAL-TIME cleanup)
    _cleanupHandler = ConnectionCleanupHandler();
    _cleanupHandler.start();
    _logger.info('✅ Connection cleanup handler initialized');

    // Initialize hint scanner service
    _hintScanner = HintScannerService(contactRepository: _contactRepo);
    await _hintScanner.initialize();
    _logger.info('✅ Hint scanner initialized');

    // ✅ FIX: Initialize Bluetooth state monitoring BEFORE attempting mesh networking
    // This ensures we know if Bluetooth is available before trying operations
    _logger.info('🔵 Initializing Bluetooth state monitor...');
    await _bluetoothStateMonitor.initialize(
      onBluetoothReady: _onBluetoothBecameReady,
      onBluetoothUnavailable: _onBluetoothBecameUnavailable,
      onInitializationRetry: _onBluetoothInitializationRetry,
    );
    _logger.info('✅ Bluetooth state monitor initialized');

    // ✅ FIX: Only attempt mesh networking if Bluetooth is actually ready
    // If not ready, _onBluetoothBecameReady callback will start it later
    if (_bluetoothStateMonitor.isBluetoothReady) {
      _logger.info('🔥 Starting mesh networking (Bluetooth ready)...');
      try {
        await _connectionManager.startMeshNetworking(
          onStartAdvertising: () async {
            _logger.info('📡 [MESH-INIT] Starting peripheral mode via AdvertisingManager...');
            await startAsPeripheral();
            _logger.info('✅ [MESH-INIT] Peripheral mode started successfully');
          },
        );
        _meshNetworkingStarted = true; // ✅ FIX: Mark as started
        _logger.info('✅ Mesh advertising active - device is now discoverable');
      } catch (e, stack) {
        _logger.severe('❌ [MESH-INIT] Failed to start mesh networking: $e', e, stack);
        // Non-fatal - scanning can still work for discovering others
      }
    } else {
      _logger.info('⏸️ Mesh networking deferred (Bluetooth not ready)');
      _logger.info('   Will start automatically when Bluetooth becomes available');
    }

    // Connect message handler callbacks to state manager
    _messageHandler.onContactRequestReceived = _stateManager.handleContactRequest;
    _messageHandler.onContactAcceptReceived = _stateManager.handleContactAccept;
    _messageHandler.onContactRejectReceived = _stateManager.handleContactReject;

    // ========== SPY MODE CALLBACKS ==========
    // These callbacks are triggered in ble_state_manager when spy mode is detected
    _stateManager.onSpyModeDetected = _handleSpyModeDetected;
    _stateManager.onIdentityRevealed = _handleIdentityRevealed;
    _messageHandler.onIdentityRevealed = _handleIdentityRevealed;

    // Wire relay message forwarding callback
    _messageHandler.onSendRelayMessage = (protocolMessage, nextHopId) async {
      _logger.info('🔀 RELAY FORWARD: Sending relay message to ${nextHopId.length > 8 ? '${nextHopId.substring(0, 8)}...' : nextHopId}');
      await _sendProtocolMessage(protocolMessage);
    };

    // Wire queue sync callback (will be fully wired after GossipSyncManager is initialized)
    // This is set again after GossipSyncManager initialization to ensure proper reference

    // 🔧 FIX P1: EphemeralKeyManager must be initialized by AppCore first
    // If it's not ready yet, skip ephemeral ID setup and continue without it
    // It will be set up properly when EphemeralKeyManager is initialized
    String? myEphemeralId;
    try {
      myEphemeralId = EphemeralKeyManager.generateMyEphemeralKey();
      _logger.info('🔧 BLE SERVICE: Using session ephemeral ID: ${myEphemeralId.substring(0, 16)}...');

      // Initialize the message handler with the ephemeral node ID for privacy-preserving routing
      _messageHandler.setCurrentNodeId(myEphemeralId);
    } catch (e) {
      _logger.warning('⚠️ EphemeralKeyManager not ready yet - will initialize later: $e');
      // Will be set up when EphemeralKeyManager is initialized by AppCore
    }

    // ===== PHASE 1 INTEGRATION: Gossip Sync Manager =====
    _logger.info('🔄 Initializing GossipSyncManager for mesh message discovery...');

    // ✅ FIX #4: Safety check for AppCore initialization
    if (!AppCore.instance.isInitialized) {
      _logger.severe('❌ AppCore not initialized yet - cannot access messageQueue');
      _logger.severe('   BLEService.initialize() must be called AFTER AppCore.initialize() completes');
      throw StateError(
        'BLEService.initialize() called before AppCore.initialize() completed. '
        'This is a critical initialization order violation. '
        'Ensure AppCore is fully initialized before creating BLE service providers.'
      );
    }

    _gossipSyncManager = GossipSyncManager(
      myNodeId: myEphemeralId ?? 'temp_node_id',  // Temporary ID until EphemeralKeyManager is ready
      messageQueue: AppCore.instance.messageQueue,
    );

    // Wire gossip sync callbacks
    _gossipSyncManager!.onSendSyncRequest = (syncRequest) async {
      // Broadcast sync request to connected peer (BLE supports 1:1 connections)
      _logger.info('📡 Gossip sync: Broadcasting sync request with ${syncRequest.messageIds.length} known messages');

      if (_connectionManager.hasBleConnection) {
        final protocolMessage = ProtocolMessage.queueSync(
          queueMessage: syncRequest,
        );

        await _sendProtocolMessage(protocolMessage);
        _logger.fine('✅ Gossip sync request sent to connected peer');
      } else {
        _logger.fine('No active BLE connection - skipping sync broadcast');
      }
    };

    _gossipSyncManager!.onSendSyncToPeer = (peerID, syncRequest) async {
      // Send sync request to specific peer (verify peer matches connected device)
      _logger.info('📡 Gossip sync: Sending sync request to ${peerID.substring(0, 8)}... with ${syncRequest.messageIds.length} known messages');

      // Verify we're actually connected to the peer we intend to sync with.
      final connectedPeerEphemeralId = _stateManager.theirEphemeralId;
      if (connectedPeerEphemeralId == null) {
        _logger.warning('Target peer ${peerID.substring(0, 8)}... not available - no active handshake');
        return;
      }

      if (connectedPeerEphemeralId != peerID) {
        _logger.warning('Target peer ${peerID.substring(0, 8)}... does not match current connection (${connectedPeerEphemeralId.substring(0, 8)}...) - skipping sync');
        return;
      }

      final protocolMessage = ProtocolMessage.queueSync(
        queueMessage: syncRequest,
      );

      await _sendProtocolMessage(protocolMessage);
      _logger.fine('✅ Gossip sync request sent to peer ${peerID.substring(0, 8)}...');
    };

    _gossipSyncManager!.onSendMessageToPeer = (peerID, message) async {
      // Send missing message to specific peer (relay message)
      _logger.info('📡 Gossip sync: Sending missing message ${message.originalMessageId.substring(0, 16)}... to ${peerID.substring(0, 8)}...');

      // Verify we're connected to the target peer
      final connectedPeerEphemeralId = _stateManager.theirEphemeralId;
      if (connectedPeerEphemeralId == null) {
        _logger.warning('Target peer ${peerID.substring(0, 8)}... not available - no active handshake');
        return;
      }

      if (connectedPeerEphemeralId != peerID) {
        _logger.warning('Target peer ${peerID.substring(0, 8)}... does not match current connection (${connectedPeerEphemeralId.substring(0, 8)}...) - skipping message send');
        return;
      }

      // Convert MeshRelayMessage to ProtocolMessage
      final protocolMessage = ProtocolMessage.meshRelay(
        originalMessageId: message.originalMessageId,
        originalSender: message.relayMetadata.originalSender,
        finalRecipient: message.relayMetadata.finalRecipient,
        relayMetadata: message.relayMetadata.toJson(),
        originalPayload: {'content': message.originalContent},
      );

      await _sendProtocolMessage(protocolMessage);
      _logger.fine('✅ Missing message sent to peer ${peerID.substring(0, 8)}...');
    };

    // ✅ FIX: Only start gossip sync if Bluetooth is ready and connected
    // This prevents wasteful timer firing when no connection exists
    if (_bluetoothStateMonitor.isBluetoothReady && _connectionManager.hasBleConnection) {
      await _gossipSyncManager!.start();
      _logger.info('✅ GossipSyncManager initialized and started');
    } else {
      _logger.info('⏳ GossipSyncManager created but not started (waiting for Bluetooth/connection)');
      _logger.info('   Will start automatically when connection established');
    }

    // Wire incoming queue sync messages to gossip sync manager
    _messageHandler.onQueueSyncReceived = (syncMessage, fromNodeId) async {
      // Allow higher-level services to intercept queue sync messages first
      if (_queueSyncMessageHandler != null) {
        await _queueSyncMessageHandler!(syncMessage, fromNodeId);
      }

      if (_gossipSyncManager != null) {
        _logger.info('📥 Received queue sync from ${fromNodeId.substring(0, 8)}... - forwarding to GossipSyncManager');
        await _gossipSyncManager!.handleSyncRequest(
          fromPeerID: fromNodeId,
          syncRequest: syncMessage,
        );
      }
    };
    _logger.info('✅ Queue sync callback wired to GossipSyncManager');

    // ===== PHASE 1 INTEGRATION: Offline Message Queue =====
    // Note: OfflineMessageQueue is already initialized elsewhere in the codebase
    // We'll get a reference to it when needed for handshake queue flush
    _logger.info('📤 Offline message queue integration ready for handshake flush');
    
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

// 🧹 REAL-TIME CLEANUP: Wire up central disconnect callback
_connectionManager.onCentralDisconnected = (deviceAddress) {
  _logger.info('🧹 Central disconnected callback: $deviceAddress');

  // Trigger real-time cleanup via ConnectionCleanupHandler
  _cleanupHandler.handleDisconnect(
    deviceId: deviceAddress,
    deviceAddress: deviceAddress,
  );
};

    await _stateManager.initialize();

_stateManager.onNameChanged = (name) {
  _logger.info('🎯 onNameChanged triggered: $name');
  _logger.info('  Current connection state: isConnected=${_currentConnectionInfo.isConnected}, isReady=${_currentConnectionInfo.isReady}');
  _logger.info('  Current mode: ${_stateManager.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"}');

  // Do NOT flip connection flags here. This callback reflects OUR name change, not the peer's identity.
  if (name == null || name.isEmpty) {
    _logger.info('  → Name cleared; no connection state change');
    return;
  }

  // If a link is active, re-send our identity with the updated name.
  try {
    if (_stateManager.isPeripheralMode) {
      // Fire-and-forget; peripheral identity exchange uses notify
      _sendPeripheralIdentityExchange();
    } else if (_connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null) {
      requestIdentityExchange();
    } else {
      _logger.fine('  → No active link; will advertise updated name');
    }
  } catch (_) {}
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

      // 🧹 CRITICAL: Clear stale device deduplication state from previous sessions
      // The _uniqueDevices map is static and persists across app restarts
      // This ensures auto-connect attempts are reset for all devices
      // MUST be called BEFORE _setupDeduplicationListener() to prevent race condition
      DeviceDeduplicationManager.clearAll();
      _logger.info('🧹 Cleared stale device deduplication state');

      // 🆕 ENHANCEMENT 3: Register auto-connect callback
      _setupAutoConnectCallback();

      // 🆕 Setup deduplicated device stream listener
      _setupDeduplicationListener();

      // Complete initialization
      _initializationCompleter.complete();
      _logger.info('✅ BLEService initialization complete');

    } catch (e, stackTrace) {
      _logger.severe('❌ CRITICAL: BLEService initialization failed', e, stackTrace);

      // Try to complete with error to unblock waiters
      if (!_initializationCompleter.isCompleted) {
        _initializationCompleter.completeError(e, stackTrace);
      }

      // Update connection info to show error state
      _updateConnectionInfo(
        statusMessage: 'Initialization failed: ${e.toString()}',
        isScanning: false,
        isAdvertising: false,
      );

      // Re-throw to propagate error to caller
      rethrow;
    }
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

/// 🎯 SINGLE SOURCE OF TRUTH: Get authoritative advertising state
/// This method ensures we ALWAYS use AdvertisingManager's state, never a stale local copy
/// Future-proof: All advertising state queries go through this single method
bool get _authoritativeAdvertisingState {
  try {
    // 📡 NEW: Use AdvertisingManager as single source of truth
    return _advertisingManager.isAdvertising;
  } catch (e) {
    // ✅ FIX: Silently return false during initialization (before advertising manager is set up)
    // This is expected behavior, not an error condition
    return false; // Safe default: not advertising until explicitly started
  }
}

/// 🎯 ENHANCED: Connection info update with automatic advertising state preservation
/// This ensures advertising state is ALWAYS accurate and never accidentally cleared
///
/// CRITICAL: If isAdvertising is not explicitly passed, we read the authoritative state
/// This prevents the "both false" bug where scanning stops but advertising state gets lost
void _updateConnectionInfo({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  }) {
    // 🎯 AUTOMATIC STATE PRESERVATION: If advertising state not provided, read authoritative value
    // This prevents the "both false" bug where scanning updates accidentally clear advertising state
    final effectiveAdvertising = isAdvertising ?? _authoritativeAdvertisingState;

    _logger.fine('🔍 CONNECTION INFO UPDATE REQUEST:');
    _logger.fine('  - Input: isConnected=$isConnected, isReady=$isReady, otherUserName="$otherUserName"');
    _logger.fine('  - Input: statusMessage="$statusMessage", isScanning=$isScanning, isAdvertising=$isAdvertising (effective: $effectiveAdvertising), isReconnecting=$isReconnecting');
    _logger.fine('  - Current: isConnected=${_currentConnectionInfo.isConnected}, isReady=${_currentConnectionInfo.isReady}, otherUserName="${_currentConnectionInfo.otherUserName}"');
    _logger.fine('  - Current: isScanning=${_currentConnectionInfo.isScanning}, isAdvertising=${_currentConnectionInfo.isAdvertising}');

    final newInfo = _currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: effectiveAdvertising, // 🎯 ALWAYS use effective value
      isReconnecting: isReconnecting,
    );

    _logger.fine('  - New Info: isConnected=${newInfo.isConnected}, isReady=${newInfo.isReady}, otherUserName="${newInfo.otherUserName}"');
    _logger.fine('  - New Info: isScanning=${newInfo.isScanning}, isAdvertising=${newInfo.isAdvertising}');

    // Check if this is a meaningful change
    if (_shouldEmitConnectionInfo(newInfo)) {
      _currentConnectionInfo = newInfo;
      _lastEmittedConnectionInfo = newInfo;
      _connectionInfoController?.add(_currentConnectionInfo);
      _logger.fine('  - ✅ EMITTED: Connection info broadcast to UI');
      _logger.fine('  - Final State: ${_currentConnectionInfo.isConnected}/${_currentConnectionInfo.isReady} - "${_currentConnectionInfo.statusMessage}"');
      _logger.fine('  - Final State: isScanning=${_currentConnectionInfo.isScanning}, isAdvertising=${_currentConnectionInfo.isAdvertising}');
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

  /// 🆕 ENHANCEMENT 3: Setup auto-connect callback for known contacts
  void _setupAutoConnectCallback() {
    _logger.info('🔗 Setting up auto-connect callback for known contacts...');

    DeviceDeduplicationManager.onKnownContactDiscovered = (device, contactName) async {
      final deviceId = device.uuid.toString();
      _logger.info('👤 KNOWN CONTACT DISCOVERED: $contactName (${deviceId.substring(0, 8)}...)');

      try {
        // Check user preference
        final prefsRepo = PreferencesRepository();
        final autoConnectEnabled = await prefsRepo.getBool(
          PreferenceKeys.autoConnectKnownContacts,
        );

        if (!autoConnectEnabled) {
          _logger.info('🔗 AUTO-CONNECT: Disabled in settings - skipping $contactName');
          return;
        }

        _logger.info('🔗 AUTO-CONNECT: Enabled for $contactName - checking prerequisites...');

        // Check connection slot availability
        final currentSlots = _connectionManager.clientConnectionCount;
        final maxSlots = _connectionManager.maxClientConnections;

        if (!_connectionManager.canAcceptClientConnection) {
          _logger.warning('⚠️ AUTO-CONNECT: Cannot connect to $contactName - slots full ($currentSlots/$maxSlots)');
          return;
        }

        _logger.info('✅ AUTO-CONNECT: Slots available ($currentSlots/$maxSlots) for $contactName');

        // Check if already connected
        final alreadyConnected = _connectionManager.clientConnections
            .any((conn) => conn.peripheral.uuid.toString() == deviceId);

        if (alreadyConnected) {
          _logger.info('🔗 AUTO-CONNECT: Already connected to $contactName - skipping');
          return;
        }

        _logger.info('✅ AUTO-CONNECT: Not yet connected to $contactName - proceeding...');

        // Initiate auto-connect
        _logger.info('🚀 AUTO-CONNECT: Initiating connection to $contactName...');
        await connectToDevice(device);
        _logger.info('✅ AUTO-CONNECT: Successfully connected to $contactName!');

      } catch (e, stackTrace) {
        _logger.warning('❌ AUTO-CONNECT: Failed to connect to $contactName: $e');
        _logger.fine('Stack trace: $stackTrace');
      }
    };

    _logger.info('✅ Auto-connect callback registered successfully');
  }

  /// 🆕 Setup deduplicated device stream listener
  void _setupDeduplicationListener() {
    _logger.info('🔗 Setting up deduplicated device stream listener...');

    // ✅ Listen to deduplicated device stream and update UI
    DeviceDeduplicationManager.uniqueDevicesStream.listen((uniqueDevices) {
      _discoveredDevices = uniqueDevices.values.map((d) => d.peripheral).toList();
      _devicesController?.add(List.from(_discoveredDevices));

      _logger.fine('📡 Deduplicated devices updated: ${uniqueDevices.length} unique devices');
    });

    // ✅ Cleanup stale devices periodically
    Timer.periodic(Duration(minutes: 1), (timer) {
      DeviceDeduplicationManager.removeStaleDevices();
    });

    _logger.info('✅ Deduplicated device stream listener registered');
  }

  void _setupEventListeners() {
    // Central manager state changes
   centralManager.stateChanged.listen((event) async {
  _logger.info('Central BLE State changed: ${event.state}');
  
if (event.state == BluetoothLowEnergyState.poweredOff) {
  _updateConnectionInfo(isConnected: false, isReady: false, statusMessage: 'Bluetooth off');
  _disposeHandshakeCoordinator();

  // ✅ FIX: Only clear session state if there's actually a connection to clear
  // This prevents verbose "SESSION CLEARING" logs when nothing was connected
  final hasActiveSession = _stateManager.otherUserName != null ||
                           _connectedCentral != null ||
                           _connectionManager.connectedDevice != null;

  if (hasActiveSession) {
    _logger.fine('🔌 Active session detected - clearing session state (Central listener)');
    _stateManager.clearSessionState();
  } else {
    _logger.fine('🔵 No active session - skipping session clear (Central listener)');
  }
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

  // ✅ FIX: Only clear session state if there's actually a connection to clear
  // This prevents verbose "SESSION CLEARING" logs when nothing was connected
  final hasActiveSession = _stateManager.otherUserName != null ||
                           _connectedCentral != null ||
                           _connectionManager.connectedDevice != null;

  if (hasActiveSession) {
    _logger.fine('🔌 Active session detected - clearing session state (Peripheral listener)');
    _stateManager.clearSessionState();
  } else {
    _logger.fine('🔵 No active session - skipping session clear (Peripheral listener)');
  }

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

    // ✅ FIX: Pass advertising callback to startMeshNetworking
    await _connectionManager.startMeshNetworking(
      onStartAdvertising: () async {
        _logger.info('📡 [AUTO-RESTART] Starting peripheral mode via AdvertisingManager...');
        await startAsPeripheral();
        _logger.info('✅ [AUTO-RESTART] Peripheral mode started successfully');
      },
    );
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

// ✅ FIX: Only clear session state if there's actually a connection to clear
// This prevents verbose "SESSION CLEARING" logs when nothing was connected
final hasActiveSession = _stateManager.otherUserName != null ||
                         _connectedCentral != null ||
                         _connectionManager.connectedDevice != null;

if (hasActiveSession) {
  _logger.fine('🔌 Active session detected - clearing session state (Peripheral listener #2)');
  _stateManager.clearSessionState();
} else {
  _logger.fine('🔵 No active session - skipping session clear (Peripheral listener #2)');
}

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
  _logger.info('🔍 [DISCOVERY-DEBUG] ========================================');
  _logger.info('🔍 [DISCOVERY-DEBUG] DEVICE DISCOVERED!');
  _logger.info('🔍 [DISCOVERY-DEBUG] UUID: ${event.peripheral.uuid}');
  _logger.info('🔍 [DISCOVERY-DEBUG] RSSI: ${event.rssi}');
  _logger.info('🔍 [DISCOVERY-DEBUG] Advertisement data:');
  _logger.info('   - Service UUIDs: ${event.advertisement.serviceUUIDs}');
  _logger.info('   - Device name: ${event.advertisement.name ?? "none"}');
  _logger.info('   - Manufacturer data: ${event.advertisement.manufacturerSpecificData.length} entries');

  if (event.advertisement.manufacturerSpecificData.isNotEmpty) {
    for (var i = 0; i < event.advertisement.manufacturerSpecificData.length; i++) {
      final mfg = event.advertisement.manufacturerSpecificData[i];
      _logger.info('     [$i] ID=0x${mfg.id.toRadixString(16)}, Data=${mfg.data.length} bytes');
    }
  }
  _logger.info('🔍 [DISCOVERY-DEBUG] ========================================');

  // ✅ Use deduplication manager instead of direct list management
  DeviceDeduplicationManager.processDiscoveredDevice(event);

  // Check hints if manufacturer data present
  final mfgData = event.advertisement.manufacturerSpecificData;
  if (mfgData.isNotEmpty) {
    _logger.info('🔍 [DISCOVERY-DEBUG] Checking manufacturer data for hints...');
    for (final data in mfgData) {
      if (data.id == 0x2E19 && data.data.length == 15) {
        _logger.info('🔍 [DISCOVERY-DEBUG] Found PakConnect hint data (0x2E19, 15 bytes)');
        // Our hint format - check for matches
        final match = await _hintScanner.checkDevice(data.data);

        if (match.isContact) {
          _logger.info('✅✅✅ [DISCOVERY-DEBUG] CONTACT NEARBY: ${match.contactName} ✅✅✅');
          _hintMatchController?.add('✅ Contact nearby: ${match.contactName}');
        } else if (match.isIntro) {
          _logger.info('👋 INTRO MATCH: ${match.introHint?.displayName}');
          _hintMatchController?.add('👋 Found: ${match.introHint?.displayName} (from QR)');
        }
      }
    }
  }
});

    // Connection state changes
centralManager.connectionStateChanged.listen((event) {
  _logger.info('Connection state: ${event.peripheral.uuid} → ${event.state}');
  
  if (event.state == ConnectionState.disconnected) {
    final deviceAddress = event.peripheral.uuid.toString();

    // 🧹 REAL-TIME CLEANUP: Trigger immediate cleanup for client disconnect
    _cleanupHandler.handleDisconnect(
      deviceId: deviceAddress,
      deviceAddress: deviceAddress,
    );

    // Remove disconnected device from discovery list
    _discoveredDevices.removeWhere((d) => d.uuid == event.peripheral.uuid);
    _devicesController?.add(List.from(_discoveredDevices));

    if (_connectionManager.connectedDevice?.uuid == event.peripheral.uuid) {
      _logger.info('Our device disconnected - clearing state');

      // Get contact ID before clearing state (for cleanup)
      final contactId = _stateManager.currentSessionId;

      _updateConnectionInfo(
        isConnected: false,
        isReady: false,
        otherUserName: null,  // Clear the name
        statusMessage: 'Disconnected'
      );

      _connectionManager.clearConnectionState(
        keepMonitoring: _connectionManager.isMonitoring,
        contactId: contactId, // Pass contact ID for immediate cleanup
      );
      _disposeHandshakeCoordinator();
      _stateManager.clearSessionState();
    }
  }
});

// Peripheral connection state changes (Android only)
if (Platform.isAndroid) {
  peripheralManager.connectionStateChanged.listen((event) {
    _logger.info('Peripheral connection state: ${event.central.uuid} → ${event.state}');

    if (event.state == ConnectionState.connected) {
      _logger.info('Central connected to our peripheral: ${event.central.uuid}');
      _connectedCentral = event.central;

      // Phase 2b: Notify connection manager of incoming connection
      _connectionManager.handleCentralConnected(event.central);

      _updateConnectionInfo(
        isConnected: false,  // Not ready yet
        isReady: false,
        statusMessage: 'Connected - exchanging names...',
        isAdvertising: _connectionManager.isAdvertising  // Use connection manager's advertising state
      );

      // Note: Handshake will be initiated after first characteristic write
      // when _connectedCharacteristic becomes available

    } else if (event.state == ConnectionState.disconnected) {
      if (_connectedCentral?.uuid == event.central.uuid) {
        _logger.info('Connected central disconnected from our peripheral');

        // Phase 2b: Notify connection manager of disconnection
        _connectionManager.handleCentralDisconnected(event.central);

        _connectedCentral = null;
        _connectedCharacteristic = null;
        _peripheralHandshakeStarted = false;
        _disposeHandshakeCoordinator();
        _stateManager.clearSessionState();

        // Phase 2b: Connection manager handles advertising resume automatically
        // Just update UI state
        _updateConnectionInfo(
          isConnected: false,
          isReady: false,
          isAdvertising: _connectionManager.isAdvertising,
          otherUserName: null,
          statusMessage: _connectionManager.isAdvertising ? 'Advertising - waiting for connection' : 'At connection limit'
        );
      }
    }
  });

  // Phase 2b: Characteristic subscription tracking
  // Note: bluetooth_low_energy plugin doesn't expose a dedicated subscription state event
  // Subscription is implicitly tracked through characteristicWriteRequested events
  // This is a platform limitation - no action needed unless plugin API changes
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

/// Get ephemeral session ID for mesh routing (NOT persistent identity)
///
/// 🔧 CRITICAL: Mesh routing uses ephemeral keys for privacy
/// - Used in: MeshNetworkingService, TopologyManager, SmartMeshRouter, MeshRelayEngine
/// - Rotates per app session - prevents long-term tracking
/// - DO NOT use persistent key for mesh routing!
Future<String> getMyEphemeralId() async {
  return _stateManager.myEphemeralId ?? '';
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

    // 🔧 FIX: If this is a handshake message but coordinator doesn't exist yet, buffer it
    // The buffered messages will be processed when coordinator is created (see _startHandshakeProtocol)
    if (_isHandshakeMessage(protocolMessage.type) && _handshakeCoordinator == null) {
      _logger.info('🔄 BUFFER: Handshake message arrived before coordinator ready - buffering ${protocolMessage.type}');
      _messageBuffer.add(_BufferedMessage(
        data: data,
        isFromPeripheral: isFromPeripheral,
        central: central,
        characteristic: characteristic,
        timestamp: DateTime.now(),
      ));
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

  // 🔧 FIX: Check if this is a message chunk (fragmented message)
  // Only attempt to parse as chunk if the payload looks like our chunk-string format
  bool isChunk = false;
  MessageChunk? chunk;

  bool looksLikeChunkStringLocal(Uint8List bytes) {
    final max = bytes.length < 128 ? bytes.length : 128;
    int pipes = 0;
    for (var i = 0; i < max; i++) {
      final b = bytes[i];
      if (b == 0x7C) pipes++; // '|'
      // Reject most control chars except TAB(9), LF(10), CR(13)
      if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return false;
      // Reject extended binary (chunk strings are ASCII)
      if (b > 0x7E) return false;
    }
    return pipes >= 4; // id|idx|total|isBinary|content
  }

  if (looksLikeChunkStringLocal(data)) {
    try {
      chunk = MessageChunk.fromBytes(data);
      isChunk = true;
    } catch (e) {
      // Not a valid chunk despite looking like one
    }
  }

  // If it's a chunk, reassemble and check if it's a handshake protocol message
  if (isChunk && chunk != null) {
    // Use MessageReassembler for proper chunk handling (get raw bytes)
    final reassembledData = _protocolMessageReassembler.addChunkBytes(chunk);
    
    if (reassembledData != null) {
      // Message fully reassembled - parse as protocol message
      try {
        final protocolMessage = ProtocolMessage.fromBytes(reassembledData);
        
        // Check if it's a handshake message
        if (_isHandshakeMessage(protocolMessage.type)) {
          _logger.info('📦 Reassembled handshake message: ${protocolMessage.type}');
          
          // Route to coordinator if it exists and is active
          if (_handshakeCoordinator != null && 
              !_handshakeCoordinator!.isComplete &&
              !_handshakeCoordinator!.hasFailed) {
            await _handshakeCoordinator!.handleReceivedMessage(protocolMessage);
            return;
          }
          
          // Buffer if coordinator doesn't exist yet
          if (_handshakeCoordinator == null) {
            _logger.info('🔄 BUFFER: Reassembled handshake message before coordinator ready - buffering ${protocolMessage.type}');
            _messageBuffer.add(_BufferedMessage(
              data: reassembledData,
              isFromPeripheral: isFromPeripheral,
              central: central,
              characteristic: characteristic,
              timestamp: DateTime.now(),
            ));
            return;
          }
        }
        
        // Not a handshake message, pass to regular protocol handler
        await _handleReceivedData(reassembledData, isFromPeripheral: isFromPeripheral, central: central, characteristic: characteristic);
        return;
        
      } catch (e) {
        // Not a protocol message, this shouldn't happen for reassembled messages
        _logger.warning('Reassembled message is not a valid protocol message: $e');
        return;
      }
    } else {
      // Still waiting for more chunks
      return;
    }
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
  // 🔑 SIMPLIFIED: Use any available ID - Noise resolution handles the rest
  // Priority: persistent key (if paired) → ephemeral ID → current session ID
  String? senderPublicKey;

  if (_stateManager.theirEphemeralId != null) {
    // Check if we have persistent key (paired)
    final persistentKey = _stateManager.getPersistentKeyFromEphemeral(_stateManager.theirEphemeralId!);

    if (persistentKey != null) {
      // Use persistent key - Noise will resolve to ephemeral internally
      senderPublicKey = persistentKey;
      _logger.info('🔐 Decrypting with persistent key (auto-resolves to ephemeral): ${persistentKey.substring(0, 8)}...');
    } else {
      // Not paired yet, use ephemeral ID directly
      senderPublicKey = _stateManager.theirEphemeralId;
      _logger.info('🔐 Decrypting with ephemeral ID: ${_stateManager.theirEphemeralId!.substring(0, 8)}...');
    }
  } else if (_stateManager.currentSessionId != null) {
    // Fallback to current session ID
    senderPublicKey = _stateManager.currentSessionId;
    _logger.info('🔐 Decrypting with session ID: ${_stateManager.currentSessionId!.substring(0, 8)}...');
  } else {
    _logger.warning('🔐 No sender identity available - decryption will fail');
  }

  final content = await _messageHandler.processReceivedData(
    data,
    onMessageIdFound: (id) => extractedMessageId = id,
    senderPublicKey: senderPublicKey,
    contactRepository: _stateManager.contactRepository,
  );
  
  if (content != null) {
    print('🟢🟢🟢 BLE_SERVICE EMITTING MESSAGE TO STREAM 🟢🟢🟢');
    print('🟢 Content length: ${content.length}');
    print('🟢 Content preview: ${content.substring(0, content.length > 100 ? 100 : content.length)}');
    print('🟢 Number of stream listeners: ${_messagesController?.hasListener ?? false}');
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
    _logger.info('📡 Starting peripheral advertising (dual-role mode)...');

    // 🔧 DUAL-ROLE FIX: NO mode switching - peripheral and central run simultaneously
    // We NEVER stop central mode or disconnect - both roles coexist
    // Only skip if already advertising to avoid redundant operations

    if (_advertisingManager.isAdvertising) {
      _logger.fine('📡 Already advertising - skipping redundant peripheral start');
      return;
    }

    // ✅ DUAL-ROLE: Track peripheral connection state (device is always both central+peripheral)
    _stateManager.setPeripheralMode(true);

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

      // 📡 NEW: Use AdvertisingManager (SINGLE RESPONSIBILITY)
      // Get my public key for identity hint
      final myPublicKey = await _stateManager.getMyPersistentId();

      // Start advertising with settings-aware hint inclusion
      final advertisingStarted = await _advertisingManager.startAdvertising(
        myPublicKey: myPublicKey,
        timeout: Duration(seconds: 5),
        skipIfAlreadyAdvertising: true,
      );

      if (!advertisingStarted) {
        throw Exception('Failed to start advertising - peripheral not ready');
      }

      // ⚠️ REMOVED: _isAdvertising assignment - connection manager tracks state
      _updateConnectionInfo(isAdvertising: true, statusMessage: 'Advertising - dual-role active');
      _logger.info('✅ Peripheral advertising active (dual-role - central still running)!');
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
      // Get my public key for identity hint
      final myPublicKey = await _stateManager.getMyPersistentId();

      // 📡 NEW: Use AdvertisingManager.refreshAdvertising (SINGLE METHOD)
      // This ensures consistent advertisement structure every time
      await _advertisingManager.refreshAdvertising(
        myPublicKey: myPublicKey,
        showOnlineStatus: showOnlineStatus,
      );

      _updateConnectionInfo(isAdvertising: true, statusMessage: 'Advertising - discoverable');
      _logger.info('✅ Advertising refreshed successfully!');

    } catch (e, stack) {
      _logger.severe('❌ Failed to refresh advertising: $e', e, stack);
      _updateConnectionInfo(isAdvertising: false, statusMessage: 'Advertising refresh failed');
    }
  }

  // ❌ REMOVED: _resumePeripheralAdvertising() method
  // This method is no longer needed because:
  // 1. Advertising is managed by AdvertisingManager (single responsibility)
  // 2. Advertising resume is handled by startAsPeripheral() when needed
  // 3. Connection manager handles advertising state based on connection limits

  Future<void> startAsCentral() async {
  _logger.info('Starting as Central (scanner)...');

    // Preserve session ID across mode switches
    final preservedOtherPublicKey = _stateManager.currentSessionId;
  final preservedOtherName = _stateManager.otherUserName;
  final preservedTheyHaveUs = _stateManager.theyHaveUsAsContact;
  final preservedWeHaveThem = await _stateManager.weHaveThemAsContact;
  
  // Set mode
  _stateManager.setPeripheralMode(false);
  // Phase 2b: Connection manager no longer has peripheral mode flag

  // Clear peripheral-specific state (but NOT encryption keys!)
  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralHandshakeStarted = false;
  _peripheralNegotiatedMTU = null;
  _peripheralMtuReady = false;  // Reset MTU ready flag

  // Phase 2b: Stop mesh networking (stops both advertising and scanning)
  try {
    await _connectionManager.stopMeshNetworking();
    // ⚠️ REMOVED: _isAdvertising assignment - connection manager tracks state
  } catch (e) {
    // ⚠️ REMOVED: _isAdvertising assignment - connection manager tracks state
    _logger.fine('Could not stop mesh networking: $e');
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
  // Phase 2b: Removed peripheral mode check - scanning and advertising can now run simultaneously

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
  
  _logger.info('🔍 [SCAN-DEBUG] ========================================');
  _logger.info('🔍 [SCAN-DEBUG] About to start discovery');
  _logger.info('🔍 [SCAN-DEBUG] Source: ${source.name}');
  _logger.info('🔍 [SCAN-DEBUG] _isDiscoveryActive: $_isDiscoveryActive');
  _logger.info('🔍 [SCAN-DEBUG] isPeripheralMode: ${_stateManager.isPeripheralMode}');
  _logger.info('🔍 [SCAN-DEBUG] Service UUID filter: ${BLEConstants.serviceUUID}');
  _logger.info('🔍 [SCAN-DEBUG] ========================================');

  try {
    _logger.info('🔍 [SCAN-DEBUG] Setting _isDiscoveryActive = true');
    _isDiscoveryActive = true;

    _logger.info('🔍 [SCAN-DEBUG] Calling centralManager.startDiscovery()...');
    await centralManager.startDiscovery(serviceUUIDs: [BLEConstants.serviceUUID]);

    _logger.info('✅✅✅ [SCAN-DEBUG] DISCOVERY STARTED! ✅✅✅');
    _logger.info('🔍 [SCAN-DEBUG] Now scanning for service UUID: ${BLEConstants.serviceUUID}');
    _logger.info('🔍 ${source.name.toUpperCase()} discovery started successfully');

    // 🔧 FIX P2: Confirm dual-role operation (advertising + scanning simultaneously)
    if (_authoritativeAdvertisingState && _stateManager.isPeripheralMode) {
      _logger.info('🔧 DUAL-ROLE: ✅ Both advertising AND scanning active simultaneously');
      _logger.info('🔧 DUAL-ROLE: Advertising state: $_authoritativeAdvertisingState, Scanning state: $_isDiscoveryActive');
      _updateConnectionInfo(
        isAdvertising: true,
        isScanning: true,
        statusMessage: 'Dual-role: Advertising + Scanning'
      );
    }
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
    // Single-link policy: if we already have an inbound (server) link to this peer, adopt it
    try {
      final inboundId = _connectedCentral?.uuid.toString();
      if (inboundId != null && inboundId == device.uuid.toString()) {
        _logger.info('🔀 Single-link: inbound link exists to ${device.uuid} — adopting inbound, skipping outbound connect');
        _updateConnectionInfo(statusMessage: 'Connected via inbound link');
        return;
      }
    } catch (_) {}

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

    // 🔧 CRITICAL: Get ephemeral ID from EphemeralKeyManager (NOT BLEStateManager)
    // BLEStateManager._myEphemeralId is for pairing messages only
    // HandshakeCoordinator uses EphemeralKeyManager for actual handshake
    final myEphemeralId = EphemeralKeyManager.generateMyEphemeralKey();
    final myPublicKey = await _stateManager.getMyPersistentId();
    final myDisplayName = _stateManager.myUserName ?? 'User';

    _logger.info('🔧 INVESTIGATION: Handshake using EphemeralKeyManager');
    _logger.info('📱 My ephemeral ID (from EphemeralKeyManager): ${myEphemeralId.length > 16 ? '${myEphemeralId.substring(0, 16)}...' : myEphemeralId}');
    _logger.info('🔒 My persistent key (not sent during handshake): ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 16)}...' : myPublicKey}');
    _logger.info('📝 My display name: $myDisplayName');
    
    // For comparison, log BLEStateManager ephemeral ID (NOT used here)
    final stateManagerEphemeralId = _stateManager.myEphemeralId;
    if (stateManagerEphemeralId != null) {
      _logger.info('⚠️ BLEStateManager ephemeral ID (NOT used in handshake): ${stateManagerEphemeralId.substring(0, 16)}...');
      if (myEphemeralId != stateManagerEphemeralId) {
        _logger.warning('⚠️ DIFFERENT ephemeral IDs! HandshakeCoordinator uses EphemeralKeyManager, NOT BLEStateManager!');
      }
    }
    
    // Create handshake coordinator
    _handshakeCoordinator = HandshakeCoordinator(
      myEphemeralId: myEphemeralId,
      myPublicKey: myPublicKey,
      myDisplayName: myDisplayName,
      contactRepo: _contactRepo,
      sendMessage: _sendHandshakeMessage,
      onHandshakeComplete: _onHandshakeComplete,
      phaseTimeout: Duration(seconds: 10),
      // ===== PHASE 1 INTEGRATION: Queue flush on handshake success =====
      onHandshakeSuccess: (peerEphemeralId) async {
        _logger.info('📤 PHASE 1: Handshake success - flushing queue for peer ${peerEphemeralId.substring(0, 8)}...');

        // Get OfflineMessageQueue from AppCore (shared singleton)
        if (AppCore.instance.isInitialized) {
          await AppCore.instance.messageQueue.flushQueueForPeer(peerEphemeralId);
          _logger.info('✅ PHASE 1: Queue flush completed for peer');
        } else {
          _logger.warning('⚠️ PHASE 1: AppCore not initialized - skipping queue flush');
        }
      },
      // Notify connection manager of handshake state (for health check coordination)
      onHandshakeStateChanged: (inProgress) {
        setHandshakeInProgress(inProgress);
      },
    );

    // Listen to phase changes for UI feedback
    _handshakePhaseSubscription = _handshakeCoordinator!.phaseStream.listen((phase) async {
      _logger.info('🤝 Handshake phase: $phase');
      _updateConnectionInfo(statusMessage: _getPhaseMessage(phase));

      // 🔧 FIX: Update connection state when handshake completes
      if (phase == ConnectionPhase.complete) {
        _updateConnectionInfo(isConnected: true, statusMessage: 'Connected');
      }

      // Phase 2b: Connection manager handles advertising stop automatically
      // when connection limit is reached (hybrid advertising strategy)

      // 🔧 FIX: Disconnect on handshake failure
      if (phase == ConnectionPhase.failed || phase == ConnectionPhase.timeout) {
        _logger.warning('⚠️ Handshake failed/timeout - disconnecting BLE connection');

        // 🚨 CRITICAL: Set isReady=false IMMEDIATELY to prevent reconnection loop
        _updateConnectionInfo(
          isReady: false,
          statusMessage: 'Connection failed - handshake timeout',
        );

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
Future<void> _onHandshakeComplete(String ephemeralId, String displayName, String? noisePublicKey) async {
  _logger.info('🎉 Handshake complete! Connected to: $displayName');
  _logger.info('   Their ephemeral ID: ${ephemeralId.length > 16 ? '${ephemeralId.substring(0, 16)}...' : ephemeralId}');

  // STEP 3: Store their ephemeral ID (separate from persistent key)
  _stateManager.setTheirEphemeralId(ephemeralId, displayName);

  // Store identity in state manager (this sets display name)
  // Note: For now we use ephemeralId as publicKey until pairing completes
  _stateManager.setOtherDeviceIdentity(ephemeralId, displayName);

  // 🔧 FIX: Store Noise session public key as persistent key
  if (noisePublicKey != null) {
    _logger.info('🔐 Storing peer Noise public key as persistent key');
    await _stateManager.handlePersistentKeyExchange(noisePublicKey);
  } else {
    _logger.warning('⚠️ No Noise public key provided - messages will be unencrypted');
  }

  // NOTE: Queue flush is handled by OfflineMessageQueue in onHandshakeSuccess callback (line 1894)
  // MessageRouter now delegates to OfflineMessageQueue, so no need for redundant flush here

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

  // ✅ FIX: Start GossipSyncManager now that connection is ready
  if (_gossipSyncManager != null && !_gossipSyncManager!.isRunning) {
    await _gossipSyncManager!.start();
    _logger.info('✅ GossipSyncManager started (connection established)');
  }

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
    case ConnectionPhase.noiseHandshake1Sent:
      return 'Establishing secure session...';
    case ConnectionPhase.noiseHandshake2Sent:
      return 'Finalizing encryption...';
    case ConnectionPhase.noiseHandshakeComplete:
      return 'Secure session established...';
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

// ========== SPY MODE CALLBACK HANDLERS ==========

/// Handle spy mode detection (chatting with friend anonymously)
void _handleSpyModeDetected(SpyModeInfo info) {
  _logger.info('🕵️ SPY MODE DETECTED: User is chatting with ${info.contactName} anonymously');

  // Emit spy mode event to UI layer
  _spyModeDetectedController?.add(info);
  _logger.fine('🕵️ Emitted spy mode event to UI');
}

/// Handle identity revealed notification
void _handleIdentityRevealed(String contactName) {
  _logger.info('🕵️ IDENTITY REVEALED: Contact $contactName now knows your identity');

  // Emit identity revealed event to UI layer
  _identityRevealedController?.add(contactName);
  _logger.fine('🕵️ Emitted identity revealed event to UI');
}

/// Check if message type is part of handshake protocol (sequential, no ACKs)
bool _isHandshakeMessage(ProtocolMessageType type) {
  return type == ProtocolMessageType.connectionReady ||
         type == ProtocolMessageType.identity ||
         type == ProtocolMessageType.noiseHandshake1 ||
         type == ProtocolMessageType.noiseHandshake2 ||
         type == ProtocolMessageType.noiseHandshake3 ||
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
  // 🔧 CRITICAL FIX: Protocol messages must be fragmented like user messages
  // ProtocolMessage.toBytes() returns binary data (compressed or uncompressed)
  // This CANNOT be sent directly to BLE - it must be:
  // 1. Fragmented into MTU-sized chunks
  // 2. Base64-encoded for text transmission
  // 3. Sent with proper headers for reassembly
  
  // Add write to queue to serialize operations
  final completer = Completer<void>();

  _writeQueue.add(() async {
    try {
      // Convert protocol message to bytes (may be compressed binary)
      final messageBytes = message.toBytes();
      
      // Generate unique message ID for fragmentation
      final msgId = 'proto_${message.type.name}_${DateTime.now().millisecondsSinceEpoch}';
      
      // Get MTU size with fallback to safe default
      final mtuSize = _connectionManager.mtuSize ?? BLEConstants.maxMessageLength;
      
      // Fragment the binary data (handles base64 encoding + MTU sizing)
      final chunks = MessageFragmenter.fragmentBytes(
        messageBytes,
        mtuSize,
        msgId,
      );
      
      _logger.fine('📦 Protocol message fragmented into ${chunks.length} chunk(s)');
      
      // Send each chunk with delay to prevent BLE congestion
      if (_connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null) {
        for (int i = 0; i < chunks.length; i++) {
          await centralManager.writeCharacteristic(
            _connectionManager.connectedDevice!,
            _connectionManager.messageCharacteristic!,
            value: chunks[i].toBytes(),
            type: GATTCharacteristicWriteType.withResponse,
          );
          
          // Small delay between chunks to prevent GATT congestion
          if (i < chunks.length - 1) {
            await Future.delayed(Duration(milliseconds: 20));
          }
        }
      } else if (isPeripheralMode && _connectedCentral != null && _connectedCharacteristic != null) {
        for (int i = 0; i < chunks.length; i++) {
          await peripheralManager.notifyCharacteristic(
            _connectedCentral!,
            _connectedCharacteristic!,
            value: chunks[i].toBytes(),
          );
          
          // Small delay between chunks to prevent GATT congestion
          if (i < chunks.length - 1) {
            await Future.delayed(Duration(milliseconds: 20));
          }
        }
      }
      
      completer.complete();
    } catch (e) {
      _logger.warning('⚠️ Protocol message send failed: $e');
      completer.completeError(e);
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
  void setHandshakeInProgress(bool inProgress) => _connectionManager.setHandshakeInProgress(inProgress);
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

    _updateConnectionInfo(statusMessage: 'Bluetooth ready for dual-role operation');

    // ✅ FIX: Start mesh networking if it was deferred during initialization
    if (!_meshNetworkingStarted) {
      _logger.info('🔥 Starting mesh networking (Bluetooth now available)...');
      _meshNetworkingStarted = true; // ✅ FIX: Set immediately to prevent duplicate starts from other listeners
      Future.delayed(Duration(milliseconds: 500), () async {
        try {
          await _connectionManager.startMeshNetworking(
            onStartAdvertising: () async {
              _logger.info('📡 [DEFERRED-START] Starting peripheral mode via AdvertisingManager...');
              await startAsPeripheral();
              _logger.info('✅ [DEFERRED-START] Peripheral mode started successfully');
            },
          );
          _logger.info('✅ Mesh advertising active - device is now discoverable');
        } catch (e) {
          _logger.warning('Failed to start mesh networking: $e');
          _meshNetworkingStarted = false; // Reset on failure so it can be retried
        }
      });
      return;
    }

    // Only restart if we actually lost advertising (not just a state monitor callback)
    if (!_authoritativeAdvertisingState && _stateManager.isPeripheralMode) {
      _logger.warning('🔵 Advertising was lost - restarting mesh networking');
      Future.delayed(Duration(milliseconds: 500), () async {
        try {
          await _connectionManager.startMeshNetworking(
            onStartAdvertising: () async {
              _logger.info('📡 [LOST-ADV-RESTART] Starting peripheral mode via AdvertisingManager...');
              await startAsPeripheral();
              _logger.info('✅ [LOST-ADV-RESTART] Peripheral mode started successfully');
            },
          );
        } catch (e) {
          _logger.warning('Failed to restart mesh networking: $e');
        }
      });
    } else {
      _logger.fine('🔵 Peripheral already advertising - no restart needed');
    }
  }

  /// Handle when Bluetooth becomes unavailable
  void _onBluetoothBecameUnavailable() {
    _logger.warning('🔵 Bluetooth state monitor: Bluetooth became unavailable');

    // ✅ FIX: Only clear session state if there's actually a connection to clear
    // This prevents verbose "SESSION CLEARING" logs when nothing was connected
    final hasActiveSession = _stateManager.otherUserName != null ||
                             _connectedCentral != null ||
                             _connectionManager.connectedDevice != null;

    if (hasActiveSession) {
      _logger.info('🔌 Active connection detected - clearing session state');
      // Clear all connections and reset state
      _disposeHandshakeCoordinator();
      _stateManager.clearSessionState();
    } else {
      _logger.fine('🔵 No active session - skipping session clear (already disconnected)');
      // Just dispose handshake coordinator if it exists
      _disposeHandshakeCoordinator();
    }

    // Always reset peripheral state variables
    _connectedCentral = null;
    _connectedCharacteristic = null;
    _peripheralHandshakeStarted = false;

    // ✅ FIX #3: Provide specific status message based on Bluetooth state
    final bluetoothMonitor = BluetoothStateMonitor.instance;
    String statusMessage;

    switch (bluetoothMonitor.currentState) {
      case BluetoothLowEnergyState.poweredOff:
        statusMessage = '📴 Bluetooth is turned off - please enable it in settings';
        break;
      case BluetoothLowEnergyState.unauthorized:
        statusMessage = '🔒 Bluetooth permission required - grant permission in app settings';
        break;
      case BluetoothLowEnergyState.unsupported:
        statusMessage = '❌ Bluetooth Low Energy not supported on this device';
        break;
      case BluetoothLowEnergyState.unknown:
        statusMessage = '⚠️ Bluetooth state unknown - checking...';
        break;
      default:
        statusMessage = '⚠️ Bluetooth unavailable - mesh networking requires Bluetooth';
    }

    // Update connection info with appropriate message
    _updateConnectionInfo(
      isConnected: false,
      isReady: false,
      isScanning: false,
      isAdvertising: false,
      otherUserName: null,
      statusMessage: statusMessage,
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

  // Dispose Phase 1 components
  _gossipSyncManager?.stop();
  _offlineMessageQueue?.dispose();

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
  _spyModeDetectedController?.close();
  _identityRevealedController?.close();
}
}
