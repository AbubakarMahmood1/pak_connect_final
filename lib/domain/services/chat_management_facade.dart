/// ChatManagementFacade - backward-compatible wrapper for extracted chat services
/// Delegates to ArchiveService, SearchService, and PinningService
/// 100% backward compatible - zero consumer code changes required

import 'package:logging/logging.dart';
import '../../core/models/archive_models.dart';
import '../../core/services/archive_service.dart';
import '../../core/services/search_service.dart';
import '../../core/services/pinning_service.dart';
import '../../domain/entities/enhanced_message.dart';
import 'chat_management_service.dart';
import 'archive_search_service.dart';

/// Facade providing backward-compatible ChatManagementService interface
/// Internally delegates to extracted services (ArchiveService, SearchService, PinningService)
class ChatManagementFacade implements IChatManagement {
  static final _logger = Logger('ChatManagementFacade');

  // Sub-services (allow dependency injection for testing)
  final ArchiveService _archiveService;
  final SearchService _searchService;
  final PinningService _pinningService;

  bool _initialized = false;
  Future<void>? _initializationFuture;

  ChatManagementFacade({
    ArchiveService? archiveService,
    SearchService? searchService,
    PinningService? pinningService,
  }) : _archiveService = archiveService ?? ArchiveService(),
       _searchService = searchService ?? SearchService(),
       _pinningService = pinningService ?? PinningService() {
    _logger.info('✅ ChatManagementFacade created (lazy initialization)');
  }

  /// Ensure all services are initialized
  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    _initializationFuture ??= () async {
      await _archiveService.loadArchivedChats();
      await _searchService.initialize();
      await _pinningService.initialize();

      _initialized = true;
      _logger.info('✅ ChatManagementFacade services initialized');
    }();

    try {
      await _initializationFuture;
    } finally {
      if (_initialized) {
        _initializationFuture = null;
      }
    }
  }

  // ========================= ARCHIVE METHODS =========================

  @override
  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    await _ensureInitialized();

    if (_archiveService.isArchived(chatId)) {
      return _archiveService.unarchiveChat(
        chatId,
        useEnhancedArchive: useEnhancedArchive,
      );
    }

    return _archiveService.archiveChat(
      chatId,
      reason: reason,
      useEnhancedArchive: useEnhancedArchive,
    );
  }

  @override
  bool isChatArchived(String chatId) => _archiveService.isArchived(chatId);

  @override
  int get archivedChatsCount => _archiveService.archivedChatsCount;

  @override
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    await _ensureInitialized();
    return _archiveService.batchArchiveChats(
      chatIds: chatIds,
      reason: reason,
      useEnhancedArchive: useEnhancedArchive,
    );
  }

  // ========================= PINNING METHODS =========================

  @override
  Future<ChatOperationResult> toggleChatPin(String chatId) async {
    await _ensureInitialized();
    return _pinningService.toggleChatPin(chatId);
  }

  @override
  bool isChatPinned(String chatId) => _pinningService.isChatPinned(chatId);

  @override
  int get pinnedChatsCount => _pinningService.pinnedChatsCount;

  @override
  Future<ChatOperationResult> toggleMessageStar(String messageId) async {
    await _ensureInitialized();
    return _pinningService.toggleMessageStar(messageId);
  }

  @override
  bool isMessageStarred(String messageId) =>
      _pinningService.isMessageStarred(messageId);

  @override
  int get starredMessagesCount => _pinningService.starredMessagesCount;

  @override
  Future<List<EnhancedMessage>> getStarredMessages() async {
    await _ensureInitialized();
    return _pinningService.getStarredMessages();
  }

  // ========================= SEARCH METHODS =========================

  @override
  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  }) async {
    await _ensureInitialized();
    return _searchService.searchMessages(
      query: query,
      chatId: chatId,
      filter: filter,
      limit: limit,
    );
  }

  @override
  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  }) async {
    await _ensureInitialized();
    return _searchService.searchMessagesUnified(
      query: query,
      chatId: chatId,
      filter: filter,
      includeArchives: includeArchives,
      limit: limit,
    );
  }

  @override
  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  }) async {
    await _ensureInitialized();
    return _searchService.performAdvancedSearch(
      query: query,
      filter: filter,
      options: options,
      includeLive: includeLive,
      includeArchives: includeArchives,
    );
  }

  @override
  List<String> getMessageSearchHistory() =>
      _searchService.getMessageSearchHistory();

  @override
  Future<void> clearMessageSearchHistory() async {
    await _ensureInitialized();
    await _searchService.clearMessageSearchHistory();
  }

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
    await _searchService.dispose();
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
