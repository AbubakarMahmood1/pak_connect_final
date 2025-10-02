import 'dart:convert';
import 'package:logging/logging.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../database/database_helper.dart';

class MessageRepository {
  static final _logger = Logger('MessageRepository');

  /// Get all messages for a specific chat, sorted by timestamp
  Future<List<Message>> getMessages(String chatId) async {
    try {
      final db = await DatabaseHelper.database;

      final results = await db.query(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [chatId],
        orderBy: 'timestamp ASC',
      );

      return results.map(_fromDatabase).toList();
    } catch (e) {
      _logger.severe('❌ Failed to get messages for chat $chatId: $e');
      return [];
    }
  }

  /// Save a new message
  Future<void> saveMessage(Message message) async {
    try {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert(
        'messages',
        _toDatabase(message, now, now),
      );

      _logger.fine('✅ Saved message ${message.id}');
    } catch (e) {
      _logger.severe('❌ Failed to save message: $e');
      rethrow;
    }
  }

  /// Update an existing message
  Future<void> updateMessage(Message message) async {
    try {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Get the original created_at timestamp
      final existing = await db.query(
        'messages',
        columns: ['created_at'],
        where: 'id = ?',
        whereArgs: [message.id],
        limit: 1,
      );

      final createdAt = existing.isNotEmpty
          ? existing.first['created_at'] as int
          : now;

      await db.update(
        'messages',
        _toDatabase(message, createdAt, now),
        where: 'id = ?',
        whereArgs: [message.id],
      );

      _logger.fine('✅ Updated message ${message.id}');
    } catch (e) {
      _logger.severe('❌ Failed to update message: $e');
      rethrow;
    }
  }

  /// Clear all messages for a specific chat
  Future<void> clearMessages(String chatId) async {
    try {
      final db = await DatabaseHelper.database;

      await db.delete(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );

      _logger.info('✅ Cleared messages for chat $chatId');
    } catch (e) {
      _logger.severe('❌ Failed to clear messages: $e');
      rethrow;
    }
  }

  /// Delete a specific message by ID
  Future<bool> deleteMessage(String messageId) async {
    try {
      final db = await DatabaseHelper.database;

      final rowsDeleted = await db.delete(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
      );

      final wasDeleted = rowsDeleted > 0;
      if (wasDeleted) {
        _logger.fine('✅ Deleted message $messageId');
      } else {
        _logger.warning('⚠️ Message $messageId not found');
      }

      return wasDeleted;
    } catch (e) {
      _logger.severe('❌ Failed to delete message: $e');
      return false;
    }
  }

  /// Get all messages for interaction calculations
  Future<List<Message>> getAllMessages() async {
    try {
      final db = await DatabaseHelper.database;

      final results = await db.query(
        'messages',
        orderBy: 'timestamp ASC',
      );

      return results.map(_fromDatabase).toList();
    } catch (e) {
      _logger.severe('❌ Failed to get all messages: $e');
      return [];
    }
  }

  /// Get messages for a specific contact (by public key/chat ID)
  Future<List<Message>> getMessagesForContact(String publicKey) async {
    try {
      final db = await DatabaseHelper.database;

      final results = await db.query(
        'messages',
        where: 'chat_id = ? OR chat_id LIKE ?',
        whereArgs: [publicKey, '%$publicKey%'],
        orderBy: 'timestamp ASC',
      );

      return results.map(_fromDatabase).toList();
    } catch (e) {
      _logger.severe('❌ Failed to get messages for contact $publicKey: $e');
      return [];
    }
  }

  // ========================================
  // PRIVATE HELPER METHODS
  // ========================================

