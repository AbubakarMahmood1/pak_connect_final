import '../../core/models/archive_models.dart';
import '../../domain/entities/archived_chat.dart';

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
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  });

  /// Restore a chat from archives
  Future<ArchiveOperationResult> restoreChat(String archiveId);

  /// Get count of archived chats
  Future<int> getArchivedChatsCount();

  /// Get list of archived chats (returns summaries for list view)
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  });

  /// Look up an archived chat summary by its original chat ID
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(String chatId);

  /// Get a specific archived chat (full details)
  Future<ArchivedChat?> getArchivedChat(String archiveId);

  /// Search archived messages
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  });

  /// Permanently delete an archive
  Future<void> permanentlyDeleteArchive(String archivedChatId);

  /// Get archive statistics
  Future<ArchiveStatistics?> getArchiveStatistics();

  /// Clear cache
  void clearCache();

  /// Dispose resources
  Future<void> dispose();
}
