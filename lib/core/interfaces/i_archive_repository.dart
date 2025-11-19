/// Interface for archive repository operations
///
/// Abstracts archive storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations
abstract class IArchiveRepository {
  /// Initialize the archive repository
  Future<void> initialize();

  /// Archive a chat (move to archives)
  Future<void> archiveChat(String chatId);

  /// Restore a chat from archives
  Future<void> restoreChat(String archivedChatId);

  /// Get count of archived chats
  Future<int> getArchivedChatsCount();

  /// Get list of archived chats
  Future<List<Map<String, dynamic>>> getArchivedChats({
    int offset = 0,
    int limit = 20,
  });

  /// Get a specific archived chat
  Future<Map<String, dynamic>?> getArchivedChat(String archivedChatId);

  /// Search archived messages
  Future<List<Map<String, dynamic>>> searchArchives(
    String query, {
    int offset = 0,
    int limit = 20,
  });

  /// Permanently delete an archive
  Future<void> permanentlyDeleteArchive(String archivedChatId);

  /// Get archive statistics
  Future<Map<String, dynamic>> getArchiveStatistics();

  /// Clear cache
  void clearCache();

  /// Dispose resources
  Future<void> dispose();
}
