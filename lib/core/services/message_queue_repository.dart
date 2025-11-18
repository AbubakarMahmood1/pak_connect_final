import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../data/database/database_helper.dart';
import '../../domain/entities/enhanced_message.dart';
import '../interfaces/i_message_queue_repository.dart';
import '../messaging/offline_message_queue.dart';
import '../models/mesh_relay_models.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Repository for offline message queue database operations
///
/// Responsibility: CRUD operations for offline message queue storage
/// - Load/save queue to persistent storage
/// - Query messages by ID, status, or peer
/// - Manage message lifecycle (pending, sending, delivered, failed)
/// - Track retry attempts and delivery status
class MessageQueueRepository implements IMessageQueueRepository {
  static final _logger = Logger('MessageQueueRepository');

  // In-memory queues
  final List<QueuedMessage> directMessageQueue;
  final List<QueuedMessage> relayMessageQueue;
  final Set<String> deletedMessageIds;

  MessageQueueRepository({
    List<QueuedMessage>? directMessageQueue,
    List<QueuedMessage>? relayMessageQueue,
    Set<String>? deletedMessageIds,
  }) : directMessageQueue = directMessageQueue ?? [],
       relayMessageQueue = relayMessageQueue ?? [],
       deletedMessageIds = deletedMessageIds ?? {};

  /// Load entire queue from persistent storage
  @override
  Future<void> loadQueueFromStorage() async {
    try {
      final db = await DatabaseHelper.database;
      final List<Map<String, dynamic>> results = await db.query(
        'offline_message_queue',
        orderBy: 'priority DESC, queued_at ASC',
      );

      // Load into appropriate queue based on isRelayMessage flag
      directMessageQueue.clear();
      relayMessageQueue.clear();

      for (final row in results) {
        try {
          final message = queuedMessageFromDb(row);
          if (message.isRelayMessage) {
            relayMessageQueue.add(message);
          } else {
            directMessageQueue.add(message);
          }
        } catch (e) {
          _logger.warning('Failed to parse queued message: $e');
        }
      }

      final totalLoaded = directMessageQueue.length + relayMessageQueue.length;
      _logger.info(
        'Loaded $totalLoaded messages from storage (direct: ${directMessageQueue.length}, relay: ${relayMessageQueue.length})',
      );
    } catch (e) {
      _logger.severe('Failed to load message queue: $e');
    }
  }

  /// Save a single message to persistent storage (optimized for individual updates)
  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    try {
      final db = await DatabaseHelper.database;

      // Use INSERT OR REPLACE for efficiency - updates if exists, inserts if not
      await db.insert(
        'offline_message_queue',
        queuedMessageToDb(message),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      _logger.warning('Failed to save message ${message.id.shortId()}...: $e');
    }
  }

  /// Delete a single message from persistent storage
  @override
  Future<void> deleteMessageFromStorage(String messageId) async {
    try {
      final db = await DatabaseHelper.database;

      await db.delete(
        'offline_message_queue',
        where: 'message_id = ?',
        whereArgs: [messageId],
      );
    } catch (e) {
      _logger.warning('Failed to delete message ${messageId.shortId()}...: $e');
    }
  }

  /// Save entire queue to persistent storage
  @override
  Future<void> saveQueueToStorage() async {
    try {
      final db = await DatabaseHelper.database;

      // Use transaction for atomic operations
      await db.transaction((txn) async {
        // Clear and reinsert all messages
        await txn.delete('offline_message_queue');

        // Save direct messages
        for (final message in directMessageQueue) {
          await txn.insert('offline_message_queue', queuedMessageToDb(message));
        }

        // Save relay messages
        for (final message in relayMessageQueue) {
          await txn.insert('offline_message_queue', queuedMessageToDb(message));
        }
      });
    } catch (e) {
      _logger.warning('Failed to save message queue: $e');
    }
  }

  /// Load deleted message IDs from persistent storage
  @override
  Future<void> loadDeletedMessageIds() async {
    try {
      final db = await DatabaseHelper.database;
      final List<Map<String, dynamic>> results = await db.query(
        'deleted_message_ids',
      );

      deletedMessageIds.clear();
      for (final row in results) {
        deletedMessageIds.add(row['message_id'] as String);
      }

      _logger.info('Loaded ${deletedMessageIds.length} deleted message IDs');
    } catch (e) {
      _logger.severe('Failed to load deleted message IDs: $e');
    }
  }

  /// Save deleted message IDs to persistent storage
  @override
  Future<void> saveDeletedMessageIds() async {
    try {
      final db = await DatabaseHelper.database;

      await db.transaction((txn) async {
        // Clear and reinsert all deleted IDs
        await txn.delete('deleted_message_ids');

        for (final messageId in deletedMessageIds) {
          await txn.insert('deleted_message_ids', {
            'message_id': messageId,
            'deleted_at': DateTime.now().millisecondsSinceEpoch,
          });
        }
      });
    } catch (e) {
      _logger.warning('Failed to save deleted message IDs: $e');
    }
  }

  /// Get message by ID
  @override
  QueuedMessage? getMessageById(String messageId) {
    return getAllMessages()
        .where((m) => m.id == messageId)
        .cast<QueuedMessage?>()
        .firstWhere((m) => m != null, orElse: () => null);
  }

