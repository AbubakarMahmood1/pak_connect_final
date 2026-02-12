import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_platform_host.dart';
import 'package:pak_connect/domain/interfaces/i_ble_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_advertising_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_handshake_coordinator_factory.dart';
import 'package:pak_connect/domain/models/connection_phase.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/protocol_message.dart'
    as domain_models;
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'ble_connection_service.dart';
import 'ble_messaging_service.dart';
import 'ble_message_handler_facade_impl.dart';
import 'ble_discovery_service.dart';
import 'ble_advertising_service.dart';
import 'ble_handshake_service.dart';
import 'ble_facade_event_bus.dart';
import 'ble_facade_lifecycle_coordinator.dart';
import 'package:pak_connect/domain/interfaces/i_ble_state_manager_facade.dart';
import 'ble_state_manager.dart';
import 'ble_state_manager_facade.dart';
import 'ble_connection_manager.dart';
import 'ble_message_handler.dart';
import '../repositories/intro_hint_repository.dart';
import '../repositories/contact_repository.dart';
import '../services/seen_message_store.dart';
import '../../domain/services/advertising_manager.dart';
import '../../domain/services/peripheral_initializer.dart';
import '../../domain/services/bluetooth_state_monitor.dart';
import '../../domain/services/ble_platform_host.dart';
import '../../domain/services/hint_scanner_service.dart';
import '../../domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../repositories/user_preferences.dart';
import '../../domain/services/ephemeral_key_manager.dart';

