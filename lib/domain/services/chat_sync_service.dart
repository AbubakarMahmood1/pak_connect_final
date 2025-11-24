import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../entities/chat_list_item.dart';
import '../entities/enhanced_message.dart';
import '../entities/archived_message.dart';
import '../../core/models/archive_models.dart';
import 'archive_search_service.dart';
import 'chat_management_models.dart';

/// Handles cache persistence, search, and sync-related chat workflows
class ChatSyncService {
  static const String _starredMessagesKey = 'starred_messages';
  static const String _archivedChatsKey = 'archived_chats';
  static const String _pinnedChatsKey = 'pinned_chats';
  static const String _messageSearchHistoryKey = 'message_search_history';

  final _logger = Logger('ChatSyncService');

  final ChatsRepository _chatsRepository;
  final MessageRepository _messageRepository;
  final ArchiveSearchService _archiveSearchService;
  final ChatCacheState _cacheState;

  bool _isInitialized = false;

  ChatSyncService({
    required ChatsRepository chatsRepository,
    required MessageRepository messageRepository,
    required ChatCacheState cacheState,
    ArchiveSearchService? archiveSearchService,
  }) : _chatsRepository = chatsRepository,
       _messageRepository = messageRepository,
       _archiveSearchService =
           archiveSearchService ?? ArchiveSearchService.instance,
       _cacheState = cacheState;

  Future<void> initialize() async {
    if (_isInitialized) return;

    await _loadCachedData();
    await _archiveSearchService.initialize();

    _isInitialized = true;
    _logger.info('ChatSyncService initialized');
  }

  Set<String> get pinnedChats => _cacheState.pinnedChats;
  Set<String> get archivedChats => _cacheState.archivedChats;
  Set<String> get starredMessages => _cacheState.starredMessageIds;

  int get pinnedChatsCount => _cacheState.pinnedChats.length;
  int get archivedChatsCount => _cacheState.archivedChats.length;
  int get starredMessagesCount => _cacheState.starredMessageIds.length;

  bool isChatPinned(String chatId) => _cacheState.pinnedChats.contains(chatId);
  bool isChatArchived(String chatId) =>
      _cacheState.archivedChats.contains(chatId);
  bool isMessageStarred(String messageId) =>
      _cacheState.starredMessageIds.contains(messageId);

