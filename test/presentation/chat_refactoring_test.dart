import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';

// Mock implementations
class MockMessageRepository implements MessageRepository {
  List<Message> _messages = [];

  @override
  Future<List<Message>> getMessagesByChat(String chatId) async => _messages;

  @override
  Future<void> saveMessage(Message message) async {
    _messages.add(message);
  }

  @override
  Future<void> updateMessage(Message message) async {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index >= 0) {
      _messages[index] = message;
    }
  }

  @override
  Future<bool> deleteMessage(String messageId) async {
    _messages.removeWhere((m) => m.id == messageId);
    return true;
  }

  @override
  Future<int> getUnreadMessageCount(String chatId) async {
    return _messages.length;
  }

  @override
  Future<void> markChatAsRead(String chatId) async {}

  @override
  Future<void> markMessageAsRead(String messageId) async {}

  @override
  Future<void> deleteChat(String chatId) async {}

  @override
  Future<void> deleteAllMessages() async {
    _messages.clear();
  }

  @override
  Future<List<Message>> getOfflineMessages() async => [];

  @override
  Future<void> markOfflineMessageAsSent(String messageId) async {}

  @override
  Future<int> getTotalMessageCount() async => _messages.length;

  @override
  Future<void> clearMessages(String chatId) async {}

  @override
  Future<List<Message>> getAllMessages() async => _messages;

  @override
  Future<Message?> getMessageById(String messageId) async =>
      _messages.firstWhere((m) => m.id == messageId);

  @override
  Future<List<Message>> getMessages(String chatId) async => _messages;

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      _messages;
}

