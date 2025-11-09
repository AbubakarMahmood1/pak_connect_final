// WhatsApp-inspired chat management system with comprehensive message operations and archive integration

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/archive_repository.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../core/models/archive_models.dart';
import 'archive_management_service.dart';
import 'archive_search_service.dart';

/// Comprehensive chat management service with WhatsApp-inspired features
/// Singleton pattern to prevent multiple service instances
class ChatManagementService {
  static final _logger = Logger('ChatManagementService');

  // Singleton instance
  static ChatManagementService? _instance;

  /// Get the singleton instance
  static ChatManagementService get instance {
    _instance ??= ChatManagementService._internal();
    return _instance!;
  }

  /// Private constructor for singleton
  ChatManagementService._internal()
    : _chatsRepository = ChatsRepository(),
      _messageRepository = MessageRepository(),
      _archiveRepository = ArchiveRepository.instance,
      _archiveManagementService = ArchiveManagementService.instance,
      _archiveSearchService = ArchiveSearchService.instance {
    _logger.info('✅ ChatManagementService singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ChatManagementService() => instance;

  // Dependencies - use singleton instances where available
  final ChatsRepository _chatsRepository;
  final MessageRepository _messageRepository;
  final ArchiveRepository _archiveRepository;
  final ArchiveManagementService _archiveManagementService;
  final ArchiveSearchService _archiveSearchService;

  static const String _starredMessagesKey = 'starred_messages';
  static const String _archivedChatsKey = 'archived_chats';
  static const String _pinnedChatsKey = 'pinned_chats';
  static const String _messageSearchHistoryKey = 'message_search_history';

  // In-memory caches for performance
  final Set<String> _starredMessageIds = {};
  final Set<String> _archivedChats = {};
  final Set<String> _pinnedChats = {};
  final List<String> _messageSearchHistory = [];

  // Stream controllers for real-time updates
  final _chatUpdatesController = StreamController<ChatUpdateEvent>.broadcast();
  final _messageUpdatesController =
      StreamController<MessageUpdateEvent>.broadcast();

  /// Stream of chat updates
  Stream<ChatUpdateEvent> get chatUpdates => _chatUpdatesController.stream;

  /// Stream of message updates
  Stream<MessageUpdateEvent> get messageUpdates =>
      _messageUpdatesController.stream;

  /// Initialize chat management service
  Future<void> initialize() async {
    await _loadCachedData();

    // Initialize archive services
    await _archiveRepository.initialize();
    await _archiveManagementService.initialize();
    await _archiveSearchService.initialize();

    _logger.info('Chat management service initialized with archive support');
  }

  /// Get all chats with enhanced filtering and sorting
  Future<List<ChatListItem>> getAllChats({
    ChatFilter? filter,
    ChatSortOption sortBy = ChatSortOption.lastMessage,
    bool ascending = false,
  }) async {
    try {
      var chats = await _chatsRepository.getAllChats();

      // Apply filters
      if (filter != null) {
        chats = await _applyFilters(chats, filter);
      }

      // Apply sorting
      chats = _sortChats(chats, sortBy, ascending);

      return chats;
    } catch (e) {
      _logger.severe('Failed to get chats: $e');
      return [];
    }
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
        final messages = await _messageRepository.getMessages(chatId);
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
      _logger.severe('Unified message search failed: $e');
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
        final messages = await _messageRepository.getMessages(chatId);
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
          _logger.warning('Archive search failed: $e');
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
      _logger.severe('Unified message search failed: $e');
      return UnifiedSearchResult.empty();
    }
  }

  /// Star/unstar message
  Future<ChatOperationResult> toggleMessageStar(String messageId) async {
    try {
      if (_starredMessageIds.contains(messageId)) {
        _starredMessageIds.remove(messageId);
        await _saveStarredMessages();
        _messageUpdatesController.add(MessageUpdateEvent.unstarred(messageId));
        return ChatOperationResult.success('Message unstarred');
      } else {
        _starredMessageIds.add(messageId);
        await _saveStarredMessages();
        _messageUpdatesController.add(MessageUpdateEvent.starred(messageId));
        return ChatOperationResult.success('Message starred');
      }
    } catch (e) {
      return ChatOperationResult.failure('Failed to update star status: $e');
    }
  }

  /// Get all starred messages
  Future<List<EnhancedMessage>> getStarredMessages() async {
    try {
      final allChats = await _chatsRepository.getAllChats();
      final List<EnhancedMessage> starredMessages = [];

      for (final chat in allChats) {
        final messages = await _messageRepository.getMessages(chat.chatId);
        for (final message in messages) {
          if (_starredMessageIds.contains(message.id)) {
            final enhanced = EnhancedMessage.fromMessage(
              message,
            ).copyWith(isStarred: true);
            starredMessages.add(enhanced);
          }
        }
      }

      // Sort by timestamp (newest first)
      starredMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return starredMessages;
    } catch (e) {
      _logger.severe('Failed to get starred messages: $e');
      return [];
    }
  }

  /// Delete messages with confirmation
  Future<ChatOperationResult> deleteMessages({
    required List<String> messageIds,
    bool deleteForEveryone = false,
  }) async {
    try {
      int successCount = 0;
      int failureCount = 0;

      for (final messageId in messageIds) {
        try {
          // Find and delete message
          final chats = await _chatsRepository.getAllChats();
          bool found = false;

          for (final chat in chats) {
            final messages = await _messageRepository.getMessages(chat.chatId);
            final messageIndex = messages.indexWhere((m) => m.id == messageId);

            if (messageIndex != -1) {
              found = true;
              // Note: This would require implementing deleteMessage in MessageRepository
              await _deleteMessageFromRepository(messageId, chat.chatId);

              // Remove from starred if applicable
              _starredMessageIds.remove(messageId);

              _messageUpdatesController.add(
                MessageUpdateEvent.deleted(messageId, chat.chatId),
              );
              successCount++;
              break;
            }
          }

          if (!found) {
            failureCount++;
          }
        } catch (e) {
          _logger.warning('Failed to delete message $messageId: $e');
          failureCount++;
        }
      }

      if (successCount > 0) {
        await _saveStarredMessages();
      }

      if (failureCount == 0) {
        return ChatOperationResult.success(
          '$successCount message${successCount > 1 ? 's' : ''} deleted',
        );
      } else {
        return ChatOperationResult.partial(
          '$successCount deleted, $failureCount failed',
        );
      }
    } catch (e) {
      return ChatOperationResult.failure('Delete operation failed: $e');
    }
  }

  /// Archive/unarchive chat with enhanced archive system
  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    try {
      if (_archivedChats.contains(chatId)) {
        // Unarchive (restore if enhanced)
        if (useEnhancedArchive) {
          // Find archive by original chat ID
          final archives = await _archiveRepository.getArchivedChats(
            filter: ArchiveSearchFilter(contactFilter: chatId),
          );

          if (archives.isNotEmpty) {
            final archiveToRestore = archives.first;
            final restoreResult = await _archiveManagementService.restoreChat(
              archiveId: archiveToRestore.id,
            );

            if (restoreResult.success) {
              _archivedChats.remove(chatId);
              await _saveArchivedChats();
              _chatUpdatesController.add(ChatUpdateEvent.unarchived(chatId));
              return ChatOperationResult.success(
                'Chat restored from enhanced archive',
              );
            } else {
              return ChatOperationResult.failure(
                'Failed to restore enhanced archive: ${restoreResult.message}',
              );
            }
          }
        }

        // Fallback to simple unarchive
        _archivedChats.remove(chatId);
        await _saveArchivedChats();
        _chatUpdatesController.add(ChatUpdateEvent.unarchived(chatId));
        return ChatOperationResult.success('Chat unarchived');
      } else {
        // Archive with enhanced system
        if (useEnhancedArchive) {
          final archiveResult = await _archiveManagementService.archiveChat(
            chatId: chatId,
            reason: reason ?? 'User archived via chat management',
          );

          if (archiveResult.success) {
            _archivedChats.add(chatId);
            await _saveArchivedChats();
            _chatUpdatesController.add(ChatUpdateEvent.archived(chatId));
            return ChatOperationResult.success(
              'Chat archived with enhanced system',
            );
          } else {
            return ChatOperationResult.failure(
              'Enhanced archive failed: ${archiveResult.message}',
            );
          }
        } else {
          // Simple archive
          _archivedChats.add(chatId);
          await _saveArchivedChats();
          _chatUpdatesController.add(ChatUpdateEvent.archived(chatId));
          return ChatOperationResult.success('Chat archived');
        }
      }
    } catch (e) {
      return ChatOperationResult.failure('Failed to toggle archive: $e');
    }
  }

