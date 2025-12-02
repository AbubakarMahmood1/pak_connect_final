import 'package:logging/logging.dart';
import '../../domain/entities/message.dart';
import '../../core/utils/chat_utils.dart';
import '../repositories/message_repository.dart';
import '../database/database_helper.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Service responsible for migrating chats from ephemeral IDs to persistent public keys
///
/// This service is used during the pairing process when:
/// 1. Two devices exchange persistent public keys after PIN verification
/// 2. Messages were sent using ephemeral (temporary) IDs
/// 3. Chat history needs to be migrated to use persistent IDs
class ChatMigrationService {
  static final _logger = Logger('ChatMigrationService');

  final MessageRepository _messageRepository = MessageRepository();

  /// Migrate a chat from ephemeral ID to persistent public key
  ///
  /// This method:
  /// 1. Checks if there are messages in the old ephemeral chat
  /// 2. Generates the new persistent chat ID
  /// 3. Copies all messages to the new chat ID
  /// 4. Updates chat metadata (contact info, last message, etc.)
  /// 5. Deletes the old ephemeral chat
  ///
  /// Parameters:
  /// - [ephemeralId]: The temporary ID used before pairing (e.g., 'temp_abc123')
  /// - [persistentPublicKey]: The other party's persistent public key
  /// - [contactName]: Optional contact name to use
  ///
  /// Returns: True if migration was successful, false if no migration was needed
  Future<bool> migrateChatToPersistentId({
    required String ephemeralId,
    required String persistentPublicKey,
    String? contactName,
  }) async {
    try {
      _logger.info('🔄 STEP 6: Starting chat migration');
      _logger.info(
        '   From ephemeral ID: ${ephemeralId.length > 20 ? ephemeralId.shortId(20) : ephemeralId}...',
      );
      _logger.info(
        '   To persistent key: ${persistentPublicKey.length > 20 ? persistentPublicKey.shortId(20) : persistentPublicKey}...',
      );

      // Get messages from ephemeral chat
      final messages = await _messageRepository.getMessages(
        ChatId(ephemeralId),
      );

      if (messages.isEmpty) {
        _logger.info('✅ STEP 6: No messages to migrate - chat is empty');
        return false;
      }

      _logger.info('📦 STEP 6: Found ${messages.length} messages to migrate');

      // Generate new persistent chat ID
      final newChatId = ChatId(ChatUtils.generateChatId(persistentPublicKey));

      if (newChatId.value == ephemeralId) {
        _logger.warning(
          '⚠️ STEP 6: Chat IDs are identical - skipping migration',
        );
        return false;
      }

      // Check if new chat already has messages (merge scenario)
      final existingMessages = await _messageRepository.getMessages(newChatId);
      final shouldMerge = existingMessages.isNotEmpty;

      if (shouldMerge) {
        _logger.info(
          '🔀 STEP 6: Merging with existing chat (${existingMessages.length} messages)',
        );
      }

      // IMPORTANT: Create the new chat entry FIRST before updating messages
      // This ensures the foreign key constraint is satisfied
      await _updateChatMetadata(
        chatId: newChatId,
        publicKey: persistentPublicKey,
        contactName: contactName,
        messages: existingMessages, // Use existing messages for now
      );

      // Migrate all messages to new chat ID by updating chat_id in database
      int migratedCount = 0;
      final db = await DatabaseHelper.database;

      for (final message in messages) {
        // Check if this message already exists in the new chat (avoid duplicates)
        final isDuplicate = existingMessages.any((m) => m.id == message.id);

        if (isDuplicate) {
          _logger.fine('   Skipping duplicate message: ${message.id}');
          continue;
        }

        // Update the chat_id directly in the database
        // This is more efficient than delete+insert and avoids UNIQUE constraint issues
        await db.update(
          'messages',
          {'chat_id': newChatId.value},
          where: 'id = ?',
          whereArgs: [message.id.value],
        );

        migratedCount++;
      }

      _logger.info(
        '✅ STEP 6: Migrated $migratedCount messages to persistent chat',
      );

      // Clean up old ephemeral chat (always do this, even if no messages were migrated)
      // This is because the chat itself needs to be migrated
      await _cleanupEphemeralChat(ephemeralId);

      // Update chat metadata with final message count
      await _updateChatMetadata(
        chatId: newChatId,
        publicKey: persistentPublicKey,
        contactName: contactName,
        messages: await _messageRepository.getMessages(
          newChatId,
        ), // Get all messages (old + new)
      );

      _logger.info('✅ STEP 6: Chat migration complete!');
      _logger.info('   Old chat ID: $ephemeralId (deleted)');
      _logger.info('   New chat ID: ${newChatId.value}');
      _logger.info('   Messages migrated: $migratedCount');

      return true; // Return true if we had messages to process
    } catch (e, stackTrace) {
      _logger.severe('❌ STEP 6: Chat migration failed: $e', e, stackTrace);
      return false;
    }
  }

