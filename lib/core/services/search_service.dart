// Search service implementation
// Extracted from ChatManagementService (~500 LOC)

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../interfaces/i_chats_repository.dart';
import '../interfaces/i_message_repository.dart';
import '../../domain/services/archive_search_service.dart';
import '../../domain/services/chat_management_service.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/archived_message.dart';
import '../../core/models/archive_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Service for searching messages across chats and archives
class SearchService {
  static final _logger = Logger('SearchService');

  // Dependencies (optional for DI/testing)
  final IChatsRepository? _chatsRepositoryOverride;
  final IMessageRepository? _messageRepositoryOverride;
  final ArchiveSearchService? _archiveSearchServiceOverride;

  // Lazy-initialized dependencies
  late final IChatsRepository _chatsRepository;
  late final IMessageRepository _messageRepository;
  late final ArchiveSearchService _archiveSearchService;

  // Storage keys
  static const String _messageSearchHistoryKey = 'message_search_history';

  // Search history state
  final List<String> _messageSearchHistory = [];

  /// Constructor with optional dependency injection
  SearchService({
    IChatsRepository? chatsRepository,
    IMessageRepository? messageRepository,
    ArchiveSearchService? archiveSearchService,
  }) : _chatsRepositoryOverride = chatsRepository,
       _messageRepositoryOverride = messageRepository,
       _archiveSearchServiceOverride = archiveSearchService {
    _logger.info('✅ SearchService created');
  }

  /// Initialize the service
  Future<void> initialize() async {
    // Initialize dependencies (use overrides if provided, else defaults)
    _chatsRepository =
        _chatsRepositoryOverride ?? GetIt.instance<IChatsRepository>();
    _messageRepository =
        _messageRepositoryOverride ?? GetIt.instance<IMessageRepository>();
    _archiveSearchService =
        _archiveSearchServiceOverride ?? ArchiveSearchService.instance;

    // Load search history
    await _loadMessageSearchHistory();

    // Initialize archive search
    await _archiveSearchService.initialize();

    _logger.info('Search service initialized');
  }

  /// Search messages across all chats or within specific chat (backward compatible)
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

      // Add to search history
      _addToMessageSearchHistory(query);

      List<EnhancedMessage> allMessages = [];

      if (chatId != null) {
        // Search within specific chat
        final messages = await _messageRepository.getMessages(ChatId(chatId));
        allMessages = messages
            .map((m) => EnhancedMessage.fromMessage(m))
            .toList();
      } else {
        // Search across all chats
        final chats = await _chatsRepository.getAllChats();
        for (final chat in chats) {
          final messages = await _messageRepository.getMessages(chat.chatId);
          allMessages.addAll(
            messages.map((m) => EnhancedMessage.fromMessage(m)),
          );
        }
      }

      // Perform text search
      var results = _performMessageTextSearch(allMessages, query);

      // Apply additional filters
      if (filter != null) {
        results = _applyMessageSearchFilter(results, filter);
      }

      // Limit results
      if (results.length > limit) {
        results = results.take(limit).toList();
      }

      // Group by chats
      final resultsByChat = _groupResultsByChat(results);

      final searchTime = DateTime.now().difference(startTime);

