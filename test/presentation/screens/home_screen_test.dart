import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/chat_notification_providers.dart';
import 'package:pak_connect/presentation/providers/home_screen_providers.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/presentation/screens/home_screen.dart';
import 'package:pak_connect/presentation/widgets/discovery_overlay.dart';

import '../../helpers/ble/ble_fakes.dart';

class _FakeChatsRepository extends Fake implements IChatsRepository {
  final List<List<ChatListItem>> scriptedResponses = <List<ChatListItem>>[];
  final List<String?> seenSearchQueries = <String?>[];
  Completer<List<ChatListItem>>? pendingGetAllChats;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    seenSearchQueries.add(searchQuery);

    final pending = pendingGetAllChats;
    if (pending != null) {
      pendingGetAllChats = null;
      return pending.future;
    }

    if (scriptedResponses.isNotEmpty) {
      return scriptedResponses.removeAt(0);
    }

    return const <ChatListItem>[];
  }
}

class _FakeChatManagementService extends Fake implements ChatManagementService {
  int initializeCalls = 0;
  final Set<ChatId> pinned = <ChatId>{};

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  bool isChatPinned(ChatId chatId) => pinned.contains(chatId);
}

class _FakeHomeScreenFacade extends Fake implements IHomeScreenFacade {
  int initializeCalls = 0;
  int openContactsCalls = 0;
  int openArchivesCalls = 0;
  int openSettingsCalls = 0;
  int openProfileCalls = 0;

  final StreamController<int> _unreadController =
      StreamController<int>.broadcast();

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Stream<int> get unreadCountStream => _unreadController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      const Stream<ConnectionStatus>.empty();

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async =>
      const <ChatListItem>[];

  @override
  List<ChatListItem> get chats => const <ChatListItem>[];

  @override
  bool get isLoading => false;

  @override
  Future<void> openChat(ChatListItem chat) async {}

  @override
  void toggleSearch() {}

  @override
  void showSearch() {}

  @override
  Future<void> clearSearch() async {}

  @override
  void openSettings() {
    openSettingsCalls++;
  }

  @override
  void openProfile() {
    openProfileCalls++;
  }

  @override
  Future<String?> editDisplayName(String currentName) async => currentName;

  @override
  void openContacts() {
    openContactsCalls++;
  }

  @override
  void openArchives() {
    openArchivesCalls++;
  }

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async => true;

  @override
  Future<void> archiveChat(ChatListItem chat) async {}

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async => true;

  @override
  Future<void> deleteChat(ChatListItem chat) async {}

  @override
  void showChatContextMenu(ChatListItem chat) {}

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {}

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

  @override
  void refreshUnreadCount() {}

  @override
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  }) {
    return ConnectionStatus.offline;
  }

  @override
  Future<void> dispose() async {
    await _unreadController.close();
  }
}

class _FakeMeshNetworkingService extends Fake
    implements IMeshNetworkingService {
  _FakeMeshNetworkingService({MeshNetworkStatus? status})
    : _status =
          status ??
          const MeshNetworkStatus(
            isInitialized: true,
            currentNodeId: 'node-test',
            isConnected: true,
            statistics: MeshNetworkStatistics(
              nodeId: 'node-test',
              isInitialized: true,
              relayStatistics: null,
              queueStatistics: null,
              syncStatistics: null,
              spamStatistics: null,
              spamPreventionActive: false,
              queueSyncActive: false,
            ),
            queueMessages: <QueuedMessage>[],
          );

  final MeshNetworkStatus _status;

  @override
  Stream<MeshNetworkStatus> get meshStatus =>
      Stream<MeshNetworkStatus>.value(_status);

  @override
  MeshNetworkStatistics getNetworkStatistics() => _status.statistics;
}

class _TestUsernameNotifier extends UsernameNotifier {
  _TestUsernameNotifier(this._name);

  final String _name;

  @override
  Future<String> build() async => _name;
}

ChatListItem _chat(String id) {
  return ChatListItem(
    chatId: ChatId(id),
    contactName: 'Contact $id',
    contactPublicKey: id,
    lastMessage: 'hello',
    lastMessageTime: DateTime(2026, 1, 1, 10, 0),
    unreadCount: 0,
    isOnline: false,
    hasUnsentMessages: false,
  );
}

