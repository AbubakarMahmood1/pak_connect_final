import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/interfaces/i_chat_interaction_handler.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/services/chat_interaction_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatInteractionHandler', () {
    late _RecordingChatsRepository chatsRepository;
    late _FakeChatManagementService chatManagementService;
    late _FakeSharedQueueProvider sharedQueueProvider;
    late _FakeOfflineQueue offlineQueue;

    setUp(() {
      chatsRepository = _RecordingChatsRepository();
      chatManagementService = _FakeChatManagementService();
      offlineQueue = _FakeOfflineQueue();
      sharedQueueProvider = _FakeSharedQueueProvider(queue: offlineQueue);
    });

    test('initialize, search intents, and dispose lifecycle', () async {
      final handler = ChatInteractionHandler();
      final intents = <ChatInteractionIntent>[];
      final sub = handler.interactionIntentStream.listen(intents.add);

      await handler.initialize();
      handler.toggleSearch();
      handler.showSearch();
      handler.clearSearch();
      await Future<void>.delayed(Duration.zero);

      expect(intents.whereType<SearchToggleIntent>().length, 3);
      expect(
        intents.whereType<SearchToggleIntent>().map(
          (intent) => intent.isActive,
        ),
        <bool>[true, true, false],
      );

      await handler.dispose();
      intents.clear();
      handler.showSearch();
      await Future<void>.delayed(Duration.zero);
      expect(intents, isEmpty);

      await sub.cancel();
    });

    test('handleMenuAction routes recognized actions and ignores unknown', () {
      final handler = ChatInteractionHandler();
      handler.handleMenuAction('openProfile');
      handler.handleMenuAction('openContacts');
      handler.handleMenuAction('openArchives');
      handler.handleMenuAction('settings');
      handler.handleMenuAction('unknown_action');
    });

    testWidgets('showArchiveConfirmation supports cancel and confirm', (
      tester,
    ) async {
      final context = await _pumpTestContext(tester);
      final handler = ChatInteractionHandler(context: context);
      final chat = _chat(chatId: 'chat-archive', unread: 1);

      final cancelFuture = handler.showArchiveConfirmation(chat);
      await tester.pumpAndSettle();
      expect(find.text('Archive Chat'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await cancelFuture, isFalse);

      final confirmFuture = handler.showArchiveConfirmation(chat);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      expect(await confirmFuture, isTrue);
    });

    testWidgets('showDeleteConfirmation supports cancel and confirm', (
      tester,
    ) async {
      final context = await _pumpTestContext(tester);
      final handler = ChatInteractionHandler(context: context);
      final chat = _chat(chatId: 'chat-delete', unread: 0);

      final cancelFuture = handler.showDeleteConfirmation(chat);
      await tester.pumpAndSettle();
      expect(find.text('Delete Chat'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await cancelFuture, isFalse);

      final confirmFuture = handler.showDeleteConfirmation(chat);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await confirmFuture, isTrue);
    });

    test('deleteChat success purges queue and emits delete intent', () async {
      chatManagementService.deleteResponses['chat-delete-success'] =
          ChatOperationResult.success('deleted');

      final handler = ChatInteractionHandler(
        chatsRepository: chatsRepository,
        chatManagementService: chatManagementService,
        sharedQueueProvider: sharedQueueProvider,
      );
      final intents = <ChatInteractionIntent>[];
      final sub = handler.interactionIntentStream.listen(intents.add);

      final chat = _chat(chatId: 'chat-delete-success', unread: 2);
      await handler.deleteChat(chat);
      await Future<void>.delayed(Duration.zero);

      expect(chatManagementService.deleteCalls, <String>[
        'chat-delete-success',
      ]);
      expect(sharedQueueProvider.initializeCalls, 1);
      expect(offlineQueue.removedChatIds, <String>['chat-delete-success']);
      expect(
        intents.whereType<ChatDeletedIntent>().single.chatId,
        'chat-delete-success',
      );

      await sub.cancel();
    });

    test(
      'deleteChat failure does not emit delete intent or purge queue',
      () async {
        chatManagementService.deleteResponses['chat-delete-fail'] =
            ChatOperationResult.failure('boom');

        final handler = ChatInteractionHandler(
          chatsRepository: chatsRepository,
          chatManagementService: chatManagementService,
          sharedQueueProvider: sharedQueueProvider,
        );
        final intents = <ChatInteractionIntent>[];
        final sub = handler.interactionIntentStream.listen(intents.add);

        final chat = _chat(chatId: 'chat-delete-fail', unread: 0);
        await handler.deleteChat(chat);
        await Future<void>.delayed(Duration.zero);

        expect(chatManagementService.deleteCalls, <String>['chat-delete-fail']);
        expect(sharedQueueProvider.initializeCalls, 0);
        expect(offlineQueue.removedChatIds, isEmpty);
        expect(intents.whereType<ChatDeletedIntent>(), isEmpty);

        await sub.cancel();
      },
    );

    test('toggleChatPin and markChatAsRead delegate and emit intent', () async {
      chatManagementService.pinResponses[const ChatId('chat-pin')] =
          ChatOperationResult.success('pinned');

      final handler = ChatInteractionHandler(
        chatsRepository: chatsRepository,
        chatManagementService: chatManagementService,
      );
      final intents = <ChatInteractionIntent>[];
      final sub = handler.interactionIntentStream.listen(intents.add);
      final chat = _chat(chatId: 'chat-pin', unread: 4);

      await handler.toggleChatPin(chat);
      await Future<void>.delayed(Duration.zero);
      expect(intents.whereType<ChatPinToggleIntent>().length, 1);
      expect(chatManagementService.toggleCalls, <ChatId>[
        const ChatId('chat-pin'),
      ]);

      await handler.markChatAsRead(chat.chatId);
      expect(chatsRepository.markedReadChatIds, <ChatId>[chat.chatId]);

      await sub.cancel();
    });

    testWidgets('showChatContextMenu handles mark-read and pin actions', (
      tester,
    ) async {
      chatManagementService.pinResponses[const ChatId('chat-menu-pin')] =
          ChatOperationResult.success('pinned');

      final context = await _pumpTestContext(tester);
      final handler = ChatInteractionHandler(
        context: context,
        chatsRepository: chatsRepository,
        chatManagementService: chatManagementService,
      );

      handler.showChatContextMenu(_chat(chatId: 'chat-menu-read', unread: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as Read'));
      await tester.pumpAndSettle();
      expect(
        chatsRepository.markedReadChatIds,
        contains(const ChatId('chat-menu-read')),
      );

      handler.showChatContextMenu(_chat(chatId: 'chat-menu-pin', unread: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin Chat'));
      await tester.pumpAndSettle();
      expect(
        chatManagementService.toggleCalls,
        contains(const ChatId('chat-menu-pin')),
      );
    });

    test('formatTime returns expected relative labels', () {
      final handler = ChatInteractionHandler();
      final now = DateTime.now();

      expect(
        handler.formatTime(now.subtract(const Duration(seconds: 10))),
        'Just now',
      );
      expect(
        handler.formatTime(now.subtract(const Duration(minutes: 10))),
        '10m ago',
      );
      expect(
        handler.formatTime(now.subtract(const Duration(hours: 3))),
        '3h ago',
      );
      expect(
        handler.formatTime(now.subtract(const Duration(days: 2))),
        '2d ago',
      );
    });
  });
}

Future<BuildContext> _pumpTestContext(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    ),
  );
  return context;
}

