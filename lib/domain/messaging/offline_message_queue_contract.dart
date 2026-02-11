import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

export 'package:pak_connect/domain/entities/queue_enums.dart';
export 'package:pak_connect/domain/entities/queue_statistics.dart';
export 'package:pak_connect/domain/entities/queued_message.dart';

/// Domain-facing contract for offline queue behavior.
///
/// Concrete implementations may live in other layers, but domain services
/// should depend on this abstraction.
abstract interface class OfflineMessageQueueContract {
  set onMessageQueued(Function(QueuedMessage message)? callback);

  set onMessageDelivered(Function(QueuedMessage message)? callback);

  set onMessageFailed(Function(QueuedMessage message, String reason)? callback);

  set onStatsUpdated(Function(QueueStatistics stats)? callback);

  set onSendMessage(Function(String messageId)? callback);

  set onConnectivityCheck(Function()? callback);

  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
    Function()? onConnectivityCheck,
  });

  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const [],
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  });

  Future<MessageId> queueMessageWithIds({
    required ChatId chatId,
    required String content,
    required ChatId recipientId,
    required ChatId senderId,
    MessagePriority priority = MessagePriority.normal,
    MessageId? replyToMessageId,
    List<String> attachments = const [],
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  });

  Future<int> removeMessagesForChat(String chatId);

  Future<void> setOnline();

  void setOffline();

  Future<void> markMessageDelivered(String messageId);

  Future<void> markMessageFailed(String messageId, String reason);

  QueueStatistics getStatistics();

  Future<void> retryFailedMessages();

  Future<void> retryFailedMessagesForChat(String chatId);

  Future<void> clearQueue();

  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status);

  QueuedMessage? getMessageById(String messageId);

  List<QueuedMessage> getPendingMessages();

  Future<void> removeMessage(String messageId);

  Future<void> flushQueueForPeer(String peerPublicKey);

  Future<bool> changePriority(String messageId, MessagePriority newPriority);

  String calculateQueueHash({bool forceRecalculation = false});

  QueueSyncMessage createSyncMessage(String nodeId);

  bool needsSynchronization(String otherQueueHash);

  Future<void> addSyncedMessage(QueuedMessage message);

  List<String> getMissingMessageIds(List<String> otherMessageIds);

  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds);

  Future<void> markMessageDeleted(String messageId);

  bool isMessageDeleted(String messageId);

  Future<void> cleanupOldDeletedIds();

  void invalidateHashCache();

  Map<String, dynamic> getPerformanceStats();

  void dispose();
}
