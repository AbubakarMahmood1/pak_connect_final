import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('chat management model defaults and value objects', () {
    test('ChatFilter exposes defaults and custom values', () {
      const defaults = ChatFilter();
      const custom = ChatFilter(
        hideArchived: false,
        onlyArchived: true,
        onlyPinned: true,
        onlyUnread: true,
        hasUnsentMessages: true,
      );

      expect(defaults.hideArchived, isTrue);
      expect(defaults.onlyArchived, isFalse);
      expect(defaults.onlyPinned, isFalse);
      expect(defaults.onlyUnread, isFalse);
      expect(defaults.hasUnsentMessages, isNull);

      expect(custom.hideArchived, isFalse);
      expect(custom.onlyArchived, isTrue);
      expect(custom.onlyPinned, isTrue);
      expect(custom.onlyUnread, isTrue);
      expect(custom.hasUnsentMessages, isTrue);
    });

    test('MessageSearchFilter and DateTimeRange store optional filters', () {
      final range = DateTimeRange(
        start: DateTime(2026, 3, 1, 10),
        end: DateTime(2026, 3, 2, 10),
      );
      final filter = MessageSearchFilter(
        fromMe: true,
        hasAttachments: false,
        isStarred: true,
        dateRange: range,
      );

      expect(filter.fromMe, isTrue);
      expect(filter.hasAttachments, isFalse);
      expect(filter.isStarred, isTrue);
      expect(filter.dateRange, same(range));
      expect(range.duration, const Duration(days: 1));
    });

    test(
      'ChatCacheState initializes empty containers and accepts injected state',
      () {
        final defaultState = ChatCacheState();
        final customState = ChatCacheState(
          starredMessageIds: {const MessageId('m1')},
          archivedChats: {const ChatId('a1')},
          pinnedChats: {const ChatId('p1')},
          messageSearchHistory: ['alice'],
        );

        expect(defaultState.starredMessageIds, isEmpty);
        expect(defaultState.archivedChats, isEmpty);
        expect(defaultState.pinnedChats, isEmpty);
        expect(defaultState.messageSearchHistory, isEmpty);

        expect(customState.starredMessageIds.single.value, 'm1');
        expect(customState.archivedChats.single.value, 'a1');
        expect(customState.pinnedChats.single.value, 'p1');
        expect(customState.messageSearchHistory, ['alice']);
      },
    );
  });

  group('operation and analytics helpers', () {
    test('MessageSearchResult.empty returns zeroed search metadata', () {
      final empty = MessageSearchResult.empty();

      expect(empty.results, isEmpty);
      expect(empty.resultsByChat, isEmpty);
      expect(empty.query, isEmpty);
      expect(empty.totalResults, 0);
      expect(empty.searchTime, Duration.zero);
      expect(empty.hasMore, isFalse);
    });

    test('ChatOperationResult factories encode success and partial flags', () {
      final success = ChatOperationResult.success('done');
      final failure = ChatOperationResult.failure('failed');
      final partial = ChatOperationResult.partial('partial');

      expect(success.success, isTrue);
      expect(success.isPartial, isFalse);
      expect(success.message, 'done');

      expect(failure.success, isFalse);
      expect(failure.isPartial, isFalse);
      expect(failure.message, 'failed');

      expect(partial.success, isTrue);
      expect(partial.isPartial, isTrue);
      expect(partial.message, 'partial');
    });

    test('ChatAnalytics empty and duration getter behave as expected', () {
      final empty = ChatAnalytics.empty('chat-1');
      final populated = ChatAnalytics(
        chatId: const ChatId('chat-2'),
        totalMessages: 5,
        myMessages: 3,
        theirMessages: 2,
        starredMessages: 1,
        firstMessage: DateTime(2026, 1, 1),
        lastMessage: DateTime(2026, 1, 4),
        averageMessageLength: 8.5,
        messagesByDay: {DateTime(2026, 1, 1): 5},
        busiestDay: DateTime(2026, 1, 1),
        busiestDayCount: 5,
      );

      expect(empty.chatId.value, 'chat-1');
      expect(empty.totalMessages, 0);
      expect(empty.chatDuration, isNull);

      expect(populated.chatDuration, const Duration(days: 3));
      expect(populated.averageMessageLength, 8.5);
      expect(populated.busiestDayCount, 5);
    });
  });

  group('event factories', () {
    test('ChatUpdateEvent factories attach chat id and timestamp', () {
      const chatId = ChatId('chat-event');
      final events = <ChatUpdateEvent>[
        ChatUpdateEvent.archived(chatId),
        ChatUpdateEvent.unarchived(chatId),
        ChatUpdateEvent.pinned(chatId),
        ChatUpdateEvent.unpinned(chatId),
        ChatUpdateEvent.deleted(chatId),
        ChatUpdateEvent.messagesCleared(chatId),
      ];

      for (final event in events) {
        expect(event.chatId, chatId);
        expect(event.timestamp, isA<DateTime>());
      }
    });

    test(
      'MessageUpdateEvent factories attach ids and deleted event chat id',
      () {
        const messageId = MessageId('msg-1');
        const chatId = ChatId('chat-1');

        final starred = MessageUpdateEvent.starred(messageId);
        final unstarred = MessageUpdateEvent.unstarred(messageId);
        final deleted = MessageUpdateEvent.deleted(messageId, chatId);

        expect(starred.messageId, messageId);
        expect(unstarred.messageId, messageId);
        expect(deleted.messageId, messageId);
        expect((deleted as dynamic).chatId, chatId);
        expect(deleted.timestamp, isA<DateTime>());
      },
    );
  });

  group('search and archive analytics aggregates', () {
    test('UnifiedSearchResult getters reflect total and source flags', () {
      final empty = UnifiedSearchResult.empty();
      final populated = UnifiedSearchResult(
        liveResults: const [],
        archiveResults: const [],
        liveResultsByChat: const {'chat-1': []},
        archiveResultsByChat: const {'archive-1': []},
        query: 'hello',
        totalLiveResults: 3,
        totalArchiveResults: 2,
        searchTime: const Duration(milliseconds: 45),
        hasMore: true,
        includeArchives: true,
      );

      expect(empty.totalResults, 0);
      expect(empty.hasResults, isFalse);
      expect(empty.hasLiveResults, isFalse);
      expect(empty.hasArchiveResults, isFalse);

      expect(populated.totalResults, 5);
      expect(populated.hasResults, isTrue);
      expect(populated.hasLiveResults, isTrue);
      expect(populated.hasArchiveResults, isTrue);
      expect(populated.includeArchives, isTrue);
    });

    test('ComprehensiveChatAnalytics exposes error and archive indicators', () {
      final errorAnalytics = ComprehensiveChatAnalytics.error('chat-err');
      final combined = CombinedChatMetrics(
        totalMessages: 30,
        liveMessages: 10,
        archivedMessages: 20,
        archivePercentage: 66.6,
        hasArchives: true,
        oldestMessage: DateTime(2026, 1, 1),
        newestMessage: DateTime(2026, 1, 11),
      );
      final archiveAnalytics = ArchivedChatAnalytics(
        archiveId: 'arc-1',
        totalMessages: 20,
        myMessages: 8,
        theirMessages: 12,
        starredMessages: 2,
        archivedAt: DateTime(2026, 2, 1),
        originalDateRange: DateTimeRange(
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 11),
        ),
        averageMessageLength: 17,
        compressionRatio: 0.72,
      );
      final fullAnalytics = ComprehensiveChatAnalytics(
        chatId: 'chat-ok',
        liveAnalytics: ChatAnalytics.empty('chat-ok'),
        archiveAnalytics: archiveAnalytics,
        combinedMetrics: combined,
      );

      expect(errorAnalytics.hasError, isTrue);
      expect(errorAnalytics.hasArchiveData, isFalse);
      expect(errorAnalytics.error, contains('Failed to generate'));

      expect(fullAnalytics.hasError, isFalse);
      expect(fullAnalytics.hasArchiveData, isTrue);
      expect(fullAnalytics.totalConversationDurationDays, 10);
      expect(
        archiveAnalytics.originalConversationDuration,
        const Duration(days: 10),
      );
      expect(archiveAnalytics.messageDistribution, closeTo(0.4, 0.0001));
    });

    test('CombinedChatMetrics and batch results compute derived summaries', () {
      final empty = CombinedChatMetrics.empty();
      final combined = CombinedChatMetrics(
        totalMessages: 40,
        liveMessages: 10,
        archivedMessages: 30,
        archivePercentage: 75,
        hasArchives: true,
        oldestMessage: DateTime(2026, 1, 1),
        newestMessage: DateTime(2026, 1, 6),
      );

      expect(empty.totalConversationDuration, isNull);
      expect(empty.conversationDurationDays, 0);
      expect(empty.isPrimarilyArchived, isFalse);

      expect(combined.totalConversationDuration, const Duration(days: 5));
      expect(combined.conversationDurationDays, 5);
      expect(combined.isPrimarilyArchived, isTrue);

      final success = ChatOperationResult.success('ok');
      final failure = ChatOperationResult.failure('nope');
      final partial = ChatOperationResult.partial('half');
      final batch = BatchArchiveResult(
        results: {'c1': success, 'c2': failure, 'c3': partial},
        totalProcessed: 3,
        successful: 2,
        failed: 1,
      );

      expect(batch.allSuccessful, isFalse);
      expect(batch.allFailed, isFalse);
      expect(batch.partialSuccess, isTrue);
      expect(batch.successRate, closeTo(2 / 3, 0.0001));
      expect(batch.successfulChatIds, containsAll(<String>['c1', 'c3']));
      expect(batch.failedChatIds, ['c2']);
    });
  });

  test('firstOrNull extension returns first element or null', () {
    expect(<int>[10, 20].firstOrNull, 10);
    expect(<int>[].firstOrNull, isNull);
  });
}
