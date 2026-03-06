import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/domain/interfaces/i_chat_interaction_handler.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/core/services/home_screen_facade.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/values/id_types.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

ChatId _cid(String value) => ChatId(value);

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
  Future<void> incrementUnreadCount(ChatId chatId) async {}

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

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
  bool throwOnInitialize = false;
  bool throwOnDispose = false;
  ChatListItem? openedChat;
  bool searchToggled = false;
  bool clearSearchCalled = false;
  bool settingsOpened = false;
  bool profileOpened = false;
  String? editDisplayNameResult;
  String? editedDisplayNameInput;
  String? handledMenuAction;
  bool contactsOpened = false;
  bool archivesOpened = false;
  bool archiveConfirmationResult = false;
  ChatListItem? archivedChat;
  bool deleteConfirmationResult = false;
  ChatListItem? deletedChat;
  ChatListItem? contextMenuChat;
  ChatListItem? pinToggledChat;
  ChatId? markedReadChatId;

  @override
  Future<void> initialize() async {
    if (throwOnInitialize) {
      throw StateError('initialize failed');
    }
    initializeCount++;
  }

  @override
  Stream<ChatInteractionIntent> get interactionIntentStream =>
      _controller.stream;

  void emit(ChatInteractionIntent intent) => _controller.add(intent);

  @override
  Future<void> dispose() async {
    if (throwOnDispose) {
      throw StateError('dispose failed');
    }
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
  void clearSearch() {
    clearSearchCalled = true;
  }

  @override
  void openSettings() {
    settingsOpened = true;
  }

  @override
  void openProfile() {
    profileOpened = true;
  }

  @override
  Future<String?> editDisplayName(String currentName) async {
    editedDisplayNameInput = currentName;
    return editDisplayNameResult;
  }

  @override
  void handleMenuAction(String action) {
    handledMenuAction = action;
  }

  @override
  void openContacts() {
    contactsOpened = true;
  }

  @override
  void openArchives() {
    archivesOpened = true;
  }

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async {
    return archiveConfirmationResult;
  }

  @override
  Future<void> archiveChat(ChatListItem chat) async {
    archivedChat = chat;
  }

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async {
    return deleteConfirmationResult;
  }

  @override
  Future<void> deleteChat(ChatListItem chat) async {
    deletedChat = chat;
  }

  @override
  void showChatContextMenu(ChatListItem chat) {
    contextMenuChat = chat;
  }

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {
    pinToggledChat = chat;
  }

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    markedReadChatId = chatId;
  }
}