      return MessageSearchResult(
        results: results,
        resultsByChat: resultsByChat,
        query: query,
        totalResults: results.length,
        searchTime: searchTime,
        hasMore: allMessages.length > limit,
      );
    } catch (e) {
      _logger.severe('❌ Message search failed: $e');
      return MessageSearchResult.empty();
    }
  }

  /// Search messages across all chats including archives
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

      // Add to search history
      _addToMessageSearchHistory(query);

      List<EnhancedMessage> liveResults = [];
      List<ArchivedMessage> archiveResults = [];

      if (chatId != null) {
        // Search within specific chat
        final messages = await _messageRepository.getMessages(ChatId(chatId));
        liveResults = messages
            .map((m) => EnhancedMessage.fromMessage(m))
            .toList();
      } else {
        // Search across all live chats
        final chats = await _chatsRepository.getAllChats();
        for (final chat in chats) {
          final messages = await _messageRepository.getMessages(chat.chatId);
          liveResults.addAll(
            messages.map((m) => EnhancedMessage.fromMessage(m)),
          );
        }
      }

      // Perform text search on live messages
      var filteredLiveResults = _performMessageTextSearch(liveResults, query);

      // Apply additional filters to live results
      if (filter != null) {
        filteredLiveResults = _applyMessageSearchFilter(
          filteredLiveResults,
          filter,
        );
      }

      // Search archives if requested
      if (includeArchives) {
        try {
          final archiveFilter = _convertToArchiveFilter(filter, chatId);
          final archiveSearchResult = await _archiveSearchService.search(
            query: query,
            filter: archiveFilter,
            limit: limit,
          );
          archiveResults = archiveSearchResult.messages;
        } catch (e) {
          _logger.warning('⚠️ Archive search failed: $e');
        }
      }

      // Combine and limit results
      final totalLiveResults = filteredLiveResults.length;
      final totalArchiveResults = archiveResults.length;
      final totalResults = totalLiveResults + totalArchiveResults;

      if (totalResults > limit) {
        // Proportionally limit results
        final liveLimit = ((totalLiveResults / totalResults) * limit).round();
        final archiveLimit = limit - liveLimit;

        if (filteredLiveResults.length > liveLimit) {
          filteredLiveResults = filteredLiveResults.take(liveLimit).toList();
        }
        if (archiveResults.length > archiveLimit) {
          archiveResults = archiveResults.take(archiveLimit).toList();
        }
      }

      // Group results by chats
      final liveResultsByChat = _groupResultsByChat(filteredLiveResults);
      final archiveResultsByChat = _groupArchiveResultsByChat(archiveResults);

      final searchTime = DateTime.now().difference(startTime);

      return UnifiedSearchResult(
        liveResults: filteredLiveResults,
        archiveResults: archiveResults,
        liveResultsByChat: liveResultsByChat,
        archiveResultsByChat: archiveResultsByChat,
        query: query,
        totalLiveResults: filteredLiveResults.length,
        totalArchiveResults: archiveResults.length,
        searchTime: searchTime,
        hasMore:
            totalResults <
            (liveResults.length + (includeArchives ? 1000 : 0)), // Estimate
        includeArchives: includeArchives,
      );
    } catch (e) {
      _logger.severe('❌ Unified message search failed: $e');
      return UnifiedSearchResult.empty();
    }
  }

  /// Search across both live and archived content with advanced options
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
        // Convert to unified search for live content
        final unifiedResult = await searchMessagesUnified(
          query: query,
          filter: _convertFromArchiveFilter(filter),
          includeArchives: false,
        );

        // Convert to AdvancedSearchResult format
        return _convertToAdvancedSearchResult(unifiedResult, query);
      } else {
        return AdvancedSearchResult.error(
          query: query,
          error: 'No search scope specified',
          searchTime: Duration.zero,
        );
      }
    } catch (e) {
      _logger.severe('❌ Advanced search failed: $e');
      return AdvancedSearchResult.error(
        query: query,
        error: 'Advanced search failed: $e',
        searchTime: Duration.zero,
      );
    }
  }

  /// Get recent message search history
  List<String> getMessageSearchHistory() {
    return List.from(_messageSearchHistory.reversed);
  }

  /// Clear message search history
  Future<void> clearMessageSearchHistory() async {
    _messageSearchHistory.clear();
    await _saveMessageSearchHistory();
  }

  // Private helper methods

  /// Perform text search on messages
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

  /// Apply additional search filters
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

  /// Group search results by chat
  Map<String, List<EnhancedMessage>> _groupResultsByChat(
    List<EnhancedMessage> results,
  ) {
    final grouped = <String, List<EnhancedMessage>>{};

    for (final message in results) {
      grouped.putIfAbsent(message.chatId.value, () => []).add(message);
    }

    return grouped;
  }

  /// Group archive results by chat
  Map<String, List<ArchivedMessage>> _groupArchiveResultsByChat(
    List<ArchivedMessage> results,
  ) {
    final grouped = <String, List<ArchivedMessage>>{};

    for (final message in results) {
      grouped.putIfAbsent(message.chatId.value, () => []).add(message);
    }

    return grouped;
  }

  /// Convert MessageSearchFilter to ArchiveSearchFilter
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

  /// Convert ArchiveSearchFilter to MessageSearchFilter
  MessageSearchFilter? _convertFromArchiveFilter(ArchiveSearchFilter? filter) {
    if (filter == null) return null;

    return MessageSearchFilter(
      fromMe: filter.messageTypeFilter?.isFromMe,
      hasAttachments: filter.messageTypeFilter?.hasAttachments,
      dateRange: filter.dateRange != null
          ? DateTimeRange(
              start: filter.dateRange!.start,
              end: filter.dateRange!.end,
            )
          : null,
    );
  }

  /// Convert UnifiedSearchResult to AdvancedSearchResult
  AdvancedSearchResult _convertToAdvancedSearchResult(
    UnifiedSearchResult legacyResult,
    String query,
  ) {
    // Convert unified result to advanced result format
    final archiveResult = ArchiveSearchResult.fromResults(
      messages: legacyResult.archiveResults,
      chats: [], // Would need to populate from archive data
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

  /// Add to message search history
  void _addToMessageSearchHistory(String query) {
    _messageSearchHistory.remove(query); // Remove if already exists
    _messageSearchHistory.add(query);

    // Keep only last 10 searches
    if (_messageSearchHistory.length > 10) {
      _messageSearchHistory.removeAt(0);
    }

    _saveMessageSearchHistory();
  }

  /// Save message search history to storage
  Future<void> _saveMessageSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _messageSearchHistoryKey,
        _messageSearchHistory,
      );
    } catch (e) {
      _logger.warning('⚠️ Failed to save search history: $e');
    }
  }

  /// Load message search history from storage
  Future<void> _loadMessageSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final searchHistory = prefs.getStringList(_messageSearchHistoryKey) ?? [];
      _messageSearchHistory.clear();
      _messageSearchHistory.addAll(searchHistory);
    } catch (e) {
      _logger.warning('⚠️ Failed to load search history: $e');
    }
  }

  /// Dispose of resources
  Future<void> dispose() async {
    await _archiveSearchService.dispose();
    _logger.info('Search service disposed');
  }
}
