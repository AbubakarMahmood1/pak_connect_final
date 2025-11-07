import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/message.dart';
import '../../core/utils/chat_utils.dart';
import '../database/database_helper.dart';
import 'message_repository.dart';
import 'contact_repository.dart';
import 'user_preferences.dart';

class ChatsRepository {
  static final _logger = Logger('ChatsRepository');
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final UserPreferences _userPreferences = UserPreferences();

  // Cache for public key to avoid repeated secure storage reads
  static String? _cachedPublicKey;
  static DateTime? _cacheTimestamp;
  static const Duration _cacheValidDuration = Duration(minutes: 5);

  Future<String> _getMyPublicKey() async {
    final now = DateTime.now();
    if (_cachedPublicKey != null &&
        _cacheTimestamp != null &&
        now.difference(_cacheTimestamp!) < _cacheValidDuration) {
      return _cachedPublicKey!;
    }

    _cachedPublicKey = await _userPreferences.getPublicKey();
    _cacheTimestamp = now;
    return _cachedPublicKey!;
  }

  /// Invalidate cached public key (call after key regeneration)
  static void invalidatePublicKeyCache() {
    _cachedPublicKey = null;
    _cacheTimestamp = null;
  }

  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
  }) async {
    final db = await DatabaseHelper.database;
    final myPublicKey = await _getMyPublicKey();

    final chatItems = <ChatListItem>[];
    final processedChatIds = <String>{};

    // Get all unique chat IDs that have messages
    final contacts = await _contactRepository.getAllContacts();
    final allChatIds = <String>{};

    for (final contact in contacts.values) {
      final chatId = _generateChatId(contact.publicKey);

      // Check if this chat has any messages
      final messages = await _messageRepository.getMessages(chatId);
      if (messages.isNotEmpty) {
        allChatIds.add(chatId);
      }
    }

    // Process each chat that has messages
    for (final chatId in allChatIds) {
      if (processedChatIds.contains(chatId)) continue;
      processedChatIds.add(chatId);

      final messages = await _messageRepository.getMessages(chatId);
      if (messages.isEmpty) continue;

      final lastMessage = messages.last;

      // Extract contact info
      String? contactPublicKey;
      String? contactName;

      if (chatId.startsWith('persistent_chat_')) {
        final parts = chatId.substring('persistent_chat_'.length).split('_');
        if (parts.length >= 2) {
          final key1 = parts[0];
          final key2 = parts[1];
          contactPublicKey = (key1 == myPublicKey) ? key2 : key1;

          final contact = await _contactRepository.getContact(contactPublicKey);
          contactName = contact?.displayName;
        }
      } else {
        // 🔥 FIX: Try to look up contact by chatId (which is theirId - ephemeral or persistent)
        // This handles ephemeral-only contacts that were saved during handshake
        contactPublicKey = chatId;
        final contact = await _contactRepository.getContact(chatId);
        if (contact != null) {
          contactName = contact.displayName;
          _logger.fine('Found contact name for $chatId: $contactName');
        }
      }

      if (contactName == null) {
        if (chatId.startsWith('temp_')) {
          contactName = 'Device ${chatId.substring(5)}';
        } else {
          // Last resort fallback
          contactName = 'Unknown Contact';
          _logger.warning('No contact found for chatId: $chatId');
        }
      }

      // Get unread count from database
      int unreadCount = 0;
      final chatRows = await db.query(
        'chats',
        columns: ['unread_count'],
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
      if (chatRows.isNotEmpty) {
        unreadCount = chatRows.first['unread_count'] as int? ?? 0;
      }

      // Get last seen data
      DateTime? lastSeen;
      if (contactPublicKey != null) {
        final lastSeenRows = await db.query(
          'contact_last_seen',
          columns: ['last_seen_at'],
          where: 'public_key = ?',
          whereArgs: [contactPublicKey],
        );
        if (lastSeenRows.isNotEmpty) {
          final lastSeenAt = lastSeenRows.first['last_seen_at'] as int?;
          if (lastSeenAt != null) {
            lastSeen = DateTime.fromMillisecondsSinceEpoch(lastSeenAt);
          }
        }
      }

      // Check if online
      final isOnline = contactPublicKey != null
          ? _isContactOnline(contactPublicKey, discoveryData)
          : false;

      // Check for unsent messages
      final hasUnsent = messages.any(
        (m) => m.isFromMe && m.status == MessageStatus.failed,
      );

      // Apply search filter
      if (searchQuery != null && searchQuery.isNotEmpty) {
        final query = searchQuery.toLowerCase();
        if (!contactName.toLowerCase().contains(query) &&
            !(lastMessage.content.toLowerCase().contains(query))) {
          continue;
        }
      }

      chatItems.add(
        ChatListItem(
          chatId: chatId,
          contactName: contactName,
          contactPublicKey: contactPublicKey,
          lastMessage: lastMessage.content,
          lastMessageTime: lastMessage.timestamp,
          unreadCount: unreadCount,
          isOnline: isOnline,
          hasUnsentMessages: hasUnsent,
          lastSeen: isOnline ? DateTime.now() : lastSeen,
        ),
      );
    }

    // Sort by online status and last message time
    chatItems.sort((a, b) {
      if (a.isOnline && !b.isOnline) return -1;
      if (!a.isOnline && b.isOnline) return 1;

      final aTime = a.lastMessageTime ?? DateTime(1970);
      final bTime = b.lastMessageTime ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });

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
  Future<void> markChatAsRead(String chatId) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Check if chat exists
    final existing = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    if (existing.isNotEmpty) {
      // Update existing chat
      await db.update(
        'chats',
        {'unread_count': 0, 'updated_at': now},
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
    } else {
      // Create new chat entry with 0 unread count
      await db.insert('chats', {
        'chat_id': chatId,
        'contact_public_key': null,
        'contact_name': 'Unknown',
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// Increment unread count for received message
  Future<void> incrementUnreadCount(String chatId) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Check if chat exists
    final existing = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    if (existing.isNotEmpty) {
      // Increment existing count
      final currentCount = existing.first['unread_count'] as int? ?? 0;
      await db.update(
        'chats',
        {'unread_count': currentCount + 1, 'updated_at': now},
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
    } else {
      // Create new chat entry with count = 1
      await db.insert('chats', {
        'chat_id': chatId,
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

  String _generateChatId(String otherPublicKey) {
    // Use the exact same logic as ChatUtils.generateChatId
    // chatId = theirId (simple and elegant)
    return otherPublicKey;
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
              'Deleted orphaned ephemeral contact: ${contact.displayName} (${contact.publicKey.substring(0, 8)}...)',
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
