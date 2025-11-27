import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/core/interfaces/i_chat_interaction_handler.dart';
import 'package:pak_connect/core/interfaces/i_chats_repository.dart';
import 'package:pak_connect/core/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/connection_status.dart';
import 'package:pak_connect/core/services/home_screen_facade.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _FakeChatsRepository implements IChatsRepository {
  int loadCount = 0;
  int unreadCount = 0;
  List<ChatListItem> chats = const [];

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
    loadCount++;
    return chats;
  }

  @override
  Future<List<Contact>> getContactsWithoutChats() async => const [];

  @override
  Future<int> getTotalMessageCount() async => chats.length;

  @override
  Future<int> getTotalUnreadCount() async => unreadCount;

  @override
  Future<void> incrementUnreadCount(String chatId) async {}

  @override
  Future<void> markChatAsRead(String chatId) async {}

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<void> updateContactLastSeen(String publicKey) async {}
}

class _FakeInteractionHandler implements IChatInteractionHandler {
  final StreamController<ChatInteractionIntent> _controller =
      StreamController.broadcast();

  int initializeCount = 0;
  int disposeCount = 0;
  ChatListItem? openedChat;
  bool searchToggled = false;

  @override
  Future<void> initialize() async {
    initializeCount++;
  }

  @override
  Stream<ChatInteractionIntent> get interactionIntentStream =>
      _controller.stream;

  void emit(ChatInteractionIntent intent) => _controller.add(intent);

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _controller.close();
  }

  @override
  Future<void> openChat(ChatListItem chat) async {
    openedChat = chat;
  }

  @override
  void toggleSearch() {
    searchToggled = true;
  }

  @override
  void showSearch() {
    searchToggled = true;
  }

  @override
  void clearSearch() {}

  @override
  void openSettings() {}

  @override
  void openProfile() {}

  @override
  Future<String?> editDisplayName(String currentName) async => null;

  @override
  void handleMenuAction(String action) {}

  @override
  void openContacts() {}

  @override
  void openArchives() {}

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async => false;

  @override
  Future<void> archiveChat(ChatListItem chat) async {}

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async => false;

  @override
  Future<void> deleteChat(ChatListItem chat) async {}

  @override
  void showChatContextMenu(ChatListItem chat) {}

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {}

  @override
  Future<void> markChatAsRead(String chatId) async {}
}

class _StubSeenStore implements ISeenMessageStore {
  @override
  Future<void> clear() async {}

  @override
  Map<String, dynamic> getStatistics() => const {};

  @override
  bool hasDelivered(String messageId) => false;

  @override
  bool hasRead(String messageId) => false;

  @override
  Future<void> markDelivered(String messageId) async {}

  @override
  Future<void> markRead(String messageId) async {}

  @override
  Future<void> performMaintenance() async {}
}

ChatListItem _sampleChat() => ChatListItem(
  chatId: 'chat-1',
  contactName: 'Alice',
  contactPublicKey: 'pk',
  lastMessage: 'hi',
  lastMessageTime: DateTime.now(),
  unreadCount: 0,
  isOnline: false,
  hasUnsentMessages: false,
  lastSeen: null,
);

void main() {
  late _FakeChatsRepository chatsRepository;
  late MockConnectionService connectionService;
  late _FakeInteractionHandler interactionHandler;
  late HomeScreenFacade facade;

  HomeScreenFacade buildFacade({bool enableListInit = false}) {
    chatsRepository = _FakeChatsRepository()
      ..chats = [_sampleChat()]
      ..unreadCount = 2;
    connectionService = MockConnectionService();
    interactionHandler = _FakeInteractionHandler();

    return HomeScreenFacade(
      chatsRepository: chatsRepository,
      bleService: connectionService,
      interactionHandlerBuilder:
          ({context, ref, chatsRepository, chatManagementService}) =>
              interactionHandler,
      enableListCoordinatorInitialization: enableListInit,
    );
  }

  test('initialize runs sub-services once and skips on second call', () async {
    facade = buildFacade(enableListInit: true);

    await facade.initialize();
    expect(interactionHandler.initializeCount, 1);
    expect(chatsRepository.loadCount, 1); // list coordinator initial load

    await facade.initialize(); // idempotent
    expect(interactionHandler.initializeCount, 1);
  });

  test('interaction intents trigger chat reload', () async {
    facade = buildFacade();

    await facade.loadChats();
    final initialLoads = chatsRepository.loadCount;

    interactionHandler.emit(ChatOpenedIntent('chat-1'));
    await Future.delayed(Duration.zero);

    expect(chatsRepository.loadCount, initialLoads + 1);
  });

  test('delegates connection status decision to connection manager', () {
    facade = buildFacade();
    connectionService.theirPersistentPublicKey = 'pk';

    final status = facade.determineConnectionStatus(
      contactPublicKey: 'pk',
      contactName: 'Alice',
      currentConnectionInfo: const ConnectionInfo(
        isConnected: true,
        isReady: false,
        statusMessage: 'connecting',
      ),
      discoveredDevices: const [],
      discoveryData: const {},
      lastSeenTime: null,
    );

    expect(status, ConnectionStatus.connecting);
  });

  test(
    'delegates interaction methods to handler and list coordinator',
    () async {
      facade = buildFacade();
      await facade.loadChats();

      await facade.openChat(_sampleChat());
      facade.toggleSearch();
      facade.showSearch();
      final loaded = await facade.loadChats(searchQuery: 'alice');
      facade.refreshUnreadCount();

      expect(interactionHandler.openedChat?.chatId, 'chat-1');
      expect(interactionHandler.searchToggled, isTrue);
      expect(loaded, isNotEmpty);
      expect(facade.chats, isNotEmpty);
      expect(facade.isLoading, isFalse);
    },
  );
}
