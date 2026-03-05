import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_lifecycle_service.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/services/chat_notification_service.dart';
import 'package:pak_connect/domain/services/chat_sync_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatLifecycleService', () {
    late _FakeChatsRepository chatsRepository;
    late _FakeMessageRepository messageRepository;
    late _FakeArchiveRepository archiveRepository;
    late ArchiveManagementService archiveManagementService;
    late ChatCacheState cacheState;
    late ChatNotificationService notificationService;
    late ChatSyncService syncService;
    late ChatLifecycleService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});

      chatsRepository = _FakeChatsRepository([
        _chat(
          id: 'chat_1',
          name: 'Alice',
          unreadCount: 2,
          lastMessageTime: DateTime(2026, 1, 1, 10, 5),
        ),
        _chat(
          id: 'chat_2',
          name: 'Bob',
          unreadCount: 0,
          lastMessageTime: DateTime(2026, 1, 1, 9, 0),
        ),
      ]);

      messageRepository = _FakeMessageRepository({
        'chat_1': [
          _message(
            id: 'm1',
            chatId: 'chat_1',
            content: 'hello',
            fromMe: true,
            timestamp: DateTime(2026, 1, 1, 10, 0),
          ),
          _message(
            id: 'm2',
            chatId: 'chat_1',
            content: 'reply',
            fromMe: false,
            timestamp: DateTime(2026, 1, 1, 10, 2),
          ),
          _message(
            id: 'm3',
            chatId: 'chat_1',
            content: 'follow up',
            fromMe: true,
            timestamp: DateTime(2026, 1, 1, 10, 5),
          ),
        ],
        'chat_2': [
          _message(
            id: 'm4',
            chatId: 'chat_2',
            content: 'other chat',
            fromMe: false,
            timestamp: DateTime(2026, 1, 1, 9, 0),
          ),
        ],
      });

      archiveRepository = _FakeArchiveRepository();
      archiveManagementService = ArchiveManagementService.withDependencies(
        archiveRepository: archiveRepository,
      );
      await archiveManagementService.initialize();

      cacheState = ChatCacheState();
      notificationService = ChatNotificationService();
      final archiveSearchService = ArchiveSearchService.withDependencies(
        archiveRepository: archiveRepository,
      );

      syncService = ChatSyncService(
        chatsRepository: chatsRepository,
        messageRepository: messageRepository,
        cacheState: cacheState,
        archiveSearchService: archiveSearchService,
      );

      service = ChatLifecycleService(
        chatsRepository: chatsRepository,
        messageRepository: messageRepository,
        archiveRepository: archiveRepository,
        archiveManagementService: archiveManagementService,
        cacheState: cacheState,
        notificationService: notificationService,
        syncService: syncService,
      );
    });

    tearDown(() async {
      await notificationService.dispose();
      await archiveManagementService.dispose();
    });

    test('toggleMessageStar toggles state, persists, and emits message updates', () async {
      final events = <MessageUpdateEvent>[];
      final sub = notificationService.messageUpdates.listen(events.add);
      final id = MessageId('m1');

      final first = await service.toggleMessageStar(id);
      expect(first.success, isTrue);
      expect(cacheState.starredMessageIds.contains(id), isTrue);

      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('starred_messages'), contains('m1'));

      final second = await service.toggleMessageStar(id);
      expect(second.success, isTrue);
      expect(cacheState.starredMessageIds.contains(id), isFalse);

      prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('starred_messages') ?? const <String>[], isEmpty);
      expect(events.length, 2);

      await sub.cancel();
    });

    test('getStarredMessages returns only starred messages sorted by newest first', () async {
      cacheState.starredMessageIds.addAll({MessageId('m1'), MessageId('m2')});

      final starred = await service.getStarredMessages();

      expect(starred.length, 2);
      expect(starred.first.id, MessageId('m2'));
      expect(starred.first.isStarred, isTrue);
      expect(starred.last.id, MessageId('m1'));
    });

    test('deleteMessages returns partial when some IDs are missing', () async {
      cacheState.starredMessageIds.add(MessageId('m2'));

      final result = await service.deleteMessages(
        messageIds: [MessageId('m2'), MessageId('missing')],
      );

      expect(result.success, isTrue);
      expect(result.isPartial, isTrue);
      expect(messageRepository.deletedIds, contains(MessageId('m2')));
      expect(cacheState.starredMessageIds.contains(MessageId('m2')), isFalse);
    });

    test('toggleChatPin enforces max 3 and supports unpin flow', () async {
      cacheState.pinnedChats.addAll({
        ChatId('chat_1'),
        ChatId('chat_2'),
        ChatId('chat_3'),
      });

      final blocked = await service.toggleChatPin(ChatId('chat_4'));
      expect(blocked.success, isFalse);
      expect(blocked.message, contains('Maximum 3 chats'));

      final unpinned = await service.toggleChatPin(ChatId('chat_3'));
      expect(unpinned.success, isTrue);
      expect(cacheState.pinnedChats.contains(ChatId('chat_3')), isFalse);
    });

    test('toggleChatArchive supports non-enhanced archive mode', () async {
      final archived = await service.toggleChatArchive(
        'chat_1',
        useEnhancedArchive: false,
      );
      expect(archived.success, isTrue);
      expect(cacheState.archivedChats.contains(ChatId('chat_1')), isTrue);

      final unarchived = await service.toggleChatArchive(
        'chat_1',
        useEnhancedArchive: false,
      );
      expect(unarchived.success, isTrue);
      expect(cacheState.archivedChats.contains(ChatId('chat_1')), isFalse);
    });

    test('toggleChatArchive uses enhanced archive manager when enabled', () async {
      final archived = await service.toggleChatArchive(
        'chat_1',
        reason: 'manual archive',
        useEnhancedArchive: true,
      );
      expect(archived.success, isTrue);
      expect(archiveRepository.lastArchiveRequestChatId, 'chat_1');
      expect(cacheState.archivedChats.contains(ChatId('chat_1')), isTrue);

      final restored = await service.toggleChatArchive(
        'chat_1',
        useEnhancedArchive: true,
      );
      expect(restored.success, isTrue);
      expect(cacheState.archivedChats.contains(ChatId('chat_1')), isFalse);
    });

    test('deleteChat clears messages and cache state for that chat', () async {
      cacheState.archivedChats.add(ChatId('chat_1'));
      cacheState.pinnedChats.add(ChatId('chat_1'));
      cacheState.starredMessageIds.addAll({
        MessageId('m1'),
        MessageId('m2'),
        MessageId('m3'),
      });

      final result = await service.deleteChat('chat_1');

      expect(result.success, isTrue);
      expect(messageRepository.clearedChatIds, contains(ChatId('chat_1')));
      expect(cacheState.archivedChats.contains(ChatId('chat_1')), isFalse);
      expect(cacheState.pinnedChats.contains(ChatId('chat_1')), isFalse);
      expect(cacheState.starredMessageIds, isEmpty);
    });

    test('clearChatMessages only clears chat messages and related starred IDs', () async {
      cacheState.starredMessageIds.addAll({MessageId('m1'), MessageId('m4')});

      final result = await service.clearChatMessages('chat_1');

      expect(result.success, isTrue);
      expect(messageRepository.clearedChatIds, contains(ChatId('chat_1')));
      expect(cacheState.starredMessageIds.contains(MessageId('m1')), isFalse);
      expect(cacheState.starredMessageIds.contains(MessageId('m4')), isTrue);
    });

    test('getChatAnalytics computes message stats and starred count', () async {
      cacheState.starredMessageIds.add(MessageId('m2'));

      final analytics = await service.getChatAnalytics('chat_1');

      expect(analytics.totalMessages, 3);
      expect(analytics.myMessages, 2);
      expect(analytics.theirMessages, 1);
      expect(analytics.starredMessages, 1);
      expect(analytics.averageMessageLength, greaterThan(0));
      expect(analytics.busiestDayCount, 3);
    });

    test('exportChat returns failure for missing chat and stores JSON export for existing chat', () async {
      final missing = await service.exportChat(chatId: 'missing');
      expect(missing.success, isFalse);

      cacheState.starredMessageIds.add(MessageId('m1'));
      final exported = await service.exportChat(
        chatId: 'chat_1',
        format: ChatExportFormat.json,
        includeMetadata: true,
      );
      expect(exported.success, isTrue);

      final prefs = await SharedPreferences.getInstance();
      final exports = prefs.getStringList('chat_exports');
      expect(exports, isNotNull);
      expect(exports, isNotEmpty);

      final meta = jsonDecode(exports!.last) as Map<String, dynamic>;
      final payload = prefs.getString(meta['key'] as String);
      expect(payload, isNotNull);
      expect(payload!, contains('is_starred'));
      expect(payload, contains('"chat_id":"chat_1"'));
    });

    test('batchArchiveChats reports aggregate success', () async {
      final result = await service.batchArchiveChats(
        chatIds: ['chat_1', 'chat_2'],
        useEnhancedArchive: false,
      );

      expect(result.totalProcessed, 2);
      expect(result.successful, 2);
      expect(result.failed, 0);
      expect(result.allSuccessful, isTrue);
    });

    test('syncService initialize loads cached ids and search history', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('starred_messages', ['m1', 'm2']);
      await prefs.setStringList('archived_chats', ['chat_1']);
      await prefs.setStringList('pinned_chats', ['chat_2']);
      await prefs.setStringList(
        'message_search_history',
        ['older', 'newer'],
      );

      await syncService.initialize();

      expect(syncService.starredMessagesCount, 2);
      expect(syncService.archivedChatsCount, 1);
      expect(syncService.pinnedChatsCount, 1);
      expect(syncService.isMessageStarred('m1'), isTrue);
      expect(syncService.isChatArchived(const ChatId('chat_1')), isTrue);
      expect(syncService.isChatPinned(const ChatId('chat_2')), isTrue);
      expect(syncService.getMessageSearchHistory(), ['newer', 'older']);

      syncService.resetInitialization();
      await syncService.initialize();
      expect(syncService.starredMessagesCount, 2);
    });

    test('syncService getAllChats applies filters and sort options', () async {
      cacheState.archivedChats.add(const ChatId('chat_1'));
      cacheState.pinnedChats.add(const ChatId('chat_2'));

      final visible = await syncService.getAllChats(
        filter: const ChatFilter(hideArchived: true),
      );
      expect(visible.map((chat) => chat.chatId.value), ['chat_2']);

      final archivedOnly = await syncService.getAllChats(
        filter: const ChatFilter(onlyArchived: true),
      );
      expect(archivedOnly.map((chat) => chat.chatId.value), ['chat_1']);

      final pinnedOnly = await syncService.getAllChats(
        filter: const ChatFilter(onlyPinned: true),
      );
      expect(pinnedOnly.map((chat) => chat.chatId.value), ['chat_2']);

      final unreadOnly = await syncService.getAllChats(
        filter: const ChatFilter(
          hideArchived: false,
          onlyUnread: true,
        ),
      );
      expect(unreadOnly.map((chat) => chat.chatId.value), ['chat_1']);

      final unsentOnly = await syncService.getAllChats(
        filter: const ChatFilter(hasUnsentMessages: true),
      );
      expect(unsentOnly, isEmpty);

      final byNameAsc = await syncService.getAllChats(
        sortBy: ChatSortOption.name,
        ascending: true,
      );
      expect(byNameAsc.map((chat) => chat.contactName), ['Alice', 'Bob']);
    });

    test('syncService searchMessages supports query, filters, grouping, and limits', () async {
      await syncService.initialize();
      cacheState.starredMessageIds.add(const MessageId('m2'));

      final empty = await syncService.searchMessages(query: '   ');
      expect(empty.totalResults, 0);

      final starredReply = await syncService.searchMessages(
        query: 'reply',
        filter: const MessageSearchFilter(
          fromMe: false,
          isStarred: true,
        ),
      );
      expect(starredReply.totalResults, 1);
      expect(starredReply.results.single.id, const MessageId('m2'));
      expect(starredReply.resultsByChat.keys, contains('chat_1'));

      final limited = await syncService.searchMessages(
        query: 'o',
        chatId: 'chat_1',
        limit: 1,
      );
      expect(limited.totalResults, 1);
      expect(limited.hasMore, isTrue);
    });

    test('syncService unified and advanced search handle scope combinations', () async {
      await syncService.initialize();

      final unified = await syncService.searchMessagesUnified(
        query: 'hello',
        includeArchives: true,
        limit: 1,
        filter: MessageSearchFilter(
          dateRange: DateTimeRange(
            start: DateTime(2026, 1, 1, 0),
            end: DateTime(2026, 1, 2, 0),
          ),
        ),
      );

      expect(unified.includeArchives, isTrue);
      expect(unified.totalLiveResults, 1);
      expect(unified.totalArchiveResults, 0);
      expect(unified.hasResults, isTrue);
      expect(unified.hasArchiveResults, isFalse);

      final combinedAdvanced = await syncService.performAdvancedSearch(
        query: 'hello',
        includeLive: true,
        includeArchives: true,
      );
      expect(combinedAdvanced.hasError, isFalse);
      expect(combinedAdvanced.query, 'hello');

      final archiveOnly = await syncService.performAdvancedSearch(
        query: 'hello',
        includeLive: false,
        includeArchives: true,
      );
      expect(archiveOnly.hasError, isFalse);

      final liveOnly = await syncService.performAdvancedSearch(
        query: 'hello',
        includeLive: true,
        includeArchives: false,
      );
      expect(liveOnly.hasError, isFalse);

      final noScope = await syncService.performAdvancedSearch(
        query: 'hello',
        includeLive: false,
        includeArchives: false,
      );
      expect(noScope.hasError, isTrue);
    });

    test('syncService search history and save helpers persist cache state', () async {
      await syncService.initialize();

      for (var i = 0; i < 12; i++) {
        await syncService.searchMessages(query: 'term_$i');
      }

      final history = syncService.getMessageSearchHistory();
      expect(history.length, 10);
      expect(history.first, 'term_11');
      expect(history.last, 'term_2');

      cacheState.starredMessageIds.addAll({
        const MessageId('m1'),
        const MessageId('m2'),
      });
      cacheState.archivedChats.add(const ChatId('chat_1'));
      cacheState.pinnedChats.add(const ChatId('chat_2'));

      await syncService.saveStarredMessages();
      await syncService.saveArchivedChats();
      await syncService.savePinnedChats();
      await syncService.saveMessageSearchHistory();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('starred_messages'),
        containsAll(<String>['m1', 'm2']),
      );
      expect(prefs.getStringList('archived_chats'), ['chat_1']);
      expect(prefs.getStringList('pinned_chats'), ['chat_2']);
      expect(prefs.getStringList('message_search_history'), isNotEmpty);

      await syncService.clearMessageSearchHistory();
      expect(syncService.getMessageSearchHistory(), isEmpty);
      expect(
        prefs.getStringList('message_search_history') ?? const <String>[],
        isEmpty,
      );
    });

    test('syncService getAllChats fails closed when repository throws', () async {
      final throwingService = ChatSyncService(
        chatsRepository: _ThrowingChatsRepository(),
        messageRepository: messageRepository,
        cacheState: cacheState,
        archiveSearchService: ArchiveSearchService.withDependencies(
          archiveRepository: archiveRepository,
        ),
      );

      final chats = await throwingService.getAllChats();
      expect(chats, isEmpty);
    });
  });
}

