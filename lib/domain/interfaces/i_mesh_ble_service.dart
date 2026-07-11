import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../models/binary_payload.dart';
import '../models/connection_info.dart';
import '../models/mesh_relay_models.dart';
import '../models/protocol_message.dart';
import 'i_ble_discovery_service.dart';

/// Minimal BLE interface required by the mesh networking domain service.
///
/// Exposes a small subset of the BLEService API so the domain layer does not
/// need to import the concrete implementation from lib/data/.
abstract interface class IMeshBleService {
  Stream<ConnectionInfo> get connectionInfo;
  ConnectionInfo get currentConnectionInfo;
  String? get currentSessionId;
  Future<String> getMyPublicKey();

  bool get canSendMessages;
  bool get hasPeripheralConnection;
  bool get isPeripheralMode;
  bool get isConnected;
  bool get canAcceptMoreConnections;
  int get activeConnectionCount;
  int get maxCentralConnections;
  List<String> get activeConnectionDeviceIds;
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData;
  Stream<String> get receivedMessages;
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges;

  /// Binary/media payloads received for this node.
  Stream<BinaryPayload> get receivedBinaryStream;

  Future<String> getMyEphemeralId();
  String? get theirPersistentPublicKey;

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

  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromDeviceAddress)
    handler,
  );

  Future<bool> sendPeripheralMessage(String message, {String? messageId});

  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  });

  Future<bool> sendProtocolMessage(ProtocolMessage message);

  Future<bool> sendQueueSyncMessage(QueueSyncMessage message, {String? peerId});
  Future<void> startScanning({ScanningSource source = ScanningSource.system});
  Future<void> stopScanning();
}
