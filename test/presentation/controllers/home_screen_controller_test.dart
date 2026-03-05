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

class _ControllerHost extends ConsumerStatefulWidget {
  const _ControllerHost({
    required this.controllerBuilder,
    required this.onControllerReady,
  });

  final HomeScreenController Function(BuildContext context, WidgetRef ref)
  controllerBuilder;
  final ValueChanged<HomeScreenController> onControllerReady;

  @override
  ConsumerState<_ControllerHost> createState() => _ControllerHostState();
}

class _ControllerHostState extends ConsumerState<_ControllerHost> {
  HomeScreenController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= widget.controllerBuilder(context, ref);
    widget.onControllerReady(_controller!);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _FakeChatsRepository implements IChatsRepository {
  int getAllChatsCallCount = 0;
  int totalUnreadCountCalls = 0;

  String? lastSearchQuery;
  int? lastLimit;
  int? lastOffset;

  Object? getAllChatsError;
  final List<List<ChatListItem>> _queuedResponses = <List<ChatListItem>>[];

  void queueResponse(List<ChatListItem> chats) {
    _queuedResponses.add(chats);
  }

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

    if (_queuedResponses.isEmpty) {
      return <ChatListItem>[];
    }
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

class _FakeHomeScreenFacade implements IHomeScreenFacade {
  int openChatCalls = 0;
  int archiveCalls = 0;
  int deleteCalls = 0;
  int pinToggleCalls = 0;
  int openContactsCalls = 0;
  int openArchivesCalls = 0;
  int openSettingsCalls = 0;
  int openProfileCalls = 0;

  String? editedDisplayName;
  ConnectionStatus statusToReturn = ConnectionStatus.offline;

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
  Future<void> archiveChat(ChatListItem chat) async {
    archiveCalls++;
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
  }) {
    return statusToReturn;
  }

  @override
  Future<void> deleteChat(ChatListItem chat) async {
    deleteCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<String?> editDisplayName(String currentName) async {
    return editedDisplayName ?? currentName;
  }

  @override
  Future<void> initialize() async {}

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
  void openArchives() {
    openArchivesCalls++;
  }

  @override
  void openContacts() {
    openContactsCalls++;
  }

  @override
  void openProfile() {
    openProfileCalls++;
  }

  @override
  void openSettings() {
    openSettingsCalls++;
  }

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
  }
}

class _TestHomeScreenController extends HomeScreenController {
  _TestHomeScreenController(super.args);

  int loadCount = 0;

  @override
  Future<void> loadChats({bool reset = true}) async {
    loadCount++;
  }
}

ChatListItem _chat({
  required String id,
  required String name,
  DateTime? time,
  bool online = false,
  int unreadCount = 0,
}) {
  return ChatListItem(
    chatId: ChatId(id),
    contactName: name,
    contactPublicKey: id,
    lastMessage: 'message-$id',
    lastMessageTime: time,
    unreadCount: unreadCount,
    isOnline: online,
    hasUnsentMessages: false,
  );
}

Future<HomeScreenController> _pumpController(
  WidgetTester tester, {
  required _FakeChatsRepository repository,
  required _FakeHomeScreenFacade facade,
  bool testable = false,
}) async {
  late HomeScreenController controller;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        discoveredDevicesProvider.overrideWith(
          (ref) => const AsyncValue<List<Peripheral>>.data(<Peripheral>[]),
        ),
        discoveryDataProvider.overrideWith(
          (ref) => const AsyncValue<Map<String, DiscoveredEventArgs>>.data(
            <String, DiscoveredEventArgs>{},
          ),
        ),
      ],
      child: MaterialApp(
        home: _ControllerHost(
          controllerBuilder: (context, ref) {
            final args = HomeScreenControllerArgs(
              context: context,
              ref: ref,
              chatsRepository: repository,
              chatManagementService: ChatManagementService(),
              homeScreenFacade: facade,
              logger: Logger('HomeScreenControllerTest'),
            );
            if (testable) {
              return _TestHomeScreenController(args);
            }
            return HomeScreenController(args);
          },
          onControllerReady: (value) {
            controller = value;
          },
        ),
      ),
    ),
  );

  await tester.pump();
  return controller;
}