ChatListItem _chat({required String chatId, required int unread}) {
  final now = DateTime(2026, 1, 1, 12);
  return ChatListItem(
    chatId: ChatId(chatId),
    contactName: 'Contact $chatId',
    contactPublicKey: 'pk-$chatId',
    lastMessage: 'hello',
    lastMessageTime: now,
    unreadCount: unread,
    isOnline: true,
    hasUnsentMessages: false,
    lastSeen: now,
  );
}

class _RecordingChatsRepository implements IChatsRepository {
  final List<ChatId> markedReadChatIds = <ChatId>[];

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    markedReadChatIds.add(chatId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected call: $invocation');
}

class _FakeChatManagementService implements ChatManagementService {
  final Map<String, ChatOperationResult> deleteResponses =
      <String, ChatOperationResult>{};
  final Map<ChatId, ChatOperationResult> pinResponses =
      <ChatId, ChatOperationResult>{};
  final Set<ChatId> pinnedChats = <ChatId>{};

  final List<String> deleteCalls = <String>[];
  final List<ChatId> toggleCalls = <ChatId>[];

  @override
  Future<ChatOperationResult> deleteChat(String chatId) async {
    deleteCalls.add(chatId);
    return deleteResponses[chatId] ??
        ChatOperationResult.failure('no delete response configured');
  }

  @override
  Future<ChatOperationResult> toggleChatPin(ChatId chatId) async {
    toggleCalls.add(chatId);
    return pinResponses[chatId] ??
        ChatOperationResult.failure('no pin response configured');
  }

  @override
  bool isChatPinned(ChatId chatId) => pinnedChats.contains(chatId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected management call: $invocation');
}

class _FakeSharedQueueProvider implements ISharedMessageQueueProvider {
  _FakeSharedQueueProvider({required OfflineMessageQueueContract queue})
    : _queue = queue;

  final OfflineMessageQueueContract _queue;
  int initializeCalls = 0;
  bool _isInitialized = false;

  @override
  bool get isInitialized => _isInitialized;

  @override
  bool get isInitializing => false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    _isInitialized = true;
  }

  @override
  OfflineMessageQueueContract get messageQueue => _queue;
}

class _FakeOfflineQueue implements OfflineMessageQueueContract {
  final List<String> removedChatIds = <String>[];

  @override
  Future<int> removeMessagesForChat(String chatId) async {
    removedChatIds.add(chatId);
    return 2;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected queue call: $invocation');
}