ChatListItem _chat({
  required String id,
  required String name,
  required int unreadCount,
  required DateTime lastMessageTime,
}) {
  return ChatListItem(
    chatId: ChatId(id),
    contactName: name,
    contactPublicKey: id,
    lastMessage: 'latest',
    lastMessageTime: lastMessageTime,
    unreadCount: unreadCount,
    isOnline: false,
    hasUnsentMessages: false,
    lastSeen: lastMessageTime,
  );
}

Message _message({
  required String id,
  required String chatId,
  required String content,
  required bool fromMe,
  required DateTime timestamp,
}) {
  return Message(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: content,
    timestamp: timestamp,
    isFromMe: fromMe,
    status: MessageStatus.delivered,
  );
}

class _FakeChatsRepository implements IChatsRepository {
  _FakeChatsRepository(this._chats);

  final List<ChatListItem> _chats;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<dynamic>? nearbyDevices,
    Map<String, dynamic>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async => List.of(_chats);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected method call: $invocation');
}

class _FakeMessageRepository implements IMessageRepository {
  _FakeMessageRepository(this._messagesByChatId);

  final Map<String, List<Message>> _messagesByChatId;
  final List<MessageId> deletedIds = [];
  final List<ChatId> clearedChatIds = [];

  @override
  Future<List<Message>> getMessages(ChatId chatId) async =>
      List.of(_messagesByChatId[chatId.value] ?? const []);