ChatListItem _sampleChat() => ChatListItem(
  chatId: _cid('chat-1'),
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
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  late _FakeChatsRepository chatsRepository;
  late MockConnectionService connectionService;
  late _FakeInteractionHandler interactionHandler;
  late HomeScreenFacade facade;

  setUp(() {
    logRecords.clear();
    allowedSevere.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
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
  });

  HomeScreenFacade buildFacade({
    bool enableListInit = false,
    bool useInteractionBuilder = true,
    bool enableInternalIntentListener = true,
  }) {
    chatsRepository = _FakeChatsRepository()
      ..chats = [_sampleChat()]
      ..unreadCount = 2;
    connectionService = MockConnectionService();
    interactionHandler = _FakeInteractionHandler();

    return HomeScreenFacade(
      chatsRepository: chatsRepository,
      bleService: connectionService,
      interactionHandlerBuilder: useInteractionBuilder
          ? ({context, ref, chatsRepository, chatManagementService}) =>
                interactionHandler
          : null,
      enableListCoordinatorInitialization: enableListInit,
      enableInternalIntentListener: enableInternalIntentListener,
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

      expect(interactionHandler.openedChat?.chatId.value, 'chat-1');
      expect(interactionHandler.searchToggled, isTrue);
      expect(loaded, isNotEmpty);
      expect(facade.chats, isNotEmpty);
      expect(facade.isLoading, isFalse);
    },
  );

  test(
    'delegates remaining interaction operations and return values',
    () async {
      facade = buildFacade();
      final chat = _sampleChat();
      interactionHandler.editDisplayNameResult = 'Updated Name';
      interactionHandler.archiveConfirmationResult = true;
      interactionHandler.deleteConfirmationResult = true;

      expect(facade.connectionStatusStream, isA<Stream<ConnectionStatus>>());
      expect(facade.unreadCountStream, isA<Stream<int>>());

      await facade.clearSearch();
      facade.openSettings();
      facade.openProfile();
      final newName = await facade.editDisplayName('Current Name');
      facade.handleMenuAction('openArchives');
      facade.openContacts();
      facade.openArchives();
      final canArchive = await facade.showArchiveConfirmation(chat);
      await facade.archiveChat(chat);
      final canDelete = await facade.showDeleteConfirmation(chat);
      await facade.deleteChat(chat);
      facade.showChatContextMenu(chat);
      await facade.toggleChatPin(chat);
      await facade.markChatAsRead(_cid('chat-1'));

      expect(interactionHandler.clearSearchCalled, isTrue);
      expect(interactionHandler.settingsOpened, isTrue);
      expect(interactionHandler.profileOpened, isTrue);
      expect(interactionHandler.editedDisplayNameInput, 'Current Name');
      expect(newName, 'Updated Name');
      expect(interactionHandler.handledMenuAction, 'openArchives');
      expect(interactionHandler.contactsOpened, isTrue);
      expect(interactionHandler.archivesOpened, isTrue);
      expect(canArchive, isTrue);
      expect(interactionHandler.archivedChat?.chatId.value, chat.chatId.value);
      expect(canDelete, isTrue);
      expect(interactionHandler.deletedChat?.chatId.value, chat.chatId.value);
      expect(
        interactionHandler.contextMenuChat?.chatId.value,
        chat.chatId.value,
      );
      expect(
        interactionHandler.pinToggledChat?.chatId.value,
        chat.chatId.value,
      );
      expect(interactionHandler.markedReadChatId?.value, 'chat-1');
    },
  );

  test('navigation intent does not trigger chat reload', () async {
    facade = buildFacade();

    await facade.loadChats();
    final initialLoads = chatsRepository.loadCount;

    interactionHandler.emit(NavigationIntent('settings'));
    await Future<void>.delayed(Duration.zero);

    expect(chatsRepository.loadCount, initialLoads);
  });

  test(
    'initialize logs and rethrows when sub-service initialization fails',
    () async {
      facade = buildFacade();
      interactionHandler.throwOnInitialize = true;
      allowedSevere.add('Error initializing HomeScreenFacade');

      await expectLater(facade.initialize(), throwsA(isA<StateError>()));
    },
  );

  test('dispose handles interaction-handler disposal failures', () async {
    facade = buildFacade();
    await facade.initialize();
    interactionHandler.throwOnDispose = true;

    await facade.dispose();
  });

  test('uses no-op interaction handler when builder is not provided', () async {
    facade = buildFacade(
      useInteractionBuilder: false,
      enableInternalIntentListener: false,
    );
    final chat = _sampleChat();

    await facade.initialize();
    await facade.openChat(chat);
    facade.toggleSearch();
    facade.showSearch();
    await facade.clearSearch();
    facade.openSettings();
    facade.openProfile();
    final edited = await facade.editDisplayName('Any Name');
    facade.handleMenuAction('noop');
    facade.openContacts();
    facade.openArchives();
    final canArchive = await facade.showArchiveConfirmation(chat);
    await facade.archiveChat(chat);
    final canDelete = await facade.showDeleteConfirmation(chat);
    await facade.deleteChat(chat);
    facade.showChatContextMenu(chat);
    await facade.toggleChatPin(chat);
    await facade.markChatAsRead(_cid('chat-2'));

    expect(edited, isNull);
    expect(canArchive, isFalse);
    expect(canDelete, isFalse);
    await facade.dispose();
  });
}
