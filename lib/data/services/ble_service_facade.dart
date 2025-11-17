import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_service_facade.dart';
import '../../core/interfaces/i_ble_connection_service.dart';
import '../../core/interfaces/i_ble_messaging_service.dart';
import '../../core/interfaces/i_ble_discovery_service.dart';
import '../../core/interfaces/i_ble_advertising_service.dart';
import '../../core/interfaces/i_ble_handshake_service.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/spy_mode_info.dart';
import 'ble_connection_service.dart';
import 'ble_messaging_service.dart';
import 'ble_discovery_service.dart';
import 'ble_advertising_service.dart';
import 'ble_handshake_service.dart';
import 'ble_state_manager.dart';
import 'ble_connection_manager.dart';
import 'ble_message_handler.dart';
import '../repositories/contact_repository.dart';
import '../repositories/intro_hint_repository.dart';
import '../../core/bluetooth/advertising_manager.dart';
import '../../core/bluetooth/peripheral_initializer.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../core/services/hint_scanner_service.dart';
import '../../core/security/ephemeral_key_manager.dart';

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
class BLEServiceFacade implements IBLEServiceFacade {
  final _logger = Logger('BLEServiceFacade');

  // Sub-services (lazy-initialized)
  BLEConnectionService? _connectionService;
  BLEMessagingService? _messagingService;
  BLEDiscoveryService? _discoveryService;
  BLEAdvertisingService? _advertisingService;
  BLEHandshakeService? _handshakeService;