  /// Pin/unpin chat
  Future<ChatOperationResult> toggleChatPin(String chatId) async {
    try {
      if (_pinnedChats.contains(chatId)) {
        _pinnedChats.remove(chatId);
        await _savePinnedChats();
        _chatUpdatesController.add(ChatUpdateEvent.unpinned(chatId));
        return ChatOperationResult.success('Chat unpinned');
      } else {
        // Limit pinned chats (WhatsApp allows 3)
        if (_pinnedChats.length >= 3) {
          return ChatOperationResult.failure('Maximum 3 chats can be pinned');
        }
        _pinnedChats.add(chatId);
        await _savePinnedChats();
        _chatUpdatesController.add(ChatUpdateEvent.pinned(chatId));
        return ChatOperationResult.success('Chat pinned');
      }
    } catch (e) {
      return ChatOperationResult.failure('Failed to toggle pin: $e');
    }
  }

  /// Delete entire chat with all messages
  Future<ChatOperationResult> deleteChat(String chatId) async {
    try {
      // Clear all messages
      await _messageRepository.clearMessages(chatId);

      // Remove from archived/pinned if applicable
      _archivedChats.remove(chatId);
      _pinnedChats.remove(chatId);

      // Remove starred messages from this chat
      final chatMessages = await _messageRepository.getMessages(chatId);
      for (final message in chatMessages) {
        _starredMessageIds.remove(message.id);
      }

      await _saveArchivedChats();
      await _savePinnedChats();
      await _saveStarredMessages();

      _chatUpdatesController.add(ChatUpdateEvent.deleted(chatId));

      return ChatOperationResult.success('Chat deleted');
    } catch (e) {
      return ChatOperationResult.failure('Failed to delete chat: $e');
    }
  }

