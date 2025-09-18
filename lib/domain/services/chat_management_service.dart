// WhatsApp-inspired chat management system with comprehensive message operations

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/chat_list_item.dart';

/// Comprehensive chat management service with WhatsApp-inspired features
class ChatManagementService {
  static final _logger = Logger('ChatManagementService');
  
  final ChatsRepository _chatsRepository = ChatsRepository();
  final MessageRepository _messageRepository = MessageRepository();
  
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
  final _messageUpdatesController = StreamController<MessageUpdateEvent>.broadcast();
  
  /// Stream of chat updates
  Stream<ChatUpdateEvent> get chatUpdates => _chatUpdatesController.stream;
  
  /// Stream of message updates  
  Stream<MessageUpdateEvent> get messageUpdates => _messageUpdatesController.stream;
  
  /// Initialize chat management service
  Future<void> initialize() async {
    await _loadCachedData();
    _logger.info('Chat management service initialized');
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
  
  /// Search messages across all chats or within specific chat
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
        allMessages = messages.map((m) => EnhancedMessage.fromMessage(m)).toList();
      } else {
        // Search across all chats
        final chats = await _chatsRepository.getAllChats();
        for (final chat in chats) {
          final messages = await _messageRepository.getMessages(chat.chatId);
          allMessages.addAll(messages.map((m) => EnhancedMessage.fromMessage(m)));
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
      _logger.severe('Message search failed: $e');
      return MessageSearchResult.empty();
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
            final enhanced = EnhancedMessage.fromMessage(message).copyWith(isStarred: true);
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
              
              _messageUpdatesController.add(MessageUpdateEvent.deleted(messageId, chat.chatId));
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
        return ChatOperationResult.success('$successCount message${successCount > 1 ? 's' : ''} deleted');
      } else {
        return ChatOperationResult.partial('$successCount deleted, $failureCount failed');
      }
      
    } catch (e) {
      return ChatOperationResult.failure('Delete operation failed: $e');
    }
  }
  
  /// Archive/unarchive chat
  Future<ChatOperationResult> toggleChatArchive(String chatId) async {
    try {
      if (_archivedChats.contains(chatId)) {
        _archivedChats.remove(chatId);
        await _saveArchivedChats();
        _chatUpdatesController.add(ChatUpdateEvent.unarchived(chatId));
        return ChatOperationResult.success('Chat unarchived');
      } else {
        _archivedChats.add(chatId);
        await _saveArchivedChats();
        _chatUpdatesController.add(ChatUpdateEvent.archived(chatId));
        return ChatOperationResult.success('Chat archived');
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
      final enhancedMessages = messages.map((m) => EnhancedMessage.fromMessage(m)).toList();
      
      final totalMessages = enhancedMessages.length;
      final myMessages = enhancedMessages.where((m) => m.isFromMe).length;
      final theirMessages = totalMessages - myMessages;
      final starredCount = enhancedMessages.where((m) => _starredMessageIds.contains(m.id)).length;
      
      final firstMessage = enhancedMessages.isNotEmpty 
        ? enhancedMessages.reduce((a, b) => a.timestamp.isBefore(b.timestamp) ? a : b)
        : null;
      
      final lastMessage = enhancedMessages.isNotEmpty
        ? enhancedMessages.reduce((a, b) => a.timestamp.isAfter(b.timestamp) ? a : b)
        : null;
      
      final averageMessageLength = enhancedMessages.isNotEmpty
        ? enhancedMessages.map((m) => m.content.length).reduce((a, b) => a + b) / enhancedMessages.length
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
      _logger.info('Exported chat ${chat.contactName} (${messages.length} messages) as ${format.name}');
      return ChatOperationResult.success('Chat exported successfully to local storage');
      
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
  bool isMessageStarred(String messageId) => _starredMessageIds.contains(messageId);
  
  /// Get pinned chats count
  int get pinnedChatsCount => _pinnedChats.length;
  
  /// Get archived chats count
  int get archivedChatsCount => _archivedChats.length;
  
  /// Get starred messages count
  int get starredMessagesCount => _starredMessageIds.length;
  
  // Private methods
  
  /// Apply filters to chat list
  Future<List<ChatListItem>> _applyFilters(List<ChatListItem> chats, ChatFilter filter) async {
    var filteredChats = chats;
    
    if (filter.hideArchived && !filter.onlyArchived) {
      filteredChats = filteredChats.where((chat) => !_archivedChats.contains(chat.chatId)).toList();
    } else if (filter.onlyArchived) {
      filteredChats = filteredChats.where((chat) => _archivedChats.contains(chat.chatId)).toList();
    }
    
    if (filter.onlyPinned) {
      filteredChats = filteredChats.where((chat) => _pinnedChats.contains(chat.chatId)).toList();
    }
    
    if (filter.onlyUnread) {
      filteredChats = filteredChats.where((chat) => chat.unreadCount > 0).toList();
    }
    
    if (filter.hasUnsentMessages != null) {
      filteredChats = filteredChats.where((chat) => chat.hasUnsentMessages == filter.hasUnsentMessages).toList();
    }
    
    return filteredChats;
  }
  
  /// Sort chats by specified criteria
  List<ChatListItem> _sortChats(List<ChatListItem> chats, ChatSortOption sortBy, bool ascending) {
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
          final aTime = a.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
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
  List<EnhancedMessage> _performMessageTextSearch(List<EnhancedMessage> messages, String query) {
    final searchTerms = query.toLowerCase().split(' ').where((term) => term.isNotEmpty).toList();
    
    return messages.where((message) {
      final searchableText = message.content.toLowerCase();
      return searchTerms.every((term) => searchableText.contains(term));
    }).toList();
  }
  
  /// Apply additional search filters
  List<EnhancedMessage> _applyMessageSearchFilter(List<EnhancedMessage> messages, MessageSearchFilter filter) {
    return messages.where((message) {
      if (filter.fromMe != null && message.isFromMe != filter.fromMe) {
        return false;
      }
      
      if (filter.hasAttachments != null && message.attachments.isNotEmpty != filter.hasAttachments) {
        return false;
      }
      
      if (filter.isStarred != null && _starredMessageIds.contains(message.id) != filter.isStarred) {
        return false;
      }
      
      if (filter.dateRange != null) {
        final messageDate = message.timestamp;
        if (messageDate.isBefore(filter.dateRange!.start) || messageDate.isAfter(filter.dateRange!.end)) {
          return false;
        }
      }
      
      return true;
    }).toList();
  }
  
  /// Group search results by chat
  Map<String, List<EnhancedMessage>> _groupResultsByChat(List<EnhancedMessage> results) {
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
      final day = DateTime(message.timestamp.year, message.timestamp.month, message.timestamp.day);
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
  String _exportChatAsText(List<Message> messages, ChatListItem chat, bool includeMetadata) {
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
  String _exportChatAsJson(List<Message> messages, ChatListItem chat, bool includeMetadata) {
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
  String _exportChatAsCsv(List<Message> messages, ChatListItem chat, bool includeMetadata) {
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
  Future<void> _deleteMessageFromRepository(String messageId, String chatId) async {
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
      await prefs.setStringList(_starredMessagesKey, _starredMessageIds.toList());
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
      await prefs.setStringList(_messageSearchHistoryKey, _messageSearchHistory);
    } catch (e) {
      _logger.warning('Failed to save search history: $e');
    }
  }

  /// Save exported data to local storage
  Future<void> _saveExportedData(String data, ChatExportFormat format, String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final key = 'chat_export_${format.name}_${chatId}_$timestamp';
      await prefs.setString(key, data);
      
      // Also save export metadata
      final exports = prefs.getStringList('chat_exports') ?? [];
      exports.add(jsonEncode({
        'key': key,
        'chat_id': chatId,
        'format': format.name,
        'timestamp': timestamp,
        'size': data.length,
      }));
      await prefs.setStringList('chat_exports', exports);
      
      _logger.info('Exported chat data saved with key: $key');
    } catch (e) {
      _logger.warning('Failed to save exported data: $e');
    }
  }
  
  /// Dispose of resources
  void dispose() {
    _chatUpdatesController.close();
    _messageUpdatesController.close();
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
  
  factory ChatOperationResult.success(String message) => ChatOperationResult._(true, message, false);
  factory ChatOperationResult.failure(String message) => ChatOperationResult._(false, message, false);
  factory ChatOperationResult.partial(String message) => ChatOperationResult._(true, message, true);
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
  factory ChatUpdateEvent.messagesCleared(String chatId) => _ChatMessagesCleared(chatId);
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
  
  factory MessageUpdateEvent.starred(String messageId) => _MessageStarred(messageId);
  factory MessageUpdateEvent.unstarred(String messageId) => _MessageUnstarred(messageId);
  factory MessageUpdateEvent.deleted(String messageId, String chatId) => _MessageDeleted(messageId, chatId);
}

class _MessageStarred extends MessageUpdateEvent {
  _MessageStarred(String messageId) : super(messageId, DateTime.now());
}

class _MessageUnstarred extends MessageUpdateEvent {
  _MessageUnstarred(String messageId) : super(messageId, DateTime.now());
}

class _MessageDeleted extends MessageUpdateEvent {
  final String chatId;
  _MessageDeleted(String messageId, this.chatId) : super(messageId, DateTime.now());
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