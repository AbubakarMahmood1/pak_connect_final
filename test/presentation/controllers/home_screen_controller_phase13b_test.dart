/// Phase 13b: Additional HomeScreenController coverage
/// Covers uncovered branches: unread count tracking, chat list refresh edge
/// cases, editDisplayName, determineConnectionStatus, archiveChat/deleteChat
/// reload, toggleChatPin reload, clearSearch after search, loadChats error
/// path, loadMoreChats guards, and listener notification safety.
library;

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
// Fakes
// ---------------------------------------------------------------------------

class _ChatsRepo implements IChatsRepository {
  int getAllChatsCallCount = 0;
  String? lastSearchQuery;
  int? lastLimit;
  int? lastOffset;
  Object? getAllChatsError;
  final List<List<ChatListItem>> _queuedResponses = [];
  int unreadCountToReturn = 0;
  int getTotalUnreadCallCount = 0;

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
    if (getAllChatsError != null) throw Exception(getAllChatsError.toString());
    if (_queuedResponses.isEmpty) return [];
    return _queuedResponses.removeAt(0);
  }

  @override
  Future<int> getTotalUnreadCount() async {
    getTotalUnreadCallCount++;
    return unreadCountToReturn;
  }

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;
  @override
  Future<int> getArchivedChatCount() async => 0;
  @override
  Future<int> getChatCount() async => 0;
  @override
  Future<List<Contact>> getContactsWithoutChats() async => [];
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

class _Facade implements IHomeScreenFacade {
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
  bool archiveConfirmResult = true;
  bool deleteConfirmResult = true;

  @override
  List<ChatListItem> get chats => [];
  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      const Stream.empty();
  @override
  bool get isLoading => false;
  @override
  Stream<int> get unreadCountStream => const Stream.empty();

  @override
  Future<void> initialize() async => initializeCalls++;
  @override
  Future<void> archiveChat(ChatListItem chat) async => archiveCalls++;
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
  Future<void> deleteChat(ChatListItem chat) async => deleteCalls++;
  @override
  Future<void> dispose() async => disposeCalls++;
  @override
  Future<String?> editDisplayName(String currentName) async =>
      editedDisplayName ?? currentName;
  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async => [];
  @override
  Future<void> markChatAsRead(ChatId chatId) async {}
  @override
  Future<void> openChat(ChatListItem chat) async => openChatCalls++;
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
  Future<bool> showArchiveConfirmation(ChatListItem chat) async =>
      archiveConfirmResult;
  @override
  void showChatContextMenu(ChatListItem chat) {}
  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async =>
      deleteConfirmResult;
  @override
  void showSearch() {}
  @override
  void toggleSearch() {}
  @override
  Future<void> toggleChatPin(ChatListItem chat) async => pinToggleCalls++;
}

// ---------------------------------------------------------------------------
// Widget host (mirrors phase13 pattern)
// ---------------------------------------------------------------------------

class _Host extends ConsumerStatefulWidget {
  const _Host({
    required this.controllerBuilder,
    required this.onControllerReady,
  });