  /// Clear all messages in chat
  Future<ChatOperationResult> clearChatMessages(String chatId) async {
    try {
      // Remove starred messages from this chat
      final chatMessages = await _messageRepository.getMessages(chatId);
      for (final message in chatMessages) {
        _starredMessageIds.remove(message.id);
      }

      await _messageRepository.clearMessages(chatId);
      await _saveStarredMessages();

      _chatUpdatesController.add(ChatUpdateEvent.messagesCleared(chatId));

      return ChatOperationResult.success('Chat messages cleared');
    } catch (e) {
      return ChatOperationResult.failure('Failed to clear messages: $e');
    }
  }

  /// Get chat statistics and analytics
  Future<ChatAnalytics> getChatAnalytics(String chatId) async {
    try {
      final messages = await _messageRepository.getMessages(chatId);
      final enhancedMessages = messages
          .map((m) => EnhancedMessage.fromMessage(m))
          .toList();

      final totalMessages = enhancedMessages.length;
      final myMessages = enhancedMessages.where((m) => m.isFromMe).length;
      final theirMessages = totalMessages - myMessages;
      final starredCount = enhancedMessages
          .where((m) => _starredMessageIds.contains(m.id))
          .length;

      final firstMessage = enhancedMessages.isNotEmpty
          ? enhancedMessages.reduce(
              (a, b) => a.timestamp.isBefore(b.timestamp) ? a : b,
            )
          : null;

      final lastMessage = enhancedMessages.isNotEmpty
          ? enhancedMessages.reduce(
              (a, b) => a.timestamp.isAfter(b.timestamp) ? a : b,
            )
          : null;

      final averageMessageLength = enhancedMessages.isNotEmpty
          ? enhancedMessages
                    .map((m) => m.content.length)
                    .reduce((a, b) => a + b) /
                enhancedMessages.length
          : 0.0;

      final messagesByDay = _groupMessagesByDay(enhancedMessages);
      final busiestDay = messagesByDay.entries.isNotEmpty
          ? messagesByDay.entries.reduce((a, b) => a.value > b.value ? a : b)
          : null;

      return ChatAnalytics(
        chatId: chatId,
        totalMessages: totalMessages,
        myMessages: myMessages,
        theirMessages: theirMessages,
        starredMessages: starredCount,
        firstMessage: firstMessage?.timestamp,
        lastMessage: lastMessage?.timestamp,
        averageMessageLength: averageMessageLength,
        messagesByDay: messagesByDay,
        busiestDay: busiestDay?.key,
        busiestDayCount: busiestDay?.value ?? 0,
      );
    } catch (e) {
      _logger.severe('Failed to get chat analytics: $e');
      return ChatAnalytics.empty(chatId);
    }
  }