void main() {
  group('HomeScreenController', () {
    late _FakeChatsRepository repository;
    late _FakeHomeScreenFacade facade;

    setUp(() {
      repository = _FakeChatsRepository();
      facade = _FakeHomeScreenFacade();
    });

    testWidgets('search sentinel and clear trigger expected reload behavior', (
      tester,
    ) async {
      final _TestHomeScreenController controller =
          await _pumpController(
                tester,
                repository: repository,
                facade: facade,
                testable: true,
              )
              as _TestHomeScreenController;

      controller.onSearchChanged(' ');
      expect(controller.searchQuery, ' ');
      expect(controller.loadCount, 0);

      controller.onSearchChanged('hello');
      expect(controller.searchQuery, 'hello');
      expect(controller.loadCount, 1);

      controller.onSearchChanged('   ');
      expect(controller.searchQuery, '');
      expect(controller.loadCount, 2);

      controller.clearSearch();
      expect(controller.searchQuery, '');
      expect(controller.loadCount, 3);

      controller.dispose();
    });

    testWidgets('loadChats supports paging and search query mode', (
      tester,
    ) async {
      final DateTime now = DateTime.now();
      repository.queueResponse(
        List<ChatListItem>.generate(
          50,
          (index) => _chat(
            id: 'chat-$index',
            name: 'Chat $index',
            time: now.subtract(Duration(minutes: index)),
          ),
        ),
      );
      repository.queueResponse(
        List<ChatListItem>.generate(
          10,
          (index) => _chat(
            id: 'chat-next-$index',
            name: 'Next $index',
            time: now.subtract(Duration(hours: index)),
          ),
        ),
      );
      repository.queueResponse(
        List<ChatListItem>.generate(
          3,
          (index) => _chat(
            id: 'search-$index',
            name: 'Search $index',
            time: now.subtract(Duration(days: index)),
          ),
        ),
      );

      final HomeScreenController controller = await _pumpController(
        tester,
        repository: repository,
        facade: facade,
      );

      await controller.loadChats(reset: true);
      expect(repository.lastSearchQuery, isNull);
      expect(repository.lastLimit, 50);
      expect(repository.lastOffset, 0);
      expect(controller.chats.length, 50);
      expect(controller.hasMore, isTrue);
      expect(controller.isPaging, isFalse);

      await controller.loadMoreChats();
      expect(repository.lastLimit, 50);
      expect(repository.lastOffset, 50);
      expect(controller.chats.length, 60);
      expect(controller.hasMore, isFalse);

      controller.searchQuery = 'alice';
      await controller.loadChats(reset: true);
      expect(repository.lastSearchQuery, 'alice');
      expect(repository.lastLimit, isNull);
      expect(repository.lastOffset, 0);
      expect(controller.chats.length, 3);
      expect(controller.hasMore, isFalse);

      controller.dispose();
    });

    testWidgets('loadMoreChats exits when no more data is available', (
      tester,
    ) async {
      repository.queueResponse(<ChatListItem>[
        _chat(id: 'only', name: 'Only', time: DateTime.now()),
      ]);

      final HomeScreenController controller = await _pumpController(
        tester,
        repository: repository,
        facade: facade,
      );

      await controller.loadChats(reset: true);
      expect(repository.getAllChatsCallCount, 1);
      expect(controller.hasMore, isFalse);

      await controller.loadMoreChats();
      expect(repository.getAllChatsCallCount, 1);

      controller.dispose();
    });

    testWidgets(
      'updateSingleChatItem updates existing chat and inserts new one',
      (tester) async {
        final DateTime now = DateTime.now();
        repository.queueResponse(<ChatListItem>[
          _chat(
            id: 'a',
            name: 'Alice Updated',
            time: now,
            online: true,
            unreadCount: 3,
          ),
        ]);
        repository.queueResponse(<ChatListItem>[
          _chat(
            id: 'z',
            name: 'Zara',
            time: now.add(const Duration(minutes: 1)),
          ),
        ]);
        repository.queueResponse(<ChatListItem>[]);

        final HomeScreenController controller = await _pumpController(
          tester,
          repository: repository,
          facade: facade,
        );

        controller.chats = <ChatListItem>[
          _chat(
            id: 'a',
            name: 'Alice',
            time: now.subtract(const Duration(days: 1)),
          ),
          _chat(
            id: 'b',
            name: 'Bob',
            time: now.subtract(const Duration(hours: 2)),
          ),
        ];

        await controller.updateSingleChatItem();
        expect(
          controller.chats
              .firstWhere((chat) => chat.chatId == const ChatId('a'))
              .contactName,
          'Alice Updated',
        );
        expect(controller.chats.first.chatId, const ChatId('a'));

        await controller.updateSingleChatItem();
        expect(controller.chats.first.chatId, const ChatId('z'));

        final int before = controller.chats.length;
        await controller.updateSingleChatItem();
        expect(controller.chats.length, before);

        controller.dispose();
      },
    );

    testWidgets('updateSingleChatItem falls back to full reload on errors', (
      tester,
    ) async {
      repository.getAllChatsError = StateError('boom');
      final _TestHomeScreenController controller =
          await _pumpController(
                tester,
                repository: repository,
                facade: facade,
                testable: true,
              )
              as _TestHomeScreenController;

      await controller.updateSingleChatItem();
      expect(controller.loadCount, 1);

      controller.dispose();
    });

    testWidgets('chat actions delegate to facade and trigger reload', (
      tester,
    ) async {
      final _TestHomeScreenController controller =
          await _pumpController(
                tester,
                repository: repository,
                facade: facade,
                testable: true,
              )
              as _TestHomeScreenController;

      final ChatListItem item = _chat(id: 'chat-1', name: 'Chat 1');

      await controller.openChat(item);
      await controller.archiveChat(item);
      await controller.deleteChat(item);
      await controller.toggleChatPin(item);

      expect(facade.openChatCalls, 1);
      expect(facade.archiveCalls, 1);
      expect(facade.deleteCalls, 1);
      expect(facade.pinToggleCalls, 1);
      expect(controller.loadCount, 4);

      controller.dispose();
    });

    testWidgets('navigation helpers and connection status delegate to facade', (
      tester,
    ) async {
      facade.editedDisplayName = 'Renamed';
      facade.statusToReturn = ConnectionStatus.connected;

      final HomeScreenController controller = await _pumpController(
        tester,
        repository: repository,
        facade: facade,
      );

      await controller.openContacts();
      await controller.openArchives();
      await controller.openSettings();
      await controller.openProfile();

      final String? edited = await controller.editDisplayName('Old');
      final ConnectionStatus status = controller.determineConnectionStatus(
        contactPublicKey: 'pk',
        contactName: 'Alice',
        currentConnectionInfo: null,
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: null,
      );

      expect(edited, 'Renamed');
      expect(status, ConnectionStatus.connected);
      expect(facade.openContactsCalls, 1);
      expect(facade.openArchivesCalls, 1);
      expect(facade.openSettingsCalls, 1);
      expect(facade.openProfileCalls, 1);
      await expectLater(
        controller.showArchiveConfirmation(_chat(id: 'a', name: 'A')),
        completion(isTrue),
      );
      await expectLater(
        controller.showDeleteConfirmation(_chat(id: 'b', name: 'B')),
        completion(isTrue),
      );

      controller.dispose();
    });
  });
}