  /// Convert database row to Message/EnhancedMessage
  Message _fromDatabase(Map<String, dynamic> row) {
    // Check if this is an EnhancedMessage by looking for enhanced fields
    final bool hasEnhancedFields = row['reply_to_message_id'] != null ||
        row['thread_id'] != null ||
        row['is_starred'] == 1 ||
        row['is_forwarded'] == 1 ||
        row['edited_at'] != null ||
        row['metadata_json'] != null ||
        row['delivery_receipt_json'] != null ||
        row['read_receipt_json'] != null ||
        row['reactions_json'] != null ||
        row['attachments_json'] != null ||
        row['encryption_info_json'] != null;

    if (!hasEnhancedFields) {
      // Return base Message
      return Message(
        id: row['id'] as String,
        chatId: row['chat_id'] as String,
        content: row['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
        isFromMe: (row['is_from_me'] as int) == 1,
        status: MessageStatus.values[row['status'] as int],
      );
    }

    // Return EnhancedMessage
    return EnhancedMessage(
      id: row['id'] as String,
      chatId: row['chat_id'] as String,
      content: row['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      isFromMe: (row['is_from_me'] as int) == 1,
      status: MessageStatus.values[row['status'] as int],
      replyToMessageId: row['reply_to_message_id'] as String?,
      threadId: row['thread_id'] as String?,
      isStarred: (row['is_starred'] as int?) == 1,
      isForwarded: (row['is_forwarded'] as int?) == 1,
      priority: MessagePriority.values[row['priority'] as int? ?? 1],
      editedAt: row['edited_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['edited_at'] as int)
          : null,
      originalContent: row['original_content'] as String?,
      metadata: _decodeJson(row['metadata_json']),
      deliveryReceipt: _decodeJson<MessageDeliveryReceipt>(
        row['delivery_receipt_json'],
        (json) => MessageDeliveryReceipt.fromJson(json),
      ),
      readReceipt: _decodeJson<MessageReadReceipt>(
        row['read_receipt_json'],
        (json) => MessageReadReceipt.fromJson(json),
      ),
      reactions: _decodeJsonList<MessageReaction>(
        row['reactions_json'],
        (json) => MessageReaction.fromJson(json),
      ),
      attachments: _decodeJsonList<MessageAttachment>(
        row['attachments_json'],
        (json) => MessageAttachment.fromJson(json),
      ),
      encryptionInfo: _decodeJson<MessageEncryptionInfo>(
        row['encryption_info_json'],
        (json) => MessageEncryptionInfo.fromJson(json),
      ),
    );
  }

  /// Convert Message/EnhancedMessage to database row
  Map<String, Object?> _toDatabase(
    Message message,
    int createdAt,
    int updatedAt,
  ) {
    final Map<String, Object?> baseData = {
      'id': message.id,
      'chat_id': message.chatId,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'is_from_me': message.isFromMe ? 1 : 0,
      'status': message.status.index,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };

    // If this is an EnhancedMessage, add enhanced fields
    if (message is EnhancedMessage) {
      baseData.addAll(<String, Object?>{
        'reply_to_message_id': message.replyToMessageId,
        'thread_id': message.threadId,
        'is_starred': message.isStarred ? 1 : 0,
        'is_forwarded': message.isForwarded ? 1 : 0,
        'priority': message.priority.index,
        'edited_at': message.editedAt?.millisecondsSinceEpoch,
        'original_content': message.originalContent,
        'has_media': message.attachments.isNotEmpty ? 1 : 0,
        'media_type': message.attachments.isNotEmpty
            ? message.attachments.first.type
            : null,
        'metadata_json': _encodeJson(message.metadata),
        'delivery_receipt_json': _encodeJson(message.deliveryReceipt?.toJson()),
        'read_receipt_json': _encodeJson(message.readReceipt?.toJson()),
        'reactions_json': _encodeJsonList(
          message.reactions.map((r) => r.toJson()).toList(),
        ),
        'attachments_json': _encodeJsonList(
          message.attachments.map((a) => a.toJson()).toList(),
        ),
        'encryption_info_json': _encodeJson(message.encryptionInfo?.toJson()),
      });
    } else {
      // Set enhanced fields to null for base Message
      baseData.addAll(<String, Object?>{
        'reply_to_message_id': null,
        'thread_id': null,
        'is_starred': 0,
        'is_forwarded': 0,
        'priority': 1,
        'edited_at': null,
        'original_content': null,
        'has_media': 0,
        'media_type': null,
        'metadata_json': null,
        'delivery_receipt_json': null,
        'read_receipt_json': null,
        'reactions_json': null,
        'attachments_json': null,
        'encryption_info_json': null,
      });
    }

    return baseData;
  }

  /// Encode object to JSON string
  String? _encodeJson(dynamic obj) {
    if (obj == null) return null;
    try {
      return jsonEncode(obj);
    } catch (e) {
      _logger.warning('⚠️ Failed to encode JSON: $e');
      return null;
    }
  }

  /// Encode list to JSON string
  String? _encodeJsonList(List<dynamic>? list) {
    if (list == null || list.isEmpty) return null;
    try {
      return jsonEncode(list);
    } catch (e) {
      _logger.warning('⚠️ Failed to encode JSON list: $e');
      return null;
    }
  }

  /// Decode JSON string to object
  T? _decodeJson<T>(dynamic jsonString, [T Function(Map<String, dynamic>)? fromJson]) {
    if (jsonString == null) return null;
    if (jsonString is! String) return null;
    if (jsonString.isEmpty) return null;

    try {
      final decoded = jsonDecode(jsonString);
      if (decoded == null) return null;

      if (fromJson != null && decoded is Map<String, dynamic>) {
        return fromJson(decoded);
      }

      return decoded as T?;
    } catch (e) {
      _logger.warning('⚠️ Failed to decode JSON: $e');
      return null;
    }
  }

  /// Decode JSON string to list of objects
  List<T> _decodeJsonList<T>(
    dynamic jsonString,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (jsonString == null) return [];
    if (jsonString is! String) return [];
    if (jsonString.isEmpty) return [];

    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! List) return [];

      return decoded
          .map((item) => fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _logger.warning('⚠️ Failed to decode JSON list: $e');
      return [];
    }
  }
}
