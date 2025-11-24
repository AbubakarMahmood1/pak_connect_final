// WhatsApp-inspired chat management system with comprehensive message operations and archive integration

import 'package:logging/logging.dart';
import '../../core/models/archive_models.dart';
import '../../data/repositories/archive_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../entities/chat_list_item.dart';
import '../entities/enhanced_message.dart';
import 'archive_management_service.dart';
import 'archive_search_service.dart';
import 'chat_lifecycle_service.dart';
import 'chat_management_models.dart';
import 'chat_notification_service.dart';
import 'chat_sync_service.dart';

export 'chat_management_models.dart';

/// Comprehensive chat management service orchestrating lifecycle, sync, and notifications
class ChatManagementService {
  static final _logger = Logger('ChatManagementService');

  static ChatManagementService? _instance;

  static ChatManagementService get instance {
    _instance ??= ChatManagementService._internal();
    return _instance!;
  }

  final ChatsRepository _chatsRepository;
  final MessageRepository _messageRepository;
  final ArchiveRepository _archiveRepository;
  final ArchiveManagementService _archiveManagementService;
  final ArchiveSearchService _archiveSearchService;

  final ChatCacheState _cacheState = ChatCacheState();
  late final ChatNotificationService _notificationService;
  late final ChatSyncService _syncService;
  late final ChatLifecycleService _lifecycleService;

  bool _isInitialized = false;
  Future<void>? _initializationFuture;

  ChatManagementService._internal()
    : _chatsRepository = ChatsRepository(),
      _messageRepository = MessageRepository(),
      _archiveRepository = ArchiveRepository.instance,
      _archiveManagementService = ArchiveManagementService.instance,
      _archiveSearchService = ArchiveSearchService.instance {
    _notificationService = ChatNotificationService();
    _syncService = ChatSyncService(
      chatsRepository: _chatsRepository,
      messageRepository: _messageRepository,
      cacheState: _cacheState,
      archiveSearchService: _archiveSearchService,
    );
    _lifecycleService = ChatLifecycleService(
      chatsRepository: _chatsRepository,
      messageRepository: _messageRepository,
      archiveRepository: _archiveRepository,
      archiveManagementService: _archiveManagementService,
      cacheState: _cacheState,
      notificationService: _notificationService,
      syncService: _syncService,
    );
    _logger.info('✅ ChatManagementService singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ChatManagementService() => instance;

  /// Stream of chat updates
  Stream<ChatUpdateEvent> get chatUpdates => _notificationService.chatUpdates;

  /// Stream of message updates
  Stream<MessageUpdateEvent> get messageUpdates =>
      _notificationService.messageUpdates;

  /// Initialize chat management service and sub-services
  Future<void> initialize() async {
    if (_isInitialized) return;

    _initializationFuture ??= () async {
      await _syncService.initialize();
      await _archiveRepository.initialize();
      await _archiveManagementService.initialize();
      _isInitialized = true;
      _logger.info('Chat management service initialized with archive support');
    }();

    try {
      await _initializationFuture;
    } catch (e) {
      // Allow callers to retry after transient failures
      _initializationFuture = null;
      _isInitialized = false;
      rethrow;
    } finally {
      if (_isInitialized) {
        _initializationFuture = null;
      }
    }
  }

  /// Get all chats with enhanced filtering and sorting
  Future<List<ChatListItem>> getAllChats({
    ChatFilter? filter,
    ChatSortOption sortBy = ChatSortOption.lastMessage,
    bool ascending = false,
  }) => _syncService.getAllChats(
    filter: filter,
    sortBy: sortBy,
    ascending: ascending,
  );

  /// Search messages across live chats
  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  }) => _syncService.searchMessages(
    query: query,
    chatId: chatId,
    filter: filter,
    limit: limit,
  );

