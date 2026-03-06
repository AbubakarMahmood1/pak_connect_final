/// Phase 12.10 — ChatSessionViewModel supplementary coverage.
///
/// Targets: sendMessage error path, deleteMessage, loadMessages,
///          retryRepositoryMessage, addReceivedMessage
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_pairing_dialog_controller.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import 'package:pak_connect/presentation/controllers/chat_search_controller.dart';
import 'package:pak_connect/presentation/models/chat_screen_config.dart';
import 'package:pak_connect/presentation/notifiers/chat_session_state_notifier.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';

// ───────────── Helpers ─────────────
ChatId _cid(String v) => ChatId(v);
MessageId _mid(String v) => MessageId(v);

Message _msg({
  required String id,
  String chatId = 'chat-1',
  String content = 'hello',
  bool isFromMe = true,
  MessageStatus status = MessageStatus.delivered,
}) =>
    Message(
      id: _mid(id),
      chatId: _cid(chatId),
      content: content,
      timestamp: DateTime(2024, 1, 1),
      isFromMe: isFromMe,
      status: status,
    );

// ───────────── Fakes ─────────────
class _FakeMessageRepo extends Fake implements IMessageRepository {
  final List<Message> updatedMessages = [];
  bool shouldThrow = false;
  int throwAfterCount = -1; // throw after N successful calls (-1 = never)
  int _callCount = 0;

  @override
  Future<void> updateMessage(Message message) async {
    _callCount++;
    if (shouldThrow || (throwAfterCount >= 0 && _callCount > throwAfterCount)) {
      throw Exception('update failed');
    }
    updatedMessages.add(message);
  }
}

class _FakeContactRepo extends Fake implements IContactRepository {}

class _FakeChatsRepo extends Fake implements IChatsRepository {
  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async =>
      [];

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}
}

class _ThrowingMessagingVM extends Fake implements ChatMessagingViewModel {
  bool shouldThrowOnSend = false;
  bool shouldThrowOnDelete = false;
  bool sendCalled = false;
  bool deleteCalled = false;
  List<Message> loadedMessages = [];
  bool shouldThrowOnLoad = false;

  @override
  Future<void> sendMessage({
    required String content,
    OnMessageAddedCallback? onMessageAdded,
    OnShowSuccessCallback? onShowSuccess,
    OnShowErrorCallback? onShowError,
    OnScrollToBottomCallback? onScrollToBottom,
    OnClearInputFieldCallback? onClearInputField,
  }) async {
    sendCalled = true;
    if (shouldThrowOnSend) throw Exception('send error');
    onMessageAdded?.call(_msg(id: 'new-msg', content: content));
  }

  @override
  Future<void> deleteMessage({
    required MessageId messageId,
    bool deleteForEveryone = false,
    OnMessageRemovedCallback? onMessageRemoved,
    OnShowSuccessCallback? onShowSuccess,
    OnShowErrorCallback? onShowError,
  }) async {
    deleteCalled = true;
    if (shouldThrowOnDelete) throw Exception('delete error');
    onMessageRemoved?.call(messageId);
  }

  @override
  Future<List<Message>> loadMessages({
    OnLoadingStateChangedCallback? onLoadingStateChanged,
    OnGetQueuedMessagesCallback? onGetQueuedMessages,
    OnScrollToBottomCallback? onScrollToBottom,
    OnShowErrorCallback? onError,
  }) async {
    if (shouldThrowOnLoad) throw Exception('load error');
    return loadedMessages;
  }
}

class _StubPairingController extends Fake
    implements ChatPairingDialogController {}

