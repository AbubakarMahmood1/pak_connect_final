import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../bluetooth/bluetooth_state_monitor.dart';
import '../interfaces/i_mesh_ble_service.dart';
import 'i_ble_discovery_service.dart';
import '../models/spy_mode_info.dart';
import '../models/connection_info.dart';
import '../models/ble_server_connection.dart';
import '../models/protocol_message.dart';
import 'i_ble_messaging_service.dart';

/// Abstraction for the BLE connection layer exposed to Core/Presentation.
///
/// This builds on top of [IMeshBleService] (used by the mesh domain) and
/// exposes the additional operations that the UI/Core layers need such as
/// discovery streams, Bluetooth state monitoring, and advertising controls.
/// The concrete `BLEService` currently implements this until the dedicated
/// facade replaces it in later phases.
abstract interface class IConnectionService implements IMeshBleService {
  // ===== Discovery / UI streams =====

  /// Stream of discovered peripherals (used by scanning overlays).
  Stream<List<Peripheral>> get discoveredDevices;

  /// Hint matches produced by the discovery hint scanner.
  Stream<String> get hintMatches;

  /// Discovery metadata stream (deduplicated devices with advertisement data).
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData;

  /// Scan for a specific device, optionally with a timeout.
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout});

  /// Spy-mode detection events (surfaced in pairing UI).
  Stream<SpyModeInfo> get spyModeDetected;

  /// Identity reveal notifications once a peer discloses their name/key.
  Stream<String> get identityRevealed;

  /// Currently connected central when acting as a peripheral.
  Central? get connectedCentral;

  /// Currently connected peripheral when acting as a central.
  Peripheral? get connectedDevice;

  /// Send binary/media payload; returns transferId for retry tracking.
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  });

  /// Retry a previously persisted binary/media payload using the latest MTU.
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  });

  // ===== Bluetooth state =====

  /// Stream of adapter state changes (powered on/off etc.).
  Stream<BluetoothStateInfo> get bluetoothStateStream;

  /// Stream of human-readable Bluetooth status messages.
  Stream<BluetoothStatusMessage> get bluetoothMessageStream;

  /// Whether the Bluetooth adapter is ready for use.
  bool get isBluetoothReady;

  /// Current adapter state reported by the BLE plugin.
  BluetoothLowEnergyState get state;

  /// Last-known connection information.
  ConnectionInfo get currentConnectionInfo;

  /// Stream of connection information updates.
  Stream<ConnectionInfo> get connectionInfo;

  /// Binary/media payloads received for this node.
  Stream<BinaryPayload> get receivedBinaryStream;

  // ===== Advertising / role management =====

  /// Start advertising so other devices can discover this node.
  Future<void> startAsPeripheral();

  /// Start central mode scanning/connection flows.
  Future<void> startAsCentral();

  /// Refresh advertising payload (display name, status flags, etc.).
  Future<void> refreshAdvertising({bool? showOnlineStatus});

  /// Whether advertising is currently active.
  bool get isAdvertising;

  /// Whether the negotiated MTU for peripheral mode is ready.
  bool get isPeripheralMTUReady;

  /// The MTU negotiated while acting as a peripheral (null if unknown).
  int? get peripheralNegotiatedMTU;

  // ===== Connection management =====

  /// Connect to a discovered peripheral (central role).
  Future<void> connectToDevice(Peripheral device);

  /// Disconnect from the active peer (both roles).
  Future<void> disconnect();

  /// Start background connection-state monitoring (RSSI/MTU health checks).
  void startConnectionMonitoring();

  /// Stop background connection-state monitoring.
  void stopConnectionMonitoring();

  /// Whether the connection manager is actively attempting to reconnect.
  bool get isActivelyReconnecting;

  // ===== Identity / handshake helpers =====

  /// Request identity exchange with the connected peer.
  Future<void> requestIdentityExchange();

  /// Trigger identity re-exchange after updating profile data.
  Future<void> triggerIdentityReExchange();

  /// Reveal identity in spy-mode flows.
  Future<ProtocolMessage?> revealIdentityToFriend();

  /// Update the cached username.
  Future<void> setMyUserName(String name);

  /// Accept a pending contact request.
  Future<void> acceptContactRequest();

  /// Reject a pending contact request.
  void rejectContactRequest();

  /// Set listener for contact request completion events.
  void setContactRequestCompletedListener(void Function(bool success) listener);

  /// Set listener for incoming contact request events.
  void setContactRequestReceivedListener(
    void Function(String publicKey, String displayName) listener,
  );

  /// Set listener for asymmetric contact detection events.
  void setAsymmetricContactListener(
    void Function(String publicKey, String displayName) listener,
  );

  /// Mark pairing as in-progress to pause health checks.
  void setPairingInProgress(bool isInProgress);

  /// Connection slots and server connection metadata.
  List<BLEServerConnection> get serverConnections;
  int get clientConnectionCount;
  int get maxCentralConnections;
}
