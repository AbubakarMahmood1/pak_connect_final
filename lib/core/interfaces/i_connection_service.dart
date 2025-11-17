import '../../domain/entities/enhanced_message.dart';

/// Interface for connection service (BLE messaging and device management)
///
/// Abstracts BLE layer from Core services that need to send/receive messages.
/// Implemented by BLEServiceFacade (or other BLE implementations in the future).
///
/// **Separation of Concerns**:
/// - Core services depend on IConnectionService (abstraction)
/// - Core services do NOT import BLEService (concrete implementation)
/// - Data layer BLEServiceFacade implements IConnectionService
/// - DI container wires them together at runtime
///
/// **Critical Invariants Preserved**:
/// ✅ Message routing (deterministic IDs, duplicate detection)
/// ✅ Session security (Noise handshake before encryption)
/// ✅ Identity management (publicKey immutable, ephemeralId per-session)
abstract class IConnectionService {
  // ============ MESSAGING OPERATIONS ============

  /// Send message to recipient via BLE
  ///
  /// Returns true if sent/queued successfully, false if critical error.
  /// Messages are automatically encrypted using Noise session.
  Future<bool> sendMessage({
    required String recipient,
    required String content,
    String? messageId,
  });

  /// Send message as peripheral (for inbound connections)
  ///
  /// Used when local device is in peripheral mode and needs to respond
  /// to a central device that initiated connection.
  Future<bool> sendPeripheralMessage({
    required String recipientAddress,
    required String content,
  });

  /// Send queue sync message (for offline queue synchronization)
  ///
  /// Synchronizes pending messages with reconnected peers.
  Future<bool> sendQueueSyncMessage({
    required String recipientId,
    required List<EnhancedMessage> pendingMessages,
  });

  /// Stream of received messages
  Stream<EnhancedMessage> get receivedMessagesStream;

  // ============ DEVICE DISCOVERY ============

  /// Start BLE scanning for nearby devices
  Future<void> startScanning();

  /// Stop BLE scanning
  Future<void> stopScanning();

  /// Stream of discovered devices (Peripheral objects)
  Stream<dynamic>
  get discoveredDevicesStream; // Peripheral type from BLE package

  /// Current list of discovered devices
  List<dynamic> get currentDiscoveredDevices; // List<Peripheral>

  /// Check if discovery/scanning is active
  bool get isDiscoveryActive;

  // ============ ADVERTISING (PERIPHERAL MODE) ============

  /// Start advertising (peripheral mode)
  ///
  /// Allows remote devices to discover and connect to this device.
  Future<void> startAsPeripheral();

  /// Check if currently advertising
  bool get isAdvertising;

  // ============ CONNECTION MANAGEMENT ============

  /// Connect to a specific device by address
  Future<void> connectToDevice(String deviceAddress);

  /// Disconnect from currently connected device
  Future<void> disconnect();

  /// Stream of connection info updates
  Stream<String> get connectionInfoStream;

  /// Get current connection information
  String? get currentConnectionInfo;

  /// Check if currently connected to a peer
  bool get isConnected;

  /// Get address of connected device (if connected)
  String? get connectedDevice;

  // ============ BLUETOOTH STATE ============

  /// Stream of Bluetooth state changes
  Stream<bool> get bluetoothStateStream;

  /// Check if Bluetooth is ready for use
  bool get isBluetoothReady;

  /// Get current Bluetooth state (BluetoothLowEnergyState enum)
  dynamic get state; // BluetoothLowEnergyState from BLE package

  // ============ IDENTITY ============

  /// Get this device's public key
  String getMyPublicKey();

  /// Get this device's ephemeral session ID
  String getMyEphemeralId();

  /// Get remote device's user name (if connected)
  String? get otherUserName;

  /// Set this device's user name for others to see
  Future<void> setMyUserName(String userName);

  // ============ SESSION & HANDSHAKE ============

  /// Get current Noise session ID for active connection
  String? get currentSessionId;

  /// Get remote device's ephemeral ID
  String? get theirEphemeralId;

  /// Get remote device's persistent key
  String? get theirPersistentKey;

  /// Check if handshake is in progress
  bool get isHandshakeInProgress;

  /// Check if handshake has completed
  bool get hasHandshakeCompleted;

  /// Perform full 4-phase BLE handshake
  Future<bool> performHandshake({
    required String deviceAddress,
    required bool isInitiator,
  });

  /// Called when handshake completes (for relay engine coordination)
  void onHandshakeComplete(Function(bool success) callback);

  /// Request identity exchange with connected peer
  Future<void> requestIdentityExchange();
}