  /// Export chat messages
  Future<ChatOperationResult> exportChat({
    required String chatId,
    ChatExportFormat format = ChatExportFormat.text,
    bool includeMetadata = false,
  }) async {
    try {
      final messages = await _messageRepository.getMessages(chatId);
      final chat = (await _chatsRepository.getAllChats())
          .where((c) => c.chatId == chatId)
          .firstOrNull;

      if (chat == null) {
        return ChatOperationResult.failure('Chat not found');
      }

      String exportData;
      switch (format) {
        case ChatExportFormat.text:
          exportData = _exportChatAsText(messages, chat, includeMetadata);
          break;
        case ChatExportFormat.json:
          exportData = _exportChatAsJson(messages, chat, includeMetadata);
          break;
        case ChatExportFormat.csv:
          exportData = _exportChatAsCsv(messages, chat, includeMetadata);
          break;
      }

      // Save exported data to local storage
      await _saveExportedData(exportData, format, chatId);
      _logger.info(
        'Exported chat ${chat.contactName} (${messages.length} messages) as ${format.name}',
      );
      return ChatOperationResult.success(
        'Chat exported successfully to local storage',
      );
    } catch (e) {
      return ChatOperationResult.failure('Export failed: $e');
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

  /// Check if chat is archived
  bool isChatArchived(String chatId) => _archivedChats.contains(chatId);

  /// Check if chat is pinned
  bool isChatPinned(String chatId) => _pinnedChats.contains(chatId);

  /// Check if message is starred
  bool isMessageStarred(String messageId) =>
      _starredMessageIds.contains(messageId);

  /// Get pinned chats count
  int get pinnedChatsCount => _pinnedChats.length;

  /// Get archived chats count
  int get archivedChatsCount => _archivedChats.length;

  /// Get starred messages count
  int get starredMessagesCount => _starredMessageIds.length;

  // Private methods

  /// Apply filters to chat list
  Future<List<ChatListItem>> _applyFilters(
    List<ChatListItem> chats,
    ChatFilter filter,
  ) async {
    var filteredChats = chats;

    if (filter.hideArchived && !filter.onlyArchived) {
      filteredChats = filteredChats
          .where((chat) => !_archivedChats.contains(chat.chatId))
          .toList();
    } else if (filter.onlyArchived) {
      filteredChats = filteredChats
          .where((chat) => _archivedChats.contains(chat.chatId))
          .toList();
    }

    if (filter.onlyPinned) {
      filteredChats = filteredChats
          .where((chat) => _pinnedChats.contains(chat.chatId))
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

  /// Sort chats by specified criteria
  List<ChatListItem> _sortChats(
    List<ChatListItem> chats,
    ChatSortOption sortBy,
    bool ascending,
  ) {
    chats.sort((a, b) {
      int comparison;

      // Always prioritize pinned chats at the top (unless specifically sorted differently)
      if (sortBy != ChatSortOption.name) {
        final aPinned = _pinnedChats.contains(a.chatId);
        final bPinned = _pinnedChats.contains(b.chatId);

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

      if (filter.isStarred != null &&
          _starredMessageIds.contains(message.id) != filter.isStarred) {
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
      grouped.putIfAbsent(message.chatId, () => []).add(message);
    }

    return grouped;
  }

  /// Group messages by day for analytics
  Map<DateTime, int> _groupMessagesByDay(List<EnhancedMessage> messages) {
    final grouped = <DateTime, int>{};

    for (final message in messages) {
      final day = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      grouped[day] = (grouped[day] ?? 0) + 1;
    }

    return grouped;
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

  /// Export chat as text format
  String _exportChatAsText(
    List<Message> messages,
    ChatListItem chat,
    bool includeMetadata,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('Chat Export: ${chat.contactName}');
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Messages: ${messages.length}');
    buffer.writeln('=' * 50);
    buffer.writeln();

    for (final message in messages) {
      final timestamp = message.timestamp.toLocal();
      final sender = message.isFromMe ? 'You' : chat.contactName;

      buffer.writeln('[${timestamp.toString().split('.')[0]}] $sender:');
      buffer.writeln(message.content);

      if (includeMetadata) {
        buffer.writeln('  Status: ${message.status.name}');
        if (_starredMessageIds.contains(message.id)) {
          buffer.writeln('  ⭐ Starred');
        }
      }

      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Export chat as JSON format
  String _exportChatAsJson(
    List<Message> messages,
    ChatListItem chat,
    bool includeMetadata,
  ) {
    final exportData = {
      'chat_info': {
        'contact_name': chat.contactName,
        'chat_id': chat.chatId,
        'export_timestamp': DateTime.now().toIso8601String(),
        'message_count': messages.length,
      },
      'messages': messages.map((message) {
        final data = message.toJson();
        if (includeMetadata) {
          data['is_starred'] = _starredMessageIds.contains(message.id);
        }
        return data;
      }).toList(),
    };

    return jsonEncode(exportData);
  }

  /// Export chat as CSV format
  String _exportChatAsCsv(
    List<Message> messages,
    ChatListItem chat,
    bool includeMetadata,
  ) {
    final csvLines = <String>[];

    // Header
    var header = ['Timestamp', 'Sender', 'Message', 'Status'];
    if (includeMetadata) {
      header.add('Starred');
    }
    csvLines.add(header.map((field) => '"$field"').join(','));

    // Data rows
    for (final message in messages) {
      final timestamp = message.timestamp.toIso8601String();
      final sender = message.isFromMe ? 'You' : chat.contactName;
      final content = message.content.replaceAll('"', '""'); // Escape quotes
      final status = message.status.name;

      var row = [timestamp, sender, content, status];
      if (includeMetadata) {
        row.add(_starredMessageIds.contains(message.id) ? 'Yes' : 'No');
      }

      csvLines.add(row.map((field) => '"$field"').join(','));
    }

    return csvLines.join('\n');
  }

  /// Delete message from repository
  Future<void> _deleteMessageFromRepository(
    String messageId,
    String chatId,
  ) async {
    try {
      final success = await _messageRepository.deleteMessage(messageId);
      if (success) {
        _logger.info('Successfully deleted message: $messageId from $chatId');
      } else {
        _logger.warning('Failed to delete message - not found: $messageId');
        throw Exception('Message not found');
      }
    } catch (e) {
      _logger.severe('Error deleting message: $e');
      throw Exception('Failed to delete message: $e');
    }
  }

  /// Load cached data from storage
  Future<void> _loadCachedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load starred messages
      final starredList = prefs.getStringList(_starredMessagesKey) ?? [];
      _starredMessageIds.clear();
      _starredMessageIds.addAll(starredList);

      // Load archived chats
      final archivedList = prefs.getStringList(_archivedChatsKey) ?? [];
      _archivedChats.clear();
      _archivedChats.addAll(archivedList);

      // Load pinned chats
      final pinnedList = prefs.getStringList(_pinnedChatsKey) ?? [];
      _pinnedChats.clear();
      _pinnedChats.addAll(pinnedList);

      // Load search history
      final searchHistory = prefs.getStringList(_messageSearchHistoryKey) ?? [];
      _messageSearchHistory.clear();
      _messageSearchHistory.addAll(searchHistory);
    } catch (e) {
      _logger.warning('Failed to load cached data: $e');
    }
  }

  /// Save starred messages to storage
  Future<void> _saveStarredMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _starredMessagesKey,
        _starredMessageIds.toList(),
      );
    } catch (e) {
      _logger.warning('Failed to save starred messages: $e');
    }
  }

  /// Save archived chats to storage
  Future<void> _saveArchivedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_archivedChatsKey, _archivedChats.toList());
    } catch (e) {
      _logger.warning('Failed to save archived chats: $e');
    }
  }

  /// Save pinned chats to storage
  Future<void> _savePinnedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pinnedChatsKey, _pinnedChats.toList());
    } catch (e) {
      _logger.warning('Failed to save pinned chats: $e');
    }
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
      _logger.warning('Failed to save search history: $e');
    }
  }

  /// Save exported data to local storage
  Future<void> _saveExportedData(
    String data,
    ChatExportFormat format,
    String chatId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final key = 'chat_export_${format.name}_${chatId}_$timestamp';
      await prefs.setString(key, data);

      // Also save export metadata
      final exports = prefs.getStringList('chat_exports') ?? [];
      exports.add(
        jsonEncode({
          'key': key,
          'chat_id': chatId,
          'format': format.name,
          'timestamp': timestamp,
          'size': data.length,
        }),
      );
      await prefs.setStringList('chat_exports', exports);

      _logger.info('Exported chat data saved with key: $key');
    } catch (e) {
      _logger.warning('Failed to save exported data: $e');
    }
  }

  // Private helper methods for archive integration

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

  ArchivedChatAnalytics _calculateArchivedChatAnalytics(ArchivedChat archive) {
    final totalMessages = archive.messageCount;
    final myMessages = archive.messages.where((m) => m.isFromMe).length;
    final theirMessages = totalMessages - myMessages;
    final starredCount = archive.messages.where((m) => m.isStarred).length;

    return ArchivedChatAnalytics(
      archiveId: archive.id,
      totalMessages: totalMessages,
      myMessages: myMessages,
      theirMessages: theirMessages,
      starredMessages: starredCount,
      archivedAt: archive.archivedAt,
      originalDateRange:
          archive.lastMessageTime != null && archive.messages.isNotEmpty
          ? DateTimeRange(
              start: archive.messages
                  .map((m) => m.originalTimestamp)
                  .reduce((a, b) => a.isBefore(b) ? a : b),
              end: archive.lastMessageTime!,
            )
          : null,
      averageMessageLength: archive.messages.isNotEmpty
          ? archive.messages
                    .map((m) => m.content.length)
                    .reduce((a, b) => a + b) /
                archive.messages.length
          : 0.0,
      compressionRatio: archive.compressionInfo?.compressionRatio ?? 1.0,
    );
  }

  CombinedChatMetrics _calculateCombinedMetrics(
    ChatAnalytics liveAnalytics,
    ArchivedChatAnalytics? archiveAnalytics,
  ) {
    final totalLiveMessages = liveAnalytics.totalMessages;
    final totalArchivedMessages = archiveAnalytics?.totalMessages ?? 0;
    final totalMessages = totalLiveMessages + totalArchivedMessages;

    return CombinedChatMetrics(
      totalMessages: totalMessages,
      liveMessages: totalLiveMessages,
      archivedMessages: totalArchivedMessages,
      archivePercentage: totalMessages > 0
          ? (totalArchivedMessages / totalMessages) * 100
          : 0.0,
      hasArchives: archiveAnalytics != null,
      oldestMessage: _getOldestMessageDate(liveAnalytics, archiveAnalytics),
      newestMessage: _getNewestMessageDate(liveAnalytics, archiveAnalytics),
    );
  }

  DateTime? _getOldestMessageDate(
    ChatAnalytics liveAnalytics,
    ArchivedChatAnalytics? archiveAnalytics,
  ) {
    final liveOldest = liveAnalytics.firstMessage;
    final archivedOldest = archiveAnalytics?.originalDateRange?.start;

    if (liveOldest == null && archivedOldest == null) return null;
    if (liveOldest == null) return archivedOldest;
    if (archivedOldest == null) return liveOldest;

    return liveOldest.isBefore(archivedOldest) ? liveOldest : archivedOldest;
  }

  DateTime? _getNewestMessageDate(
    ChatAnalytics liveAnalytics,
    ArchivedChatAnalytics? archiveAnalytics,
  ) {
    final liveNewest = liveAnalytics.lastMessage;
    final archivedNewest = archiveAnalytics?.originalDateRange?.end;

    if (liveNewest == null && archivedNewest == null) return null;
    if (liveNewest == null) return archivedNewest;
    if (archivedNewest == null) return liveNewest;

    return liveNewest.isAfter(archivedNewest) ? liveNewest : archivedNewest;
  }

  /// Get archive management service for advanced operations
  ArchiveManagementService get archiveManager => _archiveManagementService;

  /// Get archive search service for advanced search
  ArchiveSearchService get archiveSearch => _archiveSearchService;

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
      _logger.severe('Advanced search failed: $e');
      return AdvancedSearchResult.error(
        query: query,
        error: 'Advanced search failed: $e',
        searchTime: Duration.zero,
      );
    }
  }

  /// Get comprehensive chat analytics including archive data
  Future<ComprehensiveChatAnalytics> getComprehensiveChatAnalytics(
    String chatId,
  ) async {
    try {
      // Get live chat analytics
      final liveAnalytics = await getChatAnalytics(chatId);

      // Get archive analytics
      ArchivedChatAnalytics? archiveAnalytics;
      try {
        final archives = await _archiveRepository.getArchivedChats(
          filter: ArchiveSearchFilter(contactFilter: chatId),
        );

        if (archives.isNotEmpty) {
          final archive = await _archiveRepository.getArchivedChat(
            archives.first.id,
          );
          if (archive != null) {
            archiveAnalytics = _calculateArchivedChatAnalytics(archive);
          }
        }
      } catch (e) {
        _logger.warning('Failed to get archive analytics: $e');
      }

      return ComprehensiveChatAnalytics(
        chatId: chatId,
        liveAnalytics: liveAnalytics,
        archiveAnalytics: archiveAnalytics,
        combinedMetrics: _calculateCombinedMetrics(
          liveAnalytics,
          archiveAnalytics,
        ),
      );
    } catch (e) {
      _logger.severe('Failed to get comprehensive analytics: $e');
      return ComprehensiveChatAnalytics.error(chatId);
    }
  }

  /// Archive multiple chats in batch
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    final results = <String, ChatOperationResult>{};

    for (final chatId in chatIds) {
      try {
        final result = await toggleChatArchive(
          chatId,
          reason: reason,
          useEnhancedArchive: useEnhancedArchive,
        );
        results[chatId] = result;
      } catch (e) {
        results[chatId] = ChatOperationResult.failure(
          'Batch archive failed: $e',
        );
      }
    }

    final successful = results.values.where((r) => r.success).length;
    final failed = results.length - successful;

    return BatchArchiveResult(
      results: results,
      totalProcessed: chatIds.length,
      successful: successful,
      failed: failed,
    );
  }

  /// Dispose of resources
  Future<void> dispose() async {
    await _chatUpdatesController.close();
    await _messageUpdatesController.close();

    // Dispose archive services
    await _archiveManagementService.dispose();
    await _archiveSearchService.dispose();
    _archiveRepository.dispose();

    _logger.info('Chat management service disposed');
  }
}

