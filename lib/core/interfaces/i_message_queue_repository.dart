import '../messaging/offline_message_queue.dart';

/// Interface for message queue database operations
///
/// Responsibility: CRUD operations for offline message queue storage
/// - Load/save queue to persistent storage
/// - Query messages by ID, status, or peer
/// - Manage message lifecycle (pending, sending, delivered, failed)
/// - Track retry attempts and delivery status
abstract class IMessageQueueRepository {
  /// Load entire queue from persistent storage
  ///
  /// Returns list of QueuedMessage objects loaded from database.
  /// Handles both direct and relay messages.
  Future<void> loadQueueFromStorage();

  /// Save a single message to persistent storage (optimized for individual updates)
  ///
  /// Uses INSERT OR REPLACE for efficiency - updates if exists, inserts if not.
  /// Invalidates hash cache after save.
  Future<void> saveMessageToStorage(QueuedMessage message);

  /// Delete a single message from persistent storage
  ///
  /// Removes message with given ID from database.
  /// Invalidates hash cache after deletion.
  Future<void> deleteMessageFromStorage(String messageId);

  /// Save entire queue to persistent storage
  ///
  /// Used for bulk operations and queue initialization.
  /// Wraps in transaction for atomicity.
  /// Handles both direct and relay message queues.
  Future<void> saveQueueToStorage();

  /// Load deleted message IDs from persistent storage
  ///
  /// Maintains set of deleted message IDs for synchronization tracking.
  /// Prevents re-adding messages that were previously deleted.
  Future<void> loadDeletedMessageIds();

  /// Save deleted message IDs to persistent storage
  ///
  /// Persists deleted message tracking for queue synchronization.
  /// Wrapped in transaction for atomicity.
  Future<void> saveDeletedMessageIds();

  /// Get message by ID
  ///
  /// Returns message if found in either direct or relay queue, null otherwise.
  QueuedMessage? getMessageById(String messageId);

  /// Get messages by status
  ///
  /// Returns all messages with specified status from both queues.
  /// Useful for finding pending, sending, retrying, failed messages.
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status);

  /// Get all pending messages
  ///
  /// Convenience method - equivalent to getMessagesByStatus(pending).
  List<QueuedMessage> getPendingMessages();

  /// Remove message from queue by ID
  ///
  /// Cancels any associated retry timers and removes from database.
  Future<void> removeMessage(String messageId);

  /// Get oldest pending message
  ///
  /// Used for scheduling - returns message with earliest queuedAt timestamp
  /// among pending messages.
  QueuedMessage? getOldestPendingMessage();

  /// Get all messages from both queues
  ///
  /// Helper method combining direct and relay message queues.
  /// Used internally for aggregated queries.
  List<QueuedMessage> getAllMessages();

  /// Insert message into queue by priority
  ///
  /// Determines target queue (direct or relay) and finds insertion point.
  /// Maintains priority ordering: urgent > high > normal > low.
  void insertMessageByPriority(QueuedMessage message);

  /// Remove message from queue
  ///
  /// Removes from both direct and relay queues.
  /// Used internally after delivery or failure.
  void removeMessageFromQueue(String messageId);

  /// Check if message was previously deleted
  ///
  /// Used for synchronization - prevents re-adding deleted messages
  /// from peer devices.
  bool isMessageDeleted(String messageId);

  /// Mark message as deleted for sync purposes
  ///
  /// Adds to deleted IDs set and removes from active queue.
  /// Persists to storage.
  Future<void> markMessageDeleted(String messageId);

  /// Convert QueuedMessage to database row format
  ///
  /// Internal helper for persistence layer.
  /// Handles serialization of message fields and nested objects.
  Map<String, dynamic> queuedMessageToDb(QueuedMessage message);

  /// Convert database row to QueuedMessage
  ///
  /// Internal helper for persistence layer.
  /// Handles deserialization of message fields and nested objects.
  QueuedMessage queuedMessageFromDb(Map<String, dynamic> row);
}
