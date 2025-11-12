import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/discovery/device_deduplication_manager.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';

/// Interface for BLE service operations
///
/// Abstracts BLE adapter, scanning, advertising, connections, and messaging to enable:
/// - Dependency injection
/// - Test mocking (important for testing without real BLE hardware)
/// - Alternative implementations (e.g., mock BLE for UI testing)
///
/// **Phase 1 Note**: Interface defines core public API from BLEService
/// Full interface will be completed in Phase 2 when BLEService is split into sub-services
abstract class IBLEService {
  // =========================
  // INITIALIZATION & LIFECYCLE
  // =========================

  /// Initialize BLE service
  Future<void> initialize();

  /// Dispose resources
  void dispose();

  /// Future that completes when initialization is done
  Future<void> get initializationComplete;

  // =========================
  // STATE MANAGEMENT
  // =========================

  /// Current BLE connection state
  BluetoothLowEnergyState get state;

  /// Is connected to a device
  bool get isConnected;

  /// Can send messages right now
  bool get canSendMessages;

  /// Current connection info
  ConnectionInfo get currentConnectionInfo;

  /// Connection info stream
  Stream<ConnectionInfo> get connectionInfo;

  /// Discovered devices stream
  Stream<List<DiscoveredDevice>> get discoveredDevices;

  /// Received messages stream
  Stream<EnhancedMessage> get receivedMessages;

  /// State manager (for advanced usage)
  BLEStateManager get stateManager;

  /// Connection manager (for advanced usage)
  BLEConnectionManager get connectionManager;

  // =========================
  // DISCOVERY OPERATIONS
  // =========================

  /// Start BLE scanning (central mode)
  Future<void> startScanning();

  /// Stop BLE scanning
  void stopScanning();

  /// Scan for specific device by ephemeral ID
  Future<void> scanForSpecificDevice(String targetEphemeralId);

  // =========================
  // ADVERTISING OPERATIONS
  // =========================

  /// Start BLE advertising (peripheral mode)
  Future<void> startAsPeripheral();

  /// Refresh advertising data
  Future<void> refreshAdvertising();

  // =========================
  // CONNECTION OPERATIONS
  // =========================

  /// Start as BLE central (scanner + connector)
  Future<void> startAsCentral();

  /// Connect to a discovered device
  Future<void> connectToDevice(String deviceId);

  /// Disconnect from current device
  Future<void> disconnect();

  /// Start connection monitoring
  void startConnectionMonitoring();

  /// Stop connection monitoring
  void stopConnectionMonitoring();

  // =========================
  // HANDSHAKE OPERATIONS
  // =========================

  /// Request identity exchange with connected peer
  Future<void> requestIdentityExchange();

  /// Trigger identity re-exchange
  Future<void> triggerIdentityReExchange();

  /// Set handshake in progress flag
  void setHandshakeInProgress(bool inProgress);

  // =========================
  // MESSAGING OPERATIONS
  // =========================

  /// Send message to connected central device (when in peripheral mode)
  Future<void> sendMessage(String recipientKey, Uint8List encryptedMessage);

  /// Send message to connected peripheral device (when in central mode)
  Future<void> sendPeripheralMessage(Uint8List message);

  /// Register queue sync message handler
  void registerQueueSyncHandler(
    Future<void> Function(Map<String, dynamic>) handler,
  );

  /// Send queue sync message
  Future<void> sendQueueSyncMessage(Map<String, dynamic> syncMessage);

  // =========================
  // IDENTITY OPERATIONS
  // =========================

  /// Get my public key
  String getMyPublicKey();

  /// Get my current ephemeral ID
  String getMyEphemeralId();

  /// Set my user name
  void setMyUserName(String userName);

  /// Get my user name
  String get myUserName;

  /// Get other user's name (connected peer)
  String get otherUserName;

  // =========================
  // RECOVERY OPERATIONS
  // =========================

  /// Attempt to recover identity information
  Future<void> attemptIdentityRecovery();

  /// Get connection info with fallback
  Future<ConnectionInfo?> getConnectionInfoWithFallback();
}
