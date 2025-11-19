import '../models/connection_info.dart';
import '../models/mesh_relay_models.dart';

/// Minimal BLE interface required by the mesh networking domain service.
///
/// Exposes a small subset of the BLEService API so the domain layer does not
/// need to import the concrete implementation from lib/data/.
abstract interface class IMeshBleService {
  Stream<ConnectionInfo> get connectionInfo;
  ConnectionInfo get currentConnectionInfo;
  String? get currentSessionId;

  bool get canSendMessages;
  bool get hasPeripheralConnection;
  bool get isPeripheralMode;
  bool get isConnected;

  Future<String> getMyEphemeralId();

  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  );

  Future<bool> sendPeripheralMessage(String message, {String? messageId});

  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  });

  Future<void> sendQueueSyncMessage(QueueSyncMessage message);
}
