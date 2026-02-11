import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/domain/interfaces/i_ble_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_advertising_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/bluetooth_state_models.dart';

/// Main orchestrator for the entire BLE stack.
///
/// Facade pattern: Provides unified interface to complex subsystem of 5 services:
/// - IBLEConnectionService: Connection lifecycle
/// - IBLEMessagingService: Message send/receive
/// - IBLEDiscoveryService: Device discovery
/// - IBLEAdvertisingService: Peripheral advertising
/// - IBLEHandshakeService: Handshake protocol
///
/// Responsibilities:
/// - Initialize all sub-services in correct order
/// - Coordinate cross-service concerns (handshake → messaging transition)
/// - Provide unified public API for consumers
/// - Manage Bluetooth state monitoring and recovery
/// - Integrate mesh networking via callback handlers
/// - Handle graceful shutdown and resource cleanup
///
/// Consumers: All 18 files (primary public API)
abstract interface class IBLEServiceFacade
    implements
        IBLEConnectionService,
        IBLEMessagingService,
        IBLEDiscoveryService,
        IBLEAdvertisingService,
        IBLEHandshakeService {
  // ============================================================================
  // INITIALIZATION & LIFECYCLE
  // ============================================================================

  /// Initialize all BLE sub-services and event listeners.
  @override
  Future<void> initialize();

  /// Cleanup all resources and cancel subscriptions.
  @override
  Future<void> dispose();

  /// Future that completes when initialization is done.
  Future<void> get initializationComplete;

  /// True once the facade has completed initialization.
  bool get isInitialized;

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  /// Get device's persistent public key (used for chat history, pairing).
  Future<String> getMyPublicKey();

  /// Get device's current ephemeral session ID (used for mesh routing).
  Future<String> getMyEphemeralId();

  /// Set local device display name.
  Future<void> setMyUserName(String name);

  // ============================================================================
  // MESH NETWORKING INTEGRATION
  // ============================================================================

  /// Register callback for queue sync message interception.
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  );

  /// Exposes the mesh message handler facade for mesh orchestration wiring.
  IBLEMessageHandlerFacade get meshMessageHandler;

  // ============================================================================
  // SUB-SERVICE ACCESS (For direct consumers)
  // ============================================================================

  IBLEConnectionService get connectionService;
  IBLEMessagingService get messagingService;
  IBLEDiscoveryService get discoveryService;
  IBLEAdvertisingService get advertisingService;
  IBLEHandshakeService get handshakeService;

  // ============================================================================
  // BLUETOOTH STATE MONITORING
  // ============================================================================

  /// Stream of Bluetooth adapter state changes (on/off/etc).
  Stream<BluetoothStateInfo> get bluetoothStateStream;

  /// Stream of Bluetooth status messages (for UI display).
  Stream<BluetoothStatusMessage> get bluetoothMessageStream;

  /// Is Bluetooth adapter currently ready?
  bool get isBluetoothReady;

  // ============================================================================
  // LEGACY STATE GETTERS (For backward compatibility)
  // ============================================================================

  /// Current Bluetooth stack state (from CentralManager).
  BluetoothLowEnergyState get state;

  /// Local device's username.
  String? get myUserName;
}