  Future<List<ChatListItem>> getAllChats({
    ChatFilter? filter,
    ChatSortOption sortBy = ChatSortOption.lastMessage,
    bool ascending = false,
  }) async {
    try {
      var chats = await _chatsRepository.getAllChats();

      if (filter != null) {
        chats = await _applyFilters(chats, filter);
      }

      chats = _sortChats(chats, sortBy, ascending);
      return chats;
    } catch (e) {
      _logger.severe('Failed to get chats: $e');
      return [];
    }
  }

  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  }) async {
    try {
      final startTime = DateTime.now();

      if (query.trim().isEmpty) {
        return MessageSearchResult.empty();
      }

      _addToMessageSearchHistory(query);

      List<EnhancedMessage> allMessages = [];

      if (chatId != null) {
        final messages = await _messageRepository.getMessages(chatId);
        allMessages = messages
            .map((m) => EnhancedMessage.fromMessage(m))
            .toList();
      } else {
        final chats = await _chatsRepository.getAllChats();
        for (final chat in chats) {
          final messages = await _messageRepository.getMessages(chat.chatId);
          allMessages.addAll(
            messages.map((m) => EnhancedMessage.fromMessage(m)),
          );
        }
      }

      var results = _performMessageTextSearch(allMessages, query);

      if (filter != null) {
        results = _applyMessageSearchFilter(results, filter);
      }

      final totalMatched = results.length;
      if (results.length > limit) {
        results = results.take(limit).toList();
      }

      final resultsByChat = _groupResultsByChat(results);
      final searchTime = DateTime.now().difference(startTime);

      return MessageSearchResult(
        results: results,
        resultsByChat: resultsByChat,
        query: query,
        totalResults: results.length,
        searchTime: searchTime,
        hasMore: totalMatched > limit,
      );
    } catch (e) {
      _logger.severe('Unified message search failed: $e');
      return MessageSearchResult.empty();
    }
  }

  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  }) async {
    try {
      final startTime = DateTime.now();

      if (query.trim().isEmpty) {
        return UnifiedSearchResult.empty();
      }

      _addToMessageSearchHistory(query);

      List<EnhancedMessage> liveResults = [];
      List<ArchivedMessage> archiveResults = [];

      if (chatId != null) {
        final messages = await _messageRepository.getMessages(chatId);
        liveResults = messages
            .map((m) => EnhancedMessage.fromMessage(m))
            .toList();
      } else {
        final chats = await _chatsRepository.getAllChats();
        for (final chat in chats) {
          final messages = await _messageRepository.getMessages(chat.chatId);
          liveResults.addAll(
            messages.map((m) => EnhancedMessage.fromMessage(m)),
          );
        }
      }

      var filteredLiveResults = _performMessageTextSearch(liveResults, query);

      if (filter != null) {
        filteredLiveResults = _applyMessageSearchFilter(
          filteredLiveResults,
          filter,
        );
      }

      bool archiveHasMore = false;
      if (includeArchives) {
        try {
          final archiveFilter = _convertToArchiveFilter(filter, chatId);
          final archiveSearchResult = await _archiveSearchService.search(
            query: query,
            filter: archiveFilter,
            limit: limit,
          );
          archiveResults = archiveSearchResult.messages;
          archiveHasMore = archiveSearchResult.searchResult.hasMore;
        } catch (e) {
          _logger.warning('Archive search failed: $e');
        }
      }

      final totalLiveResults = filteredLiveResults.length;
      final totalArchiveResults = archiveResults.length;
      final totalResults = totalLiveResults + totalArchiveResults;

      var limitedLiveResults = filteredLiveResults;
      var limitedArchiveResults = archiveResults;

      if (totalResults > limit) {
        final liveLimit = ((totalLiveResults / totalResults) * limit).round();
        final archiveLimit = limit - liveLimit;

        if (limitedLiveResults.length > liveLimit) {
          limitedLiveResults = limitedLiveResults.take(liveLimit).toList();
        }
        if (limitedArchiveResults.length > archiveLimit) {
          limitedArchiveResults = limitedArchiveResults
              .take(archiveLimit)
              .toList();
        }
      }

      final liveResultsByChat = _groupResultsByChat(limitedLiveResults);
      final archiveResultsByChat = _groupArchiveResultsByChat(
        limitedArchiveResults,
      );

      final searchTime = DateTime.now().difference(startTime);

      final liveTrimmed = totalLiveResults > limitedLiveResults.length;
      final archiveTrimmed = totalArchiveResults > limitedArchiveResults.length;
      final hasMore = liveTrimmed || archiveTrimmed || archiveHasMore;

      return UnifiedSearchResult(
        liveResults: limitedLiveResults,
        archiveResults: limitedArchiveResults,
        liveResultsByChat: liveResultsByChat,
        archiveResultsByChat: archiveResultsByChat,
        query: query,
        totalLiveResults: limitedLiveResults.length,
        totalArchiveResults: limitedArchiveResults.length,
        searchTime: searchTime,
        hasMore: hasMore,
        includeArchives: includeArchives,
      );
    } catch (e) {
      _logger.severe('Unified message search failed: $e');
      return UnifiedSearchResult.empty();
    }
  }

  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  }) async {
    try {
      if (includeArchives) {
        return await _archiveSearchService.search(
          query: query,
          filter: filter,
          options: options,
        );
      } else if (includeLive) {
        final unifiedResult = await searchMessagesUnified(
          query: query,
          filter: _convertFromArchiveFilter(filter),
          includeArchives: false,
        );

        return _convertToAdvancedSearchResult(unifiedResult, query);
      } else {
        return AdvancedSearchResult.error(
          query: query,
          error: 'No search scope specified',
          searchTime: Duration.zero,
        );
      }
    } catch (e) {
      _logger.severe('Advanced search failed: $e');
      return AdvancedSearchResult.error(
        query: query,
        error: 'Advanced search failed: $e',
        searchTime: Duration.zero,
      );
    }
  }

  List<String> getMessageSearchHistory() =>
      List.from(_cacheState.messageSearchHistory.reversed);

  Future<void> clearMessageSearchHistory() async {
    _cacheState.messageSearchHistory.clear();
    await _saveMessageSearchHistory();
  }

  Future<void> saveStarredMessages() => _saveStarredMessages();
  Future<void> saveArchivedChats() => _saveArchivedChats();
  Future<void> savePinnedChats() => _savePinnedChats();
  Future<void> saveMessageSearchHistory() => _saveMessageSearchHistory();

  // Helpers

  void _addToMessageSearchHistory(String query) {
    _cacheState.messageSearchHistory.remove(query);
    _cacheState.messageSearchHistory.add(query);

    if (_cacheState.messageSearchHistory.length > 10) {
      _cacheState.messageSearchHistory.removeAt(0);
    }

    _saveMessageSearchHistory();
  }

  Future<List<ChatListItem>> _applyFilters(
    List<ChatListItem> chats,
    ChatFilter filter,
  ) async {
    var filteredChats = chats;

    if (filter.hideArchived && !filter.onlyArchived) {
      filteredChats = filteredChats
          .where((chat) => !_cacheState.archivedChats.contains(chat.chatId))
          .toList();
    } else if (filter.onlyArchived) {
      filteredChats = filteredChats
          .where((chat) => _cacheState.archivedChats.contains(chat.chatId))
          .toList();
    }

    if (filter.onlyPinned) {
      filteredChats = filteredChats
          .where((chat) => _cacheState.pinnedChats.contains(chat.chatId))
          .toList();
    }

    if (filter.onlyUnread) {
      filteredChats = filteredChats
          .where((chat) => chat.unreadCount > 0)
          .toList();
    }

    if (filter.hasUnsentMessages != null) {
      filteredChats = filteredChats
          .where((chat) => chat.hasUnsentMessages == filter.hasUnsentMessages)
          .toList();
    }

    return filteredChats;
  }

  List<ChatListItem> _sortChats(
    List<ChatListItem> chats,
    ChatSortOption sortBy,
    bool ascending,
  ) {
    chats.sort((a, b) {
      int comparison;

      if (sortBy != ChatSortOption.name) {
        final aPinned = _cacheState.pinnedChats.contains(a.chatId);
        final bPinned = _cacheState.pinnedChats.contains(b.chatId);

        if (aPinned && !bPinned) return -1;
        if (!aPinned && bPinned) return 1;
      }

      switch (sortBy) {
        case ChatSortOption.name:
          comparison = a.contactName.compareTo(b.contactName);
          break;
        case ChatSortOption.lastMessage:
          final aTime =
              a.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime =
              b.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          comparison = aTime.compareTo(bTime);
          break;
        case ChatSortOption.unreadCount:
          comparison = a.unreadCount.compareTo(b.unreadCount);
          break;
      }

      return ascending ? comparison : -comparison;
    });

    return chats;
  }

  List<EnhancedMessage> _performMessageTextSearch(
    List<EnhancedMessage> messages,
    String query,
  ) {
    final searchTerms = query
        .toLowerCase()
        .split(' ')
        .where((term) => term.isNotEmpty)
        .toList();

    return messages.where((message) {
      final searchableText = message.content.toLowerCase();
      return searchTerms.every((term) => searchableText.contains(term));
    }).toList();
  }

  List<EnhancedMessage> _applyMessageSearchFilter(
    List<EnhancedMessage> messages,
    MessageSearchFilter filter,
  ) {
    return messages.where((message) {
      if (filter.fromMe != null && message.isFromMe != filter.fromMe) {
        return false;
      }

      if (filter.hasAttachments != null &&
          message.attachments.isNotEmpty != filter.hasAttachments) {
        return false;
      }

      if (filter.isStarred != null &&
          _cacheState.starredMessageIds.contains(message.id) !=
              filter.isStarred) {
        return false;
      }

      if (filter.dateRange != null) {
        final messageDate = message.timestamp;
        if (messageDate.isBefore(filter.dateRange!.start) ||
            messageDate.isAfter(filter.dateRange!.end)) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  Map<String, List<EnhancedMessage>> _groupResultsByChat(
    List<EnhancedMessage> results,
  ) {
    final grouped = <String, List<EnhancedMessage>>{};

    for (final message in results) {
      grouped.putIfAbsent(message.chatId, () => []).add(message);
    }

    return grouped;
  }

  Map<String, List<ArchivedMessage>> _groupArchiveResultsByChat(
    List<ArchivedMessage> results,
  ) {
    final grouped = <String, List<ArchivedMessage>>{};

    for (final message in results) {
      grouped.putIfAbsent(message.chatId, () => []).add(message);
    }

    return grouped;
  }

  AdvancedSearchResult _convertToAdvancedSearchResult(
    UnifiedSearchResult legacyResult,
    String query,
  ) {
    final archiveResult = ArchiveSearchResult.fromResults(
      messages: legacyResult.archiveResults,
      chats: [],
      query: query,
      searchTime: legacyResult.searchTime,
    );

    return AdvancedSearchResult.fromSearchResult(
      searchResult: archiveResult,
      query: query,
      searchTime: legacyResult.searchTime,
      suggestions: [],
    );
  }

  ArchiveSearchFilter? _convertToArchiveFilter(
    MessageSearchFilter? filter,
    String? chatId,
  ) {
    if (filter == null && chatId == null) return null;

    return ArchiveSearchFilter(
      contactFilter: chatId,
      messageTypeFilter: filter != null
          ? ArchiveMessageTypeFilter(
              isFromMe: filter.fromMe,
              hasAttachments: filter.hasAttachments,
              wasStarred: filter.isStarred,
            )
          : null,
      dateRange: filter?.dateRange != null
          ? ArchiveDateRange(
              start: filter!.dateRange!.start,
              end: filter.dateRange!.end,
            )
          : null,
    );
  }

  MessageSearchFilter? _convertFromArchiveFilter(ArchiveSearchFilter? filter) {
    if (filter == null) return null;

    return MessageSearchFilter(
      fromMe: filter.messageTypeFilter?.isFromMe,
      hasAttachments: filter.messageTypeFilter?.hasAttachments,
      isStarred: filter.messageTypeFilter?.wasStarred,
      dateRange: filter.dateRange != null
          ? DateTimeRange(
              start: filter.dateRange!.start,
              end: filter.dateRange!.end,
            )
          : null,
    );
  }

  Future<void> _loadCachedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final starredList = prefs.getStringList(_starredMessagesKey) ?? [];
      _cacheState.starredMessageIds
        ..clear()
        ..addAll(starredList);

      final archivedList = prefs.getStringList(_archivedChatsKey) ?? [];
      _cacheState.archivedChats
        ..clear()
        ..addAll(archivedList);

      final pinnedList = prefs.getStringList(_pinnedChatsKey) ?? [];
      _cacheState.pinnedChats
        ..clear()
        ..addAll(pinnedList);

      final searchHistory = prefs.getStringList(_messageSearchHistoryKey) ?? [];
      _cacheState.messageSearchHistory
        ..clear()
        ..addAll(searchHistory);
    } catch (e) {
      _logger.warning('Failed to load cached data: $e');
    }
  }

  Future<void> _saveStarredMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _starredMessagesKey,
        _cacheState.starredMessageIds.toList(),
      );
    } catch (e) {
      _logger.warning('Failed to save starred messages: $e');
    }
  }

  Future<void> _saveArchivedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _archivedChatsKey,
        _cacheState.archivedChats.toList(),
      );
    } catch (e) {
      _logger.warning('Failed to save archived chats: $e');
    }
  }

  Future<void> _savePinnedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _pinnedChatsKey,
        _cacheState.pinnedChats.toList(),
      );
    } catch (e) {
      _logger.warning('Failed to save pinned chats: $e');
    }
  }

  Future<void> _saveMessageSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _messageSearchHistoryKey,
        _cacheState.messageSearchHistory,
      );
    } catch (e) {
      _logger.warning('Failed to save search history: $e');
    }
  }
}
