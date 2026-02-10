import '../messaging/offline_message_queue.dart';
import '../models/mesh_relay_models.dart';

export '../messaging/offline_message_queue.dart'
    show QueuedMessage, QueueStatistics, QueuedMessageStatus;
export '../models/mesh_relay_models.dart' show QueueSyncMessage;
export '../../domain/entities/enhanced_message.dart' show MessagePriority;

/// Interface for comprehensive offline message queue management
/// Combines queue persistence, retry scheduling, and synchronization
abstract class IOfflineMessageQueue {
  // ===== INITIALIZATION =====

  /// Initialize the offline message queue with callbacks and dependencies
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
    Function()? onConnectivityCheck,
  });

  // ===== QUEUE MANAGEMENT =====

  /// Queue a message for offline delivery with retry handling
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const [],
  });

  /// Mark connection as online and attempt delivery
  Future<void> setOnline();

  /// Mark connection as offline and cancel active retries
  void setOffline();

  /// Mark message as successfully delivered
  void markMessageDelivered(String messageId);

  /// Mark message as failed with reason
  void markMessageFailed(String messageId, String reason);

  /// Get current queue statistics
  QueueStatistics getStatistics();

  /// Retry all failed messages
  Future<void> retryFailedMessages();

  /// Clear entire queue
  Future<void> clearQueue();

  /// Get messages by status
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status);

  /// Get message by ID
  QueuedMessage? getMessageById(String messageId);

  /// Get all pending messages
  List<QueuedMessage> getPendingMessages();

  /// Remove message from queue
  Future<void> removeMessage(String messageId);

  /// Flush queue for specific peer (send all pending messages)
  Future<void> flushQueueForPeer(String recipientPublicKey);

  /// Change message priority
  Future<bool> changePriority(String messageId, MessagePriority newPriority);

  // ===== SYNCHRONIZATION =====

  /// Calculate deterministic hash of queue state
  String calculateQueueHash({bool forceRecalculation = false});

  /// Create sync message for peer synchronization
  QueueSyncMessage createSyncMessage(String nodeId);

  /// Check if synchronization is needed with a peer
  bool needsSynchronization(String peerKey);

  /// Add synced message from peer
  void addSyncedMessage(QueuedMessage message);

  /// Get missing message IDs from peer sync
  List<String> getMissingMessageIds(List<String> peerMessageIds);

  /// Get excess messages not in peer sync
  List<QueuedMessage> getExcessMessages(List<String> peerMessageIds);

  // ===== DELETED MESSAGE TRACKING =====

  /// Mark message as deleted (for sync tracking)
  void markMessageDeleted(String messageId);

  /// Check if message is marked as deleted
  bool isMessageDeleted(String messageId);

  /// Clean up old deleted message IDs
  Future<void> cleanupOldDeletedIds();

  /// Invalidate hash cache
  void invalidateHashCache();

  // ===== STATISTICS & MAINTENANCE =====

  /// Get performance statistics
  Map<String, dynamic> getPerformanceStats();

  /// Dispose of resources
  void dispose();
}