// ───────────── Tests ─────────────
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatSessionViewModel vm;
  late _ThrowingMessagingVM fakeMessaging;
  late _FakeChatsRepo chatsRepo;
  late _FakeMessageRepo messageRepo;

  Future<ChatSessionViewModel> buildVM(
    WidgetTester tester, {
    bool Function()? isDisposedFn,
  }) async {
    chatsRepo = _FakeChatsRepo();
    fakeMessaging = _ThrowingMessagingVM();
    messageRepo = _FakeMessageRepo();
    late ChatSessionViewModel viewModel;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final scrollCtl = chat_controller.ChatScrollingController(
              chatsRepository: chatsRepo,
              chatId: _cid('chat-1'),
              onScrollToBottom: () {},
              onUnreadCountChanged: (_) {},
              onStateChanged: () {},
            );
            final searchCtl = ChatSearchController(
              onSearchModeToggled: (_) {},
              onSearchResultsChanged: (_, __) {},
              onNavigateToResult: (_) {},
              scrollController: scrollCtl.scrollController,
            );

            viewModel = ChatSessionViewModel(
              config: const ChatScreenConfig(
                chatId: 'chat-1',
                contactName: 'Alice',
              ),
              messageRepository: messageRepo,
              contactRepository: _FakeContactRepo(),
              chatsRepository: chatsRepo,
              messagingViewModel: fakeMessaging,
              scrollingController: scrollCtl,
              searchController: searchCtl,
              pairingDialogController: _StubPairingController(),
              isDisposedFn: isDisposedFn,
              getChatIdFn: () => 'chat-1',
              getContactPublicKeyFn: () => 'pk_alice',
              displayContactNameFn: () => 'Alice',
            );

            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await tester.pumpAndSettle();
    return viewModel;
  }

  group('ChatSessionViewModel - sendMessage error path', () {
    testWidgets('catches exception from messagingViewModel', (tester) async {
      vm = await buildVM(tester);
      fakeMessaging.shouldThrowOnSend = true;

      // Should not throw — error is caught internally
      await vm.sendMessage('test message');
      expect(fakeMessaging.sendCalled, isTrue);
    });

    testWidgets('sendMessage with bound store appends message', (tester) async {
      vm = await buildVM(tester);

      final store = ChatSessionStateStore();
      vm.bindStateStore(store);

      await vm.sendMessage('hello world');

      expect(fakeMessaging.sendCalled, isTrue);
      expect(store.current.messages, isNotEmpty);
    });
  });

  group('ChatSessionViewModel - deleteMessage', () {
    testWidgets('successful delete removes from store', (tester) async {
      vm = await buildVM(tester);

      final store = ChatSessionStateStore();
      store.setMessages([_msg(id: 'msg-1'), _msg(id: 'msg-2')]);
      vm.bindStateStore(store);

      await vm.deleteMessage(_mid('msg-1'), false);

      expect(fakeMessaging.deleteCalled, isTrue);
      expect(store.current.messages.length, 1);
      expect(store.current.messages.first.id.value, 'msg-2');
    });

    testWidgets('delete error is caught gracefully', (tester) async {
      vm = await buildVM(tester);
      fakeMessaging.shouldThrowOnDelete = true;

      await vm.deleteMessage(_mid('msg-1'), false);
      expect(fakeMessaging.deleteCalled, isTrue);
      // No throw
    });
  });

  group('ChatSessionViewModel - loadMessages', () {
    testWidgets('loadMessages populates store', (tester) async {
      vm = await buildVM(tester);
      fakeMessaging.loadedMessages = [
        _msg(id: 'a'),
        _msg(id: 'b'),
      ];

      final store = ChatSessionStateStore();
      vm.bindStateStore(store);

      await vm.loadMessages();

      expect(store.current.messages.length, 2);
    });

    testWidgets('loadMessages error shows error message', (tester) async {
      fakeMessaging = _ThrowingMessagingVM();
      fakeMessaging.shouldThrowOnLoad = true;
      String? errorMsg;

      final store = ChatSessionStateStore();
      store.setLoading(true);

      // Create a VM with onShowError to capture
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final scrollCtl = chat_controller.ChatScrollingController(
                chatsRepository: _FakeChatsRepo(),
                chatId: _cid('chat-1'),
                onScrollToBottom: () {},
                onUnreadCountChanged: (_) {},
                onStateChanged: () {},
              );
              final searchCtl = ChatSearchController(
                onSearchModeToggled: (_) {},
                onSearchResultsChanged: (_, __) {},
                onNavigateToResult: (_) {},
                scrollController: scrollCtl.scrollController,
              );

              vm = ChatSessionViewModel(
                config: const ChatScreenConfig(
                  chatId: 'chat-1',
                  contactName: 'Alice',
                ),
                messageRepository: _FakeMessageRepo(),
                contactRepository: _FakeContactRepo(),
                chatsRepository: _FakeChatsRepo(),
                messagingViewModel: fakeMessaging,
                scrollingController: scrollCtl,
                searchController: searchCtl,
                pairingDialogController: _StubPairingController(),
                onShowError: (msg) => errorMsg = msg,
              );
              vm.bindStateStore(store);

              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await vm.loadMessages();

      expect(errorMsg, isNotNull);
      expect(errorMsg, contains('Failed to load'));
    });
  });

  group('ChatSessionViewModel - retryRepositoryMessage', () {
    testWidgets('retry without sessionLifecycle marks as failed',
        (tester) async {
      vm = await buildVM(tester);
      // sessionLifecycle is null → success = false → status = failed
      final msg = _msg(id: 'fail-1', status: MessageStatus.failed);

      await vm.retryRepositoryMessage(msg);

      // First update sets sending, second sets failed (no lifecycle → false)
      expect(messageRepo.updatedMessages.length, 2);
      expect(messageRepo.updatedMessages[0].status, MessageStatus.sending);
      expect(messageRepo.updatedMessages[1].status, MessageStatus.failed);
    });

    testWidgets('retry catches updateMessage error and rethrows',
        (tester) async {
      vm = await buildVM(tester);
      messageRepo.throwAfterCount = 0; // first call fails

      final msg = _msg(id: 'fail-1', status: MessageStatus.failed);

      Object? caught;
      try {
        await vm.retryRepositoryMessage(msg);
      } catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
    });
  });
}