  /// Get messages by status
  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return getAllMessages().where((m) => m.status == status).toList();
  }

  /// Get all pending messages
  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  /// Remove message from queue by ID
  @override
  Future<void> removeMessage(String messageId) async {
    removeMessageFromQueue(messageId);
    await deleteMessageFromStorage(messageId);
  }

  /// Get oldest pending message
  @override
  QueuedMessage? getOldestPendingMessage() {
    final pending = getAllMessages()
        .where((m) => m.status == QueuedMessageStatus.pending)
        .toList();

    if (pending.isEmpty) return null;

    pending.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return pending.first;
  }

  /// Get all messages from both queues
  @override
  List<QueuedMessage> getAllMessages() {
    return [...directMessageQueue, ...relayMessageQueue];
  }

  /// Insert message into queue by priority
  @override
  void insertMessageByPriority(QueuedMessage message) {
    // Determine target queue
    final targetQueue = message.isRelayMessage
        ? relayMessageQueue
        : directMessageQueue;

    // Find insertion point based on priority
    int insertIndex = 0;
    for (int i = 0; i < targetQueue.length; i++) {
      if (targetQueue[i].priority.index <= message.priority.index) {
        insertIndex = i;
        break;
      }
      insertIndex = i + 1;
    }

    targetQueue.insert(insertIndex, message);

    _logger.fine(
      'Inserted into ${message.isRelayMessage ? "relay" : "direct"} queue at index $insertIndex (queue size: ${targetQueue.length})',
    );
  }

  /// Remove message from queue
  @override
  void removeMessageFromQueue(String messageId) {
    directMessageQueue.removeWhere((m) => m.id == messageId);
    relayMessageQueue.removeWhere((m) => m.id == messageId);
  }

  /// Check if message was previously deleted
  @override
  bool isMessageDeleted(String messageId) {
    return deletedMessageIds.contains(messageId);
  }

  /// Mark message as deleted for sync purposes
  @override
  Future<void> markMessageDeleted(String messageId) async {
    deletedMessageIds.add(messageId);
    await saveDeletedMessageIds();

    // Remove from active queue if present
    removeMessageFromQueue(messageId);
    await saveQueueToStorage();

    _logger.info(
      'Message marked as deleted: ${messageId.length > 16 ? "${messageId.shortId()}..." : messageId}',
    );
  }

  /// Convert QueuedMessage to database row
  @override
  Map<String, dynamic> queuedMessageToDb(QueuedMessage message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'queue_id': message.id,
      'message_id': message.id,
      'chat_id': message.chatId,
      'content': message.content,
      'recipient_public_key': message.recipientPublicKey,
      'sender_public_key': message.senderPublicKey,
      'queued_at': message.queuedAt.millisecondsSinceEpoch,
      'retry_count': message.attempts,
      'max_retries': message.maxRetries,
      'next_retry_at': message.nextRetryAt?.millisecondsSinceEpoch,
      'priority': message.priority.index,
      'status': message.status.index,
      'attempts': message.attempts,
      'last_attempt_at': message.lastAttemptAt?.millisecondsSinceEpoch,
      'delivered_at': message.deliveredAt?.millisecondsSinceEpoch,
      'failed_at': message.failedAt?.millisecondsSinceEpoch,
      'failure_reason': message.failureReason,
      'expires_at': message.expiresAt?.millisecondsSinceEpoch,
      'is_relay_message': message.isRelayMessage ? 1 : 0,
      'original_message_id': message.originalMessageId,
      'relay_node_id': message.relayNodeId,
      'message_hash': message.messageHash,
      'relay_metadata_json': message.relayMetadata != null
          ? jsonEncode(message.relayMetadata!.toJson())
          : null,
      'reply_to_message_id': message.replyToMessageId,
      'attachments_json': message.attachments.isNotEmpty
          ? jsonEncode(message.attachments)
          : null,
      'sender_rate_count': message.senderRateCount,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Convert database row to QueuedMessage
  @override
  QueuedMessage queuedMessageFromDb(Map<String, dynamic> row) {
    return QueuedMessage(
      id: row['message_id'] as String,
      chatId: row['chat_id'] as String,
      content: row['content'] as String,
      recipientPublicKey: row['recipient_public_key'] as String,
      senderPublicKey: row['sender_public_key'] as String,
      priority: MessagePriority.values[row['priority'] as int],
      queuedAt: DateTime.fromMillisecondsSinceEpoch(row['queued_at'] as int),
      maxRetries: row['max_retries'] as int,
      replyToMessageId: row['reply_to_message_id'] as String?,
      attachments: row['attachments_json'] != null
          ? List<String>.from(jsonDecode(row['attachments_json'] as String))
          : [],
      status: QueuedMessageStatus.values[row['status'] as int],
      attempts: row['attempts'] as int,
      lastAttemptAt: row['last_attempt_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['last_attempt_at'] as int)
          : null,
      nextRetryAt: row['next_retry_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['next_retry_at'] as int)
          : null,
      deliveredAt: row['delivered_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['delivered_at'] as int)
          : null,
      failedAt: row['failed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['failed_at'] as int)
          : null,
      failureReason: row['failure_reason'] as String?,
      expiresAt: row['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int)
          : null,
      isRelayMessage: (row['is_relay_message'] as int) == 1,
      relayMetadata: row['relay_metadata_json'] != null
          ? RelayMetadata.fromJson(
              jsonDecode(row['relay_metadata_json'] as String),
            )
          : null,
      originalMessageId: row['original_message_id'] as String?,
      relayNodeId: row['relay_node_id'] as String?,
      messageHash: row['message_hash'] as String?,
      senderRateCount: row['sender_rate_count'] as int? ?? 0,
    );
  }
}
