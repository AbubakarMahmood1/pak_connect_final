import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/contact.dart';

/// Interface for chats repository operations
///
/// Abstracts chat storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations
abstract class IChatsRepository {
  /// Get all chats with optional discovery and search filtering
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  });

  /// Get contacts without existing chats (for discovery integration)
  Future<List<Contact>> getContactsWithoutChats();

  /// Mark a chat as read
  Future<void> markChatAsRead(String chatId);

  /// Increment unread count for a chat
  Future<void> incrementUnreadCount(String chatId);

  /// Update contact's last seen timestamp
  Future<void> updateContactLastSeen(String publicKey);

  /// Get total unread message count
  Future<int> getTotalUnreadCount();

  /// Store device mapping for online status tracking
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey);

  /// Get chat count
  Future<int> getChatCount();

  /// Get archived chat count
  Future<int> getArchivedChatCount();

  /// Get total message count
  Future<int> getTotalMessageCount();

  /// Cleanup orphaned ephemeral contacts (not in contact list)
  Future<int> cleanupOrphanedEphemeralContacts();
}
