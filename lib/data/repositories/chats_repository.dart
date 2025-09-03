import 'dart:async';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/message.dart';
import '../../core/utils/chat_utils.dart';
import 'message_repository.dart';
import 'contact_repository.dart';
import 'user_preferences.dart';

class ChatsRepository {
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final UserPreferences _userPreferences = UserPreferences();
  
  static const String _unreadCountsKey = 'chat_unread_counts';
  static const String _lastSeenKey = 'contact_last_seen';

  /// Get all chats with aggregated data (main method for ChatsScreen)
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
  }) async {
    final contacts = await _contactRepository.getAllContacts();
    final myPublicKey = await _userPreferences.getPublicKey();
    final unreadCounts = await _getUnreadCounts();
    final lastSeenData = await _getLastSeenData();
    
    final chatItems = <ChatListItem>[];
    final processedChatIds = <String>{};
    
    // Process each contact
    for (final contact in contacts.values) {
      final chatId = _generateChatId(myPublicKey, contact.publicKey);
      if (processedChatIds.contains(chatId)) continue;
      processedChatIds.add(chatId);
      
      // Get last message for this chat
      final messages = await _messageRepository.getMessages(chatId);
      final lastMessage = messages.isNotEmpty ? messages.last : null;
      
      // Check if contact is online (nearby via BLE)
      final isOnline = _isContactOnline(contact.publicKey, discoveryData);
      
      // Check for unsent messages
      final hasUnsent = messages.any((m) => 
        m.isFromMe && m.status == MessageStatus.failed);
      
      // Apply search filter if provided
      if (searchQuery != null && searchQuery.isNotEmpty) {
        final query = searchQuery.toLowerCase();
        if (!contact.displayName.toLowerCase().contains(query) &&
            !(lastMessage?.content.toLowerCase().contains(query) ?? false)) {
          continue;
        }
      }
      
      chatItems.add(ChatListItem(
        chatId: chatId,
        contactName: contact.displayName,
        contactPublicKey: contact.publicKey,
        lastMessage: lastMessage?.content,
        lastMessageTime: lastMessage?.timestamp,
        unreadCount: unreadCounts[chatId] ?? 0,
        isOnline: isOnline,
        hasUnsentMessages: hasUnsent,
        lastSeen: isOnline ? DateTime.now() : 
  (lastSeenData[contact.publicKey] != null 
    ? DateTime.fromMillisecondsSinceEpoch(lastSeenData[contact.publicKey]!)
    : null),
      ));
    }
    
    // Sort: Online contacts first, then by last activity
    chatItems.sort((a, b) {
      if (a.isOnline && !b.isOnline) return -1;
      if (!a.isOnline && b.isOnline) return 1;
      
      // Both same online status - sort by last activity
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
            print('✅ ONLINE: Contact $contactKeyHash matches device hash $deviceHash');
            return true;
          }
        }
      }
    }
  }
  
  return false;
}
}