import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import '../../core/interfaces/i_ble_service_facade.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/interfaces/i_ble_platform_host.dart';
import '../../core/interfaces/i_ble_connection_service.dart';
import '../../core/interfaces/i_ble_messaging_service.dart';
import '../../core/interfaces/i_ble_discovery_service.dart';
import '../../core/interfaces/i_ble_advertising_service.dart';
import '../../core/interfaces/i_ble_handshake_service.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/models/ble_server_connection.dart';
import '../../core/bluetooth/handshake_coordinator.dart';
import 'ble_connection_service.dart';
import 'ble_messaging_service.dart';
import 'ble_message_handler_facade_impl.dart';
import 'ble_discovery_service.dart';
import 'ble_advertising_service.dart';
import 'ble_handshake_service.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import 'ble_state_manager.dart';
import 'ble_state_manager_facade.dart';
import 'ble_connection_manager.dart';
import 'ble_message_handler.dart';
import '../repositories/intro_hint_repository.dart';
import '../repositories/contact_repository.dart';
import '../services/seen_message_store.dart';
import '../../core/bluetooth/advertising_manager.dart';
import '../../core/bluetooth/peripheral_initializer.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../core/services/hint_scanner_service.dart';
import '../../core/bluetooth/ble_platform_host.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/di/service_locator.dart';
import '../../core/services/security_manager.dart';
import '../../core/utils/string_extensions.dart';
import '../../core/models/connection_state.dart' show ChatConnectionState;
import '../repositories/user_preferences.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/security/security_types.dart';

/// Main orchestrator for the entire BLE stack.
///
/// Phase 2A Migration: Facade pattern that coordinates 5 sub-services
/// and provides unified public API. Gradually replaces BLEService.
///
/// Responsibilities:
/// - Initialize all sub-services in correct order
/// - Coordinate cross-service concerns (handshake → messaging transition)
/// - Provide unified public API for consumers
/// - Manage Bluetooth state monitoring and recovery
/// - Integrate mesh networking via callback handlers
/// - Handle graceful shutdown and resource cleanup
class BLEServiceFacade implements IBLEServiceFacade, IConnectionService {
  final _logger = Logger('BLEServiceFacade');
  final IBLEPlatformHost _platformHost;
  final BLEStateManagerFacade _stateManager;
  final BLEMessageHandler _messageHandler;
  late final BLEMessageHandlerFacadeImpl _messageHandlerFacade;
  final HintScannerService _hintScanner;
  final IntroHintRepository _introHintRepository;
  final BluetoothStateMonitor _bluetoothStateMonitor;
  final ContactRepository _contactRepository;
  late final BLEConnectionManager _connectionManager;
  late final PeripheralInitializer _peripheralInitializer;
  late final AdvertisingManager _advertisingManager;

  // Sub-services (lazy-initialized)
  BLEConnectionService? _connectionService;
  IBLEMessagingService? _messagingService;
  IBLEDiscoveryService? _discoveryService;
  IBLEAdvertisingService? _advertisingService;
  IBLEHandshakeService? _handshakeService;