part 'ble_service_facade_runtime_helper.dart';

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
  final GetIt _getIt = GetIt.instance;
  late final BleFacadeEventBus _eventBus;
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
  final IHandshakeCoordinatorFactory? _handshakeCoordinatorFactory;
  late final _BleServiceFacadeRuntimeHelper _runtimeHelper;

  // Sub-services (lazy-initialized)
  BLEConnectionService? _connectionService;
  IBLEMessagingService? _messagingService;
  IBLEDiscoveryService? _discoveryService;
  IBLEAdvertisingService? _advertisingService;
  IBLEHandshakeService? _handshakeService;
  late final BleLifecycleCoordinator _lifecycleCoordinator;

  // State
  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Ready',
  );

  Future<bool> Function(QueueSyncMessage message, String fromNodeId)?
  _queueSyncHandler;
  final List<dynamic> _handshakeMessageBuffer = [];
  bool _forwardingSpyModeEvent = false;
  bool _forwardingIdentityEvent = false;
  StreamSubscription<ConnectionInfo>? _connectionInfoSubscription;

  // Initialization state
  final Completer<void> _initializationCompleter = Completer<void>();

  @override
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
    IHandshakeCoordinatorFactory? handshakeCoordinatorFactory,
  }) : _platformHost =
           platformHost ??
           BlePlatformHost(
             ephemeralIdProvider: EphemeralKeyManager.generateMyEphemeralKey,
           ),
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
       _handshakeService = handshakeService,
       _handshakeCoordinatorFactory = handshakeCoordinatorFactory {
    _eventBus = BleFacadeEventBus(logger: _logger);
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
          sessionKeyProvider: () => EphemeralKeyManager.currentSessionKey,
        );
    DeviceDeduplicationManager.myEphemeralHintProvider =
        EphemeralKeyManager.generateMyEphemeralKey;

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

    _lifecycleCoordinator = BleLifecycleCoordinator(
      logger: _logger,
      platformHost: _platformHost,
      connectionManager: _connectionManager,
      getConnectionService: _getConnectionService,
      getDiscoveryService: _getDiscoveryService,
      getAdvertisingService: _getAdvertisingService,
      getMessagingService: _getMessagingService,
      getHandshakeService: _getHandshakeService,
    );
    _runtimeHelper = _BleServiceFacadeRuntimeHelper(this);
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
      _eventBus.emitConnectionInfo(connectionInfo);
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
  Stream<String> get hintMatches => _eventBus.hintMatchesStream();

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
      handshakeCoordinatorFactory: _handshakeCoordinatorFactory,
    );

    // Make the handshake service discoverable to the message handler (fragment
    // pipeline) via DI so reassembled handshake frames route correctly.
    try {
      if (!_getIt.isRegistered<IBLEHandshakeService>()) {
        _getIt.registerSingleton<IBLEHandshakeService>(_handshakeService!);
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
  Future<void> initialize() => _runtimeHelper.initializeFacade();

  @override
  Future<void> dispose() => _runtimeHelper.disposeFacade();

  @override
  Future<void> get initializationComplete => _initializationCompleter.future;

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  @override
  Future<String> getMyPublicKey() => _runtimeHelper.getMyPublicKey();

  @override
  Future<String> getMyEphemeralId() => _runtimeHelper.getMyEphemeralId();

  @override
  @override
  Future<void> setMyUserName(String name) => _runtimeHelper.setMyUserName(name);

  // ============================================================================
  // MESH NETWORKING INTEGRATION
  // ============================================================================

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) => _runtimeHelper.registerQueueSyncHandler(handler);

  @override
  Future<domain_models.ProtocolMessage?> revealIdentityToFriend() =>
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
      _eventBus.connectionInfoStream(_currentConnectionInfo);

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
      _runtimeHelper.discoveredDevicesStream;

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
  Stream<SpyModeInfo> get spyModeDetected => _eventBus.spyModeDetectedStream();

  @override
  Stream<String> get identityRevealedStream =>
      _eventBus.identityRevealedStream();

  @override
  Stream<String> get identityRevealed => identityRevealedStream;

  @override
  void emitSpyModeDetected(SpyModeInfo info) =>
      _runtimeHelper.emitSpyModeDetected(info);

  void _notifySpyModeDetected(SpyModeInfo info) =>
      _runtimeHelper.notifySpyModeDetected(info);

  @override
  void emitIdentityRevealed(String contactId) =>
      _runtimeHelper.emitIdentityRevealed(contactId);

  void _notifyIdentityRevealed(String contactId) =>
      _runtimeHelper.notifyIdentityRevealed(contactId);

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
    _runtimeHelper.ensureConnectionServicePrepared();
  }

  Future<void> _ensureDiscoveryInitialized() async {
    await _runtimeHelper.ensureDiscoveryInitialized();
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
  }) => _runtimeHelper.updateConnectionInfo(
    isConnected: isConnected,
    isReady: isReady,
    otherUserName: otherUserName,
    statusMessage: statusMessage,
    isScanning: isScanning,
    isAdvertising: isAdvertising,
    isReconnecting: isReconnecting,
  );

  Future<void> _initializeNodeIdentity() =>
      _runtimeHelper.initializeNodeIdentity();

  Future<void> _onBluetoothBecameReady() =>
      _runtimeHelper.onBluetoothBecameReady();

  Future<void> _onBluetoothBecameUnavailable() =>
      _runtimeHelper.onBluetoothBecameUnavailable();

  Future<void> _onBluetoothInitializationRetry() =>
      _runtimeHelper.onBluetoothInitializationRetry();

  void _handleIdentityExchangeSent(String publicKey, String displayName) =>
      _runtimeHelper.handleIdentityExchangeSent(publicKey, displayName);

  Future<void> _sendHandshakeProtocolMessage(ProtocolMessage message) =>
      _runtimeHelper.sendHandshakeProtocolMessage(message);

  Future<void> _processPendingHandshakeMessages() =>
      _runtimeHelper.processPendingHandshakeMessages();

  Future<void> _startGossipSync() => _runtimeHelper.startGossipSync();

  Future<void> _handleHandshakeComplete(
    String ephemeralId,
    String displayName,
    String? noiseKey,
  ) => _runtimeHelper.handleHandshakeComplete(
    ephemeralId: ephemeralId,
    displayName: displayName,
    noiseKey: noiseKey,
  );

  void _handleSpyModeDetected(SpyModeInfo info) =>
      _runtimeHelper.handleSpyModeDetected(info);

  void _handleIdentityRevealed(String contactId) =>
      _runtimeHelper.handleIdentityRevealed(contactId);

  // ============================================================================
  // TEST SUPPORT
  // ============================================================================

  @visibleForTesting
  void debugEmitSpyModeDetected(SpyModeInfo info) => emitSpyModeDetected(info);

  @visibleForTesting
  void debugEmitIdentityRevealed(String contactId) =>
      emitIdentityRevealed(contactId);

  @visibleForTesting
  void debugHandleQueueSync(QueueSyncMessage message, String fromNodeId) {
    final handler = _queueSyncHandler;
    if (handler != null) {
      handler(message, fromNodeId);
    }
  }

  /// Production accessor for the configured message handler facade used by mesh
  /// networking and queue orchestration.
  @override
  IBLEMessageHandlerFacade get meshMessageHandler => _messageHandlerFacade;

  /// Expose underlying message handler for integration wiring (AppCore tests).
  @visibleForTesting
  BLEMessageHandler get messageHandler => _messageHandler;
}