  /// Search messages across live and archived chats
  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  }) => _syncService.searchMessagesUnified(
    query: query,
    chatId: chatId,
    filter: filter,
    includeArchives: includeArchives,
    limit: limit,
  );

  /// Star/unstar message
  Future<ChatOperationResult> toggleMessageStar(String messageId) =>
      _lifecycleService.toggleMessageStar(messageId);

  /// Get all starred messages
  Future<List<EnhancedMessage>> getStarredMessages() =>
      _lifecycleService.getStarredMessages();

  /// Delete messages with confirmation
  Future<ChatOperationResult> deleteMessages({
    required List<String> messageIds,
    bool deleteForEveryone = false,
  }) => _lifecycleService.deleteMessages(
    messageIds: messageIds,
    deleteForEveryone: deleteForEveryone,
  );

  /// Archive/unarchive chat with enhanced archive system
  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) => _lifecycleService.toggleChatArchive(
    chatId,
    reason: reason,
    useEnhancedArchive: useEnhancedArchive,
  );

  /// Pin/unpin chat
  Future<ChatOperationResult> toggleChatPin(String chatId) =>
      _lifecycleService.toggleChatPin(chatId);

  /// Delete entire chat with all messages
  Future<ChatOperationResult> deleteChat(String chatId) =>
      _lifecycleService.deleteChat(chatId);

  /// Clear all messages in chat
  Future<ChatOperationResult> clearChatMessages(String chatId) =>
      _lifecycleService.clearChatMessages(chatId);

  /// Get chat statistics and analytics
  Future<ChatAnalytics> getChatAnalytics(String chatId) =>
      _lifecycleService.getChatAnalytics(chatId);

  /// Export chat messages
  Future<ChatOperationResult> exportChat({
    required String chatId,
    ChatExportFormat format = ChatExportFormat.text,
    bool includeMetadata = false,
  }) => _lifecycleService.exportChat(
    chatId: chatId,
    format: format,
    includeMetadata: includeMetadata,
  );

  /// Get recent message search history
  List<String> getMessageSearchHistory() =>
      _syncService.getMessageSearchHistory();

  /// Clear message search history
  Future<void> clearMessageSearchHistory() =>
      _syncService.clearMessageSearchHistory();

  /// Check if chat is archived
  bool isChatArchived(String chatId) => _syncService.isChatArchived(chatId);

  /// Check if chat is pinned
  bool isChatPinned(String chatId) => _syncService.isChatPinned(chatId);

  /// Check if message is starred
  bool isMessageStarred(String messageId) =>
      _syncService.isMessageStarred(messageId);

  /// Get pinned chats count
  int get pinnedChatsCount => _syncService.pinnedChatsCount;

  /// Get archived chats count
  int get archivedChatsCount => _syncService.archivedChatsCount;

  /// Get starred messages count
  int get starredMessagesCount => _syncService.starredMessagesCount;

  /// Search across both live and archived content with advanced options
  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  }) => _syncService.performAdvancedSearch(
    query: query,
    filter: filter,
    options: options,
    includeLive: includeLive,
    includeArchives: includeArchives,
  );

  /// Get comprehensive chat analytics including archive data
  Future<ComprehensiveChatAnalytics> getComprehensiveChatAnalytics(
    String chatId,
  ) => _lifecycleService.getComprehensiveChatAnalytics(chatId);

  /// Archive multiple chats in batch
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) => _lifecycleService.batchArchiveChats(
    chatIds: chatIds,
    reason: reason,
    useEnhancedArchive: useEnhancedArchive,
  );

  /// Get archive management service for advanced operations
  ArchiveManagementService get archiveManager =>
      _lifecycleService.archiveManager;

  /// Get archive search service for advanced search
  ArchiveSearchService get archiveSearch => _archiveSearchService;

  /// Dispose of resources
  Future<void> dispose() async {
    await _notificationService.dispose();
    await _archiveManagementService.dispose();
    await _archiveSearchService.dispose();
    _archiveRepository.dispose();
    _isInitialized = false;
    _logger.info('Chat management service disposed');
  }
}
