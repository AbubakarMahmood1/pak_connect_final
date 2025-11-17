import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import 'i_ble_connection_service.dart';
import 'i_ble_messaging_service.dart';
import 'i_ble_discovery_service.dart';
import 'i_ble_advertising_service.dart';
import 'i_ble_handshake_service.dart';

/// Main orchestrator for the entire BLE stack
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
abstract class IBLEServiceFacade
    implements
        IBLEConnectionService,
        IBLEMessagingService,
        IBLEDiscoveryService,
        IBLEAdvertisingService,
        IBLEHandshakeService {
  // ============================================================================
  // INITIALIZATION & LIFECYCLE
  // ============================================================================

  /// Initialize all BLE sub-services and event listeners
  /// Called at app startup after AppCore initialization
  ///
  /// Setup order:
  /// 1. Create stream controllers for UI events
  /// 2. Initialize sub-service managers (connection, message, discovery, etc.)
  /// 3. Wire event listeners (central → peripheral, deduplication, auto-connect, etc.)
  /// 4. Start Bluetooth state monitoring
  /// 5. Initialize mesh networking managers (gossip sync, offline queue)
  /// 6. Load persistent settings (username, etc.)
  ///
  /// Throws:
  ///   StateError if AppCore not initialized
  ///   PlatformException if BLE initialization fails
  Future<void> initialize();

  /// Cleanup all resources and cancel subscriptions
  /// Called at app shutdown or when BLE needs to be disabled
  ///
  /// Cleanup order:
  /// 1. Stop all active scans and connections
  /// 2. Dispose handshake coordinator (if active)
  /// 3. Close all stream controllers
  /// 4. Cancel all subscriptions (Bluetooth monitor, etc.)
  /// 5. Cleanup gossip sync manager
  /// 6. Cleanup hint scanner
  /// 7. Shutdown external managers
  void dispose();

  /// Future that completes when initialization is done
  /// Used by consumers to wait for full BLE readiness
  Future<void> get initializationComplete;

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  /// Get device's persistent public key (used for chat history, pairing)
  /// IMMUTABLE: Never changes for this device
  ///
  /// Returns:
  ///   Persistent public key or empty string if not available
  Future<String> getMyPublicKey();

  /// Get device's current ephemeral session ID (used for mesh routing)
  /// ROTATES: Changes per connection for privacy
  ///
  /// Returns:
  ///   Ephemeral ID or empty string if not in session
  Future<String> getMyEphemeralId();

  /// Set local device display name
  /// Propagates to peer via identity exchange
  ///
  /// Args:
  ///   name - New display name
  /// Throws:
  ///   StateError if storage unavailable
  Future<void> setMyUserName(String name);

  // ============================================================================
  // MESH NETWORKING INTEGRATION
  // ============================================================================

  /// Register callback for queue sync message interception
  /// Called by MeshNetworkingService during initialization
  /// Allows mesh layer to intercept and handle relay messages
  ///
  /// Args:
  ///   handler - Callback that processes queue sync messages
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  );

  // ============================================================================
  // SUB-SERVICE ACCESS (For direct consumers)
  // ============================================================================

  /// Access to connection service (for advanced consumers)
  IBLEConnectionService get connectionService;

  /// Access to messaging service (for advanced consumers)
  IBLEMessagingService get messagingService;

  /// Access to discovery service (for advanced consumers)
  IBLEDiscoveryService get discoveryService;

  /// Access to advertising service (for advanced consumers)
  IBLEAdvertisingService get advertisingService;

  /// Access to handshake service (for advanced consumers)
  IBLEHandshakeService get handshakeService;

  // ============================================================================
  // BLUETOOTH STATE MONITORING
  // ============================================================================

  /// Stream of Bluetooth adapter state changes (on/off/etc)
  /// Emitted by BluetoothStateMonitor
  Stream<BluetoothStateInfo> get bluetoothStateStream;

  /// Stream of Bluetooth status messages (for UI display)
  /// Emitted by BluetoothStateMonitor
  Stream<BluetoothStatusMessage> get bluetoothMessageStream;

  /// Is Bluetooth adapter currently ready?
  /// Synchronous check (not stream)
  bool get isBluetoothReady;

  // ============================================================================
  // LEGACY STATE GETTERS (For backward compatibility)
  // ============================================================================

  /// Current Bluetooth stack state (from CentralManager)
  BluetoothLowEnergyState get state;

  /// Local device's username
  String? get myUserName;
}