Future<void> _pumpHomeScreen(
  WidgetTester tester, {
  required _FakeChatsRepository repository,
  required _FakeChatManagementService chatManagementService,
  required _FakeHomeScreenFacade facade,
  required IMeshNetworkingService meshService,
  BluetoothLowEnergyState bleState = BluetoothLowEnergyState.poweredOn,
  List<Peripheral> discoveredDevices = const <Peripheral>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeScreenFacadeProvider.overrideWith((ref, args) => facade),
        meshNetworkingServiceProvider.overrideWithValue(meshService),
        usernameProvider.overrideWith(() => _TestUsernameNotifier('Alice')),
        bleStateProvider.overrideWith((ref) => AsyncValue.data(bleState)),
        connectionInfoProvider.overrideWith(
          (ref) => const AsyncValue.data(
            ConnectionInfo(
              isConnected: false,
              isReady: false,
              awaitingHandshake: false,
            ),
          ),
        ),
        discoveredDevicesProvider.overrideWith(
          (ref) => AsyncValue.data(discoveredDevices),
        ),
        discoveryDataProvider.overrideWith(
          (ref) => const AsyncValue.data(<String, DiscoveredEventArgs>{}),
        ),
        deduplicatedDevicesProvider.overrideWith(
          (ref) => Stream<Map<String, DiscoveredDevice>>.value(
            const <String, DiscoveredDevice>{},
          ),
        ),
        receivedMessagesProvider.overrideWith(
          (ref) => const Stream<String>.empty(),
        ),
        chatUpdatesStreamProvider.overrideWith(
          (ref) => const Stream<ChatUpdateEvent>.empty(),
        ),
        messageUpdatesStreamProvider.overrideWith(
          (ref) => const Stream<MessageUpdateEvent>.empty(),
        ),
      ],
      child: MaterialApp(
        home: HomeScreen(
          chatsRepository: repository,
          chatManagementService: chatManagementService,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openMenuAndSelect(WidgetTester tester, String label) async {
  await tester.tap(find.byType(PopupMenuButton<HomeMenuAction>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('HomeScreen', () {
    testWidgets('shows loading spinner during initial load then empty state', (
      tester,
    ) async {
      final loadGate = Completer<List<ChatListItem>>();
      final repository = _FakeChatsRepository()..pendingGetAllChats = loadGate;
      final chatManagementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();
      final meshService = _FakeMeshNetworkingService();

      await _pumpHomeScreen(
        tester,
        repository: repository,
        chatManagementService: chatManagementService,
        facade: facade,
        meshService: meshService,
      );

      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      loadGate.complete(const <ChatListItem>[]);
      await tester.pumpAndSettle();

      expect(find.text('No conversations yet'), findsOneWidget);
      expect(chatManagementService.initializeCalls, 1);
      expect(facade.initializeCalls, 1);
    });

    testWidgets('shows nearby-device empty-state copy when devices exist', (
      tester,
    ) async {
      final repository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();
      final meshService = _FakeMeshNetworkingService();
      final nearby = [
        FakePeripheral(
          uuid: UUID.fromString('11111111-1111-1111-1111-111111111111'),
        ),
      ];

      await _pumpHomeScreen(
        tester,
        repository: repository,
        chatManagementService: chatManagementService,
        facade: facade,
        meshService: meshService,
        discoveredDevices: nearby,
      );
      await tester.pumpAndSettle();

      expect(find.text('Connect to a nearby device first.'), findsOneWidget);
    });

    testWidgets('shows bluetooth banner when adapter is not powered on', (
      tester,
    ) async {
      final repository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();
      final meshService = _FakeMeshNetworkingService();

      await _pumpHomeScreen(
        tester,
        repository: repository,
        chatManagementService: chatManagementService,
        facade: facade,
        meshService: meshService,
        bleState: BluetoothLowEnergyState.poweredOff,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Bluetooth poweredOff - Allow Permission!'),
        findsOneWidget,
      );
    });

    testWidgets('search button opens bar and clear button collapses it', (
      tester,
    ) async {
      final repository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();
      final meshService = _FakeMeshNetworkingService();

      await _pumpHomeScreen(
        tester,
        repository: repository,
        chatManagementService: chatManagementService,
        facade: facade,
        meshService: meshService,
      );
      await tester.pumpAndSettle();

      expect(find.text('Search chats...'), findsNothing);

      await tester.tap(find.byIcon(Icons.search).first);
      await tester.pumpAndSettle();
      expect(find.text('Search chats...'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ali');
      await tester.pumpAndSettle();
      expect(repository.seenSearchQueries, contains('ali'));

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(find.text('Search chats...'), findsNothing);
    });

    testWidgets('menu actions delegate to facade navigation helpers', (
      tester,
    ) async {
      final repository = _FakeChatsRepository()
        ..scriptedResponses.add(<ChatListItem>[_chat('chat-1')]);
      final chatManagementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();
      final meshService = _FakeMeshNetworkingService();

      await _pumpHomeScreen(
        tester,
        repository: repository,
        chatManagementService: chatManagementService,
        facade: facade,
        meshService: meshService,
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Profile');
      await _openMenuAndSelect(tester, 'Contacts');
      await _openMenuAndSelect(tester, 'Archived Chats');
      await _openMenuAndSelect(tester, 'Settings');

      expect(facade.openProfileCalls, 1);
      expect(facade.openContactsCalls, 1);
      expect(facade.openArchivesCalls, 1);
      expect(facade.openSettingsCalls, 1);
    });

    testWidgets(
      'relay tab shows queue card and toggles floating action button',
      (tester) async {
        final repository = _FakeChatsRepository();
        final chatManagementService = _FakeChatManagementService();
        final facade = _FakeHomeScreenFacade();
        final meshService = _FakeMeshNetworkingService();

        await _pumpHomeScreen(
          tester,
          repository: repository,
          chatManagementService: chatManagementService,
          facade: facade,
          meshService: meshService,
        );
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);

        await tester.tap(find.text('Mesh Relay'));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.bluetooth_searching), findsNothing);
        expect(find.textContaining('Relay Queue'), findsOneWidget);

        await tester.tap(find.text('Chats'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
      },
    );

    testWidgets('floating action button opens discovery overlay', (
      tester,
    ) async {
      final repository = _FakeChatsRepository();
      final chatManagementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();
      final meshService = _FakeMeshNetworkingService();

      await _pumpHomeScreen(
        tester,
        repository: repository,
        chatManagementService: chatManagementService,
        facade: facade,
        meshService: meshService,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.bluetooth_searching));
      await tester.pumpAndSettle();

      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });
  });
}