  @override
  Future<bool> deleteMessage(MessageId messageId) async {
    for (final entry in _messagesByChatId.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((message) => message.id == messageId);
      if (entry.value.length != before) {
        deletedIds.add(messageId);
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> clearMessages(ChatId chatId) async {
    clearedChatIds.add(chatId);
    _messagesByChatId.remove(chatId.value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected method call: $invocation');
}

class _FakeArchiveRepository implements IArchiveRepository {
  String? lastArchiveRequestChatId;
  final Map<String, ArchivedChat> _archivesById = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async {
    lastArchiveRequestChatId = chatId;
    final id = ArchiveId('arch_$chatId');
    _archivesById[id.value] = _archivedChat(id, chatId);
    return ArchiveOperationResult.success(
      message: 'archived',
      operationType: ArchiveOperationType.archive,
      archiveId: id,
      operationTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async {
    if (!_archivesById.containsKey(archiveId.value)) {
      return ArchiveOperationResult.failure(
        message: 'missing archive',
        operationType: ArchiveOperationType.restore,
        operationTime: Duration.zero,
      );
    }
    return ArchiveOperationResult.success(
      message: 'restored',
      operationType: ArchiveOperationType.restore,
      archiveId: archiveId,
      operationTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async => _archivesById.values.map((archive) => archive.toSummary()).toList();

  @override
  Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async =>
      _archivesById[archiveId.value];

  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(String chatId) async {
    for (final archive in _archivesById.values) {
      if (archive.originalChatId.value == chatId) {
        return archive.toSummary();
      }
    }
    return null;
  }

  @override
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async => ArchiveSearchResult.empty(query);

  @override
  Future<ArchiveStatistics?> getArchiveStatistics() async =>
      ArchiveStatistics.empty();

  @override
  Future<int> getArchivedChatsCount() async => _archivesById.length;

  @override
  Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async {
    _archivesById.remove(archivedChatId.value);
  }

  @override
  void clearCache() {}

  @override
  Future<void> dispose() async {}
}

class _ThrowingChatsRepository implements IChatsRepository {
  @override
  Future<List<ChatListItem>> getAllChats({
    List<dynamic>? nearbyDevices,
    Map<String, dynamic>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async => throw StateError('boom');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected method call: $invocation');
}

ArchivedChat _archivedChat(ArchiveId archiveId, String chatId) {
  final message = Message(
    id: MessageId('arch_msg_$chatId'),
    chatId: ChatId(chatId),
    content: 'archived',
    timestamp: DateTime(2026, 1, 1, 10),
    isFromMe: true,
    status: MessageStatus.delivered,
  );

  return ArchivedChat(
    id: archiveId,
    originalChatId: ChatId(chatId),
    contactName: chatId,
    archivedAt: DateTime(2026, 1, 1, 12),
    lastMessageTime: message.timestamp,
    messageCount: 1,
    metadata: const ArchiveMetadata(
      version: '1.0',
      reason: 'test',
      originalUnreadCount: 0,
      wasOnline: false,
      hadUnsentMessages: false,
      estimatedStorageSize: 100,
      archiveSource: 'test',
      tags: [],
    ),
    messages: [],
  );
}
