import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../models/connection_info.dart';

/// Manages BLE connection lifecycle including:
/// - Central role connection initiation and termination
/// - Connection state monitoring and health checks
/// - MTU negotiation and connection info broadcasting
///
/// Single responsibility: Handle all connection-related operations
/// Dependencies: CentralManager, PeripheralManager, BLEStateManager
/// Consumers: HomeScreen, DiscoveryOverlay, MeshNetworkingService
abstract class IBLEConnectionService {
  // ============================================================================
  // CONNECTION MANAGEMENT
  // ============================================================================

  /// Initiate connection to a discovered peripheral device
  /// Stops discovery, validates Bluetooth state, and handles inbound link adoption
  ///
  /// Args:
  ///   device - The discovered peripheral to connect to
  /// Throws:
  ///   StateError if Bluetooth not ready
  ///   PlatformException if connection fails
  Future<void> connectToDevice(Peripheral device);

  /// Disconnect from the currently connected device
  /// Cleans up connection state and resets session
  Future<void> disconnect();

  /// Start monitoring connection health (signal strength, MTU changes)
  /// Emits connection state updates at regular intervals
  void startConnectionMonitoring();

  /// Stop monitoring connection health
  void stopConnectionMonitoring();

  /// Dispose connection-related resources and monitoring
  void disposeConnection();

  /// Set/unset flag indicating handshake is in progress
  /// Used to prevent premature message sending during handshake
  void setHandshakeInProgress(bool isInProgress);

  /// Set/unset flag indicating pairing workflow is in progress
  /// Used to pause health checks and prevent reconnection churn
  void setPairingInProgress(bool isInProgress);

  // ============================================================================
  // CONNECTION STATE QUERIES
  // ============================================================================

  /// Get current connection state (connected/disconnected/monitoring)
  ConnectionInfo? getConnectionInfo();

  /// Get connection info with fallback to persistent storage
  /// Used during recovery scenarios when session state is cleared
  Future<ConnectionInfo?> getConnectionInfoWithFallback();

  /// Attempt to recover identity and connection state from storage
  /// Called when session state is unexpectedly cleared
  Future<bool> attemptIdentityRecovery();

  // ============================================================================
  // PROPERTIES & STREAMS
  // ============================================================================

  /// Stream of connection state changes (connected, ready, statusMessage, etc.)
  Stream<ConnectionInfo> get connectionInfoStream;

  /// Current connection state (synchronized copy, not stream)
  ConnectionInfo? get currentConnectionInfo;

  /// Is device currently connected via central role?
  bool get isConnected;

  /// Are we monitoring an active connection?
  bool get isMonitoring;

  /// Currently connected device (central role)
  Peripheral? get connectedDevice;

  /// Remote device's display name
  String? get otherUserName;

  /// Session ID for current connection
  String? get currentSessionId;

  /// Remote device's ephemeral session ID
  String? get theirEphemeralId;

  /// Remote device's persistent public key (if paired)
  String? get theirPersistentKey;

  /// Local device's persistent ID
  String? get myPersistentId;

  /// Is device actively attempting to reconnect?
  bool get isActivelyReconnecting;

  /// Do we have a peripheral-mode (server) connection?
  bool get hasPeripheralConnection;

  /// Do we have a central-mode (client) connection?
  bool get hasCentralConnection;

  /// Can we send regular chat messages (identity established)?
  bool get canSendMessages;

  /// Currently connected central (peripheral mode)
  Central? get connectedCentral;
}
