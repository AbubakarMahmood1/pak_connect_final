/// ChatManagementFacade - backward-compatible wrapper for extracted chat services
/// Delegates to ArchiveService, SearchService, and PinningService
/// 100% backward compatible - zero consumer code changes required

import 'package:logging/logging.dart';
import '../../core/services/archive_service.dart';
import '../../core/services/search_service.dart';
import '../../core/services/pinning_service.dart';
import 'chat_management_service.dart';
import 'archive_search_service.dart';

/// Facade providing backward-compatible ChatManagementService interface
/// Internally delegates to extracted services (ArchiveService, SearchService, PinningService)
class ChatManagementFacade implements IChatManagement {
  static final _logger = Logger('ChatManagementFacade');

  // Lazy-initialized sub-services
  late final ArchiveService _archiveService;
  late final SearchService _searchService;
  late final PinningService _pinningService;

  final bool _initialized = false;

  ChatManagementFacade() {
    _logger.info('✅ ChatManagementFacade created (lazy initialization)');
  }

  /// Ensure all services are initialized
  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    _archiveService = ArchiveService();
    _searchService = SearchService();
    _pinningService = PinningService();

    await _archiveService.loadArchivedChats();

    _logger.info('✅ ChatManagementFacade services initialized');
  }

  // ========================= ARCHIVE METHODS =========================

  @override
  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) => _archiveService.toggleChatArchive(
    chatId,
    reason: reason,
    useEnhancedArchive: useEnhancedArchive,
  );

  @override
  bool isChatArchived(String chatId) => _archiveService.isArchived(chatId);

  @override
  int get archivedChatsCount => _archiveService.archivedChatsCount;

  @override
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) => _archiveService.batchArchiveChats(
    chatIds: chatIds,
    reason: reason,
    useEnhancedArchive: useEnhancedArchive,
  );

  // ========================= PINNING METHODS =========================

  @override
  Future<ChatOperationResult> toggleChatPin(String chatId) =>
      _pinningService.toggleChatPin(chatId);

  @override
  bool isChatPinned(String chatId) => _pinningService.isChatPinned(chatId);

  @override
  int get pinnedChatsCount => _pinningService.pinnedChatsCount;

  @override
  Future<ChatOperationResult> toggleMessageStar(String messageId) =>
      _pinningService.toggleMessageStar(messageId);

  @override
  bool isMessageStarred(String messageId) =>
      _pinningService.isMessageStarred(messageId);

  @override
  int get starredMessagesCount => _pinningService.starredMessagesCount;

  @override
  Future<List<EnhancedMessage>> getStarredMessages() =>
      _pinningService.getStarredMessages();

  // ========================= SEARCH METHODS =========================

  @override
  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  }) => _searchService.searchMessages(
    query: query,
    chatId: chatId,
    filter: filter,
    limit: limit,
  );

  @override
  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  }) => _searchService.searchMessagesUnified(
    query: query,
    chatId: chatId,
    filter: filter,
    includeArchives: includeArchives,
    limit: limit,
  );

  @override
  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  }) => _searchService.performAdvancedSearch(
    query: query,
    filter: filter,
    options: options,
    includeLive: includeLive,
    includeArchives: includeArchives,
  );

  @override
  List<String> getMessageSearchHistory() =>
      _searchService.getMessageSearchHistory();

  @override
  Future<void> clearMessageSearchHistory() =>
      _searchService.clearMessageSearchHistory();

  // ========================= LIFECYCLE =========================

  @override
  Future<void> initialize() async {
    await _ensureInitialized();
    _logger.info('✅ ChatManagementFacade initialized');
  }

  @override
  Future<void> dispose() async {
    if (!_initialized) return;

    await _archiveService.saveArchivedChats();
    await _searchService.clearMessageSearchHistory();
    await _pinningService.dispose();

    _logger.info('✅ ChatManagementFacade disposed');
  }
}

/// Interface defining facade contract
abstract interface class IChatManagement {
  // Archive operations
  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  });
  bool isChatArchived(String chatId);
  int get archivedChatsCount;
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  });

  // Pinning operations
  Future<ChatOperationResult> toggleChatPin(String chatId);
  bool isChatPinned(String chatId);
  int get pinnedChatsCount;
  Future<ChatOperationResult> toggleMessageStar(String messageId);
  bool isMessageStarred(String messageId);
  int get starredMessagesCount;
  Future<List<EnhancedMessage>> getStarredMessages();

  // Search operations
  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  });
  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  });
  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  });
  List<String> getMessageSearchHistory();
  Future<void> clearMessageSearchHistory();

  // Lifecycle
  Future<void> initialize();
  Future<void> dispose();
}
