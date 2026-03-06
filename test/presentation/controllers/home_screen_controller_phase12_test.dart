import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/home_screen_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';

// ---------------------------------------------------------------------------
// Fakes (independent of the existing test file)
// ---------------------------------------------------------------------------

class _Phase12ChatsRepository implements IChatsRepository {
  int getAllChatsCallCount = 0;
  int totalUnreadCountCalls = 0;

  String? lastSearchQuery;
  int? lastLimit;
  int? lastOffset;

  Object? getAllChatsError;
  final List<List<ChatListItem>> _queuedResponses = <List<ChatListItem>>[];

  void queueResponse(List<ChatListItem> chats) =>
      _queuedResponses.add(chats);

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    getAllChatsCallCount++;
    lastSearchQuery = searchQuery;
    lastLimit = limit;
    lastOffset = offset;

    final Object? error = getAllChatsError;
    if (error != null) {
      if (error is Error) throw error;
      throw Exception(error.toString());
    }
    if (_queuedResponses.isEmpty) return <ChatListItem>[];
    return _queuedResponses.removeAt(0);
  }

  @override
  Future<int> getTotalUnreadCount() async {
    totalUnreadCountCalls++;
    return 0;
  }

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;
  @override
  Future<int> getArchivedChatCount() async => 0;
  @override
  Future<int> getChatCount() async => 0;
  @override
  Future<List<Contact>> getContactsWithoutChats() async => <Contact>[];
  @override
  Future<int> getTotalMessageCount() async => 0;
  @override
  Future<void> incrementUnreadCount(ChatId chatId) async {}
  @override
  Future<void> markChatAsRead(ChatId chatId) async {}
  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}
  @override
  Future<void> updateContactLastSeen(String publicKey) async {}
}

class _Phase12Facade implements IHomeScreenFacade {
  int initializeCalls = 0;
  int openChatCalls = 0;
  int archiveCalls = 0;
  int deleteCalls = 0;
  int pinToggleCalls = 0;
  int openContactsCalls = 0;
  int openArchivesCalls = 0;
  int openSettingsCalls = 0;
  int openProfileCalls = 0;
  int disposeCalls = 0;

  String? editedDisplayName;
  ConnectionStatus statusToReturn = ConnectionStatus.offline;

  Object? initializeError;
  ChatListItem? lastArchivedChat;
  ChatListItem? lastDeletedChat;
  ChatListItem? lastPinnedChat;

  @override
  List<ChatListItem> get chats => <ChatListItem>[];
  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      const Stream<ConnectionStatus>.empty();
  @override
  bool get isLoading => false;
  @override
  Stream<int> get unreadCountStream => const Stream<int>.empty();

  @override
  Future<void> initialize() async {
    initializeCalls++;
    final err = initializeError;
    if (err != null) {
      if (err is Error) throw err;
      throw Exception(err.toString());
    }
  }

  @override
  Future<void> archiveChat(ChatListItem chat) async {
    archiveCalls++;
    lastArchivedChat = chat;
  }

  @override
  Future<void> clearSearch() async {}

  @override
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  }) =>
      statusToReturn;

  @override
  Future<void> deleteChat(ChatListItem chat) async {
    deleteCalls++;
    lastDeletedChat = chat;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  Future<String?> editDisplayName(String currentName) async =>
      editedDisplayName ?? currentName;

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async =>
      <ChatListItem>[];

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

  @override
  Future<void> openChat(ChatListItem chat) async {
    openChatCalls++;
  }

  @override
  void openArchives() => openArchivesCalls++;
  @override
  void openContacts() => openContactsCalls++;
  @override
  void openProfile() => openProfileCalls++;
  @override
  void openSettings() => openSettingsCalls++;
  @override
  void refreshUnreadCount() {}
  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async => true;
  @override
  void showChatContextMenu(ChatListItem chat) {}
  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async => true;
  @override
  void showSearch() {}
  @override
  void toggleSearch() {}
  @override
  Future<void> toggleChatPin(ChatListItem chat) async {
    pinToggleCalls++;
    lastPinnedChat = chat;
  }
}

// ---------------------------------------------------------------------------
// Widget host to provide BuildContext + WidgetRef
// ---------------------------------------------------------------------------

class _Phase12Host extends ConsumerStatefulWidget {
  const _Phase12Host({
    required this.controllerBuilder,
    required this.onControllerReady,
  });

  final HomeScreenController Function(BuildContext, WidgetRef)
      controllerBuilder;
  final ValueChanged<HomeScreenController> onControllerReady;

  @override
  ConsumerState<_Phase12Host> createState() => _Phase12HostState();
}