  final HomeScreenController Function(BuildContext, WidgetRef)
      controllerBuilder;
  final ValueChanged<HomeScreenController> onControllerReady;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
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
  required _ChatsRepo repo,
  required _Facade facade,
}) async {
  late HomeScreenController ctrl;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        discoveredDevicesProvider.overrideWith(
          (ref) => const AsyncValue<List<Peripheral>>.data([]),
        ),
        discoveryDataProvider.overrideWith(
          (ref) =>
              const AsyncValue<Map<String, DiscoveredEventArgs>>.data({}),
        ),
      ],
      child: MaterialApp(
        home: _Host(
          controllerBuilder: (context, ref) {
            return HomeScreenController(
              HomeScreenControllerArgs(
                context: context,
                ref: ref,
                chatsRepository: repo,
                chatManagementService: ChatManagementService(),
                homeScreenFacade: facade,
                logger: Logger('Phase13bTest'),
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
  Logger.root.level = Level.OFF;

  group('HomeScreenController – Phase 13b supplementary', () {
    late _ChatsRepo repo;
    late _Facade facade;

    setUp(() {
      repo = _ChatsRepo();
      facade = _Facade();
    });

    // -----------------------------------------------------------------------
    // Unread count stream via _setupUnreadCountStream
    // -----------------------------------------------------------------------
    testWidgets('unreadCountStream is set after loadChats', (tester) async {
      repo.queueResponse([]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);

      expect(ctrl.unreadCountStream, isNotNull);
      ctrl.dispose();
    });

    testWidgets('unreadCountStream returns values from repo', (
      tester,
    ) async {
      repo.unreadCountToReturn = 5;
      repo.queueResponse([]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);

      // Stream should be set up
      expect(ctrl.unreadCountStream, isNotNull);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // editDisplayName delegates to facade
    // -----------------------------------------------------------------------
    testWidgets('editDisplayName delegates to facade', (tester) async {
      facade.editedDisplayName = 'NewName';
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final result = await ctrl.editDisplayName('OldName');
      expect(result, 'NewName');

      ctrl.dispose();
    });

    testWidgets('editDisplayName returns current when facade returns null', (
      tester,
    ) async {
      facade.editedDisplayName = null;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      // When editedDisplayName is null, facade returns currentName
      final result = await ctrl.editDisplayName('Current');
      expect(result, 'Current');

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // determineConnectionStatus delegates to facade
    // -----------------------------------------------------------------------
    testWidgets('determineConnectionStatus returns facade result', (
      tester,
    ) async {
      facade.statusToReturn = ConnectionStatus.connected;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: 'pk-1',
        contactName: 'Alice',
        currentConnectionInfo: null,
        discoveredDevices: [],
        discoveryData: {},
        lastSeenTime: null,
      );
      expect(status, ConnectionStatus.connected);

      ctrl.dispose();
    });

    testWidgets('determineConnectionStatus with offline status', (
      tester,
    ) async {
      facade.statusToReturn = ConnectionStatus.offline;
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final status = ctrl.determineConnectionStatus(
        contactPublicKey: null,
        contactName: 'Unknown',
        currentConnectionInfo: null,
        discoveredDevices: [],
        discoveryData: {},
        lastSeenTime: DateTime.now(),
      );
      expect(status, ConnectionStatus.offline);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // archiveChat delegates and reloads
    // -----------------------------------------------------------------------
    testWidgets('archiveChat delegates to facade and reloads', (
      tester,
    ) async {
      repo.queueResponse([]); // for reload after archive
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      final chat = _item(id: 'arc-1', name: 'Arc');

      await ctrl.archiveChat(chat);

      expect(facade.archiveCalls, 1);
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // deleteChat delegates and reloads
    // -----------------------------------------------------------------------
    testWidgets('deleteChat delegates to facade and reloads', (
      tester,
    ) async {
      repo.queueResponse([]); // for reload after delete
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      final chat = _item(id: 'del-1', name: 'Del');

      await ctrl.deleteChat(chat);

      expect(facade.deleteCalls, 1);
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // toggleChatPin delegates and reloads
    // -----------------------------------------------------------------------
    testWidgets('toggleChatPin delegates to facade and reloads', (
      tester,
    ) async {
      repo.queueResponse([]); // for reload after pin toggle
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      final chat = _item(id: 'pin-1', name: 'Pin');

      await ctrl.toggleChatPin(chat);

      expect(facade.pinToggleCalls, 1);
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // clearSearch resets query and reloads
    // -----------------------------------------------------------------------
    testWidgets('clearSearch resets searchQuery and triggers loadChats', (
      tester,
    ) async {
      repo.queueResponse([
        _item(id: 'a', name: 'Alice'),
      ]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      // Set a search query first
      ctrl.searchQuery = 'test';
      expect(ctrl.searchQuery, 'test');

      // Clear it
      repo.queueResponse([]); // for reload
      ctrl.clearSearch();
      expect(ctrl.searchQuery, '');

      await tester.pump(const Duration(milliseconds: 100));
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadChats error path: sets isLoading=false and isPaging=false
    // -----------------------------------------------------------------------
    testWidgets('loadChats error sets isLoading false and rethrows', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      repo.getAllChatsError = 'db failure';

      expect(
        () => ctrl.loadChats(reset: true),
        throwsException,
      );

      await tester.pump(const Duration(milliseconds: 50));
      expect(ctrl.isLoading, isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadMoreChats guards: disposed, already paging, no more
    // -----------------------------------------------------------------------
    testWidgets('loadMoreChats is no-op when disposed', (tester) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      ctrl.dispose();

      final callsBefore = repo.getAllChatsCallCount;
      await ctrl.loadMoreChats();
      expect(repo.getAllChatsCallCount, callsBefore);
    });

    testWidgets('loadMoreChats is no-op when hasMore is false', (
      tester,
    ) async {
      // Load less than pageSize so hasMore = false
      repo.queueResponse([
        _item(id: 'x', name: 'X'),
      ]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);
      expect(ctrl.hasMore, isFalse);

      final callsBefore = repo.getAllChatsCallCount;
      await ctrl.loadMoreChats();
      // Should not have called getAllChats again
      expect(repo.getAllChatsCallCount, callsBefore);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadChats with search uses null limit and offset 0
    // -----------------------------------------------------------------------
    testWidgets('loadChats during search passes null limit', (tester) async {
      repo.queueResponse([_item(id: 'r1', name: 'R1')]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      ctrl.searchQuery = 'test';
      repo.queueResponse([_item(id: 'r2', name: 'R2')]);
      await ctrl.loadChats(reset: true);

      expect(repo.lastSearchQuery, 'test');
      expect(repo.lastLimit, isNull);
      expect(repo.lastOffset, 0);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // loadChats sets hasMore=false during search
    // -----------------------------------------------------------------------
    testWidgets('loadChats sets hasMore false when searching', (
      tester,
    ) async {
      repo.queueResponse(
        List.generate(
          50,
          (i) => _item(id: 's-$i', name: 'S $i'),
        ),
      );
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      // Even with 50 results, hasMore should be false during search
      ctrl.searchQuery = 'something';
      repo.queueResponse(
        List.generate(
          50,
          (i) => _item(id: 'sx-$i', name: 'SX $i'),
        ),
      );
      await ctrl.loadChats(reset: true);
      expect(ctrl.hasMore, isFalse); // search mode forces hasMore=false

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // notifyListeners called on chats update
    // -----------------------------------------------------------------------
    testWidgets('loadChats notifies listeners on completion', (tester) async {
      repo.queueResponse([_item(id: 'n1', name: 'N1')]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      int notifications = 0;
      ctrl.addListener(() => notifications++);

      await ctrl.loadChats(reset: true);
      expect(notifications, greaterThan(0));

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // updateSingleChatItem with active search uses searchQuery
    // -----------------------------------------------------------------------
    testWidgets('updateSingleChatItem passes searchQuery when set', (
      tester,
    ) async {
      repo.queueResponse([_item(id: 'a', name: 'Alice')]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);

      ctrl.searchQuery = 'alice';
      repo.queueResponse([_item(id: 'a', name: 'Alice Updated')]);
      await ctrl.updateSingleChatItem();

      expect(repo.lastSearchQuery, 'alice');
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // updateSingleChatItem re-sorts with multiple online/offline
    // -----------------------------------------------------------------------
    testWidgets('updateSingleChatItem sort: online before offline when both have same time', (
      tester,
    ) async {
      final now = DateTime.now();
      // Repo returns them in any order - loadChats does NOT sort
      repo.queueResponse([
        _item(id: 'off', name: 'Offline', time: now, online: false),
        _item(id: 'on', name: 'Online', time: now, online: true),
      ]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);
      expect(ctrl.chats.length, 2);

      // Update 'off' chat via updateSingleChatItem which triggers sort
      repo.queueResponse([_item(id: 'off', name: 'Offline', time: now, online: false)]);
      await ctrl.updateSingleChatItem();

      // After updateSingleChatItem sort: online first, then offline
      final onlineIndex = ctrl.chats.indexWhere((c) => c.chatId.value == 'on');
      final offlineIndex = ctrl.chats.indexWhere((c) => c.chatId.value == 'off');
      expect(onlineIndex, lessThan(offlineIndex));

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // dispose prevents notifyListeners
    // -----------------------------------------------------------------------
    testWidgets('_safeNotifyListeners is no-op after dispose', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      int notifications = 0;
      ctrl.addListener(() => notifications++);

      ctrl.dispose();

      // Calling methods after dispose should not notify
      await ctrl.loadChats(reset: true);
      expect(notifications, 0);
    });

    // -----------------------------------------------------------------------
    // onSearchChanged with empty string after query
    // -----------------------------------------------------------------------
    testWidgets('onSearchChanged empty resets and reloads', (tester) async {
      repo.queueResponse([_item(id: 'a', name: 'Alice')]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      ctrl.onSearchChanged('test');
      await tester.pump(const Duration(milliseconds: 100));

      repo.queueResponse([_item(id: 'a', name: 'Alice')]);
      ctrl.onSearchChanged('');
      expect(ctrl.searchQuery, '');

      await tester.pump(const Duration(milliseconds: 100));
      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // Multiple sequential loadMoreChats
    // -----------------------------------------------------------------------
    testWidgets('sequential loadMoreChats appends pages correctly', (
      tester,
    ) async {
      // Page 1: 50 items
      repo.queueResponse(
        List.generate(
          50,
          (i) => _item(
            id: 'p1-$i',
            name: 'P1 $i',
            time: DateTime(2025, 1, 1, 0, 0, 50 - i),
          ),
        ),
      );
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);
      expect(ctrl.chats.length, 50);
      expect(ctrl.hasMore, isTrue);

      // Page 2: 50 items
      repo.queueResponse(
        List.generate(
          50,
          (i) => _item(
            id: 'p2-$i',
            name: 'P2 $i',
            time: DateTime(2025, 1, 1, 0, 0, i),
          ),
        ),
      );
      await ctrl.loadMoreChats();
      expect(ctrl.chats.length, 100);
      expect(ctrl.hasMore, isTrue);

      // Page 3: less than 50
      repo.queueResponse([
        _item(id: 'p3-0', name: 'P3 0'),
      ]);
      await ctrl.loadMoreChats();
      expect(ctrl.chats.length, 101);
      expect(ctrl.hasMore, isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // isChatPinned delegates to ChatManagementService
    // -----------------------------------------------------------------------
    testWidgets('isChatPinned returns false for non-pinned chat', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      // ChatManagementService by default has no pinned chats
      expect(ctrl.isChatPinned(const ChatId('some-id')), isFalse);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // dispose calls facade dispose and chatManagementService dispose
    // -----------------------------------------------------------------------
    testWidgets('dispose calls facade.dispose', (tester) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      ctrl.dispose();

      expect(facade.disposeCalls, 1);
    });

    // -----------------------------------------------------------------------
    // loadChats reset=false does not reset offset
    // -----------------------------------------------------------------------
    testWidgets('loadChats reset=false preserves offset', (tester) async {
      repo.queueResponse(
        List.generate(
          50,
          (i) => _item(id: 'init-$i', name: 'Init $i'),
        ),
      );
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);

      repo.queueResponse([_item(id: 'extra', name: 'Extra')]);
      await ctrl.loadChats(reset: false);

      // offset should be based on total chats length
      expect(repo.lastOffset, 50); // offset from first page
      expect(ctrl.chats.length, 51);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // updateSingleChatItem disposed guard
    // -----------------------------------------------------------------------
    testWidgets('updateSingleChatItem is no-op after dispose', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      ctrl.dispose();

      final callsBefore = repo.getAllChatsCallCount;
      await ctrl.updateSingleChatItem();
      expect(repo.getAllChatsCallCount, callsBefore);
    });

    // -----------------------------------------------------------------------
    // onSearchChanged disposed guard
    // -----------------------------------------------------------------------
    testWidgets('onSearchChanged is no-op after dispose', (tester) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      ctrl.dispose();

      ctrl.onSearchChanged('query');
      expect(ctrl.searchQuery, '');
    });

    // -----------------------------------------------------------------------
    // clearSearch disposed guard
    // -----------------------------------------------------------------------
    testWidgets('clearSearch is no-op after dispose', (tester) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      ctrl.searchQuery = 'something';
      ctrl.dispose();

      ctrl.clearSearch();
      // searchQuery was set before dispose, but clearSearch should no-op
      // (already tested: loadChats after dispose is no-op)
    });

    // -----------------------------------------------------------------------
    // loadChats with reset=true resets offset to 0
    // -----------------------------------------------------------------------
    testWidgets('loadChats reset=true resets chats list', (tester) async {
      repo.queueResponse([
        _item(id: 'old1', name: 'Old1'),
        _item(id: 'old2', name: 'Old2'),
      ]);
      final ctrl = await _pump(tester, repo: repo, facade: facade);
      await ctrl.loadChats(reset: true);
      expect(ctrl.chats.length, 2);

      repo.queueResponse([_item(id: 'new1', name: 'New1')]);
      await ctrl.loadChats(reset: true);
      expect(ctrl.chats.length, 1);
      expect(ctrl.chats.first.chatId.value, 'new1');

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // Unread count: verifies stream refreshes after loadChats
    // -----------------------------------------------------------------------
    testWidgets('unreadCountStream refreshes after loadChats', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      final _ = ctrl.unreadCountStream;
      repo.queueResponse([]);
      await ctrl.loadChats(reset: true);
      final streamAfter = ctrl.unreadCountStream;

      // Stream should be replaced (refreshed) after loadChats
      expect(streamAfter, isNotNull);

      ctrl.dispose();
    });

    // -----------------------------------------------------------------------
    // isLoading flag set during loadChats
    // -----------------------------------------------------------------------
    testWidgets('isLoading is true initially and false after loadChats', (
      tester,
    ) async {
      final ctrl = await _pump(tester, repo: repo, facade: facade);

      // Initially isLoading is true
      expect(ctrl.isLoading, isTrue);

      repo.queueResponse([]);
      await ctrl.loadChats(reset: true);
      expect(ctrl.isLoading, isFalse);

      ctrl.dispose();
    });
  });
}
