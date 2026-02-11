import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';

/// Interface for message queue database operations.
///
/// Responsibility: CRUD operations for offline message queue storage.
abstract class IMessageQueueRepository {
  /// Load entire queue from persistent storage.
  Future<void> loadQueueFromStorage();

  /// Save a single message to persistent storage.
  Future<void> saveMessageToStorage(QueuedMessage message);

  /// Delete a single message from persistent storage.
  Future<void> deleteMessageFromStorage(String messageId);

  /// Save entire queue to persistent storage.
  Future<void> saveQueueToStorage();

  /// Load deleted message IDs from persistent storage.
  Future<void> loadDeletedMessageIds();

  /// Save deleted message IDs to persistent storage.
  Future<void> saveDeletedMessageIds();

  /// Get message by ID.
  QueuedMessage? getMessageById(String messageId);

  /// Get messages by status.
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status);

  /// Get all pending messages.
  List<QueuedMessage> getPendingMessages();

  /// Remove message from queue by ID.
  Future<void> removeMessage(String messageId);

  /// Get oldest pending message.
  QueuedMessage? getOldestPendingMessage();

  /// Get all messages from both queues.
  List<QueuedMessage> getAllMessages();

  /// Insert message into queue by priority.
  void insertMessageByPriority(QueuedMessage message);

  /// Remove message from queue.
  void removeMessageFromQueue(String messageId);

  /// Check if message was previously deleted.
  bool isMessageDeleted(String messageId);

  /// Mark message as deleted for sync purposes.
  Future<void> markMessageDeleted(String messageId);

  /// Convert QueuedMessage to database row format.
  Map<String, dynamic> queuedMessageToDb(QueuedMessage message);

  /// Convert database row to QueuedMessage.
  QueuedMessage queuedMessageFromDb(Map<String, dynamic> row);
}
