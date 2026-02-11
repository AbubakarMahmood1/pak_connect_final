import '../messaging/queue_sync_manager.dart';
import '../models/mesh_relay_models.dart';
import '../models/protocol_message.dart';
import '../values/id_types.dart';

/// Domain contract for relay coordination between BLE and mesh networking.
///
/// Implementations may live in infrastructure layers, but higher-level code
/// should depend on this interface.
abstract interface class IRelayCoordinator {
  Future<void> initializeRelaySystem({required String currentNodeId});

  Future<bool> handleMeshRelay({
    required String originalMessageId,
    required String content,
    required String originalSender,
    required String? intendedRecipient,
    required Map<String, dynamic>? messageData,
    required int? currentHopCount,
  });

  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String content,
    required String originalSender,
    required String? intendedRecipient,
    required int currentHopCount,
  });

  Future<void> handleRelayToNextHop({
    required MeshRelayMessage relayMessage,
    required String nextHopDeviceId,
  });

  void handleRelayDeliveryToSelf({
    required String originalMessageId,
    required String content,
    required String originalSender,
  });

  bool shouldAttemptRelay({
    required String messageId,
    required int currentHopCount,
  });

  Future<bool> shouldAttemptDecryption({
    required String messageId,
    required String senderKey,
  });

  Future<void> sendRelayAck({
    required String originalMessageId,
    required String toDeviceId,
    required String relayAckContent,
  });

  Future<void> handleRelayAck({
    required String originalMessageId,
    required String fromDeviceId,
    required Map<String, dynamic>? ackData,
  });

  Future<RelayStatistics> getRelayStatistics();

  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  });

  void setCurrentNodeId(String nodeId);

  List<String> getAvailableNextHops();

  void onRelayStatsUpdated(Function(RelayStatistics stats) callback);

  void onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)
    callback,
  );

  void onRelayMessageReceivedIds(
    Function(MessageId originalMessageId, String content, String originalSender)
    callback,
  );

  void onRelayDecisionMade(Function(RelayDecision decision) callback);

  void onSendRelayMessage(
    Function(ProtocolMessage message, String nextHopId) callback,
  );

  void onSendAckMessage(Function(ProtocolMessage message) callback);

  void onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId) callback,
  );

  void onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result) callback,
  );

  void dispose();
}