  // State
  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Ready',
  );

  // Timer for delayed responder handshake (collision handling)
  Timer? _serverHandshakeTimer;

  final Set<void Function(ConnectionInfo)> _connectionInfoListeners = {};
  final Set<void Function(String)> _hintMatchListeners = {};
  Future<bool> Function(QueueSyncMessage message, String fromNodeId)?
  _queueSyncHandler;
  final List<dynamic> _handshakeMessageBuffer = [];
  final Set<void Function(SpyModeInfo)> _spyModeListeners = {};
  final Set<void Function(String)> _identityListeners = {};
  StreamSubscription<ConnectionInfo>? _connectionInfoSubscription;
  StreamSubscription<CentralConnectionStateChangedEventArgs>?
  _peripheralConnectionSub;
  StreamSubscription<CentralMTUChangedEventArgs>? _peripheralMtuSub;
  StreamSubscription<GATTCharacteristicNotifyStateChangedEventArgs>?
  _peripheralNotifyStateSub;
  StreamSubscription<GATTCharacteristicWriteRequestedEventArgs>?
  _peripheralWriteSub;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>? _centralNotifySub;
  bool _peripheralEventsBound = false;

  // Initialization state
  final Completer<void> _initializationCompleter = Completer<void>();
  bool _connectionSetupComplete = false;
  bool _discoveryInitialized = false;

  bool get isInitialized => _initializationCompleter.isCompleted;

  BLEServiceFacade({
    IBLEPlatformHost? platformHost,
    BLEConnectionService? connectionService,
    IBLEMessagingService? messagingService,
    IBLEDiscoveryService? discoveryService,
    IBLEAdvertisingService? advertisingService,
    IBLEHandshakeService? handshakeService,
    BLEStateManagerFacade? stateManager,
    BLEStateManager? legacyStateManager,
    BLEMessageHandler? messageHandler,
    HintScannerService? hintScanner,
    IntroHintRepository? introHintRepository,
    BluetoothStateMonitor? bluetoothStateMonitor,
    BLEConnectionManager? connectionManager,
    PeripheralInitializer? peripheralInitializer,
    AdvertisingManager? advertisingManager,
    ContactRepository? contactRepository,
  }) : _platformHost = platformHost ?? BlePlatformHost(),
       _stateManager =
           stateManager ??
           BLEStateManagerFacade(legacyStateManager: legacyStateManager),
       _messageHandler = messageHandler ?? BLEMessageHandler(),
       _hintScanner = hintScanner ?? HintScannerService(),
       _introHintRepository = introHintRepository ?? IntroHintRepository(),
       _bluetoothStateMonitor =
           bluetoothStateMonitor ?? BluetoothStateMonitor.instance,
       _contactRepository = contactRepository ?? ContactRepository(),
       _connectionService = connectionService,
       _messagingService = messagingService,
       _discoveryService = discoveryService,
       _advertisingService = advertisingService,
       _handshakeService = handshakeService {
    _connectionManager =
        connectionManager ??
        BLEConnectionManager(
          centralManager: _platformHost.centralManager,
          peripheralManager: _platformHost.peripheralManager,
        );
    _connectionManager.onInboundDuplicateRejected = (address) {
      _handshakeService?.disposeHandshakeCoordinator();
    };
    _peripheralInitializer =
        peripheralInitializer ??
        PeripheralInitializer(_platformHost.peripheralManager);
    _advertisingManager =
        advertisingManager ??
        AdvertisingManager(
          peripheralInitializer: _peripheralInitializer,
          peripheralManager: _platformHost.peripheralManager,
          introHintRepo: _introHintRepository,
        );

    _messageHandlerFacade = BLEMessageHandlerFacadeImpl(
      _messageHandler,
      SeenMessageStore.instance,
      connectionManager: _connectionManager,
      stateManager: _stateManager,
      getCentralManager: () => _platformHost.centralManager,
      getPeripheralManager: () => _platformHost.peripheralManager,
      getConnectedCentral: () => _getConnectionService().connectedCentral,
      getMessageCharacteristic: () =>
          _getConnectionService().connectedCharacteristic,
      getPeripheralMessageCharacteristic: () =>
          _getConnectionService().connectedCharacteristic,
      getPeripheralMtuReady: () =>
          _getAdvertisingService().isPeripheralMTUReady,
      getPeripheralNegotiatedMtu: () =>
          _getAdvertisingService().peripheralNegotiatedMTU ??
          _connectionManager.mtuSize,
      enableFragmentCleanupTimer: true,
    );
  }

  /// Get or create connection service (lazy singleton)
  BLEConnectionService _getConnectionService() {
    if (_connectionService != null) return _connectionService!;

    final service = BLEConnectionService(
      stateManager: _stateManager,
      connectionManager: _connectionManager,
      centralManager: _platformHost.centralManager,
      bluetoothStateMonitor: _bluetoothStateMonitor,
      onUpdateConnectionInfo: _updateConnectionInfo,
    );

    _connectionInfoSubscription = service.connectionInfoStream.listen((
      connectionInfo,
    ) {
      for (final listener in List.of(_connectionInfoListeners)) {
        try {
          listener(connectionInfo);
        } catch (e, stackTrace) {
          _logger.warning(
            'Error notifying connection info listener: $e',
            e,
            stackTrace,
          );
        }
      }
    });

    _connectionService = service;
    return _connectionService!;
  }

  /// Get or create discovery service (lazy singleton)
  IBLEDiscoveryService _getDiscoveryService() {
    return _discoveryService ??= BLEDiscoveryService(
      centralManager: _platformHost.centralManager,
      stateManager: _stateManager,
      hintScanner: _hintScanner,
      onUpdateConnectionInfo: _updateConnectionInfo,
      isAdvertising: () => _getAdvertisingService().isAdvertising,
      isConnected: () => _getConnectionService().isConnected,
    );
  }

  @override
  Stream<String> get hintMatches => Stream<String>.multi((controller) {
    void listener(String hint) {
      controller.add(hint);
    }

    _hintMatchListeners.add(listener);
    controller.onCancel = () {
      _hintMatchListeners.remove(listener);
    };
  });

  /// Get or create advertising service (lazy singleton)
  IBLEAdvertisingService _getAdvertisingService() {
    _advertisingManager
        .start(); // Idempotent; required before startAdvertising()
    return _advertisingService ??= BLEAdvertisingService(
      stateManager: _stateManager,
      connectionManager: _connectionManager,
      advertisingManager: _advertisingManager,
      peripheralInitializer: _peripheralInitializer,
      peripheralManager: _platformHost.peripheralManager,
      onUpdateConnectionInfo: _updateConnectionInfo,
    );
  }

  /// Get or create messaging service (lazy singleton)
  IBLEMessagingService _getMessagingService() {
    final service = _messagingService ??= BLEMessagingService(
      messageHandler: _messageHandlerFacade,
      connectionManager: _connectionManager,
      stateManager: _stateManager,
      contactRepository: _contactRepository,
      getCentralManager: () => _platformHost.centralManager,
      getPeripheralManager: () => _platformHost.peripheralManager,
      getConnectedCentral: () => _getConnectionService().connectedCentral,
      getPeripheralMessageCharacteristic: () =>
          _getConnectionService().connectedCharacteristic,
      getPeripheralMtuReady: () =>
          _getAdvertisingService().isPeripheralMTUReady,
      getPeripheralNegotiatedMtu: () =>
          _getAdvertisingService().peripheralNegotiatedMTU ??
          _connectionManager.mtuSize ??
          20,
    );
    // Wire ACK sender so inbound text messages can emit ProtocolMessage.ack.
    _messageHandlerFacade.onSendAckMessage = (protocolMessage) async {
      await service.sendHandshakeMessage(protocolMessage);
    };
    return service;
  }

  /// Get or create handshake service (lazy singleton)
  IBLEHandshakeService _getHandshakeService() {
    if (_handshakeService != null) return _handshakeService!;

    _handshakeService = BLEHandshakeService(
      stateManager: _stateManager,
      onIdentityExchangeSent: _handleIdentityExchangeSent,
      updateConnectionInfo: _updateConnectionInfo,
      setHandshakeInProgress: _getConnectionService().setHandshakeInProgress,
      handleSpyModeDetected: _handleSpyModeDetected,
      handleIdentityRevealed: _handleIdentityRevealed,
      sendProtocolMessage: _sendHandshakeProtocolMessage,
      processPendingMessages: _processPendingHandshakeMessages,
      startGossipSync: _startGossipSync,
      onHandshakeCompleteCallback: _handleHandshakeComplete,
      introHintRepo: _introHintRepository,
      messageBuffer: _handshakeMessageBuffer,
      connectionStatusProvider: () =>
          _connectionManager.hasBleConnection ||
          _connectionManager.serverConnectionCount > 0,
    );

    // Make the handshake service discoverable to the message handler (fragment
    // pipeline) via DI so reassembled handshake frames route correctly.
    try {
      if (!getIt.isRegistered<IBLEHandshakeService>()) {
        getIt.registerSingleton<IBLEHandshakeService>(_handshakeService!);
      }
    } catch (_) {
      // DI is best-effort; the service still works via direct references.
    }

    return _handshakeService!;
  }

  // ============================================================================
  // INITIALIZATION & LIFECYCLE
  // ============================================================================

  @override
  Future<void> initialize() async {
    _logger.info('🏗️ Initializing BLEServiceFacade (lazy initialization)...');
    try {
      await _platformHost.ensureEphemeralKeysInitialized();
      await _stateManager.initialize();
      await _initializeNodeIdentity();
      await _bluetoothStateMonitor.initialize(
        onBluetoothReady: () => unawaited(_onBluetoothBecameReady()),
        onBluetoothUnavailable: () =>
            unawaited(_onBluetoothBecameUnavailable()),
        onInitializationRetry: () =>
            unawaited(_onBluetoothInitializationRetry()),
      );
      _ensureConnectionServicePrepared();
      await _ensureDiscoveryInitialized();
    } catch (e, stack) {
      _logger.severe('❌ Failed to initialize BLEServiceFacade', e, stack);
      if (!_initializationCompleter.isCompleted) {
        _initializationCompleter.completeError(e, stack);
      }
      rethrow;
    }
    _logger.info('✅ BLEServiceFacade ready');
    if (!_initializationCompleter.isCompleted) {
      _initializationCompleter.complete();
    }
  }

  @override
  Future<void> dispose() async {
    _logger.info('🧹 Disposing BLEServiceFacade...');
    _serverHandshakeTimer?.cancel();
    _serverHandshakeTimer = null;

    try {
      // Stop all active operations (only if services were created)
      if (_discoveryService != null) {
        await _discoveryService!.dispose().catchError((_) {});
      }
      if (_connectionService != null) {
        _connectionService!.stopConnectionMonitoring();
        await _connectionService!.disconnect().catchError((_) {});
        _connectionService!.disposeConnection();
      }
      if (_handshakeService != null) {
        _handshakeService!.disposeHandshakeCoordinator();
      }
      _messageHandlerFacade.dispose();
      _messageHandler.dispose();
      _logger.info('✅ BLEServiceFacade disposed');
    } catch (e, stack) {
      _logger.severe('❌ Disposal error', e, stack);
    } finally {
      _spyModeListeners.clear();
      _identityListeners.clear();
      _connectionInfoListeners.clear();
      _hintMatchListeners.clear();
      await _connectionInfoSubscription?.cancel();
      _connectionInfoSubscription = null;
      await _peripheralConnectionSub?.cancel();
      await _peripheralMtuSub?.cancel();
      await _peripheralNotifyStateSub?.cancel();
      await _peripheralWriteSub?.cancel();
      await _centralNotifySub?.cancel();
      _peripheralConnectionSub = null;
      _peripheralMtuSub = null;
      _peripheralNotifyStateSub = null;
      _peripheralWriteSub = null;
      _centralNotifySub = null;
      _peripheralEventsBound = false;
    }
  }

  @override
  Future<void> get initializationComplete => _initializationCompleter.future;

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  @override
  Future<String> getMyPublicKey() async {
    _logger.fine('Getting public key from BLEStateManager...');
    try {
      return await _stateManager.getMyPersistentId();
    } catch (e, stack) {
      _logger.warning('Failed to read persistent key', e, stack);
      return '';
    }
  }

  @override
  Future<String> getMyEphemeralId() async {
    String? ephemeralId;
    try {
      ephemeralId = _stateManager.myEphemeralId;
    } on StateError catch (e, stack) {
      _logger.warning(
        'EphemeralKeyManager not initialized via BLEStateManager',
        e,
        stack,
      );
      await _platformHost.ensureEphemeralKeysInitialized();
      try {
        ephemeralId = _stateManager.myEphemeralId;
      } catch (_) {
        // Fallback handled below
      }
    }
    if (ephemeralId != null && ephemeralId.isNotEmpty) {
      return ephemeralId;
    }
    try {
      _logger.fine('State manager missing ephemeral ID - querying platform');
      return _platformHost.getCurrentEphemeralId();
    } catch (e, stack) {
      _logger.warning('Ephemeral key provider not available', e, stack);
      return '';
    }
  }

  @override
  @override
  Future<void> setMyUserName(String name) async {
    _logger.fine('Setting username to: $name');
    await _stateManager.setMyUserName(name);
  }

  // ============================================================================
  // MESH NETWORKING INTEGRATION
  // ============================================================================

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {
    _logger.info('📡 Registering queue sync handler for mesh networking');
    _queueSyncHandler = handler;
    _messageHandlerFacade.onQueueSyncReceived = (message, fromNodeId) {
      final registeredHandler = _queueSyncHandler;
      if (registeredHandler != null) {
        unawaited(registeredHandler(message, fromNodeId));
      }
    };
    _getMessagingService().registerQueueSyncMessageHandler(handler);
  }

  @override
  Future<ProtocolMessage?> revealIdentityToFriend() =>
      _stateManager.revealIdentityToFriend();

  @override
  Future<void> acceptContactRequest() => _stateManager.acceptContactRequest();

  @override
  void rejectContactRequest() => _stateManager.rejectContactRequest();

  @override
  void setContactRequestCompletedListener(
    void Function(bool success) listener,
  ) {
    _stateManager.onContactRequestCompleted = listener;
  }

  @override
  void setContactRequestReceivedListener(
    void Function(String publicKey, String displayName) listener,
  ) {
    _stateManager.onContactRequestReceived = listener;
  }

  @override
  void setAsymmetricContactListener(
    void Function(String publicKey, String displayName) listener,
  ) {
    _stateManager.onAsymmetricContactDetected = listener;
  }

  @override
  void setPairingInProgress(bool isInProgress) =>
      _getConnectionService().setPairingInProgress(isInProgress);

  // ============================================================================
  // SUB-SERVICE ACCESS
  // ============================================================================

  @override
  IBLEConnectionService get connectionService => _getConnectionService();

  @override
  IBLEMessagingService get messagingService => _getMessagingService();

  @override
  IBLEDiscoveryService get discoveryService => _getDiscoveryService();

  @override
  IBLEAdvertisingService get advertisingService => _getAdvertisingService();

  @override
  IBLEHandshakeService get handshakeService => _getHandshakeService();

  // ============================================================================
  // BLUETOOTH STATE MONITORING
  // ============================================================================

  @override
  Stream<BluetoothStateInfo> get bluetoothStateStream =>
      _bluetoothStateMonitor.stateStream;

  @override
  Stream<BluetoothStatusMessage> get bluetoothMessageStream =>
      _bluetoothStateMonitor.messageStream;

  @override
  bool get isBluetoothReady => _bluetoothStateMonitor.isBluetoothReady;

  @override
  BluetoothLowEnergyState get state => _bluetoothStateMonitor.currentState;

  @override
  String? get myUserName => _stateManager.myUserName;

  // ============================================================================
  // DELEGATION TO SUB-SERVICES (IBLEConnectionService)
  // ============================================================================

  @override
  Future<void> connectToDevice(Peripheral device) =>
      _getConnectionService().connectToDevice(device);

  @override
  Future<void> disconnect() => _getConnectionService().disconnect();

  @override
  void startConnectionMonitoring() =>
      _getConnectionService().startConnectionMonitoring();

  @override
  void stopConnectionMonitoring() =>
      _getConnectionService().stopConnectionMonitoring();

  @override
  void disposeConnection() => _getConnectionService().disposeConnection();

  @override
  void setHandshakeInProgress(bool isInProgress) =>
      _getConnectionService().setHandshakeInProgress(isInProgress);

  @override
  ConnectionInfo? getConnectionInfo() =>
      _getConnectionService().getConnectionInfo();

  @override
  Future<ConnectionInfo?> getConnectionInfoWithFallback() =>
      _getConnectionService().getConnectionInfoWithFallback();

  @override
  Future<bool> attemptIdentityRecovery() =>
      _getConnectionService().attemptIdentityRecovery();

  @override
  Stream<ConnectionInfo> get connectionInfoStream =>
      Stream<ConnectionInfo>.multi((controller) {
        controller.add(_currentConnectionInfo);

        void listener(ConnectionInfo info) {
          controller.add(info);
        }

        _connectionInfoListeners.add(listener);
        controller.onCancel = () {
          _connectionInfoListeners.remove(listener);
        };
      });

  @override
  Stream<ConnectionInfo> get connectionInfo => connectionInfoStream;

  @override
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;

  @override
  bool get isConnected => _getConnectionService().isConnected;

  @override
  bool get isMonitoring => _getConnectionService().isMonitoring;

  @override
  String? get otherUserName => _getConnectionService().otherUserName;

  @override
  String? get currentSessionId => _getConnectionService().currentSessionId;

  @override
  String? get theirEphemeralId => _getConnectionService().theirEphemeralId;

  @override
  String? get theirPersistentKey => _getConnectionService().theirPersistentKey;

  @override
  String? get theirPersistentPublicKey => _stateManager.theirPersistentKey;

  @override
  String? get myPersistentId => _getConnectionService().myPersistentId;

  @override
  bool get isActivelyReconnecting =>
      _getConnectionService().isActivelyReconnecting;

  @override
  bool get hasPeripheralConnection =>
      _getConnectionService().hasPeripheralConnection;

  @override
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges =>
      _platformHost.peripheralManager.connectionStateChanged;

  @override
  bool get hasCentralConnection => _getConnectionService().hasCentralConnection;

  @override
  bool get canSendMessages => _getConnectionService().canSendMessages;

  @override
  Central? get connectedCentral => _getConnectionService().connectedCentral;

  @override
  Peripheral? get connectedDevice => _getConnectionService().connectedDevice;

  /// Get connection manager for low-level connection operations
  /// 🔑 Used for pairing flow (setPairingInProgress)
  BLEConnectionManager get connectionManager =>
      _getConnectionService().connectionManager;

  @override
  List<BLEServerConnection> get serverConnections =>
      List.unmodifiable(_connectionManager.serverConnections);

  @override
  int get clientConnectionCount => _connectionManager.clientConnectionCount;

  @override
  bool get canAcceptMoreConnections =>
      _connectionManager.canAcceptMoreConnections;

  @override
  int get activeConnectionCount =>
      _connectionManager.clientConnectionCount +
      _connectionManager.serverConnectionCount;

  @override
  int get maxCentralConnections => _connectionManager.maxClientConnections;

  @override
  List<String> get activeConnectionDeviceIds {
    final ids = <String>[];
    final connected = _getConnectionService().connectedDevice;
    if (connected != null) {
      ids.add(connected.uuid.toString());
    }
    ids.addAll(
      _connectionManager.serverConnections.map((conn) => conn.address),
    );
    return ids;
  }

  /// Get state manager for Noise protocol and security operations
  /// 🔑 Used for pairing flow (generatePairingCode, completePairing, etc.)
  IBLEStateManagerFacade get stateManager => _stateManager;

  // ============================================================================
  // DELEGATION TO SUB-SERVICES (IBLEMessagingService)
  // ============================================================================

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) => _getMessagingService().sendMessage(
    message,
    messageId: messageId,
    originalIntendedRecipient: originalIntendedRecipient,
  );

  @override
  Future<bool> sendPeripheralMessage(String message, {String? messageId}) =>
      _getMessagingService().sendPeripheralMessage(
        message,
        messageId: messageId,
      );

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage) =>
      _getMessagingService().sendQueueSyncMessage(queueMessage);

  @override
  Future<void> sendIdentityExchange() =>
      _getMessagingService().sendIdentityExchange();

  @override
  Future<void> sendPeripheralIdentityExchange() =>
      _getMessagingService().sendPeripheralIdentityExchange();

  @override
  Future<void> sendHandshakeMessage(ProtocolMessage message) =>
      _getMessagingService().sendHandshakeMessage(message);

  @override
  void registerQueueSyncMessageHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) => _getMessagingService().registerQueueSyncMessageHandler(handler);

  @override
  Stream<String> get receivedMessagesStream =>
      _getMessagingService().receivedMessagesStream;

  @override
  Stream<BinaryPayload> get receivedBinaryStream =>
      _getMessagingService().receivedBinaryStream;

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) => _getMessagingService().sendBinaryMedia(
    data: data,
    recipientId: recipientId,
    originalType: originalType,
    metadata: metadata,
    persistOnly: persistOnly,
  );

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) => _getMessagingService().retryBinaryMedia(
    transferId: transferId,
    recipientId: recipientId,
    originalType: originalType,
  );

  @override
  Stream<String> get receivedMessages => receivedMessagesStream;

  @override
  String? get lastExtractedMessageId =>
      _getMessagingService().lastExtractedMessageId;

  @override
  Future<void> processIncomingPeripheralData(
    Uint8List data, {
    required String senderDeviceId,
    String? senderNodeId,
  }) => _getMessagingService().processIncomingPeripheralData(
    data,
    senderDeviceId: senderDeviceId,
    senderNodeId: senderNodeId,
  );

  // ============================================================================
  // DELEGATION TO SUB-SERVICES (IBLEDiscoveryService)
  // ============================================================================

  @override
  Future<void> startScanning({ScanningSource source = ScanningSource.system}) =>
      _getDiscoveryService().startScanning(source: source);

  @override
  Future<void> stopScanning() => _getDiscoveryService().stopScanning();

  @override
  Future<void> startScanningWithValidation({
    ScanningSource source = ScanningSource.manual,
  }) => _getDiscoveryService().startScanningWithValidation(source: source);

  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) =>
      _getDiscoveryService().scanForSpecificDevice(timeout: timeout);

  @override
  Stream<List<Peripheral>> get discoveredDevices =>
      _getDiscoveryService().discoveredDevices;

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
      _getDiscoveryService().discoveryData;

  @override
  Stream<List<Peripheral>> get discoveredDevicesStream =>
      Stream<List<Peripheral>>.multi((controller) {
        controller.add(_connectionManager.activeConnections);

        final subscription = _getDiscoveryService().discoveredDevices.listen(
          (devices) {
            controller.add(devices);
          },
          onError: (error, stackTrace) {
            controller.addError(error, stackTrace);
          },
        );

        controller.onCancel = () {
          subscription.cancel();
        };
      }, isBroadcast: true);

  @override
  List<Peripheral> get currentDiscoveredDevices =>
      _getDiscoveryService().currentDiscoveredDevices;

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryDataStream =>
      _getDiscoveryService().discoveryDataStream;

  @override
  bool get isDiscoveryActive => _getDiscoveryService().isDiscoveryActive;

  @override
  ScanningSource? get currentScanningSource =>
      _getDiscoveryService().currentScanningSource;

  @override
  Stream<String> get hintMatchesStream =>
      _getDiscoveryService().hintMatchesStream;

  @override
  Stream<ConnectionPhase> get handshakePhaseStream =>
      _getHandshakeService().handshakePhaseStream;

  // ============================================================================
  // DELEGATION TO SUB-SERVICES (IBLEAdvertisingService)
  // ============================================================================

  @override
  Future<void> startAsPeripheral() =>
      _getAdvertisingService().startAsPeripheral();

  @override
  Future<void> startAsPeripheralWithValidation() =>
      _getAdvertisingService().startAsPeripheralWithValidation();

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) =>
      _getAdvertisingService().refreshAdvertising(
        showOnlineStatus: showOnlineStatus,
      );

  @override
  Future<void> startAsCentral() => _getAdvertisingService().startAsCentral();

  @override
  bool get isAdvertising => _getAdvertisingService().isAdvertising;

  @override
  bool get isPeripheralMode => _getAdvertisingService().isPeripheralMode;

  @override
  int? get peripheralNegotiatedMTU =>
      _getAdvertisingService().peripheralNegotiatedMTU;

  @override
  bool get isPeripheralMTUReady =>
      _getAdvertisingService().isPeripheralMTUReady;

  @override
  GATTCharacteristic? get messageCharacteristic =>
      _getAdvertisingService().messageCharacteristic;

  @override
  bool get peripheralHandshakeStarted =>
      _getAdvertisingService().peripheralHandshakeStarted;

  @override
  set peripheralHandshakeStarted(bool value) =>
      _getAdvertisingService().peripheralHandshakeStarted = value;

  @override
  Future<void> stopAdvertising() => _getAdvertisingService().stopAdvertising();

  @override
  Future<void> startAdvertising() =>
      _getAdvertisingService().startAdvertising();

  @override
  void updatePeripheralMtu(int mtu) =>
      _getAdvertisingService().updatePeripheralMtu(mtu);

  @override
  void resetPeripheralSession() =>
      _getAdvertisingService().resetPeripheralSession();

  // ============================================================================
  // DELEGATION TO SUB-SERVICES (IBLEHandshakeService)
  // ============================================================================

  @override
  Future<void> performHandshake({bool? startAsInitiatorOverride}) =>
      _getHandshakeService().performHandshake(
        startAsInitiatorOverride: startAsInitiatorOverride,
      );

  @override
  Future<void> onHandshakeComplete() =>
      _getHandshakeService().onHandshakeComplete();

  @override
  void disposeHandshakeCoordinator() =>
      _getHandshakeService().disposeHandshakeCoordinator();

  @override
  Future<void> requestIdentityExchange() =>
      _getHandshakeService().requestIdentityExchange();

  @override
  Future<void> triggerIdentityReExchange() =>
      _getHandshakeService().triggerIdentityReExchange();

  @override
  Stream<SpyModeInfo> get spyModeDetectedStream =>
      _getHandshakeService().spyModeDetectedStream;

  @override
  Stream<SpyModeInfo> get spyModeDetected =>
      Stream<SpyModeInfo>.multi((controller) {
        void listener(SpyModeInfo info) {
          controller.add(info);
        }

        _spyModeListeners.add(listener);
        controller.onCancel = () {
          _spyModeListeners.remove(listener);
        };
      });

  @override
  Stream<String> get identityRevealedStream =>
      Stream<String>.multi((controller) {
        void listener(String identity) {
          controller.add(identity);
        }

        _identityListeners.add(listener);
        controller.onCancel = () {
          _identityListeners.remove(listener);
        };
      });

  @override
  Stream<String> get identityRevealed => identityRevealedStream;

  @override
  void emitSpyModeDetected(SpyModeInfo info) {
    _stateManager.onSpyModeDetected?.call(info);
    for (final listener in List.of(_spyModeListeners)) {
      try {
        listener(info);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying spy mode listener: $e', e, stackTrace);
      }
    }
    if (_handshakeService != null) {
      _handshakeService!.emitSpyModeDetected(info);
    }
  }

  @override
  void emitIdentityRevealed(String contactId) {
    _stateManager.onIdentityRevealed?.call(contactId);
    for (final listener in List.of(_identityListeners)) {
      try {
        listener(contactId);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying identity listener: $e', e, stackTrace);
      }
    }
    if (_handshakeService != null) {
      _handshakeService!.emitIdentityRevealed(contactId);
    }
  }

  @override
  Future<String?> buildLocalCollisionHint() =>
      _getHandshakeService().buildLocalCollisionHint();

  @override
  List<dynamic> getBufferedMessages() =>
      _getHandshakeService().getBufferedMessages();

  @override
  String getPhaseMessage(String phase) =>
      _getHandshakeService().getPhaseMessage(phase);

  @override
  Future<void> handleAsymmetricContact(String contactKey) =>
      _getHandshakeService().handleAsymmetricContact(contactKey);

  @override
  Future<void> handleMutualConsentRequired() =>
      _getHandshakeService().handleMutualConsentRequired();

  @override
  bool get hasHandshakeCompleted =>
      _getHandshakeService().hasHandshakeCompleted;

  @override
  bool get isHandshakeInProgress =>
      _getHandshakeService().isHandshakeInProgress;

  @override
  bool isHandshakeMessage(String messageType) =>
      _getHandshakeService().isHandshakeMessage(messageType);

  @override
  String? get currentHandshakePhase =>
      _getHandshakeService().currentHandshakePhase;

  @override
  Future<bool> handleIncomingHandshakeMessage(
    Uint8List data, {
    bool isFromPeripheral = false,
  }) => _getHandshakeService().handleIncomingHandshakeMessage(
    data,
    isFromPeripheral: isFromPeripheral,
  );

  void _ensureConnectionServicePrepared() {
    if (_connectionSetupComplete) {
      return;
    }
    _getConnectionService().setupConnectionInitialization();
    _bindPeripheralEventHandlers();
    _bindCentralNotificationHandler();
    // Provide a local collision hint to allow deterministic tie-breaks.
    _connectionManager.setLocalHintProvider(() async {
      try {
        final hint = await _getHandshakeService().buildLocalCollisionHint();
        return hint;
      } catch (_) {
        return null;
      }
    });
    _connectionManager.onConnectionComplete = () =>
        _getHandshakeService().performHandshake(startAsInitiatorOverride: true);
    _connectionSetupComplete = true;
  }

  Future<void> _ensureDiscoveryInitialized() async {
    if (_discoveryInitialized) {
      return;
    }
    await _getDiscoveryService().initialize();
    _discoveryInitialized = true;
  }

  void _bindPeripheralEventHandlers() {
    if (_peripheralEventsBound) return;

    try {
      final peripheralManager = _platformHost.peripheralManager;

      _peripheralConnectionSub = peripheralManager.connectionStateChanged.listen((
        event,
      ) {
        if (event.state == ConnectionState.connected) {
          _connectionManager.handleCentralConnected(event.central);
          final connectionService = _getConnectionService();
          connectionService.connectedCentral = event.central;
          _scheduleResponderHandshakeFallback();
        } else {
          _connectionManager.handleCentralDisconnected(event.central);
          final connectionService = _getConnectionService();
          final advertisingService = _getAdvertisingService();

          final disconnectedId = event.central.uuid.toString();
          final activeId = connectionService.connectedCentral?.uuid.toString();
          final disconnectedWasActive = disconnectedId == activeId;
          final hasOtherServerConnections =
              _connectionManager.serverConnectionCount > 0;

          if (disconnectedWasActive) {
            // Active link dropped: clear the coordinator/target state so we can
            // safely start a new handshake with any remaining connection.
            _getHandshakeService().disposeHandshakeCoordinator();
            connectionService.connectedCentral = null;
            connectionService.connectedCharacteristic = null;
          }

          if (!hasOtherServerConnections) {
            advertisingService.resetPeripheralSession();
          } else if (disconnectedWasActive) {
            // Pivot to another connected central now that the active one is gone.
            final remainingConnections = _connectionManager.serverConnections;
            if (remainingConnections.isNotEmpty) {
              final replacement = remainingConnections.last;
              connectionService.connectedCentral = replacement.central;
              connectionService.connectedCharacteristic =
                  replacement.subscribedCharacteristic;
            }
            advertisingService.peripheralHandshakeStarted = false;
            _maybeStartResponderHandshake(
              characteristicOverride: connectionService.connectedCharacteristic,
            );
          }
        }
      });

      _peripheralMtuSub = peripheralManager.mtuChanged.listen((event) {
        final connectionService = _getConnectionService();
        connectionService.connectedCentral = event.central;
        _getAdvertisingService().updatePeripheralMtu(event.mtu);
        _connectionManager.updateServerMtu(
          event.central.uuid.toString(),
          event.mtu,
        );
        _maybeStartResponderHandshake();
      });

      _peripheralNotifyStateSub = peripheralManager
          .characteristicNotifyStateChanged
          .listen((event) {
            if (!event.state) return;
            _connectionManager.handleCharacteristicSubscribed(
              event.central,
              event.characteristic,
            );
            final connectionService = _getConnectionService();
            connectionService.connectedCentral = event.central;
            connectionService.connectedCharacteristic = event.characteristic;
            _maybeStartResponderHandshake(
              characteristicOverride: event.characteristic,
            );
            // Notify ready arrived; cancel any delayed fallback.
          });

      // Handle inbound writes (central → our peripheral). This is required so
      // handshake/messages received on server links are processed.
      _peripheralWriteSub = peripheralManager.characteristicWriteRequested.listen((
        event,
      ) async {
        try {
          final data = event.request.value;
          final connectionService = _getConnectionService();
          connectionService.connectedCentral = event.central;
          connectionService.connectedCharacteristic = event.characteristic;

          final handled = await _getHandshakeService()
              .handleIncomingHandshakeMessage(data, isFromPeripheral: true);

          // Start responder handshake immediately if not already started.
          _maybeStartResponderHandshake(
            characteristicOverride: event.characteristic,
          );
          // If notify enablement is slow, ensure we still try responder start.
          _scheduleResponderHandshakeFallback();

          // If handshake payload, we already handled it.
          if (handled) {
            await peripheralManager.respondWriteRequest(event.request);
            return;
          }

          await _getMessagingService().processIncomingPeripheralData(
            data,
            senderDeviceId: event.central.uuid.toString(),
            senderNodeId: DeviceDeduplicationManager.getDevice(
              event.central.uuid.toString(),
            )?.ephemeralHint,
          );

          await peripheralManager.respondWriteRequest(event.request);
        } catch (e, stack) {
          _logger.warning(
            '⚠️ Failed to handle inbound write from ${event.central.uuid}: $e',
            e,
            stack,
          );
          try {
            await peripheralManager.respondWriteRequestWithError(
              event.request,
              error: GATTError.unlikelyError,
            );
          } catch (_) {}
        }
      });

      _peripheralEventsBound = true;
    } on UnsupportedError catch (e, stack) {
      _logger.fine('Peripheral event binding not supported: $e', e, stack);
    }
  }

  /// This runs when a server connection is established but no data has arrived yet.
  void _maybeStartResponderHandshake({
    GATTCharacteristic? characteristicOverride,
  }) {
    // 🚀 NEW: Don't start a fallback responder handshake if we're already busy or ready.
    final handshakeService = _getHandshakeService();
    if (handshakeService.isHandshakeInProgress ||
        _connectionManager.connectionState == ChatConnectionState.ready) {
      _logger.info(
        '🛑 Skipping fallback responder handshake: already ${handshakeService.isHandshakeInProgress ? "IN_PROGRESS" : "READY"}',
      );
      return;
    }

    if (_serverHandshakeTimer != null) return;

    final advertisingService = _getAdvertisingService();
    final connectionService = _getConnectionService();
    final central = connectionService.connectedCentral;
    final characteristic =
        characteristicOverride ??
        connectionService.connectedCharacteristic ??
        advertisingService.messageCharacteristic;

    if (central == null || characteristic == null) {
      return;
    }

    final address = central.uuid.toString();
    if (_connectionManager.hasClientLinkForPeer(address) ||
        _connectionManager.hasPendingClientForPeer(address)) {
      _logger.fine(
        '🛑 Skipping responder handshake for ${address.shortId(8)} — client link already active/pending',
      );
      return;
    }

    if (_connectionManager.isResponderHandshakeBlocked(address)) {
      _logger.fine(
        '🛑 Skipping responder handshake for ${address.shortId(8)} — inbound link blocked as duplicate',
      );
      return;
    }

    if (_connectionManager.isServerTeardownDeferred(address)) {
      _logger.fine(
        '⏸️ Server teardown deferred for $address — skipping responder handshake.',
      );
      return;
    }
    if (_connectionManager.isCollisionResolving(address)) {
      _logger.fine(
        '⏸️ Collision resolution in progress for $address — deferring responder handshake',
      );
      return;
    }

    // Gate responder handshake to only run if the inbound link is still alive
    // (i.e., collision resolution kept the server connection).
    if (!_connectionManager.hasServerConnection(address)) {
      _logger.fine(
        '⏸️ Skipping responder handshake start; no server connection for $address (likely yielded to client).',
      );
      return;
    }

    advertisingService.peripheralHandshakeStarted = true;
    _connectionManager.onCharacteristicFound?.call(characteristic);

    unawaited(
      _getHandshakeService().performHandshake(startAsInitiatorOverride: false),
    );
  }

  void _scheduleResponderHandshakeFallback({
    Duration delay = const Duration(milliseconds: 400),
  }) {
    // Only schedule if a server connection exists and no handshake has started.
    if (_connectionManager.serverConnectionCount == 0) return;

    // 🚀 NEW: Early exit if we're already busy or ready
    if (_connectionManager.connectionState == ChatConnectionState.ready ||
        _getHandshakeService().isHandshakeInProgress) {
      return;
    }

    final address =
        _getConnectionService().connectedCentral?.uuid.toString() ?? '';
    if (address.isNotEmpty &&
        (_connectionManager.hasClientLinkForPeer(address) ||
            _connectionManager.hasPendingClientForPeer(address))) {
      _logger.fine(
        '⏸️ Fallback responder handshake suppressed for ${address.shortId(8)} — client link already active/pending',
      );
      return;
    }
    if (address.isNotEmpty &&
        _connectionManager.isCollisionResolving(address)) {
      _logger.fine(
        '⏸️ Skipping responder handshake fallback; collision resolution in progress for $address',
      );
      return;
    }
    if (address.isNotEmpty &&
        _connectionManager.isServerTeardownDeferred(address)) {
      _logger.fine(
        '⏸️ Fallback suppressed; server teardown deferred for $address',
      );
      return;
    }

    // Timer logic updated to use the new field
    _serverHandshakeTimer?.cancel();
    _serverHandshakeTimer = Timer(delay, () {
      _serverHandshakeTimer = null;
      try {
        if (_connectionManager.serverConnectionCount == 0) return;

        // 🚀 NEW: Double check status inside timer
        if (_connectionManager.connectionState == ChatConnectionState.ready ||
            _getHandshakeService().isHandshakeInProgress) {
          return;
        }

        if (address.isNotEmpty &&
            (_connectionManager.hasClientLinkForPeer(address) ||
                _connectionManager.hasPendingClientForPeer(address))) {
          _logger.fine(
            '⏸️ Fallback suppressed; client link already active/pending for ${address.shortId(8)}',
          );
          return;
        }

        if (address.isNotEmpty &&
            _connectionManager.isCollisionResolving(address)) {
          _logger.fine(
            '⏸️ Fallback suppressed; collision resolution still in progress for $address',
          );
          return;
        }
        if (address.isNotEmpty &&
            _connectionManager.isServerTeardownDeferred(address)) {
          _logger.fine(
            '⏸️ Fallback suppressed; server teardown deferred for $address',
          );
          return;
        }

        final advertisingService = _getAdvertisingService();
        if (advertisingService.peripheralHandshakeStarted) {
          return;
        }
        _logger.fine(
          '⏳ Fallback: starting responder handshake after delay (notify may be slow)',
        );
        _maybeStartResponderHandshake();
      } catch (_) {}
    });
  }

  void _bindCentralNotificationHandler() {
    if (_centralNotifySub != null) return;

    try {
      _centralNotifySub = _platformHost.centralManager.characteristicNotified
          .listen((event) async {
            try {
              // 🧟 ZOMBIE CONNECTION FIX: Detect Service Changed (0x2A05)
              // This indicates the peripheral app has restarted/crashed.
              final uuid = event.characteristic.uuid;
              // 0x2A05 = Service Changed
              final isServiceChanged = uuid == UUID.fromAddress(0x2A05);

              if (isServiceChanged) {
                final deviceId = event.peripheral.uuid.toString();
                _logger.warning(
                  '🧟 Service Changed (0x2A05) received from $deviceId - Remote app likely restarted. Disconnecting to clear zombie state.',
                );
                await _connectionManager.disconnectClient(deviceId);
                return;
              }

              // Forward handshake messages immediately.
              final handled = await _getHandshakeService()
                  .handleIncomingHandshakeMessage(
                    event.value,
                    isFromPeripheral: false,
                  );

              if (handled) return;

              final deviceId = event.peripheral.uuid.toString();
              final nodeId = DeviceDeduplicationManager.getDevice(
                deviceId,
              )?.ephemeralHint;

              await _getMessagingService().processIncomingPeripheralData(
                event.value,
                senderDeviceId: deviceId,
                senderNodeId: nodeId,
              );
            } catch (e, stack) {
              _logger.warning(
                '⚠️ Failed to process central notification: $e',
                e,
                stack,
              );
            }
          });
    } on UnsupportedError catch (e, stack) {
      _logger.fine('Central notify binding not supported: $e', e, stack);
    }
  }

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  void _updateConnectionInfo({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  }) {
    _currentConnectionInfo = _currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );
    for (final listener in List.of(_connectionInfoListeners)) {
      try {
        listener(_currentConnectionInfo);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying connection info listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  Future<void> _initializeNodeIdentity() async {
    try {
      final prefs = UserPreferences();
      final persistent = await prefs.getPublicKey();
      final sessionId = EphemeralKeyManager.currentSessionKey;
      final nodeId = (sessionId != null && sessionId.isNotEmpty)
          ? sessionId
          : (persistent.isNotEmpty ? persistent : null);

      if (nodeId != null) {
        _messageHandler.setCurrentNodeId(nodeId);
        _messageHandlerFacade.setCurrentNodeId(nodeId);
        _logger.fine(
          '🔧 Node identity set for messaging: ${nodeId.shortId(8)}',
        );
      } else {
        _logger.warning(
          '⚠️ Unable to set node identity (no session or persistent key)',
        );
      }
    } catch (e) {
      _logger.warning('⚠️ Failed to initialize node identity: $e');
    }
  }

  Future<void> _onBluetoothBecameReady() async {
    _logger.info('🔵 Bluetooth ready - facade notified');
    final advertisingService = _getAdvertisingService();
    try {
      await _connectionManager.startMeshNetworking(
        onStartAdvertising: () => advertisingService.startAsPeripheral(),
      );
      _updateConnectionInfo(
        statusMessage: 'Bluetooth ready for dual-role operation',
        isAdvertising: advertisingService.isAdvertising,
      );
    } catch (e, stack) {
      _logger.warning(
        '⚠️ Failed to start mesh networking after Bluetooth ready: $e',
        e,
        stack,
      );
      _updateConnectionInfo(
        statusMessage: 'Bluetooth ready (advertising unavailable)',
        isAdvertising: advertisingService.isAdvertising,
      );
    }
  }

  Future<void> _onBluetoothBecameUnavailable() async {
    _logger.warning('🔵 Bluetooth unavailable - facade notified');
    _updateConnectionInfo(
      isConnected: false,
      isReady: false,
      statusMessage: 'Bluetooth unavailable',
      isScanning: false,
      isAdvertising: false,
    );
  }

  Future<void> _onBluetoothInitializationRetry() async {
    _logger.info('🔄 Retrying Bluetooth initialization...');
  }

  void _handleIdentityExchangeSent(String publicKey, String displayName) {
    final truncatedKey = publicKey.length > 16
        ? '${publicKey.substring(0, 8)}...'
        : publicKey;
    _logger.fine(
      '🪪 Identity exchange sent (pubKey: $truncatedKey, displayName: $displayName)',
    );
  }

  Future<void> _sendHandshakeProtocolMessage(ProtocolMessage message) =>
      _getMessagingService().sendHandshakeMessage(message);

  Future<void> _processPendingHandshakeMessages() async {
    if (_handshakeMessageBuffer.isNotEmpty) {
      _logger.fine(
        '📦 Flushing ${_handshakeMessageBuffer.length} buffered handshake message(s)',
      );
      _handshakeMessageBuffer.clear();
    }
  }

  Future<void> _startGossipSync() async {
    // Placeholder hook for full gossip sync integration once wired
    _logger.finer('🕸️ Gossip sync start hook invoked');
  }

  Future<void> _handleHandshakeComplete(
    String ephemeralId,
    String displayName,
    String? noiseKey,
  ) async {
    final truncatedId = ephemeralId.length > 8
        ? '${ephemeralId.substring(0, 8)}...'
        : ephemeralId;
    _logger.info('🤝 Handshake complete with $displayName ($truncatedId)');
    _stateManager.setOtherUserName(displayName);
    _stateManager.setTheirEphemeralId(ephemeralId, displayName);
    // Persist or create contact record using the session ephemeral as the
    // immutable key for LOW security contacts. This prevents later sends from
    // resolving to an empty/“NOT SPECIFIED” recipient.
    try {
      final existingContact = await _contactRepository.getContact(ephemeralId);
      if (existingContact == null) {
        await _contactRepository.saveContactWithSecurity(
          ephemeralId,
          displayName,
          SecurityLevel.low,
          currentEphemeralId: ephemeralId,
        );
        _logger.info(
          '🔒 HANDSHAKE: Created LOW-security contact for $displayName ($truncatedId)',
        );
      } else {
        if (existingContact.currentEphemeralId != ephemeralId) {
          await _contactRepository.updateContactEphemeralId(
            existingContact.publicKey,
            ephemeralId,
          );
        }
        if (existingContact.persistentPublicKey != null &&
            existingContact.persistentPublicKey!.isNotEmpty) {
          SecurityManager.instance.registerIdentityMapping(
            persistentPublicKey: existingContact.persistentPublicKey!,
            ephemeralID: ephemeralId,
          );
        }
      }
    } catch (e) {
      _logger.warning('⚠️ Failed to persist contact after handshake: $e');
    }
    // Allow health checks now that handshake is done.
    _connectionManager.markHandshakeComplete();
    // Refresh our node identity in case session keys rotated during handshake.
    await _initializeNodeIdentity();
    _updateConnectionInfo(
      isConnected: true,
      isReady: true,
      otherUserName: displayName,
      statusMessage: 'Ready to chat',
    );
    await _processPendingHandshakeMessages();
    await _startGossipSync();
  }

  void _handleSpyModeDetected(SpyModeInfo info) {
    _logger.warning(
      '🕵️ Spy mode detected with ${info.contactName ?? 'unknown contact'}',
    );
    emitSpyModeDetected(info);
  }

  void _handleIdentityRevealed(String contactId) {
    _logger.info('🪪 Identity revealed to contact: $contactId');
    emitIdentityRevealed(contactId);
  }

  // ============================================================================
  // TEST SUPPORT
  // ============================================================================

  @visibleForTesting
  void debugEmitSpyModeDetected(SpyModeInfo info) =>
      _handleSpyModeDetected(info);

  @visibleForTesting
  void debugEmitIdentityRevealed(String contactId) =>
      _handleIdentityRevealed(contactId);

  @visibleForTesting
  void debugHandleQueueSync(QueueSyncMessage message, String fromNodeId) {
    final handler = _queueSyncHandler;
    if (handler != null) {
      handler(message, fromNodeId);
    }
  }

  /// Expose underlying message handler for integration wiring (AppCore tests).
  @visibleForTesting
  BLEMessageHandler get messageHandler => _messageHandler;
}