  // State
  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Ready',
  );
  Future<bool> Function(QueueSyncMessage message, String fromNodeId)?
  _queueSyncHandler;

  // Initialization state
  final Completer<void> _initializationCompleter = Completer<void>();

  BLEServiceFacade() {
    // Immediate completion - actual initialization is deferred
    _initializationCompleter.complete();
  }

  /// Get or create connection service (lazy singleton)
  BLEConnectionService _getConnectionService() {
    return _connectionService ??= BLEConnectionService(
      stateManager: BLEStateManager(),
      connectionManager: BLEConnectionManager(
        centralManager: CentralManager(),
        peripheralManager: PeripheralManager(),
      ),
      centralManager: CentralManager(),
      bluetoothStateMonitor: BluetoothStateMonitor.instance,
      onUpdateConnectionInfo: _updateConnectionInfo,
    );
  }

  /// Get or create discovery service (lazy singleton)
  BLEDiscoveryService _getDiscoveryService() {
    return _discoveryService ??= BLEDiscoveryService(
      centralManager: CentralManager(),
      stateManager: BLEStateManager(),
      hintScanner: HintScannerService(contactRepository: ContactRepository()),
      onUpdateConnectionInfo: _updateConnectionInfo,
      isAdvertising: () => _getAdvertisingService().isAdvertising,
      isConnected: () => _getConnectionService().isConnected,
    );
  }

  /// Get or create advertising service (lazy singleton)
  BLEAdvertisingService _getAdvertisingService() {
    return _advertisingService ??= BLEAdvertisingService(
      stateManager: BLEStateManager(),
      connectionManager: BLEConnectionManager(
        centralManager: CentralManager(),
        peripheralManager: PeripheralManager(),
      ),
      advertisingManager: AdvertisingManager(
        peripheralInitializer: PeripheralInitializer(PeripheralManager()),
        peripheralManager: PeripheralManager(),
        introHintRepo: IntroHintRepository(),
      ),
      peripheralInitializer: PeripheralInitializer(PeripheralManager()),
      peripheralManager: PeripheralManager(),
      onUpdateConnectionInfo: _updateConnectionInfo,
    );
  }

  /// Get or create messaging service (lazy singleton)
  BLEMessagingService _getMessagingService() {
    return _messagingService ??= BLEMessagingService(
      messageHandler: BLEMessageHandler(),
      connectionManager: BLEConnectionManager(
        centralManager: CentralManager(),
        peripheralManager: PeripheralManager(),
      ),
      stateManager: BLEStateManager(),
      getCentralManager: () => CentralManager(),
      getPeripheralManager: () => PeripheralManager(),
      messagesController: StreamController<String>.broadcast(),
      getConnectedCentral: () => null,
      getPeripheralMessageCharacteristic: () => null,
      getPeripheralMtuReady: () => false,
      getPeripheralNegotiatedMtu: () => 20,
    );
  }

  /// Get or create handshake service (lazy singleton)
  BLEHandshakeService _getHandshakeService() {
    return _handshakeService ??= BLEHandshakeService(
      stateManager: BLEStateManager(),
      onIdentityExchangeSent: (ephemeralId, displayName) {},
      updateConnectionInfo: _updateConnectionInfo,
      setHandshakeInProgress: (val) {},
      handleSpyModeDetected: (info) {},
      handleIdentityRevealed: (identity) {},
      sendProtocolMessage: (msg) async {},
      processPendingMessages: () async {},
      startGossipSync: () async {},
      onHandshakeCompleteCallback:
          (ephemeralId, displayName, noiseKey) async {},
      spyModeDetectedController: StreamController<SpyModeInfo>.broadcast(),
      identityRevealedController: StreamController<String>.broadcast(),
      introHintRepo: IntroHintRepository(),
      messageBuffer: [],
    );
  }

  // ============================================================================
  // INITIALIZATION & LIFECYCLE
  // ============================================================================

  @override
  Future<void> initialize() async {
    _logger.info('🏗️ Initializing BLEServiceFacade (lazy initialization)...');
    // Note: Sub-services are created on-demand (lazy singleton pattern)
    // This ensures proper initialization order and dependency resolution
    _logger.info('✅ BLEServiceFacade ready');
    // Note: _initializationCompleter is already completed in constructor
  }

  @override
  void dispose() {
    _logger.info('🧹 Disposing BLEServiceFacade...');

    try {
      // Stop all active operations (only if services were created)
      if (_discoveryService != null) {
        _discoveryService!.stopScanning().catchError((_) {});
      }
      if (_connectionService != null) {
        _connectionService!.stopConnectionMonitoring();
        _connectionService!.disconnect().catchError((_) {});
        _connectionService!.disposeConnection();
      }
      if (_handshakeService != null) {
        _handshakeService!.disposeHandshakeCoordinator();
      }

      _logger.info('✅ BLEServiceFacade disposed');
    } catch (e, stack) {
      _logger.severe('❌ Disposal error', e, stack);
    }
  }

  @override
  Future<void> get initializationComplete => _initializationCompleter.future;

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  @override
  Future<String> getMyPublicKey() async {
    _logger.fine('Getting public key...');
    // Will be properly implemented in Phase 2A.3
    return 'temp_public_key';
  }

  @override
  Future<String> getMyEphemeralId() async {
    try {
      return EphemeralKeyManager.generateMyEphemeralKey();
    } catch (e) {
      _logger.warning('EphemeralKeyManager not available', e);
      return 'temp_ephemeral_id';
    }
  }

  @override
  Future<void> setMyUserName(String name) async {
    _logger.fine('Setting username to: $name');
    // Will be properly implemented in Phase 2A.3
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
  }

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
  Stream<BluetoothStateInfo> get bluetoothStateStream {
    // Will be properly implemented in Phase 2A.3
    return Stream.empty();
  }

  @override
  Stream<BluetoothStatusMessage> get bluetoothMessageStream {
    // Will be properly implemented in Phase 2A.3
    return Stream.empty();
  }

  @override
  bool get isBluetoothReady {
    // Will be properly implemented in Phase 2A.3
    return false;
  }

  @override
  BluetoothLowEnergyState get state {
    // Will be properly implemented in Phase 2A.3
    return BluetoothLowEnergyState.unknown;
  }

  @override
  String? get myUserName {
    // Will be properly implemented in Phase 2A.3
    return null;
  }

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
  ConnectionInfo? get currentConnectionInfo =>
      _getConnectionService().currentConnectionInfo;

  @override
  bool get isConnected => _getConnectionService().isConnected;

  @override
  bool get isMonitoring => _getConnectionService().isMonitoring;

  @override
  Peripheral? get connectedDevice => _getConnectionService().connectedDevice;

  @override
  String? get otherUserName => _getConnectionService().otherUserName;

  @override
  String? get currentSessionId => _getConnectionService().currentSessionId;

  @override
  String? get theirEphemeralId => _getConnectionService().theirEphemeralId;

  @override
  String? get theirPersistentKey => _getConnectionService().theirPersistentKey;

  @override
  String? get myPersistentId => _getConnectionService().myPersistentId;

  @override
  bool get isActivelyReconnecting =>
      _getConnectionService().isActivelyReconnecting;

  @override
  bool get hasPeripheralConnection =>
      _getConnectionService().hasPeripheralConnection;

  @override
  bool get hasCentralConnection => _getConnectionService().hasCentralConnection;

  @override
  bool get canSendMessages => _getConnectionService().canSendMessages;

  @override
  Central? get connectedCentral => _getConnectionService().connectedCentral;

  /// Get connection manager for low-level connection operations
  /// 🔑 Used for pairing flow (setPairingInProgress)
  BLEConnectionManager get connectionManager =>
      _getConnectionService().connectionManager;

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
  String? get lastExtractedMessageId =>
      _getMessagingService().lastExtractedMessageId;

  // ============================================================================
  // DELEGATION TO SUB-SERVICES (IBLEDiscoveryService)
  // ============================================================================

  @override
  Future<void> startScanning({ScanningSource source = ScanningSource.manual}) =>
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
  Stream<String> get identityRevealedStream =>
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

  // ============================================================================
  // PRIVATE HELPER METHODS (STUB FOR PHASE 2A.3)
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
    // Will be fully implemented in Phase 2A.3
  }

  Future<void> _onBluetoothBecameReady() async {
    // Will be fully implemented in Phase 2A.3
  }

  Future<void> _onBluetoothBecameUnavailable() async {
    // Will be fully implemented in Phase 2A.3
  }

  Future<void> _onBluetoothInitializationRetry(int attemptNumber) async {
    // Will be fully implemented in Phase 2A.3
  }

  void _handleSpyModeDetected(SpyModeInfo info) {
    // Will be fully implemented in Phase 2A.3
  }

  void _handleIdentityRevealed(String contactId) {
    // Will be fully implemented in Phase 2A.3
  }

  Future<void> _onHandshakeComplete() async {
    // Will be fully implemented in Phase 2A.3
  }
}
