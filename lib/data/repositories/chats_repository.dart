import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';
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

  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
  }) async {
    final db = await DatabaseHelper.database;
    final myPublicKey = await _userPreferences.getPublicKey();

    final chatItems = <ChatListItem>[];
    final processedChatIds = <String>{};

    // Get all unique chat IDs that have messages
    final contacts = await _contactRepository.getAllContacts();
    final allChatIds = <String>{};

    for (final contact in contacts.values) {
      final chatId = _generateChatId(myPublicKey, contact.publicKey);

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
      }

      if (contactName == null) {
        if (chatId.startsWith('temp_')) {
          contactName = 'Device ${chatId.substring(5)}';
        } else {
          contactName = 'Unknown Contact';
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
      final isOnline = contactPublicKey != null ?
        _isContactOnline(contactPublicKey, discoveryData) : false;

      // Check for unsent messages
      final hasUnsent = messages.any((m) =>
        m.isFromMe && m.status == MessageStatus.failed);

      // Apply search filter
      if (searchQuery != null && searchQuery.isNotEmpty) {
        final query = searchQuery.toLowerCase();
        if (!contactName.toLowerCase().contains(query) &&
            !(lastMessage.content.toLowerCase().contains(query))) {
          continue;
        }
      }

      chatItems.add(ChatListItem(
        chatId: chatId,
        contactName: contactName,
        contactPublicKey: contactPublicKey,
        lastMessage: lastMessage.content,
        lastMessageTime: lastMessage.timestamp,
        unreadCount: unreadCount,
        isOnline: isOnline,
        hasUnsentMessages: hasUnsent,
        lastSeen: isOnline ? DateTime.now() : lastSeen,
      ));
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
    final myPublicKey = await _userPreferences.getPublicKey();

    final contactsWithoutChats = <Contact>[];

    for (final contact in allContacts.values) {
      final chatId = _generateChatId(myPublicKey, contact.publicKey);
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
        {
          'unread_count': 0,
          'updated_at': now,
        },
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
        {
          'unread_count': currentCount + 1,
          'updated_at': now,
        },
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
    await db.insert(
      'contact_last_seen',
      {
        'public_key': publicKey,
        'last_seen_at': now,
        'was_online': 1,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get total unread count across all chats
  Future<int> getTotalUnreadCount() async {
    final db = await DatabaseHelper.database;

    final result = await db.rawQuery(
      'SELECT SUM(unread_count) as total FROM chats'
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
    await db.insert(
      'device_mappings',
      {
        'device_uuid': deviceUuid,
        'public_key': publicKey,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // PRIVATE HELPERS

  String _generateChatId(String myPublicKey, String otherPublicKey) {
    // Use the exact same logic as ChatUtils.generateChatId
    final ids = [myPublicKey, otherPublicKey]..sort();
    return 'persistent_chat_${ids[0]}_${ids[1]}';
  }

  /// Get device to public key mapping (for internal use)
  Future<Map<String, String>> _getDeviceToPublicKeyMapping() async {
    final db = await DatabaseHelper.database;

    final rows = await db.query('device_mappings');

    final mapping = <String, String>{};
    for (final row in rows) {
      final deviceUuid = row['device_uuid'] as String;
      final publicKey = row['public_key'] as String;
      mapping[deviceUuid] = publicKey;
    }

    return mapping;
  }

  /// Online detection using public key hash matching
  bool _isContactOnline(String contactPublicKey, Map<String, DiscoveredEventArgs>? discoveryData) {
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
          if (manufacturerData.id == 0x2E19 && manufacturerData.data.length >= 4) {
            // Convert bytes back to hex string
            final deviceHash = manufacturerData.data
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();

            // Match found!
            if (deviceHash == contactKeyHash) {
              _logger.info('✅ ONLINE: Contact $contactKeyHash matches device hash $deviceHash');
              return true;
            }
          }
        }
      }
    }

    return false;
  }
}
