import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/core/interfaces/i_message_repository.dart';

ChatId _cid(String value) => ChatId(value);

// Mock implementations
class MockMessageRepository implements IMessageRepository {
  List<Message> _messages = [];

  @override
  Future<void> saveMessage(Message message) async {
    _messages.add(message);
  }

  @override
  Future<void> updateMessage(Message message) async {
    final index = _messages.indexWhere((m) => m.id.value == message.id.value);
    if (index >= 0) {
      _messages[index] = message;
    }
  }

  @override
  Future<bool> deleteMessage(MessageId messageId) async {
    final before = _messages.length;
    _messages.removeWhere((m) => m.id == messageId);
    return _messages.length != before;
  }

  @override
  Future<void> clearMessages(ChatId chatId) async {
    _messages.removeWhere((m) => m.chatId == chatId);
  }

  @override
  Future<List<Message>> getAllMessages() async => _messages;

  @override
  Future<Message?> getMessageById(MessageId messageId) async {
    for (final message in _messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  @override
  Future<List<Message>> getMessages(ChatId chatId) async =>
      _messages.where((m) => m.chatId == chatId).toList();

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      _messages.where((m) => m.chatId.value == publicKey).toList();

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].chatId == oldChatId) {
        _messages[i] = _messages[i].copyWith(chatId: newChatId);
      }
    }
  }
}

class MockChatsRepository implements IChatsRepository {
  List<ChatListItem> chats = [];
  final Map<String, int> _unreadByChat = {};

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;

  @override
  Future<int> getArchivedChatCount() async => 0;

  @override
  Future<int> getChatCount() async => chats.length;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    return chats
        .map(
          (chat) => ChatListItem(
            chatId: chat.chatId,
            contactName: chat.contactName,
            contactPublicKey: chat.contactPublicKey,
            lastMessage: chat.lastMessage,
            lastMessageTime: chat.lastMessageTime,
            unreadCount: _unreadByChat[chat.chatId.value] ?? chat.unreadCount,
            isOnline: chat.isOnline,
            hasUnsentMessages: chat.hasUnsentMessages,
            lastSeen: chat.lastSeen,
          ),
        )
        .toList();
  }

  @override
  Future<List<Contact>> getContactsWithoutChats() async => [];

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  Future<int> getTotalUnreadCount() async =>
      _unreadByChat.values.fold<int>(0, (total, count) => total + count);

  @override
  Future<void> incrementUnreadCount(ChatId chatId) async {
    _unreadByChat.update(chatId.value, (value) => value + 1, ifAbsent: () => 1);
  }

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    _unreadByChat[chatId.value] = 0;
  }

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<void> updateContactLastSeen(String publicKey) async {}
}

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('ChatUIState', () {
    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() async {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

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
          id: MessageId('1'),
          chatId: ChatId('chat1'),
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
    late MockChatsRepository mockChatsRepository;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      mockChatsRepository = MockChatsRepository();
      controller = ChatScrollingController(
        chatsRepository: mockChatsRepository,
        chatId: ChatId('chat-1'),
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
        onStateChanged: () {},
      );
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
      controller.dispose();
    });

    test('should initialize with correct defaults', () {
      expect(controller.isUserAtBottom, isTrue);
      expect(controller.unreadMessageCount, equals(0));
      expect(controller.shouldShowScrollDownButton(0), isFalse);
    });

    test('should set unread count', () {
      controller.setUnreadCount(5);
      expect(controller.unreadMessageCount, equals(5));
    });

    test('should sync unread state from repository data', () async {
      mockChatsRepository.chats = const [
        ChatListItem(
          chatId: ChatId('chat-1'),
          contactName: 'Alice',
          unreadCount: 2,
          isOnline: false,
          hasUnsentMessages: false,
        ),
      ];

      final messages = [
        Message(
          id: MessageId('1'),
          chatId: ChatId('chat-1'),
          content: 'Hello',
          isFromMe: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        ),
        Message(
          id: MessageId('2'),
          chatId: ChatId('chat-1'),
          content: 'Again',
          isFromMe: true,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        ),
        Message(
          id: MessageId('3'),
          chatId: ChatId('chat-1'),
          content: 'More',
          isFromMe: false,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
        ),
      ];

      await controller.syncUnreadCount(messages: messages);

      expect(controller.unreadMessageCount, equals(2));
      expect(controller.showUnreadSeparator, isTrue);
      expect(controller.lastReadMessageIndex, equals(0));
    });

    test('should decrement unread count', () {
      controller.setUnreadCount(3);
      controller.decrementUnreadCount();

      // unreadMessageCount should decrease, newMessagesWhileScrolledUp increases
      expect(controller.unreadMessageCount, equals(2));
    });

    test('should track scroll position changes', () {
      expect(controller.isUserAtBottom, isTrue);
      expect(controller.shouldShowScrollDownButton(0), isFalse);
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
    late MockChatsRepository mockChatsRepository;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      mockChatsRepository = MockChatsRepository();
      controller1 = ChatScrollingController(
        chatsRepository: mockChatsRepository,
        chatId: ChatId('chat-1'),
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
        onStateChanged: () {},
      );
      controller2 = ChatScrollingController(
        chatsRepository: mockChatsRepository,
        chatId: ChatId('chat-2'),
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
        onStateChanged: () {},
      );
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
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
    late MockChatsRepository mockChatsRepository;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      mockChatsRepository = MockChatsRepository()
        ..chats = [
          const ChatListItem(
            chatId: ChatId('chat-1'),
            contactName: 'User',
            unreadCount: 0,
            isOnline: false,
            hasUnsentMessages: false,
          ),
        ];
      scrollController = ChatScrollingController(
        chatsRepository: mockChatsRepository,
        chatId: ChatId('chat-1'),
        onScrollToBottom: () {},
        onUnreadCountChanged: (_) {},
        onStateChanged: () {},
      );
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
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
