import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/notifiers/chat_session_state_notifier.dart';

Message _message({
  required String id,
  String content = 'content',
  MessageStatus status = MessageStatus.sent,
}) {
  return Message(
    id: MessageId(id),
    chatId: const ChatId('chat-1'),
    content: content,
    timestamp: DateTime(2026, 1, 1),
    isFromMe: true,
    status: status,
  );
}

void main() {
  group('ChatSessionStateStore', () {
    late ChatSessionStateStore store;

    setUp(() {
      store = ChatSessionStateStore();
    });

    test('replace and update mutate state and current snapshot', () {
      store.replace(store.current.copyWith(isLoading: false));
      expect(store.current.isLoading, isFalse);

      store.update((state) => state.copyWith(searchQuery: 'term'));
      expect(store.current.searchQuery, 'term');
    });

    test('message helpers set, append, update, status-update, and remove', () {
      final first = _message(id: 'm1', content: 'first');
      final second = _message(id: 'm2', content: 'second');

      store.setMessages([first]);
      expect(store.current.messages.map((m) => m.id.value), ['m1']);

      store.appendMessage(second);
      expect(store.current.messages.map((m) => m.id.value), ['m1', 'm2']);

      store.updateMessage(_message(id: 'm2', content: 'updated'));
      expect(store.current.messages.last.content, 'updated');

      store.updateMessageStatus(const MessageId('m2'), MessageStatus.delivered);
      expect(store.current.messages.last.status, MessageStatus.delivered);

      store.removeMessage(const MessageId('m1'));
      expect(store.current.messages.map((m) => m.id.value), ['m2']);
    });

    test('ui flags and mesh state helpers update expected fields', () {
      store.setLoading(false);
      expect(store.current.isLoading, isFalse);

      store.setUnreadCount(5);
      expect(store.current.unreadMessageCount, 5);

      store.update((state) => state.copyWith(newMessagesWhileScrolledUp: 7));
      store.clearNewWhileScrolledUp();
      expect(store.current.newMessagesWhileScrolledUp, 0);

      store.setSearchMode(true);
      store.setSearchQuery('needle');
      expect(store.current.isSearchMode, isTrue);
      expect(store.current.searchQuery, 'needle');

      store.setMeshState(
        meshInitializing: true,
        initializationStatus: 'Initializing mesh',
      );
      expect(store.current.meshInitializing, isTrue);
      expect(store.current.initializationStatus, 'Initializing mesh');

      store.setInitializationStatus('Ready');
      expect(store.current.initializationStatus, 'Ready');
    });

    test('markMounted false blocks further updates', () {
      store.markMounted(false);

      store.setLoading(false);
      store.setSearchQuery('blocked');
      store.appendMessage(_message(id: 'blocked'));

      expect(store.current.isLoading, isTrue);
      expect(store.current.searchQuery, '');
      expect(store.current.messages, isEmpty);
    });

    test('dispose freezes snapshot and ignores subsequent writes', () {
      store.setSearchQuery('before-dispose');
      store.appendMessage(_message(id: 'm1'));
      final snapshotBeforeDispose = store.current;

      store.dispose();

      expect(store.isDisposed, isTrue);
      expect(store.isMounted, isFalse);
      expect(store.current.searchQuery, snapshotBeforeDispose.searchQuery);
      expect(
        store.current.messages.length,
        snapshotBeforeDispose.messages.length,
      );

      store.setSearchQuery('after-dispose');
      store.appendMessage(_message(id: 'm2'));

      expect(store.current.searchQuery, 'before-dispose');
      expect(store.current.messages.length, 1);
    });
  });
}
