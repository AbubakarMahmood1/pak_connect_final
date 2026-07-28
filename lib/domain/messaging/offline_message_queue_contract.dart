import 'dart:async';

import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

export 'package:pak_connect/domain/entities/queue_enums.dart';
export 'package:pak_connect/domain/entities/queue_statistics.dart';
export 'package:pak_connect/domain/entities/queued_message.dart';

/// Result of handing one queued message to the active transport route.
enum OfflineQueueSendDisposition {
  /// A direct-message transport observed the protocol delivery ACK.
  delivered,

  /// A relay hop accepted the payload and now needs the relay ACK timeout.
  awaitingAck,

  /// No eligible route exists yet. This must not consume a retry attempt.
  deferred,

  /// An eligible transport attempt was made and failed.
  failed,
}

typedef OfflineQueueSendCallback =
    FutureOr<OfflineQueueSendDisposition> Function(String messageId);

/// Eventual outcome of a transport attempt that was synchronously admitted.
///
/// `deferred` is deliberately absent: a prepared action must return `null`
/// synchronously when its exact route disappeared before launch. Once it
/// returns a future, the queue may safely receipt the durable admission.
enum OfflineQueuePreparedSendDisposition {
  delivered,
  awaitingAck,
  failed;

  OfflineQueueSendDisposition get asSendDisposition => switch (this) {
    delivered => OfflineQueueSendDisposition.delivered,
    awaitingAck => OfflineQueueSendDisposition.awaitingAck,
    failed => OfflineQueueSendDisposition.failed,
  };
}

/// A transport action that has already passed route and recipient preflight.
///
/// Creating this object must not start the transport. The queue first persists
/// the `sending` admission, then invokes [tryStart]. This lets queue-sync return
/// an exact durable-admission receipt without waiting for a delivery ACK.
class OfflineQueuePreparedSend {
  const OfflineQueuePreparedSend(this.tryStart);

  /// Starts the already-preflighted transport synchronously.
  ///
  /// `null` means the exact transport disappeared before admission and the
  /// queue must restore the pre-attempt state without receipting the ID. A
  /// non-null future means the transport accepted the attempt. Its eventual
  /// outcome cannot be `deferred`; only a synchronous `null` can decline the
  /// admission.
  final Future<OfflineQueuePreparedSendDisposition>? Function() tryStart;
}

typedef OfflineQueuePrepareSendCallback =
    FutureOr<OfflineQueuePreparedSend?> Function(String messageId);

/// Domain-facing contract for offline queue behavior.
///
/// Concrete implementations may live in other layers, but domain services
/// should depend on this abstraction.
abstract interface class OfflineMessageQueueContract {
  set onMessageQueued(Function(QueuedMessage message)? callback);

  set onMessageDelivered(Function(QueuedMessage message)? callback);

  set onMessageFailed(Function(QueuedMessage message, String reason)? callback);

  set onStatsUpdated(Function(QueueStatistics stats)? callback);

  set onSendMessage(OfflineQueueSendCallback? callback);

  set onConnectivityCheck(Function()? callback);

  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    OfflineQueueSendCallback? onSendMessage,
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

  /// Durably reset and re-drive one queued message.
  ///
  /// Returns false when the message is absent, disposed, or already being
  /// delivered. A true result means the retry was accepted, not that transport
  /// delivery succeeded.
  Future<bool> retryMessage(String messageId);

  Future<void> clearQueue();

  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status);

  QueuedMessage? getMessageById(String messageId);

  List<QueuedMessage> getPendingMessages();

  Future<void> removeMessage(String messageId);

  Future<void> flushQueueForPeer(String peerPublicKey);

  /// Attempt only the supplied, currently eligible queued messages.
  ///
  /// The returned IDs entered a real transport attempt. Missing, deferred,
  /// disposed, in-flight, and backoff-blocked messages are omitted.
  ///
  /// When [prepareSend] is supplied, each non-null prepared action is launched
  /// only after its `sending` state is durable. The receipt then returns without
  /// waiting for transport/ACK completion; outcome finalization continues in
  /// the queue's storage-only state machine.
  Future<Set<String>> attemptMessages(
    Iterable<String> messageIds, {
    OfflineQueuePrepareSendCallback? prepareSend,
  });

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
