/// Interface for chats repository operations
///
/// Abstracts chat storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations
abstract class IChatsRepository {
  /// Get all chats
  Future<List<Map<String, dynamic>>> getAllChats();

  /// Get contacts without existing chats
  Future<List<Map<String, dynamic>>> getContactsWithoutChats();

  /// Mark a chat as read
  Future<void> markChatAsRead(String chatId);

  /// Increment unread count for a chat
  Future<void> incrementUnreadCount(String chatId);

  /// Update contact's last seen timestamp
  Future<void> updateContactLastSeen(String contactPublicKey);

  /// Get total unread message count
  Future<int> getTotalUnreadCount();

  /// Store device mapping for a chat
  Future<void> storeDeviceMapping(String chatId, String deviceId);

  /// Get chat count
  Future<int> getChatCount();

  /// Get archived chat count
  Future<int> getArchivedChatCount();

  /// Get total message count
  Future<int> getTotalMessageCount();

  /// Cleanup orphaned ephemeral contacts (not in contact list)
  Future<void> cleanupOrphanedEphemeralContacts();
}