// Enums and data classes

enum ChatSortOption { name, lastMessage, unreadCount }

enum ChatExportFormat { text, json, csv }

class ChatFilter {
  final bool hideArchived;
  final bool onlyArchived;
  final bool onlyPinned;
  final bool onlyUnread;
  final bool? hasUnsentMessages;

  const ChatFilter({
    this.hideArchived = true,
    this.onlyArchived = false,
    this.onlyPinned = false,
    this.onlyUnread = false,
    this.hasUnsentMessages,
  });
}

class MessageSearchFilter {
  final bool? fromMe;
  final bool? hasAttachments;
  final bool? isStarred;
  final DateTimeRange? dateRange;

  const MessageSearchFilter({
    this.fromMe,
    this.hasAttachments,
    this.isStarred,
    this.dateRange,
  });
}

class DateTimeRange {
  final DateTime start;
  final DateTime end;

  const DateTimeRange({required this.start, required this.end});
}

class MessageSearchResult {
  final List<EnhancedMessage> results;
  final Map<String, List<EnhancedMessage>> resultsByChat;
  final String query;
  final int totalResults;
  final Duration searchTime;
  final bool hasMore;

  const MessageSearchResult({
    required this.results,
    required this.resultsByChat,
    required this.query,
    required this.totalResults,
    required this.searchTime,
    required this.hasMore,
  });

