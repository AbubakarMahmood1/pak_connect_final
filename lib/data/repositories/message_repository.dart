import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../database/database_helper.dart';
import '../../core/compression/compression_util.dart';
import '../../core/utils/chat_utils.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../core/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class MessageRepository implements IMessageRepository {
  static final _logger = Logger('MessageRepository');

  /// Get all messages for a specific chat, sorted by timestamp
  Future<List<Message>> getMessages(ChatId chatId) async {
    try {
      final db = await DatabaseHelper.database;

      final results = await db.query(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [chatId.value],
        orderBy: 'timestamp ASC',
      );

      return results.map(_fromDatabase).toList();
    } catch (e) {
      _logger.severe('❌ Failed to get messages for chat $chatId: $e');
      return [];
    }
  }

  /// Get a single message by ID (for duplicate checking)
  Future<Message?> getMessageById(MessageId messageId) async {
    try {
      final db = await DatabaseHelper.database;

      final results = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId.value],
        limit: 1,
      );

      if (results.isEmpty) {
        return null;
      }

      return _fromDatabase(results.first);
    } catch (e) {
      _logger.severe('❌ Failed to get message by ID ${messageId.value}: $e');
      return null;
    }
  }

  /// Save a new message (with duplicate prevention)
  Future<void> saveMessage(Message message) async {
    try {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // ✅ Ensure chat exists before saving message (lazy creation)
      await _ensureChatExists(db, message.chatId, now);

      // 🔧 FIX: Use INSERT OR IGNORE to prevent duplicate messages
      // If a message with the same ID already exists, this will silently skip the insert
      final insertedId = await db.insert(
        'messages',
        _toDatabase(message, now, now),
        conflictAlgorithm: ConflictAlgorithm.ignore, // Prevent duplicates
      );

      // If the insert was ignored (duplicate), perform an update so status changes persist.
      if (insertedId == 0) {
        await updateMessage(message);
      }

      _logger.info(
        '💾 Saved message ${message.id.value} to chat ${message.chatId.value} '
        '(fromMe=${message.isFromMe}, status=${message.status})',
      );
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
        whereArgs: [message.id.value],
        limit: 1,
      );

      final createdAt = existing.isNotEmpty
          ? existing.first['created_at'] as int
          : now;

      await db.update(
        'messages',
        _toDatabase(message, createdAt, now),
        where: 'id = ?',
        whereArgs: [message.id.value],
      );

      _logger.fine('✅ Updated message ${message.id.value}');
    } catch (e) {
      _logger.severe('❌ Failed to update message: $e');
      rethrow;
    }
  }

  /// Clear all messages for a specific chat
  Future<void> clearMessages(ChatId chatId) async {
    try {
      final db = await DatabaseHelper.database;

      await db.delete(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [chatId.value],
      );

      _logger.info('✅ Cleared messages for chat ${chatId.value}');
    } catch (e) {
      _logger.severe('❌ Failed to clear messages: $e');
      rethrow;
    }
  }

  /// Delete a specific message by ID
  Future<bool> deleteMessage(MessageId messageId) async {
    try {
      final db = await DatabaseHelper.database;

      final rowsDeleted = await db.delete(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId.value],
      );

      final wasDeleted = rowsDeleted > 0;
      if (wasDeleted) {
        _logger.fine('✅ Deleted message ${messageId.value}');
      } else {
        _logger.warning('⚠️ Message ${messageId.value} not found');
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

      final results = await db.query('messages', orderBy: 'timestamp ASC');

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
      _logger.severe(
        '❌ Failed to get messages for contact ${publicKey.shortId(8)}...: $e',
      );
      return [];
    }
  }

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {
    try {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Ensure the new chat exists before migration
      await _ensureChatExists(db, newChatId, now);

      // Atomic update of all messages
      final count = await db.update(
        'messages',
        {'chat_id': newChatId.value, 'updated_at': now},
        where: 'chat_id = ?',
        whereArgs: [oldChatId.value],
      );

      // Clean up old chat entry (optional, but keeps DB clean)
      await db.delete(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [oldChatId.value],
      );

      _logger.info(
        '✅ Migrated $count messages from ${oldChatId.value} to ${newChatId.value}',
      );
    } catch (e) {
      _logger.severe('❌ Failed to migrate chat ID: $e');
      rethrow;
    }
  }

  // ========================================
  // PRIVATE HELPER METHODS
  // ========================================

  /// Ensure chat entry exists before saving message (lazy creation)
  /// This prevents foreign key constraint violations while keeping ChatsScreen clean
  Future<void> _ensureChatExists(
    Database db,
    ChatId chatId,
    int timestamp,
  ) async {
    // Check if chat already exists
    final existing = await db.query(
      'chats',
      columns: ['chat_id'],
      where: 'chat_id = ?',
      whereArgs: [chatId.value],
      limit: 1,
    );

    if (existing.isEmpty) {
      // Create chat entry on first message
      // ChatsScreen filters by messages, so empty chats won't appear
      String? contactPublicKey;
      String contactName = 'Unknown';

      // Extract contact info from chat_id
      // 🔥 FIX: Use ChatUtils.extractContactKey() to handle all formats robustly
      // Note: We don't have myPublicKey here, so pass empty string for test compatibility
      // The helper handles this case by returning the first key
      contactPublicKey = ChatUtils.extractContactKey(chatId.value, '');

      if (chatId.value.startsWith('persistent_chat_')) {
        contactName = 'Chat ${chatId.value.shortId(20)}...';
      } else if (chatId.value.startsWith('temp_')) {
        contactName = 'Device ${chatId.value.substring(5, 20)}...';
      }

      if (contactPublicKey != null) {
        final contactExists = await db.query(
          'contacts',
          columns: ['public_key'],
          where: 'public_key = ?',
          whereArgs: [contactPublicKey],
          limit: 1,
        );

        if (contactExists.isEmpty) {
          contactPublicKey = null;
        }
      }

      await db.insert(
        'chats',
        {
          'chat_id': chatId.value,
          'contact_public_key': contactPublicKey,
          'contact_name': contactName,
          'unread_count': 0,
          'is_archived': 0,
          'is_muted': 0,
          'is_pinned': 0,
          'created_at': timestamp,
          'updated_at': timestamp,
        },
        conflictAlgorithm:
            ConflictAlgorithm.ignore, // Prevent duplicates if concurrent
      );

      _logger.info('✅ Created chat entry for: ${chatId.value}');
    }
  }

  /// Convert database row to Message/EnhancedMessage
  Message _fromDatabase(Map<String, dynamic> row) {
    // Check if this is an EnhancedMessage by looking for enhanced fields
    final bool hasEnhancedFields =
        row['reply_to_message_id'] != null ||
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
        id: MessageId(row['id'] as String),
        chatId: ChatId(row['chat_id'] as String),
        content: row['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
        isFromMe: (row['is_from_me'] as int) == 1,
        status: MessageStatus.values[row['status'] as int],
      );
    }

    // Return EnhancedMessage
    return EnhancedMessage(
      id: MessageId(row['id'] as String),
      chatId: ChatId(row['chat_id'] as String),
      content: row['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      isFromMe: (row['is_from_me'] as int) == 1,
      status: MessageStatus.values[row['status'] as int],
      replyToMessageId: row['reply_to_message_id'] != null
          ? MessageId(row['reply_to_message_id'] as String)
          : null,
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
      'id': message.id.value,
      'chat_id': message.chatId.value,
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
        'reply_to_message_id': message.replyToMessageId?.value,
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

  /// Encode object to JSON string with optional compression
  String? _encodeJson(dynamic obj) {
    if (obj == null) return null;
    try {
      final jsonString = jsonEncode(obj);

      // Try to compress if beneficial (using default config)
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonString));
      final compressionResult = CompressionUtil.compress(jsonBytes);

      if (compressionResult != null) {
        // Compression was beneficial - store as base64 with marker
        final compressedBase64 = base64Encode(compressionResult.compressed);
        return 'COMPRESSED:$compressedBase64';
      }

      // Compression not beneficial - store uncompressed
      return jsonString;
    } catch (e) {
      _logger.warning('⚠️ Failed to encode JSON: $e');
      return null;
    }
  }

  /// Encode list to JSON string with optional compression
  String? _encodeJsonList(List<dynamic>? list) {
    if (list == null || list.isEmpty) return null;
    try {
      final jsonString = jsonEncode(list);

      // Try to compress if beneficial
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonString));
      final compressionResult = CompressionUtil.compress(jsonBytes);

      if (compressionResult != null) {
        // Compression was beneficial - store as base64 with marker
        final compressedBase64 = base64Encode(compressionResult.compressed);
        return 'COMPRESSED:$compressedBase64';
      }

      // Compression not beneficial - store uncompressed
      return jsonString;
    } catch (e) {
      _logger.warning('⚠️ Failed to encode JSON list: $e');
      return null;
    }
  }

  /// Decode JSON string to object (with automatic decompression)
  T? _decodeJson<T>(
    dynamic jsonString, [
    T Function(Map<String, dynamic>)? fromJson,
  ]) {
    if (jsonString == null) return null;
    if (jsonString is! String) return null;
    if (jsonString.isEmpty) return null;

    try {
      String actualJsonString = jsonString;

      // Check if data is compressed
      if (jsonString.startsWith('COMPRESSED:')) {
        // Extract and decompress
        final compressedBase64 = jsonString.substring('COMPRESSED:'.length);
        final compressedBytes = base64Decode(compressedBase64);
        final decompressed = CompressionUtil.decompress(
          Uint8List.fromList(compressedBytes),
        );

        if (decompressed == null) {
          _logger.warning('⚠️ Failed to decompress JSON data');
          return null;
        }

        actualJsonString = utf8.decode(decompressed);
      }

      final decoded = jsonDecode(actualJsonString);
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

  /// Decode JSON string to list of objects (with automatic decompression)
  List<T> _decodeJsonList<T>(
    dynamic jsonString,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (jsonString == null) return [];
    if (jsonString is! String) return [];
    if (jsonString.isEmpty) return [];

    try {
      String actualJsonString = jsonString;

      // Check if data is compressed
      if (jsonString.startsWith('COMPRESSED:')) {
        // Extract and decompress
        final compressedBase64 = jsonString.substring('COMPRESSED:'.length);
        final compressedBytes = base64Decode(compressedBase64);
        final decompressed = CompressionUtil.decompress(
          Uint8List.fromList(compressedBytes),
        );

        if (decompressed == null) {
          _logger.warning('⚠️ Failed to decompress JSON list data');
          return [];
        }

        actualJsonString = utf8.decode(decompressed);
      }

      final decoded = jsonDecode(actualJsonString);
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
