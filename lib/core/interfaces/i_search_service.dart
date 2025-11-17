// Interface for search service operations
// Extracted from ChatManagementService for better separation of concerns

import '../../domain/services/chat_management_service.dart';
import '../../domain/services/archive_search_service.dart';
import '../../core/models/archive_models.dart';

/// Interface for message search operations
abstract class ISearchService {
  /// Search messages across all chats or within specific chat (backward compatible)
  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  });

  /// Search messages across all chats including archives
  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  });

  /// Search across both live and archived content with advanced options
  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  });

  /// Get recent message search history
  List<String> getMessageSearchHistory();

  /// Clear message search history
  Future<void> clearMessageSearchHistory();

  /// Initialize the service
  Future<void> initialize();

  /// Dispose of resources
  Future<void> dispose();
}