  /// Batch migrate multiple chats (useful for bulk operations)
  Future<Map<String, bool>> migrateBatchChats(
    Map<String, String> ephemeralToPersistentMapping,
  ) async {
    final results = <String, bool>{};

    for (final entry in ephemeralToPersistentMapping.entries) {
      final ephemeralId = entry.key;
      final persistentKey = entry.value;

      final success = await migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      results[ephemeralId] = success;
    }

    return results;
  }

  /// Check if a chat needs migration (has ephemeral ID and messages exist)
  Future<bool> needsMigration(String chatId) async {
    // Only temp chats need migration
    if (!chatId.startsWith('temp_')) {
      return false;
    }

    final messages = await _messageRepository.getMessages(ChatId(chatId));
    return messages.isNotEmpty;
  }

  /// Get all chats that need migration
  Future<List<String>> getChatsNeedingMigration() async {
    final db = await DatabaseHelper.database;

    final results = await db.query(
      'chats',
      columns: ['chat_id'],
      where: 'chat_id LIKE ?',
      whereArgs: ['temp_%'],
    );

    final chatIds = <String>[];

    for (final row in results) {
      final chatId = row['chat_id'] as String;
      if (await needsMigration(chatId)) {
        chatIds.add(chatId);
      }
    }

    return chatIds;
  }

  // ========================================
  // PRIVATE HELPER METHODS
  // ========================================

  /// Update chat metadata after migration
  Future<void> _updateChatMetadata({
    required ChatId chatId,
    required String publicKey,
    String? contactName,
    required List<Message> messages,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Get last message details
    String? lastMessage;
    int? lastMessageTime;

    if (messages.isNotEmpty) {
      final lastMsg = messages.last;
      lastMessage = lastMsg.content;
      lastMessageTime = lastMsg.timestamp.millisecondsSinceEpoch;
    }

    // Check if chat entry exists
    final existing = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId.value],
    );

    if (existing.isNotEmpty) {
      // Update existing chat
      // Note: Don't update contact_public_key to avoid foreign key constraints
      await db.update(
        'chats',
        {
          // Skip updating contact_public_key to avoid foreign key constraints
          'contact_name': contactName ?? existing.first['contact_name'],
          'last_message': lastMessage,
          'last_message_time': lastMessageTime,
          'updated_at': now,
        },
        where: 'chat_id = ?',
        whereArgs: [chatId.value],
      );
    } else {
      // Create new chat entry
      // Note: contact_public_key is set to NULL initially to avoid foreign key constraints
      // It will be updated later when the contact exists in the contacts table
      await db.insert('chats', {
        'chat_id': chatId.value,
        'contact_public_key':
            null, // Set to NULL to avoid foreign key constraint
        'contact_name': contactName ?? 'User',
        'last_message': lastMessage,
        'last_message_time': lastMessageTime,
        'unread_count': 0, // Don't mark migrated messages as unread
        'created_at': now,
        'updated_at': now,
      });
    }

    _logger.fine('   Updated chat metadata for ${chatId.value}');
  }

  /// Clean up ephemeral chat after successful migration
  Future<void> _cleanupEphemeralChat(String ephemeralId) async {
    final db = await DatabaseHelper.database;

    // Delete all messages from ephemeral chat
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [ephemeralId]);

    // Delete chat entry
    await db.delete('chats', where: 'chat_id = ?', whereArgs: [ephemeralId]);

    _logger.fine('   Cleaned up ephemeral chat: $ephemeralId');
  }
}
