/// Phase 11.3 — ChatSessionViewModel pure state transformer tests.
///
/// These test the ~15 state transformation methods that are pure functions
/// of ChatUIState → ChatUIState. No widget infrastructure needed because
/// they don't touch Flutter widgets, providers, or platform channels.
///
/// Also tests: bindStateStore, _canUpdateState guard, rebindControllers,
/// sendMessage empty-content guard, onSearchModeToggled, updateSearchQuery.
library;

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
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/notifiers/chat_session_state_notifier.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Minimal fakes — only what the constructor requires
// ---------------------------------------------------------------------------
class _FakeMessageRepo extends Fake implements IMessageRepository {}

class _FakeContactRepo extends Fake implements IContactRepository {}

class _FakeChatsRepo extends Fake implements IChatsRepository {
  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async => [];

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}
}

class _FakeMessagingVM extends Fake implements ChatMessagingViewModel {
  bool sendCalled = false;

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
  }
}

class _StubPairingController extends Fake
    implements ChatPairingDialogController {}

// ---------------------------------------------------------------------------
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Build a minimal ViewModel that can be instantiated without pumpWidget.
  // State-transformer methods are tested independently via a shared ViewModel.
  //
  // For methods that need a ScrollController (syncScrollState), we use a
  // testWidgets wrapper so the framework initializes the binding.

  late ChatSessionViewModel vm;
  late _FakeMessagingVM fakeMessaging;
  late _FakeChatsRepo chatsRepo;

  /// Build ViewModel inside a testWidgets so ScrollController is created
  /// in a valid binding context.
  Future<ChatSessionViewModel> buildVM(
    WidgetTester tester, {
    bool Function()? isDisposedFn,
  }) async {
    chatsRepo = _FakeChatsRepo();
    fakeMessaging = _FakeMessagingVM();
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
              onSearchResultsChanged: (_, _) {},
              onNavigateToResult: (_) {},
              scrollController: scrollCtl.scrollController,
            );

            viewModel = ChatSessionViewModel(
              config: const ChatScreenConfig(
                chatId: 'chat-1',
                contactName: 'Alice',
              ),
              messageRepository: _FakeMessageRepo(),
              contactRepository: _FakeContactRepo(),
              chatsRepository: chatsRepo,
              messagingViewModel: fakeMessaging,
              scrollingController: scrollCtl,
              searchController: searchCtl,
              pairingDialogController: _StubPairingController(),
              isDisposedFn: isDisposedFn,
            );

            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return viewModel;
  }

  // =======================================================================
  // Pure state transformers (no stateStore or scrolling needed)
  // =======================================================================

  group('applyMessageStatus', () {
    testWidgets('updates status of matching message', (tester) async {
      vm = await buildVM(tester);
      final state = ChatUIState(
        messages: [_msg(id: 'm1', status: MessageStatus.sending)],
      );
      final result =
          vm.applyMessageStatus(state, _mid('m1'), MessageStatus.delivered);
      expect(result.messages.first.status, MessageStatus.delivered);
    });

    testWidgets('no-op when message id not found', (tester) async {
      vm = await buildVM(tester);
      final state = ChatUIState(messages: [_msg(id: 'm1')]);
      final result =
          vm.applyMessageStatus(state, _mid('no-match'), MessageStatus.failed);
      expect(result.messages.first.status, MessageStatus.delivered);
    });
  });

  group('applyMessageUpdate', () {
    testWidgets('replaces matching message', (tester) async {
      vm = await buildVM(tester);
      final original = _msg(id: 'm1', content: 'old');
      final updated = original.copyWith(content: 'new');
      final state = ChatUIState(messages: [original]);
      final result = vm.applyMessageUpdate(state, updated);
      expect(result.messages.first.content, 'new');
    });

    testWidgets('no-op when message id not found', (tester) async {
      vm = await buildVM(tester);
      final state = ChatUIState(messages: [_msg(id: 'm1')]);
      final result =
          vm.applyMessageUpdate(state, _msg(id: 'no-match', content: 'x'));
      expect(result.messages.length, 1);
      expect(result.messages.first.content, 'hello');
    });
  });

  group('applySearchMode', () {
    testWidgets('sets search mode on', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(isSearchMode: false);
      expect(vm.applySearchMode(state, true).isSearchMode, isTrue);
    });

    testWidgets('sets search mode off', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(isSearchMode: true);
      expect(vm.applySearchMode(state, false).isSearchMode, isFalse);
    });
  });

  group('applySearchQuery', () {
    testWidgets('updates query string', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(searchQuery: '');
      final result = vm.applySearchQuery(state, 'hello');
      expect(result.searchQuery, 'hello');
    });
  });

  group('applyMessages', () {
    testWidgets('replaces entire message list', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState();
      final msgs = [_msg(id: 'a'), _msg(id: 'b')];
      final result = vm.applyMessages(state, msgs);
      expect(result.messages.length, 2);
    });
  });

  group('applyLoading', () {
    testWidgets('sets loading true', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(isLoading: false);
      expect(vm.applyLoading(state, true).isLoading, isTrue);
    });

    testWidgets('sets loading false', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(isLoading: true);
      expect(vm.applyLoading(state, false).isLoading, isFalse);
    });
  });

  group('clearNewWhileScrolledUp', () {
    testWidgets('resets counter to zero', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(newMessagesWhileScrolledUp: 5);
      expect(vm.clearNewWhileScrolledUp(state).newMessagesWhileScrolledUp, 0);
    });
  });

  group('appendMessage', () {
    testWidgets('appends to end of list', (tester) async {
      vm = await buildVM(tester);
      final state = ChatUIState(messages: [_msg(id: 'a')]);
      final result = vm.appendMessage(state, _msg(id: 'b'));
      expect(result.messages.length, 2);
      expect(result.messages.last.id, _mid('b'));
    });
  });

  group('removeMessageById', () {
    testWidgets('removes matching message', (tester) async {
      vm = await buildVM(tester);
      final state = ChatUIState(
        messages: [_msg(id: 'a'), _msg(id: 'b'), _msg(id: 'c')],
      );
      final result = vm.removeMessageById(state, _mid('b'));
      expect(result.messages.length, 2);
      expect(result.messages.any((m) => m.id == _mid('b')), isFalse);
    });

    testWidgets('no-op when id not found', (tester) async {
      vm = await buildVM(tester);
      final state = ChatUIState(messages: [_msg(id: 'a')]);
      final result = vm.removeMessageById(state, _mid('no-match'));
      expect(result.messages.length, 1);
    });
  });

  group('applyUnreadCount', () {
    testWidgets('updates unread count', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(unreadMessageCount: 0);
      expect(vm.applyUnreadCount(state, 7).unreadMessageCount, 7);
    });
  });

  group('applyMeshState', () {
    testWidgets('updates mesh flags', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(
        meshInitializing: false,
        initializationStatus: 'idle',
      );
      final result = vm.applyMeshState(
        state,
        meshInitializing: true,
        initializationStatus: 'Connecting...',
      );
      expect(result.meshInitializing, isTrue);
      expect(result.initializationStatus, 'Connecting...');
    });
  });

  group('applyInitializationStatus', () {
    testWidgets('updates status text', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(initializationStatus: 'old');
      final result = vm.applyInitializationStatus(state, 'Ready');
      expect(result.initializationStatus, 'Ready');
    });
  });

  group('syncScrollState', () {
    testWidgets('syncs unread/scroll flags from controller', (tester) async {
      vm = await buildVM(tester);
      final state = const ChatUIState(unreadMessageCount: 99);
      // scrollingController starts fresh → unreadMessageCount=0
      final result = vm.syncScrollState(state);
      expect(result.unreadMessageCount, 0);
      expect(result.newMessagesWhileScrolledUp, 0);
      expect(result.showUnreadSeparator, isFalse);
    });
  });

  // =======================================================================
  // bindStateStore & _canUpdateState guard
  // =======================================================================

  group('bindStateStore and _canUpdateState', () {
    testWidgets('stateStore is null before bind', (tester) async {
      vm = await buildVM(tester);
      expect(vm.stateStore, isNull);
    });

    testWidgets('bindStateStore sets the store', (tester) async {
      vm = await buildVM(tester);
      final store = ChatSessionStateStore();
      vm.bindStateStore(store);
      expect(vm.stateStore, store);
      store.dispose();
    });

    testWidgets('onSearchModeToggled updates store when canUpdate',
        (tester) async {
      vm = await buildVM(tester);
      final store = ChatSessionStateStore();
      vm.bindStateStore(store);
      vm.onSearchModeToggled(true);
      expect(store.current.isSearchMode, isTrue);
      store.dispose();
    });

    testWidgets('onSearchModeToggled is no-op on disposed store',
        (tester) async {
      vm = await buildVM(tester);
      final store = ChatSessionStateStore();
      vm.bindStateStore(store);
      store.dispose();
      // Should not throw
      vm.onSearchModeToggled(true);
    });

    testWidgets('updateSearchQuery updates store', (tester) async {
      vm = await buildVM(tester);
      final store = ChatSessionStateStore();
      vm.bindStateStore(store);
      vm.updateSearchQuery('test query');
      expect(store.current.searchQuery, 'test query');
      store.dispose();
    });

    testWidgets('updateSearchQuery is no-op on disposed store',
        (tester) async {
      vm = await buildVM(tester);
      final store = ChatSessionStateStore();
      vm.bindStateStore(store);
      store.dispose();
      vm.updateSearchQuery('should not crash');
    });
  });

  // =======================================================================
  // rebindControllers
  // =======================================================================
  group('rebindControllers', () {
    testWidgets('swaps controllers and invokes callback', (tester) async {
      var callbackInvoked = false;
      ChatMessagingViewModel? prevMvm;
      chat_controller.ChatScrollingController? prevScroll;
      ChatSearchController? prevSearch;

      late ChatSessionViewModel viewModel;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final chats = _FakeChatsRepo();
              final scrollCtl = chat_controller.ChatScrollingController(
                chatsRepository: chats,
                chatId: _cid('chat-1'),
                onScrollToBottom: () {},
                onUnreadCountChanged: (_) {},
                onStateChanged: () {},
              );
              final searchCtl = ChatSearchController(
                onSearchModeToggled: (_) {},
                onSearchResultsChanged: (_, _) {},
                onNavigateToResult: (_) {},
                scrollController: scrollCtl.scrollController,
              );

              viewModel = ChatSessionViewModel(
                config: const ChatScreenConfig(
                  chatId: 'chat-1',
                  contactName: 'Bob',
                ),
                messageRepository: _FakeMessageRepo(),
                contactRepository: _FakeContactRepo(),
                chatsRepository: chats,
                messagingViewModel: _FakeMessagingVM(),
                scrollingController: scrollCtl,
                searchController: searchCtl,
                pairingDialogController: _StubPairingController(),
                onControllersRebound: ({
                  required messagingViewModel,
                  required scrollingController,
                  required searchController,
                  previousMessagingViewModel,
                  previousScrollingController,
                  previousSearchController,
                }) {
                  callbackInvoked = true;
                  prevMvm = previousMessagingViewModel;
                  prevScroll = previousScrollingController;
                  prevSearch = previousSearchController;
                },
              );

              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final originalMvm = viewModel.messagingViewModel;
      final originalScroll = viewModel.scrollingController;
      final originalSearch = viewModel.searchController;

      // Create new controllers
      final newScrollCtl = chat_controller.ChatScrollingController(
        chatsRepository: _FakeChatsRepo(),
        chatId: _cid('chat-2'),
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
        onStateChanged: () {},
      );
      final newSearchCtl = ChatSearchController(
        scrollController: newScrollCtl.scrollController,
      );
      final newMvm = _FakeMessagingVM();

      viewModel.rebindControllers(
        messagingViewModel: newMvm,
        scrollingController: newScrollCtl,
        searchController: newSearchCtl,
      );

      expect(callbackInvoked, isTrue);
      expect(viewModel.messagingViewModel, same(newMvm));
      expect(viewModel.scrollingController, same(newScrollCtl));
      expect(viewModel.searchController, same(newSearchCtl));
      expect(prevMvm, same(originalMvm));
      expect(prevScroll, same(originalScroll));
      expect(prevSearch, same(originalSearch));
    });
  });

  // =======================================================================
  // sendMessage empty content guard
  // =======================================================================
  group('sendMessage', () {
    testWidgets('empty content is rejected', (tester) async {
      vm = await buildVM(tester);
      await vm.sendMessage('');
      expect(fakeMessaging.sendCalled, isFalse);
    });

    testWidgets('whitespace-only content is rejected', (tester) async {
      vm = await buildVM(tester);
      await vm.sendMessage('   \t\n  ');
      expect(fakeMessaging.sendCalled, isFalse);
    });

    testWidgets('non-empty content calls messagingViewModel', (tester) async {
      vm = await buildVM(tester);
      await vm.sendMessage('hello');
      expect(fakeMessaging.sendCalled, isTrue);
    });
  });

  // =======================================================================
  // isDisposed guard
  // =======================================================================
  group('_isDisposed guard', () {
    testWidgets('_canUpdateState false when isDisposedFn returns true',
        (tester) async {
      vm = await buildVM(tester, isDisposedFn: () => true);
      final store = ChatSessionStateStore();
      vm.bindStateStore(store);

      // Operations that use _canUpdateState should silently skip
      vm.onSearchModeToggled(true);
      expect(store.current.isSearchMode, isFalse); // unchanged
      store.dispose();
    });
  });

  // =======================================================================
  // autoRetryFailedMessages (no sessionLifecycle)
  // =======================================================================
  group('autoRetryFailedMessages', () {
    testWidgets('returns normally when sessionLifecycle is null',
        (tester) async {
      vm = await buildVM(tester);
      // Should complete without error
      await vm.autoRetryFailedMessages();
    });
  });

  // =======================================================================
  // scrollToBottom delegates
  // =======================================================================
  group('scrollToBottom', () {
    testWidgets('does not throw', (tester) async {
      vm = await buildVM(tester);
      // scrollingController.scrollToBottom depends on scrollController
      // being attached — it won't scroll but shouldn't throw
      vm.scrollToBottom();
    });
  });

  // =======================================================================
  // toggleSearchMode delegates to searchController
  // =======================================================================
  group('toggleSearchMode', () {
    testWidgets('toggles via searchController', (tester) async {
      vm = await buildVM(tester);
      vm.toggleSearchMode();
      // Doesn't crash, just delegates
    });
  });
}
