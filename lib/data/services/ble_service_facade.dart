import 'dart:async';
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
import 'ble_connection_service.dart';
import 'ble_messaging_service.dart';
import 'ble_discovery_service.dart';
import 'ble_advertising_service.dart';
import 'ble_handshake_service.dart';
import 'ble_state_manager.dart';
import 'ble_connection_manager.dart';
import 'ble_message_handler.dart';
import '../repositories/intro_hint_repository.dart';
import '../../core/bluetooth/advertising_manager.dart';
import '../../core/bluetooth/peripheral_initializer.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../core/services/hint_scanner_service.dart';
import '../../core/bluetooth/ble_platform_host.dart';

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
  final BLEStateManager _stateManager;
  final BLEMessageHandler _messageHandler;
  final HintScannerService _hintScanner;
  final IntroHintRepository _introHintRepository;
  final BluetoothStateMonitor _bluetoothStateMonitor;
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
  final StreamController<ConnectionInfo> _connectionInfoController =
      StreamController<ConnectionInfo>.broadcast();
  final StreamController<List<Peripheral>> _discoveredDevicesController =
      StreamController<List<Peripheral>>.broadcast();
  final StreamController<String> _hintMatchesController =
      StreamController<String>.broadcast();
  Future<bool> Function(QueueSyncMessage message, String fromNodeId)?
  _queueSyncHandler;
  final List<dynamic> _handshakeMessageBuffer = [];
  final StreamController<SpyModeInfo> _handshakeSpyModeController =
      StreamController<SpyModeInfo>.broadcast();
  final StreamController<String> _handshakeIdentityController =
      StreamController<String>.broadcast();

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
    BLEStateManager? stateManager,
    BLEMessageHandler? messageHandler,
    HintScannerService? hintScanner,
    IntroHintRepository? introHintRepository,
    BluetoothStateMonitor? bluetoothStateMonitor,
    BLEConnectionManager? connectionManager,
    PeripheralInitializer? peripheralInitializer,
    AdvertisingManager? advertisingManager,
  }) : _platformHost = platformHost ?? BlePlatformHost(),
       _stateManager = stateManager ?? BLEStateManager(),
       _messageHandler = messageHandler ?? BLEMessageHandler(),
       _hintScanner = hintScanner ?? HintScannerService(),
       _introHintRepository = introHintRepository ?? IntroHintRepository(),
       _bluetoothStateMonitor =
           bluetoothStateMonitor ?? BluetoothStateMonitor.instance,
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
  }

  /// Get or create connection service (lazy singleton)
  BLEConnectionService _getConnectionService() {
    return _connectionService ??= BLEConnectionService(
      stateManager: _stateManager,
      connectionManager: _connectionManager,
      centralManager: _platformHost.centralManager,
      bluetoothStateMonitor: _bluetoothStateMonitor,
      onUpdateConnectionInfo: _updateConnectionInfo,
    )..connectionInfoController = _connectionInfoController;
  }

  /// Get or create discovery service (lazy singleton)
  IBLEDiscoveryService _getDiscoveryService() {
    return _discoveryService ??=
        BLEDiscoveryService(
            centralManager: _platformHost.centralManager,
            stateManager: _stateManager,
            hintScanner: _hintScanner,
            onUpdateConnectionInfo: _updateConnectionInfo,
            isAdvertising: () => _getAdvertisingService().isAdvertising,
            isConnected: () => _getConnectionService().isConnected,
          )
          ..devicesController = _discoveredDevicesController
          ..hintMatchController = _hintMatchesController;
  }

  @override
  Stream<String> get hintMatches => _hintMatchesController.stream;

  /// Get or create advertising service (lazy singleton)
  IBLEAdvertisingService _getAdvertisingService() {
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
    return _messagingService ??= BLEMessagingService(
      messageHandler: _messageHandler,
      connectionManager: _connectionManager,
      stateManager: _stateManager,
      getCentralManager: () => _platformHost.centralManager,
      getPeripheralManager: () => _platformHost.peripheralManager,
      messagesController: StreamController<String>.broadcast(),
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
  }

  /// Get or create handshake service (lazy singleton)
  IBLEHandshakeService _getHandshakeService() {
    return _handshakeService ??= BLEHandshakeService(
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
      spyModeDetectedController: _handshakeSpyModeController,
      identityRevealedController: _handshakeIdentityController,
      introHintRepo: _introHintRepository,
      messageBuffer: _handshakeMessageBuffer,
    );
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
      _logger.info('✅ BLEServiceFacade disposed');
    } catch (e, stack) {
      _logger.severe('❌ Disposal error', e, stack);
    } finally {
      if (!_connectionInfoController.isClosed) {
        await _connectionInfoController.close();
      }
      if (!_discoveredDevicesController.isClosed) {
        await _discoveredDevicesController.close();
      }
      if (!_hintMatchesController.isClosed) {
        await _hintMatchesController.close();
      }
      if (!_handshakeSpyModeController.isClosed) {
        await _handshakeSpyModeController.close();
      }
      if (!_handshakeIdentityController.isClosed) {
        await _handshakeIdentityController.close();
      }
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
    _messageHandler.onQueueSyncReceived = (message, fromNodeId) {
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
      _getConnectionService().connectionInfoStream;

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
  BLEStateManager get stateManager => _getConnectionService().stateManager;

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
  Stream<String> get receivedMessages => receivedMessagesStream;

  @override
  String? get lastExtractedMessageId =>
      _getMessagingService().lastExtractedMessageId;

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
      _getDiscoveryService().discoveredDevicesStream;

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
      _getHandshakeService().spyModeDetectedStream;

  @override
  Stream<String> get identityRevealedStream =>
      _getHandshakeService().identityRevealedStream;

  @override
  Stream<String> get identityRevealed =>
      _getHandshakeService().identityRevealedStream;

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

  void _ensureConnectionServicePrepared() {
    if (_connectionSetupComplete) {
      return;
    }
    _getConnectionService().setupConnectionInitialization();
    _connectionSetupComplete = true;
  }

  Future<void> _ensureDiscoveryInitialized() async {
    if (_discoveryInitialized) {
      return;
    }
    await _getDiscoveryService().initialize();
    _discoveryInitialized = true;
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
    if (!_connectionInfoController.isClosed) {
      _connectionInfoController.add(_currentConnectionInfo);
    }
  }

  Future<void> _onBluetoothBecameReady() async {
    _logger.info('🔵 Bluetooth ready - facade notified');
    _updateConnectionInfo(
      statusMessage: 'Bluetooth ready for dual-role operation',
      isAdvertising: _getAdvertisingService().isAdvertising,
    );
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
    // Notify state manager + any registered listeners
    _stateManager.onSpyModeDetected?.call(info);
    if (!_handshakeSpyModeController.isClosed) {
      _handshakeSpyModeController.add(info);
    }
  }

  void _handleIdentityRevealed(String contactId) {
    _logger.info('🪪 Identity revealed to contact: $contactId');
    _stateManager.onIdentityRevealed?.call(contactId);
    if (!_handshakeIdentityController.isClosed) {
      _handshakeIdentityController.add(contactId);
    }
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
    final callback = _messageHandler.onQueueSyncReceived;
    if (callback != null) {
      callback(message, fromNodeId);
    }
  }
}
