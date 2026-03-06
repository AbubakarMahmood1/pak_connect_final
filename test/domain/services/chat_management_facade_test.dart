import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_search_models.dart';
import 'package:pak_connect/domain/services/chat_management_facade.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('ChatManagementFacade', () {
    late _FakeChatManagementService service;
    late ChatManagementFacade facade;

    setUp(() {
      service = _FakeChatManagementService();
      facade = ChatManagementFacade(chatManagementService: service);
    });

    test('initializes once and re-initializes after dispose', () async {
      await facade.initialize();
      await facade.initialize();
      expect(service.initializeCalls, 1);

      await facade.dispose();
      await facade.toggleChatArchive('chat-after-dispose');
      expect(service.initializeCalls, 2);
      expect(service.disposeCalls, 0);
    });

    test('delegates archive and pin/star operations', () async {
      final archiveResult = await facade.toggleChatArchive(
        'chat-1',
        reason: 'manual',
        useEnhancedArchive: false,
      );
      final batch = await facade.batchArchiveChats(chatIds: <String>['a', 'b']);
      final pinResult = await facade.toggleChatPin(const ChatId('chat-1'));
      final starResult = await facade.toggleMessageStarById(const MessageId('m-1'));
      final legacyStar = await facade.toggleMessageStar('m-2');

      expect(archiveResult.success, isTrue);
      expect(batch.totalProcessed, 2);
      expect(pinResult.success, isTrue);
      expect(starResult.success, isTrue);
      expect(legacyStar.success, isTrue);
      expect(facade.isChatArchived('chat-1'), isTrue);
      expect(facade.archivedChatsCount, 4);
      expect(facade.isChatPinned(const ChatId('chat-1')), isTrue);
      expect(facade.pinnedChatsCount, 3);
      expect(facade.isMessageStarredById(const MessageId('m-1')), isTrue);
      expect(facade.isMessageStarred('m-2'), isTrue);
      expect(facade.starredMessagesCount, 7);
      expect(await facade.getStarredMessages(), isEmpty);
    });

    test('delegates search and history operations', () async {
      final basic = await facade.searchMessages(query: 'hello');
      final unified = await facade.searchMessagesUnified(
        query: 'hello',
        includeArchives: true,
      );
      final advanced = await facade.performAdvancedSearch(
        query: 'hello',
        options: const SearchOptions(fuzzySearch: true),
      );

      expect(basic.totalResults, 0);
      expect(unified.totalResults, 0);
      expect(advanced.hasError, isTrue);
      expect(facade.getMessageSearchHistory(), <String>['one', 'two']);

      await facade.clearMessageSearchHistory();
      expect(service.clearSearchHistoryCalls, 1);
    });
  });
}

class _FakeChatManagementService extends Fake implements ChatManagementService {
  int initializeCalls = 0;
  int disposeCalls = 0;
  int clearSearchHistoryCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    return ChatOperationResult.success('archived');
  }

  @override
  bool isChatArchived(String chatId) => true;

  @override
  int get archivedChatsCount => 4;

  @override
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    return BatchArchiveResult(
      results: <String, ChatOperationResult>{
        for (final id in chatIds) id: ChatOperationResult.success('ok'),
      },
      totalProcessed: chatIds.length,
      successful: chatIds.length,
      failed: 0,
    );
  }

  @override
  Future<ChatOperationResult> toggleChatPin(ChatId chatId) async =>
      ChatOperationResult.success('pinned');

  @override
  Future<ChatOperationResult> toggleMessageStar(MessageId messageId) async =>
      ChatOperationResult.success('starred');

  @override
  bool isChatPinned(ChatId chatId) => true;

  @override
  int get pinnedChatsCount => 3;

  @override
  bool isMessageStarred(MessageId messageId) => true;

  @override
  int get starredMessagesCount => 7;

  @override
  Future<List<EnhancedMessage>> getStarredMessages() async =>
      <EnhancedMessage>[];

  @override
  Future<MessageSearchResult> searchMessages({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    int limit = 50,
  }) async {
    return MessageSearchResult.empty();
  }

  @override
  Future<UnifiedSearchResult> searchMessagesUnified({
    required String query,
    String? chatId,
    MessageSearchFilter? filter,
    bool includeArchives = false,
    int limit = 50,
  }) async {
    return UnifiedSearchResult.empty();
  }

  @override
  Future<AdvancedSearchResult> performAdvancedSearch({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    bool includeLive = true,
    bool includeArchives = true,
  }) async {
    return AdvancedSearchResult.error(
      query: query,
      error: 'none',
      searchTime: Duration.zero,
    );
  }

  @override
  List<String> getMessageSearchHistory() => <String>['one', 'two'];

  @override
  Future<void> clearMessageSearchHistory() async {
    clearSearchHistoryCalls++;
  }
}