class _Phase12HostState extends ConsumerState<_Phase12Host> {
  HomeScreenController? _ctrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ctrl ??= widget.controllerBuilder(context, ref);
    widget.onControllerReady(_ctrl!);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ChatListItem _item({
  required String id,
  required String name,
  DateTime? time,
  bool online = false,
  int unread = 0,
}) {
  return ChatListItem(
    chatId: ChatId(id),
    contactName: name,
    contactPublicKey: id,
    lastMessage: 'msg-$id',
    lastMessageTime: time,
    unreadCount: unread,
    isOnline: online,
    hasUnsentMessages: false,
  );
}

Future<HomeScreenController> _pump(
  WidgetTester tester, {
  required _Phase12ChatsRepository repo,
  required _Phase12Facade facade,
}) async {
  late HomeScreenController ctrl;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        discoveredDevicesProvider.overrideWith(
          (ref) => const AsyncValue<List<Peripheral>>.data(<Peripheral>[]),
        ),
        discoveryDataProvider.overrideWith(
          (ref) =>
              const AsyncValue<Map<String, DiscoveredEventArgs>>.data(
                <String, DiscoveredEventArgs>{},
              ),
        ),
      ],
      child: MaterialApp(
        home: _Phase12Host(
          controllerBuilder: (context, ref) {
            return HomeScreenController(
              HomeScreenControllerArgs(
                context: context,
                ref: ref,
                chatsRepository: repo,
                chatManagementService: ChatManagementService(),
                homeScreenFacade: facade,
                logger: Logger('Phase12Test'),
              ),
            );
          },
          onControllerReady: (c) => ctrl = c,
        ),
      ),
    ),
  );

  await tester.pump();
  return ctrl;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('HomeScreenController – Phase 1-2 supplementary', () {
    late _Phase12ChatsRepository repo;
    late _Phase12Facade facade;

    setUp(() {
      repo = _Phase12ChatsRepository();
      facade = _Phase12Facade();
    });

    // -----------------------------------------------------------------------
    // loadChats – error path rethrows and resets flags
    // -----------------------------------------------------------------------
    testWidgets('loadChats rethrows on repository error and resets state', (
      tester,
    ) async {
      repo.getAllChatsError = 'db failure';

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      await expectLater(ctrl.loadChats(reset: true), throwsException);
      expect(ctrl.isLoading, isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadChats – hasMore becomes false when < pageSize results
    // -----------------------------------------------------------------------
    testWidgets('loadChats sets hasMore=false when results < pageSize', (
      tester,
    ) async {
      repo.queueResponse(
        List.generate(
          10,
          (i) => _item(id: 'c-$i', name: 'C $i', time: DateTime.now()),
        ),
      );

      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);

      expect(ctrl.chats.length, 10);
      expect(ctrl.hasMore, isFalse);
      expect(ctrl.isLoading, isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadChats – error path sets isPaging/isLoading false
    // -----------------------------------------------------------------------
    testWidgets('loadChats error resets isLoading and isPaging', (
      tester,
    ) async {
      repo.getAllChatsError = 'boom';

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      await expectLater(ctrl.loadChats(reset: true), throwsException);
      expect(ctrl.isLoading, isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadChats with search query active returns search results
    // -----------------------------------------------------------------------
    testWidgets('loadChats with searchQuery set fetches with search params', (
      tester,
    ) async {
      repo.queueResponse([
        _item(id: 's-1', name: 'Alice', time: DateTime.now()),
        _item(id: 's-2', name: 'Alicia', time: DateTime.now()),
      ]);

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      ctrl.searchQuery = 'ali';
      await ctrl.loadChats(reset: true);

      expect(ctrl.chats.length, 2);
      expect(repo.lastSearchQuery, 'ali');
      expect(repo.lastLimit, isNull); // no pagination for search
      expect(repo.lastOffset, 0);
      // search results always set hasMore=false
      expect(ctrl.hasMore, isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // clearSearch resets query then loads non-search results
    // -----------------------------------------------------------------------
    testWidgets('clearSearch resets searchQuery and reloads full list', (
      tester,
    ) async {
      repo.queueResponse([
        _item(id: 'a', name: 'A', time: DateTime.now()),
      ]);

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      ctrl.searchQuery = 'foo';
      // clearSearch sets searchQuery to '' and calls loadChats(reset:true)
      // We can await the loadChats portion by calling clearSearch then
      // waiting on loadChats ourselves (clearSearch is sync, loadChats fires).
      ctrl.clearSearch();
      // clearSearch fires loadChats fire-and-forget; directly await a loadChats
      // to ensure repo was called with non-search params.
      expect(ctrl.searchQuery, '');
      // Verify via a second awaitable call that search was cleared
      repo.queueResponse([
        _item(id: 'b', name: 'B', time: DateTime.now()),
      ]);
      await ctrl.loadChats(reset: true);

      expect(repo.lastSearchQuery, isNull);
      expect(repo.lastLimit, 50);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // archiveChat actual flow – delegates + reloads
    // -----------------------------------------------------------------------
    testWidgets('archiveChat delegates to facade and reloads chats', (
      tester,
    ) async {
      repo.queueResponse(<ChatListItem>[]); // reload inside archiveChat

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final chat = _item(id: 'arc-1', name: 'To Archive');
      await ctrl.archiveChat(chat);

      expect(facade.archiveCalls, 1);
      expect(facade.lastArchivedChat?.chatId, const ChatId('arc-1'));
      expect(repo.getAllChatsCallCount, 1); // loadChats called inside

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // deleteChat actual flow – delegates + reloads
    // -----------------------------------------------------------------------
    testWidgets('deleteChat delegates to facade and reloads chats', (
      tester,
    ) async {
      repo.queueResponse(<ChatListItem>[]); // reload inside deleteChat

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final chat = _item(id: 'del-1', name: 'To Delete');
      await ctrl.deleteChat(chat);

      expect(facade.deleteCalls, 1);
      expect(facade.lastDeletedChat?.chatId, const ChatId('del-1'));
      expect(repo.getAllChatsCallCount, 1);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // toggleChatPin actual flow
    // -----------------------------------------------------------------------
    testWidgets('toggleChatPin delegates to facade and reloads', (
      tester,
    ) async {
      repo.queueResponse(<ChatListItem>[]); // reload inside toggleChatPin

      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final chat = _item(id: 'pin-1', name: 'Pinnable');
      await ctrl.toggleChatPin(chat);

      expect(facade.pinToggleCalls, 1);
      expect(facade.lastPinnedChat?.chatId, const ChatId('pin-1'));
      expect(repo.getAllChatsCallCount, 1);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // determineConnectionStatus – all five enum values
    // -----------------------------------------------------------------------
    testWidgets('determineConnectionStatus returns connected', (
      tester,
    ) async {
      facade.statusToReturn = ConnectionStatus.connected;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: 'pk-1',
        contactName: 'Alice',
        currentConnectionInfo: null,
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: DateTime.now(),
      );

      expect(status, ConnectionStatus.connected);
      ctrl.dispose();
    });

    testWidgets('determineConnectionStatus returns connecting', (
      tester,
    ) async {
      facade.statusToReturn = ConnectionStatus.connecting;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: 'pk-2',
        contactName: 'Bob',
        currentConnectionInfo: null,
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: DateTime.now(),
      );

      expect(status, ConnectionStatus.connecting);
      ctrl.dispose();
    });

    testWidgets('determineConnectionStatus returns nearby', (tester) async {
      facade.statusToReturn = ConnectionStatus.nearby;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: 'pk-3',
        contactName: 'Carol',
        currentConnectionInfo: null,
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.nearby);
      ctrl.dispose();
    });

    testWidgets('determineConnectionStatus returns recent', (tester) async {
      facade.statusToReturn = ConnectionStatus.recent;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: 'pk-4',
        contactName: 'Dave',
        currentConnectionInfo: null,
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      expect(status, ConnectionStatus.recent);
      ctrl.dispose();
    });

    testWidgets('determineConnectionStatus returns offline', (tester) async {
      facade.statusToReturn = ConnectionStatus.offline;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: null,
        contactName: 'Eve',
        currentConnectionInfo: null,
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: null,
      );

      expect(status, ConnectionStatus.offline);
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // editDisplayName delegation
    // -----------------------------------------------------------------------
    testWidgets('editDisplayName delegates to facade', (tester) async {
      facade.editedDisplayName = 'NewName';
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final result = await ctrl.editDisplayName('OldName');
      expect(result, 'NewName');

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // dispose cleanup
    // -----------------------------------------------------------------------
    testWidgets('dispose sets _isDisposed and cleans up facade', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      ctrl.dispose();

      expect(facade.disposeCalls, 1);
      // After dispose, methods should be no-ops (guard checks).
      // loadChats should early-return silently.
      await ctrl.loadChats(reset: true);
      // No additional repo calls after dispose because of guard
      expect(repo.getAllChatsCallCount, 0);
    });

    // -----------------------------------------------------------------------
    // loadMoreChats early return when hasMore=false
    // -----------------------------------------------------------------------
    testWidgets('loadMoreChats is no-op when hasMore is false', (
      tester,
    ) async {
      repo.queueResponse([
        _item(id: 'only', name: 'Only', time: DateTime.now()),
      ]);

      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);
      expect(ctrl.hasMore, isFalse);

      final callsBefore = repo.getAllChatsCallCount;
      await ctrl.loadMoreChats();
      expect(repo.getAllChatsCallCount, callsBefore);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadMoreChats early return when _isDisposed
    // -----------------------------------------------------------------------
    testWidgets('loadMoreChats is no-op after dispose', (tester) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      ctrl.dispose();

      final callsBefore = repo.getAllChatsCallCount;
      await ctrl.loadMoreChats();
      expect(repo.getAllChatsCallCount, callsBefore);
    });

    // -----------------------------------------------------------------------
    // onSearchChanged with empty/whitespace clears searchQuery
    // -----------------------------------------------------------------------
    testWidgets('onSearchChanged with whitespace clears searchQuery', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      ctrl.searchQuery = 'something';
      // Whitespace-only clears search and fires loadChats (fire-and-forget).
      // We test the synchronous part: searchQuery is reset.
      ctrl.onSearchChanged('   ');
      expect(ctrl.searchQuery, '');

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // isChatPinned delegates to ChatManagementService
    // -----------------------------------------------------------------------
    testWidgets('isChatPinned delegates to chat management service', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      // ChatManagementService defaults to false for unknown ids
      final pinned = ctrl.isChatPinned(const ChatId('unknown'));
      expect(pinned, isFalse);

      ctrl.dispose();
    });
  });
}
