// Shared models and enums for chat management services

import '../entities/archived_message.dart';
import '../entities/enhanced_message.dart';
import '../values/id_types.dart';

/// Sorting options for chat lists
enum ChatSortOption { name, lastMessage, unreadCount }

/// Export formats supported by chat export routines
enum ChatExportFormat { text, json, csv }

/// Filter parameters for chat list queries
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

/// Filter parameters for message searches
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

/// Lightweight date range used by search and analytics
class DateTimeRange {
  final DateTime start;
  final DateTime end;

  const DateTimeRange({required this.start, required this.end});
}

extension DateTimeRangeExtension on DateTimeRange {
  Duration get duration => end.difference(start);
}

/// In-memory cache container for chat state
class ChatCacheState {
  final Set<MessageId> starredMessageIds;
  final Set<ChatId> archivedChats;
  final Set<ChatId> pinnedChats;
  final List<String> messageSearchHistory;

  ChatCacheState({
    Set<MessageId>? starredMessageIds,
    Set<ChatId>? archivedChats,
    Set<ChatId>? pinnedChats,
    List<String>? messageSearchHistory,
  }) : starredMessageIds = starredMessageIds ?? <MessageId>{},
       archivedChats = archivedChats ?? <ChatId>{},
       pinnedChats = pinnedChats ?? <ChatId>{},
       messageSearchHistory = messageSearchHistory ?? <String>[];
}

/// Message search result for live chats
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

/// Standard operation result for chat actions
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

/// Basic analytics for a single chat
class ChatAnalytics {
  final ChatId chatId;
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
    chatId: ChatId(chatId),
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

/// Chat-level update event
abstract class ChatUpdateEvent {
  final ChatId chatId;
  final DateTime timestamp;

  const ChatUpdateEvent(this.chatId, this.timestamp);

  factory ChatUpdateEvent.archived(ChatId chatId) => _ChatArchived(chatId);
  factory ChatUpdateEvent.unarchived(ChatId chatId) => _ChatUnarchived(chatId);
  factory ChatUpdateEvent.pinned(ChatId chatId) => _ChatPinned(chatId);
  factory ChatUpdateEvent.unpinned(ChatId chatId) => _ChatUnpinned(chatId);
  factory ChatUpdateEvent.deleted(ChatId chatId) => _ChatDeleted(chatId);
  factory ChatUpdateEvent.messagesCleared(ChatId chatId) =>
      _ChatMessagesCleared(chatId);
}

class _ChatArchived extends ChatUpdateEvent {
  _ChatArchived(ChatId chatId) : super(chatId, DateTime.now());
}

class _ChatUnarchived extends ChatUpdateEvent {
  _ChatUnarchived(ChatId chatId) : super(chatId, DateTime.now());
}

class _ChatPinned extends ChatUpdateEvent {
  _ChatPinned(ChatId chatId) : super(chatId, DateTime.now());
}

class _ChatUnpinned extends ChatUpdateEvent {
  _ChatUnpinned(ChatId chatId) : super(chatId, DateTime.now());
}

class _ChatDeleted extends ChatUpdateEvent {
  _ChatDeleted(ChatId chatId) : super(chatId, DateTime.now());
}

class _ChatMessagesCleared extends ChatUpdateEvent {
  _ChatMessagesCleared(ChatId chatId) : super(chatId, DateTime.now());
}

/// Message-level update event
abstract class MessageUpdateEvent {
  final MessageId messageId;
  final DateTime timestamp;

  const MessageUpdateEvent(this.messageId, this.timestamp);

  factory MessageUpdateEvent.starred(MessageId messageId) =>
      _MessageStarred(messageId);
  factory MessageUpdateEvent.unstarred(MessageId messageId) =>
      _MessageUnstarred(messageId);
  factory MessageUpdateEvent.deleted(MessageId messageId, ChatId chatId) =>
      _MessageDeleted(messageId, chatId);
}

class _MessageStarred extends MessageUpdateEvent {
  _MessageStarred(MessageId messageId) : super(messageId, DateTime.now());
}

class _MessageUnstarred extends MessageUpdateEvent {
  _MessageUnstarred(MessageId messageId) : super(messageId, DateTime.now());
}

class _MessageDeleted extends MessageUpdateEvent {
  final ChatId chatId;
  _MessageDeleted(MessageId messageId, this.chatId)
    : super(messageId, DateTime.now());
}

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

/// Comprehensive chat analytics including archive data
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

extension FirstWhereOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
