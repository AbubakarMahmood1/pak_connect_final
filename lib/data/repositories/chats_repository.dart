import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../core/utils/chat_utils.dart';
import '../database/database_helper.dart';
import 'message_repository.dart';
import 'contact_repository.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class ChatsRepository implements IChatsRepository {
  static final _logger = Logger('ChatsRepository');
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();

  // Note: UserPreferences removed after FIX-006 optimization
  // The JOIN query doesn't need myPublicKey since it uses direct contact matching

  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    final db = await DatabaseHelper.database;

    // ✅ FIX-006: Single JOIN query replaces N+1 pattern
    // Before: 1 + 4N queries (get contacts, check messages N times, get messages N times, get unread N times, get last seen N times)
    // After: 1 query with JOINs
    final buffer = StringBuffer('''
      SELECT
        c.public_key,
        c.display_name,
        c.security_level,
        c.trust_status,
        ch.chat_id,
        ch.unread_count,
        cls.last_seen_at,
        COUNT(m.id) as message_count,
        MAX(m.timestamp) as latest_message_timestamp,
        (SELECT m2.content FROM messages m2 WHERE m2.chat_id = c.public_key ORDER BY m2.timestamp DESC LIMIT 1) as last_message_content,
        (SELECT m3.status FROM messages m3 WHERE m3.chat_id = c.public_key ORDER BY m3.timestamp DESC LIMIT 1) as last_message_status,
        (SELECT COUNT(*) FROM messages m4 WHERE m4.chat_id = c.public_key AND m4.is_from_me = 1 AND m4.status = 3) as failed_message_count
      FROM contacts c
      LEFT JOIN chats ch ON ch.contact_public_key = c.public_key
      LEFT JOIN messages m ON m.chat_id = c.public_key
      LEFT JOIN contact_last_seen cls ON cls.public_key = c.public_key
      GROUP BY c.public_key
      HAVING message_count > 0
      ORDER BY latest_message_timestamp DESC NULLS LAST
    ''');

    final params = <Object?>[];
    if (limit != null) {
      buffer.write(' LIMIT ?');
      params.add(limit);
      if (offset != null) {
        buffer.write(' OFFSET ?');
        params.add(offset);
      }
    }

    final results = await db.rawQuery(buffer.toString(), params);

    final chatItems = <ChatListItem>[];

    for (final row in results) {
      final contactPublicKey = row['public_key'] as String;
      final contactName = row['display_name'] as String;
      final chatId = _generateChatId(contactPublicKey);

      final unreadCount = (row['unread_count'] as int?) ?? 0;
      final lastSeenAt = row['last_seen_at'] as int?;
      final lastMessageContent = row['last_message_content'] as String?;
      final lastMessageTimestamp = row['latest_message_timestamp'] as int?;
      final failedMessageCount = (row['failed_message_count'] as int?) ?? 0;

      // Parse last seen
      DateTime? lastSeen;
      if (lastSeenAt != null) {
        lastSeen = DateTime.fromMillisecondsSinceEpoch(lastSeenAt);
      }

      // Check if online
      final isOnline = _isContactOnline(contactPublicKey, discoveryData);

      // Parse last message timestamp
      DateTime? lastMessageTime;
      if (lastMessageTimestamp != null) {
        lastMessageTime = DateTime.fromMillisecondsSinceEpoch(
          lastMessageTimestamp,
        );
      }

      // Apply search filter
      if (searchQuery != null && searchQuery.isNotEmpty) {
        final query = searchQuery.toLowerCase();
        if (!contactName.toLowerCase().contains(query) &&
            !(lastMessageContent?.toLowerCase().contains(query) ?? false)) {
          continue;
        }
      }

      chatItems.add(
        ChatListItem(
          chatId: chatId,
          contactName: contactName,
          contactPublicKey: contactPublicKey,
          lastMessage: lastMessageContent ?? '',
          lastMessageTime: lastMessageTime,
          unreadCount: unreadCount,
          isOnline: isOnline,
          hasUnsentMessages: failedMessageCount > 0,
          lastSeen: isOnline ? DateTime.now() : lastSeen,
        ),
      );
    }

    // Sort by online status first, then by last message time
    chatItems.sort((a, b) {
      if (a.isOnline && !b.isOnline) return -1;
      if (!a.isOnline && b.isOnline) return 1;

      final aTime = a.lastMessageTime ?? DateTime(1970);
      final bTime = b.lastMessageTime ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });

    _logger.info(
      '📊 getAllChats: Returned ${chatItems.length} chats (optimized JOIN query)',
    );
    return chatItems;
  }

  /// Get list of contacts without active chats (for discovery integration)
  Future<List<Contact>> getContactsWithoutChats() async {
    final allContacts = await _contactRepository.getAllContacts();

    final contactsWithoutChats = <Contact>[];

    for (final contact in allContacts.values) {
      final chatId = _generateChatId(contact.publicKey);
      final messages = await _messageRepository.getMessages(chatId);

      if (messages.isEmpty) {
        contactsWithoutChats.add(contact);
      }
    }

    return contactsWithoutChats;
  }

  /// Mark chat as read (reset unread count)
  Future<void> markChatAsRead(ChatId chatId) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Check if chat exists
    final existing = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId.value],
    );

    if (existing.isNotEmpty) {
      // Update existing chat
      await db.update(
        'chats',
        {'unread_count': 0, 'updated_at': now},
        where: 'chat_id = ?',
        whereArgs: [chatId.value],
      );
    } else {
      // Create new chat entry with 0 unread count
      await db.insert('chats', {
        'chat_id': chatId.value,
        'contact_public_key': null,
        'contact_name': 'Unknown',
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// Increment unread count for received message
  Future<void> incrementUnreadCount(ChatId chatId) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Check if chat exists
    final existing = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId.value],
    );

    if (existing.isNotEmpty) {
      // Increment existing count
      final currentCount = existing.first['unread_count'] as int? ?? 0;
      await db.update(
        'chats',
        {'unread_count': currentCount + 1, 'updated_at': now},
        where: 'chat_id = ?',
        whereArgs: [chatId.value],
      );
    } else {
      // Create new chat entry with count = 1
      await db.insert('chats', {
        'chat_id': chatId.value,
        'contact_public_key': null,
        'contact_name': 'Unknown',
        'unread_count': 1,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// Update contact's last seen timestamp
  Future<void> updateContactLastSeen(String publicKey) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Upsert (insert or replace) last seen data
    await db.insert('contact_last_seen', {
      'public_key': publicKey,
      'last_seen_at': now,
      'was_online': 1,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Get total unread count across all chats
  Future<int> getTotalUnreadCount() async {
    final db = await DatabaseHelper.database;

    final result = await db.rawQuery(
      'SELECT SUM(unread_count) as total FROM chats',
    );

    if (result.isNotEmpty && result.first['total'] != null) {
      return result.first['total'] as int;
    }

    return 0;
  }

  /// Store device UUID to public key mapping
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {
    if (deviceUuid == null) return;

    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Upsert (insert or replace) device mapping
    await db.insert('device_mappings', {
      'device_uuid': deviceUuid,
      'public_key': publicKey,
      'last_seen': now,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // PRIVATE HELPERS

  ChatId _generateChatId(String otherPublicKey) {
    // Use the exact same logic as ChatUtils.generateChatId
    // chatId = theirId (simple and elegant)
    return ChatId(otherPublicKey);
  }

  /// Online detection using public key hash matching
  bool _isContactOnline(
    String contactPublicKey,
    Map<String, DiscoveredEventArgs>? discoveryData,
  ) {
    if (discoveryData == null || discoveryData.isEmpty) return false;

    // Generate hash for this contact's public key
    final contactKeyHash = ChatUtils.generatePublicKeyHash(contactPublicKey);

    // Check each discovered device
    for (final discoveryEvent in discoveryData.values) {
      final advertisement = discoveryEvent.advertisement;

      // Check manufacturer data for our hash (Android/Windows only)
      if (advertisement.manufacturerSpecificData.isNotEmpty) {
        for (final manufacturerData in advertisement.manufacturerSpecificData) {
          // Check if it's our manufacturer ID
          if (manufacturerData.id == 0x2E19 &&
              manufacturerData.data.length >= 4) {
            // Convert bytes back to hex string
            final deviceHash = manufacturerData.data
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();

            // Match found!
            if (deviceHash == contactKeyHash) {
              _logger.info(
                '✅ ONLINE: Contact $contactKeyHash matches device hash $deviceHash',
              );
              return true;
            }
          }
        }
      }
    }

    return false;
  }

  // =========================
  // STATISTICS METHODS
  // =========================

  /// Get total chat count (non-archived)
  Future<int> getChatCount() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM chats WHERE is_archived = 0',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get chat count: $e');
      return 0;
    }
  }

  /// Get archived chat count
  Future<int> getArchivedChatCount() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM chats WHERE is_archived = 1',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get archived chat count: $e');
      return 0;
    }
  }

  /// Get total message count across all chats
  Future<int> getTotalMessageCount() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM messages',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get total message count: $e');
      return 0;
    }
  }

  /// 🔥 Clean up orphaned ephemeral contacts (no chat history, not verified/paired)
  /// This removes temporary contacts that were never upgraded to persistent relationships
  /// Called during app maintenance or when storage needs cleaning
  Future<int> cleanupOrphanedEphemeralContacts() async {
    try {
      _logger.info('🧹 Starting cleanup of orphaned ephemeral contacts...');

      final allContacts = await _contactRepository.getAllContacts();
      int deletedCount = 0;

      for (final contact in allContacts.values) {
        // Skip verified contacts and those with persistent relationships
        if (contact.trustStatus == TrustStatus.verified) {
          continue;
        }

        // Check if contact has any chat history
        final chatId = _generateChatId(contact.publicKey);
        final messages = await _messageRepository.getMessages(chatId);

        if (messages.isEmpty) {
          // No chat history - safe to delete ephemeral contact
          final deleted = await _contactRepository.deleteContact(
            contact.publicKey,
          );
          if (deleted) {
            deletedCount++;
            _logger.fine(
              'Deleted orphaned ephemeral contact: ${contact.displayName} (${contact.publicKey.shortId(8)}...)',
            );
          }
        }
      }

      if (deletedCount > 0) {
        _logger.info(
          '✅ Cleaned up $deletedCount orphaned ephemeral contact(s)',
        );
      } else {
        _logger.info('✅ No orphaned ephemeral contacts found');
      }

      return deletedCount;
    } catch (e) {
      _logger.warning('Failed to cleanup orphaned ephemeral contacts: $e');
      return 0;
    }
  }
}