  factory MessageSearchResult.empty() => MessageSearchResult(
    results: [],
    resultsByChat: {},
    query: '',
    totalResults: 0,
    searchTime: Duration.zero,
    hasMore: false,
  );
}

class ChatOperationResult {
  final bool success;
  final String message;
  final bool isPartial;

  const ChatOperationResult._(this.success, this.message, this.isPartial);

  factory ChatOperationResult.success(String message) =>
      ChatOperationResult._(true, message, false);
  factory ChatOperationResult.failure(String message) =>
      ChatOperationResult._(false, message, false);
  factory ChatOperationResult.partial(String message) =>
      ChatOperationResult._(true, message, true);
}

class ChatAnalytics {
  final String chatId;
  final int totalMessages;
  final int myMessages;
  final int theirMessages;
  final int starredMessages;
  final DateTime? firstMessage;
  final DateTime? lastMessage;
  final double averageMessageLength;
  final Map<DateTime, int> messagesByDay;
  final DateTime? busiestDay;
  final int busiestDayCount;

  const ChatAnalytics({
    required this.chatId,
    required this.totalMessages,
    required this.myMessages,
    required this.theirMessages,
    required this.starredMessages,
    this.firstMessage,
    this.lastMessage,
    required this.averageMessageLength,
    required this.messagesByDay,
    this.busiestDay,
    required this.busiestDayCount,
  });

