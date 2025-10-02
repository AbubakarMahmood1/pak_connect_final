import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/message.dart';
import '../../core/utils/chat_utils.dart';
import 'message_repository.dart';
import 'contact_repository.dart';
import 'user_preferences.dart';

class ChatsRepository {
  static final _logger = Logger('ChatsRepository');
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final UserPreferences _userPreferences = UserPreferences();
  
  static const String _unreadCountsKey = 'chat_unread_counts';
  static const String _lastSeenKey = 'contact_last_seen';

  Future<List<ChatListItem>> getAllChats({
  List<Peripheral>? nearbyDevices,
  Map<String, DiscoveredEventArgs>? discoveryData,
  String? searchQuery,
}) async {
  final myPublicKey = await _userPreferences.getPublicKey();
  final unreadCounts = await _getUnreadCounts();
  final lastSeenData = await _getLastSeenData();
  
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
  
  // Also check for any temp chats (not associated with contacts)
  // by looking at messages with temp_ prefix
  final _ = await SharedPreferences.getInstance();
  // We'll have to use a workaround - check for temp chats by getting all messages
  // This is less efficient but avoids accessing private fields
  
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
      unreadCount: unreadCounts[chatId] ?? 0,
      isOnline: isOnline,
      hasUnsentMessages: hasUnsent,
      lastSeen: isOnline ? DateTime.now() : 
        (lastSeenData[contactPublicKey] != null 
          ? DateTime.fromMillisecondsSinceEpoch(lastSeenData[contactPublicKey]!)
          : null),
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
    final prefs = await SharedPreferences.getInstance();
    final unreadCounts = await _getUnreadCounts();
    
    unreadCounts.remove(chatId);
    await prefs.setString(_unreadCountsKey, 
      unreadCounts.entries.map((e) => '${e.key}:${e.value}').join(','));
  }

  /// Increment unread count for received message
  Future<void> incrementUnreadCount(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final unreadCounts = await _getUnreadCounts();
    
    unreadCounts[chatId] = (unreadCounts[chatId] ?? 0) + 1;
    await prefs.setString(_unreadCountsKey,
      unreadCounts.entries.map((e) => '${e.key}:${e.value}').join(','));
  }

  /// Update contact's last seen timestamp
  Future<void> updateContactLastSeen(String publicKey) async {
    final prefs = await SharedPreferences.getInstance();
    final lastSeenData = await _getLastSeenData();
    
    lastSeenData[publicKey] = DateTime.now().millisecondsSinceEpoch;
    await prefs.setString(_lastSeenKey,
      lastSeenData.entries.map((e) => '${e.key}:${e.value}').join(','));
  }

  /// Get total unread count across all chats
  Future<int> getTotalUnreadCount() async {
    final unreadCounts = await _getUnreadCounts();
    return unreadCounts.values.fold<int>(0, (sum, count) => sum + count);
  }

  // PRIVATE HELPERS
  
String _generateChatId(String myPublicKey, String otherPublicKey) {
  // Use the exact same logic as ChatUtils.generateChatId
  final ids = [myPublicKey, otherPublicKey]..sort();
  return 'persistent_chat_${ids[0]}_${ids[1]}';
}

  Future<Map<String, int>> _getUnreadCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_unreadCountsKey) ?? '';
    
    final counts = <String, int>{};
    if (data.isNotEmpty) {
      for (final entry in data.split(',')) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          counts[parts[0]] = int.tryParse(parts[1]) ?? 0;
        }
      }
    }
    return counts;
  }

  Future<Map<String, int>> _getLastSeenData() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_lastSeenKey) ?? '';
    
    final lastSeen = <String, int>{};
    if (data.isNotEmpty) {
      for (final entry in data.split(',')) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          lastSeen[parts[0]] = int.tryParse(parts[1]) ?? 0;
        }
      }
    }
    return lastSeen;
  }

  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {
  if (deviceUuid == null) return;
  
  final prefs = await SharedPreferences.getInstance();
  final mapping = await _getDeviceToPublicKeyMapping();
  mapping[deviceUuid] = publicKey;
  
  await prefs.setString('device_public_key_mapping',
    mapping.entries.map((e) => '${e.key}:${e.value}').join(','));
}

Future<Map<String, String>> _getDeviceToPublicKeyMapping() async {
  final prefs = await SharedPreferences.getInstance();
  final mappingData = prefs.getString('device_public_key_mapping') ?? '';
  
  final mapping = <String, String>{};
  if (mappingData.isNotEmpty) {
    for (final entry in mappingData.split(',')) {
      final parts = entry.split(':');
      if (parts.length == 2) {
        mapping[parts[0]] = parts[1]; // deviceUUID : publicKey
      }
    }
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