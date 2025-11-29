import 'package:logging/logging.dart';
import '../../core/models/archive_models.dart';
import '../../domain/entities/enhanced_message.dart';
import 'chat_management_service.dart';
import 'archive_search_service.dart';
import 'chat_management_models.dart';

import 'package:pak_connect/domain/values/id_types.dart';

/// Facade providing backward-compatible ChatManagementService interface
/// Internally delegates to ChatManagementService and keeps APIs stable
class ChatManagementFacade implements IChatManagement {
  static final _logger = Logger('ChatManagementFacade');

  final ChatManagementService _chatManagementService;

  bool _initialized = false;
  Future<void>? _initializationFuture;

  ChatManagementFacade({ChatManagementService? chatManagementService})
    : _chatManagementService =
          chatManagementService ?? ChatManagementService.instance {
    _logger.info('✅ ChatManagementFacade created (thin orchestrator)');
  }

  /// Ensure all services are initialized
  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    _initializationFuture ??= () async {
      await _chatManagementService.initialize();

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
    return _chatManagementService.toggleChatArchive(
      chatId,
      reason: reason,
      useEnhancedArchive: useEnhancedArchive,
    );
  }

  @override
  bool isChatArchived(String chatId) =>
      _chatManagementService.isChatArchived(chatId);

  @override
  int get archivedChatsCount => _chatManagementService.archivedChatsCount;

  @override
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    await _ensureInitialized();
    return _chatManagementService.batchArchiveChats(
      chatIds: chatIds,
      reason: reason,
      useEnhancedArchive: useEnhancedArchive,
    );
  }

  // ========================= PINNING METHODS =========================

  @override
  Future<ChatOperationResult> toggleChatPin(String chatId) async {
    await _ensureInitialized();
    return _chatManagementService.toggleChatPin(chatId);
  }

  @override
  bool isChatPinned(String chatId) =>
      _chatManagementService.isChatPinned(chatId);

  @override
  int get pinnedChatsCount => _chatManagementService.pinnedChatsCount;

  @override
  Future<ChatOperationResult> toggleMessageStar(String messageId) async {
    await _ensureInitialized();
    return _chatManagementService.toggleMessageStar(MessageId(messageId));
  }

  @override
  bool isMessageStarred(String messageId) =>
      _chatManagementService.isMessageStarred(messageId);

  @override
  int get starredMessagesCount => _chatManagementService.starredMessagesCount;

  @override
  Future<List<EnhancedMessage>> getStarredMessages() async {
    await _ensureInitialized();
    return _chatManagementService.getStarredMessages();
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
    return _chatManagementService.searchMessages(
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
    return _chatManagementService.searchMessagesUnified(
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
    return _chatManagementService.performAdvancedSearch(
      query: query,
      filter: filter,
      options: options,
      includeLive: includeLive,
      includeArchives: includeArchives,
    );
  }

  @override
  List<String> getMessageSearchHistory() =>
      _chatManagementService.getMessageSearchHistory();

  @override
  Future<void> clearMessageSearchHistory() async {
    await _ensureInitialized();
    await _chatManagementService.clearMessageSearchHistory();
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

    // Facade should not tear down the shared ChatManagementService singleton
    // because other consumers may still be using it.
    _initializationFuture = null;
    _initialized = false;
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