  factory ChatAnalytics.empty(String chatId) => ChatAnalytics(
    chatId: chatId,
    totalMessages: 0,
    myMessages: 0,
    theirMessages: 0,
    starredMessages: 0,
    averageMessageLength: 0.0,
    messagesByDay: {},
    busiestDayCount: 0,
  );

  Duration? get chatDuration {
    if (firstMessage != null && lastMessage != null) {
      return lastMessage!.difference(firstMessage!);
    }
    return null;
  }
}

abstract class ChatUpdateEvent {
  final String chatId;
  final DateTime timestamp;

  const ChatUpdateEvent(this.chatId, this.timestamp);

  factory ChatUpdateEvent.archived(String chatId) => _ChatArchived(chatId);
  factory ChatUpdateEvent.unarchived(String chatId) => _ChatUnarchived(chatId);
  factory ChatUpdateEvent.pinned(String chatId) => _ChatPinned(chatId);
  factory ChatUpdateEvent.unpinned(String chatId) => _ChatUnpinned(chatId);
  factory ChatUpdateEvent.deleted(String chatId) => _ChatDeleted(chatId);
  factory ChatUpdateEvent.messagesCleared(String chatId) =>
      _ChatMessagesCleared(chatId);
}

class _ChatArchived extends ChatUpdateEvent {
  _ChatArchived(String chatId) : super(chatId, DateTime.now());
}

class _ChatUnarchived extends ChatUpdateEvent {
  _ChatUnarchived(String chatId) : super(chatId, DateTime.now());
}

class _ChatPinned extends ChatUpdateEvent {
  _ChatPinned(String chatId) : super(chatId, DateTime.now());
}

class _ChatUnpinned extends ChatUpdateEvent {
  _ChatUnpinned(String chatId) : super(chatId, DateTime.now());
}

class _ChatDeleted extends ChatUpdateEvent {
  _ChatDeleted(String chatId) : super(chatId, DateTime.now());
}

class _ChatMessagesCleared extends ChatUpdateEvent {
  _ChatMessagesCleared(String chatId) : super(chatId, DateTime.now());
}

abstract class MessageUpdateEvent {
  final String messageId;
  final DateTime timestamp;

  const MessageUpdateEvent(this.messageId, this.timestamp);

  factory MessageUpdateEvent.starred(String messageId) =>
      _MessageStarred(messageId);
  factory MessageUpdateEvent.unstarred(String messageId) =>
      _MessageUnstarred(messageId);
  factory MessageUpdateEvent.deleted(String messageId, String chatId) =>
      _MessageDeleted(messageId, chatId);
}

class _MessageStarred extends MessageUpdateEvent {
  _MessageStarred(String messageId) : super(messageId, DateTime.now());
}

class _MessageUnstarred extends MessageUpdateEvent {
  _MessageUnstarred(String messageId) : super(messageId, DateTime.now());
}

class _MessageDeleted extends MessageUpdateEvent {
  final String chatId;
  _MessageDeleted(String messageId, this.chatId)
    : super(messageId, DateTime.now());
}

// Extended data classes for archive integration

/// Unified search result combining live and archived content
class UnifiedSearchResult {
  final List<EnhancedMessage> liveResults;
  final List<ArchivedMessage> archiveResults;
  final Map<String, List<EnhancedMessage>> liveResultsByChat;
  final Map<String, List<ArchivedMessage>> archiveResultsByChat;
  final String query;
  final int totalLiveResults;
  final int totalArchiveResults;
  final Duration searchTime;
  final bool hasMore;
  final bool includeArchives;