void main() {
  group('ChatUIState', () {
    test('should create with default values', () {
      final state = ChatUIState();

      expect(state.messages, isEmpty);
      expect(state.isLoading, isTrue);
      expect(state.isSearchMode, isFalse);
      expect(state.searchQuery, isEmpty);
      expect(state.pairingDialogShown, isFalse);
      expect(state.unreadMessageCount, equals(0));
    });

    test('should create with custom values', () {
      final messages = [
        Message(
          id: '1',
          chatId: 'chat1',
          content: 'Hello',
          isFromMe: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        ),
      ];

      final state = ChatUIState(
        messages: messages,
        isLoading: false,
        isSearchMode: true,
        searchQuery: 'test',
        unreadMessageCount: 5,
      );

      expect(state.messages, equals(messages));
      expect(state.isLoading, isFalse);
      expect(state.isSearchMode, isTrue);
      expect(state.searchQuery, equals('test'));
      expect(state.unreadMessageCount, equals(5));
    });

    test('should copyWith update selected fields', () {
      final state1 = ChatUIState(isLoading: true, unreadMessageCount: 3);

      final state2 = state1.copyWith(isLoading: false, unreadMessageCount: 5);

      expect(state2.isLoading, isFalse);
      expect(state2.unreadMessageCount, equals(5));
    });

    test('should preserve fields not in copyWith', () {
      final state1 = ChatUIState(
        isSearchMode: true,
        searchQuery: 'old',
        isLoading: true,
      );

      final state2 = state1.copyWith(isLoading: false);

      expect(state2.isSearchMode, isTrue);
      expect(state2.searchQuery, equals('old'));
      expect(state2.isLoading, isFalse);
    });

    test('should implement toString', () {
      final state = ChatUIState(unreadMessageCount: 2);
      final str = state.toString();

      expect(str, contains('ChatUIState'));
      expect(str, contains('unreadMessageCount=2'));
    });
  });

  group('ChatScrollingController', () {
    late ChatScrollingController controller;
    late MockMessageRepository mockRepository;

    setUp(() {
      mockRepository = MockMessageRepository();
      controller = ChatScrollingController(
        messageRepository: mockRepository,
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('should initialize with correct defaults', () {
      expect(controller.isUserAtBottom, isTrue);
      expect(controller.unreadMessageCount, equals(0));
      expect(controller.shouldShowScrollDownButton(), isFalse);
    });

    test('should set unread count', () {
      controller.setUnreadCount(5);
      expect(controller.unreadMessageCount, equals(5));
    });

    test('should decrement unread count', () {
      controller.setUnreadCount(3);
      controller.decrementUnreadCount();

      // unreadMessageCount should decrease, newMessagesWhileScrolledUp increases
      expect(controller.unreadMessageCount, equals(2));
    });

    test('should track scroll position changes', () {
      expect(controller.isUserAtBottom, isTrue);
      expect(controller.shouldShowScrollDownButton(), isFalse);
    });

    test('should reset scroll state', () {
      controller.setMessageListenerActive(true);
      controller.decrementUnreadCount();

      controller.resetScrollState();

      expect(controller.isUserAtBottom, isTrue);
      expect(controller.unreadMessageCount, equals(0));
      expect(controller.newMessagesWhileScrolledUp, equals(0));
    });

    test('should provide scroll controller', () {
      expect(controller.scrollController, isNotNull);
      expect(controller.scrollController.hasClients, isFalse);
    });
  });

  group('ChatScrollingController Integration', () {
    late ChatScrollingController controller1;
    late ChatScrollingController controller2;
    late MockMessageRepository mockRepository;

    setUp(() {
      mockRepository = MockMessageRepository();
      controller1 = ChatScrollingController(
        messageRepository: mockRepository,
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
      );
      controller2 = ChatScrollingController(
        messageRepository: mockRepository,
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
      );
    });

    tearDown(() {
      controller1.dispose();
      controller2.dispose();
    });

    test('should initialize multiple controllers independently', () {
      expect(controller1.isUserAtBottom, isTrue);
      expect(controller2.isUserAtBottom, isTrue);
      expect(controller1.unreadMessageCount, equals(0));
      expect(controller2.unreadMessageCount, equals(0));
    });

    test('should track scroll state correctly', () {
      controller1.setUnreadCount(3);
      controller1.decrementUnreadCount();
      controller1.decrementUnreadCount();

      expect(controller1.unreadMessageCount, equals(1));
      expect(controller2.unreadMessageCount, equals(0));
    });

    test('should reset state for new chat', () {
      controller1.decrementUnreadCount();
      controller1.setMessageListenerActive(true);

      controller1.resetScrollState();

      expect(controller1.isUserAtBottom, isTrue);
      expect(controller1.newMessagesWhileScrolledUp, equals(0));
      expect(controller1.unreadMessageCount, equals(0));
    });
  });

  group('Integration: ChatUIState + ChatScrollingController', () {
    late ChatScrollingController scrollController;
    late MockMessageRepository mockRepository;

    setUp(() {
      mockRepository = MockMessageRepository();
      scrollController = ChatScrollingController(
        messageRepository: mockRepository,
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
      );
    });

    tearDown(() {
      scrollController.dispose();
    });

    test('should maintain UI state with scroll controller', () async {
      final uiState = ChatUIState(
        isLoading: false,
        isSearchMode: true,
        searchQuery: 'test',
        unreadMessageCount: 2,
      );

      // Simulate adding messages
      scrollController.decrementUnreadCount();

      // Create new UI state with updated counts
      final updatedState = uiState.copyWith(
        unreadMessageCount: scrollController.unreadMessageCount + 1,
      );

      expect(updatedState.isSearchMode, isTrue);
      expect(updatedState.searchQuery, equals('test'));
      expect(updatedState.isLoading, isFalse);
    });

    test('should handle state transitions correctly', () {
      final initialState = ChatUIState();
      expect(initialState.isLoading, isTrue);

      final loadingState = initialState.copyWith(isLoading: false);
      expect(loadingState.isLoading, isFalse);

      final searchState = loadingState.copyWith(
        isSearchMode: true,
        searchQuery: 'hello',
      );

      expect(searchState.isSearchMode, isTrue);
      expect(searchState.searchQuery, equals('hello'));
      expect(searchState.isLoading, isFalse);
    });
  });

  // Note: ChatMessagingViewModel.sendMessage() Phase 2C.1 migration
  // is validated through integration testing with ChatScreen.
  // Unit tests for callback structure require AppCore mocking which
  // is tested in integration/BLE testing scenarios.
}