  const UnifiedSearchResult({
    required this.liveResults,
    required this.archiveResults,
    required this.liveResultsByChat,
    required this.archiveResultsByChat,
    required this.query,
    required this.totalLiveResults,
    required this.totalArchiveResults,
    required this.searchTime,
    required this.hasMore,
    required this.includeArchives,
  });

  factory UnifiedSearchResult.empty() => const UnifiedSearchResult(
    liveResults: [],
    archiveResults: [],
    liveResultsByChat: {},
    archiveResultsByChat: {},
    query: '',
    totalLiveResults: 0,
    totalArchiveResults: 0,
    searchTime: Duration.zero,
    hasMore: false,
    includeArchives: false,
  );

  int get totalResults => totalLiveResults + totalArchiveResults;
  bool get hasResults => totalResults > 0;
  bool get hasLiveResults => totalLiveResults > 0;
  bool get hasArchiveResults => totalArchiveResults > 0;
}

/// Comprehensive chat analytics including live and archived data
class ComprehensiveChatAnalytics {
  final String chatId;
  final ChatAnalytics liveAnalytics;
  final ArchivedChatAnalytics? archiveAnalytics;
  final CombinedChatMetrics combinedMetrics;
  final String? error;

  const ComprehensiveChatAnalytics({
    required this.chatId,
    required this.liveAnalytics,
    this.archiveAnalytics,
    required this.combinedMetrics,
    this.error,
  });

  factory ComprehensiveChatAnalytics.error(String chatId) =>
      ComprehensiveChatAnalytics(
        chatId: chatId,
        liveAnalytics: ChatAnalytics.empty(chatId),
        combinedMetrics: CombinedChatMetrics.empty(),
        error: 'Failed to generate comprehensive analytics',
      );

  bool get hasError => error != null;
  bool get hasArchiveData => archiveAnalytics != null;
  double get totalConversationDurationDays =>
      combinedMetrics.conversationDurationDays;
}

/// Analytics for archived chat data
class ArchivedChatAnalytics {
  final String archiveId;
  final int totalMessages;
  final int myMessages;
  final int theirMessages;
  final int starredMessages;
  final DateTime archivedAt;
  final DateTimeRange? originalDateRange;
  final double averageMessageLength;
  final double compressionRatio;

  const ArchivedChatAnalytics({
    required this.archiveId,
    required this.totalMessages,
    required this.myMessages,
    required this.theirMessages,
    required this.starredMessages,
    required this.archivedAt,
    this.originalDateRange,
    required this.averageMessageLength,
    required this.compressionRatio,
  });

  Duration? get originalConversationDuration => originalDateRange?.duration;
  double get messageDistribution =>
      totalMessages > 0 ? myMessages / totalMessages : 0.0;
}

/// Combined metrics from live and archived data
class CombinedChatMetrics {
  final int totalMessages;
  final int liveMessages;
  final int archivedMessages;
  final double archivePercentage;
  final bool hasArchives;
  final DateTime? oldestMessage;
  final DateTime? newestMessage;

  const CombinedChatMetrics({
    required this.totalMessages,
    required this.liveMessages,
    required this.archivedMessages,
    required this.archivePercentage,
    required this.hasArchives,
    this.oldestMessage,
    this.newestMessage,
  });

  factory CombinedChatMetrics.empty() => const CombinedChatMetrics(
    totalMessages: 0,
    liveMessages: 0,
    archivedMessages: 0,
    archivePercentage: 0.0,
    hasArchives: false,
  );

  Duration? get totalConversationDuration =>
      oldestMessage != null && newestMessage != null
      ? newestMessage!.difference(oldestMessage!)
      : null;

  double get conversationDurationDays =>
      totalConversationDuration?.inDays.toDouble() ?? 0.0;

  bool get isPrimarilyArchived => archivePercentage > 50.0;
}

/// Result of batch archive operation
class BatchArchiveResult {
  final Map<String, ChatOperationResult> results;
  final int totalProcessed;
  final int successful;
  final int failed;

  const BatchArchiveResult({
    required this.results,
    required this.totalProcessed,
    required this.successful,
    required this.failed,
  });

  bool get allSuccessful => failed == 0;
  bool get allFailed => successful == 0;
  bool get partialSuccess => successful > 0 && failed > 0;
  double get successRate =>
      totalProcessed > 0 ? successful / totalProcessed : 0.0;

  List<String> get successfulChatIds => results.entries
      .where((entry) => entry.value.success)
      .map((entry) => entry.key)
      .toList();

  List<String> get failedChatIds => results.entries
      .where((entry) => !entry.value.success)
      .map((entry) => entry.key)
      .toList();
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}

extension DateTimeRangeExtension on DateTimeRange {
  Duration get duration => end.difference(start);
}
