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


// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

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
 int toggleSearchCalls = 0;
 int showSearchCalls = 0;
 int clearSearchCalls = 0;
 int refreshUnreadCountCalls = 0;

 final List<ChatListItem> archivedChats = <ChatListItem>[];
 final List<ChatListItem> deletedChats = <ChatListItem>[];
 final List<ChatListItem> pinnedChats = <ChatListItem>[];
 final List<ChatListItem> openedChats = <ChatListItem>[];
 final List<ChatId> markedReadChats = <ChatId>[];
 String? lastEditedName;

 bool archiveConfirmResult = true;
 bool deleteConfirmResult = true;

 final StreamController<int> _unreadController =
 StreamController<int>.broadcast();

 void emitUnreadCount(int count) => _unreadController.add(count);

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
 Future<void> openChat(ChatListItem chat) async {
 openedChats.add(chat);
 }

 @override
 void toggleSearch() {
 toggleSearchCalls++;
 }

 @override
 void showSearch() {
 showSearchCalls++;
 }

 @override
 Future<void> clearSearch() async {
 clearSearchCalls++;
 }

 @override
 void openSettings() {
 openSettingsCalls++;
 }

 @override
 void openProfile() {
 openProfileCalls++;
 }

 @override
 Future<String?> editDisplayName(String currentName) async {
 lastEditedName = currentName;
 return currentName;
 }

 @override
 void openContacts() {
 openContactsCalls++;
 }

 @override
 void openArchives() {
 openArchivesCalls++;
 }

 @override
 Future<bool> showArchiveConfirmation(ChatListItem chat) async =>
 archiveConfirmResult;

 @override
 Future<void> archiveChat(ChatListItem chat) async {
 archivedChats.add(chat);
 }

 @override
 Future<bool> showDeleteConfirmation(ChatListItem chat) async =>
 deleteConfirmResult;

 @override
 Future<void> deleteChat(ChatListItem chat) async {
 deletedChats.add(chat);
 }

 @override
 void showChatContextMenu(ChatListItem chat) {}

 @override
 Future<void> toggleChatPin(ChatListItem chat) async {
 pinnedChats.add(chat);
 }

 @override
 Future<void> markChatAsRead(ChatId chatId) async {
 markedReadChats.add(chatId);
 }

 @override
 void refreshUnreadCount() {
 refreshUnreadCountCalls++;
 }

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

class _ConnectedHomeScreenFacade extends _FakeHomeScreenFacade {
 @override
 ConnectionStatus determineConnectionStatus({
 required String? contactPublicKey,
 required String contactName,
 required ConnectionInfo? currentConnectionInfo,
 required List<Peripheral> discoveredDevices,
 required Map<String, dynamic> discoveryData,
 required DateTime? lastSeenTime,
 }) {
 return ConnectionStatus.connected;
 }
}

class _NearbyHomeScreenFacade extends _FakeHomeScreenFacade {
 @override
 ConnectionStatus determineConnectionStatus({
 required String? contactPublicKey,
 required String contactName,
 required ConnectionInfo? currentConnectionInfo,
 required List<Peripheral> discoveredDevices,
 required Map<String, dynamic> discoveryData,
 required DateTime? lastSeenTime,
 }) {
 return ConnectionStatus.nearby;
 }
}

class _FakeMeshNetworkingService extends Fake
 implements IMeshNetworkingService {
 _FakeMeshNetworkingService({MeshNetworkStatus? status})
 : _status = status ??
 const MeshNetworkStatus(isInitialized: true,
 currentNodeId: 'node-test',
 isConnected: true,
 statistics: MeshNetworkStatistics(nodeId: 'node-test',
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

class _EmptyUsernameNotifier extends UsernameNotifier {
 @override
 Future<String> build() async => '';
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ChatListItem _chat(String id, {
 int unreadCount = 0,
 bool hasUnsentMessages = false,
 String? lastMessage = 'hello',
 DateTime? lastMessageTime,
 bool isOnline = false,
 DateTime? lastSeen,
}) {
 return ChatListItem(chatId: ChatId(id),
 contactName: 'Contact $id',
 contactPublicKey: id,
 lastMessage: lastMessage,
 lastMessageTime: lastMessageTime ?? DateTime(2026, 1, 1, 10, 0),
 unreadCount: unreadCount,
 isOnline: isOnline,
 hasUnsentMessages: hasUnsentMessages,
 lastSeen: lastSeen,
);
}

Future<void> _pumpHomeScreen(WidgetTester tester, {
 required _FakeChatsRepository repository,
 required _FakeChatManagementService chatManagementService,
 required _FakeHomeScreenFacade facade,
 required IMeshNetworkingService meshService,
 BluetoothLowEnergyState bleState = BluetoothLowEnergyState.poweredOn,
 List<Peripheral> discoveredDevices = const <Peripheral>[],
 String username = 'Alice',
 UsernameNotifier? usernameNotifier,
}) async {
 await tester.pumpWidget(ProviderScope(overrides: [
 homeScreenFacadeProvider.overrideWith((ref, args) => facade),
 meshNetworkingServiceProvider.overrideWithValue(meshService),
 usernameProvider.overrideWith(() => usernameNotifier ?? _TestUsernameNotifier(username),
),
 bleStateProvider.overrideWith((ref) => AsyncValue.data(bleState)),
 connectionInfoProvider.overrideWith((ref) => const AsyncValue.data(ConnectionInfo(isConnected: false,
 isReady: false,
 awaitingHandshake: false,
),
),
),
 discoveredDevicesProvider.overrideWith((ref) => AsyncValue.data(discoveredDevices),
),
 discoveryDataProvider.overrideWith((ref) => const AsyncValue.data(<String, DiscoveredEventArgs>{}),
),
 deduplicatedDevicesProvider.overrideWith((ref) => Stream<Map<String, DiscoveredDevice>>.value(const <String, DiscoveredDevice>{},
),
),
 receivedMessagesProvider.overrideWith((ref) => const Stream<String>.empty(),
),
 chatUpdatesStreamProvider.overrideWith((ref) => const Stream<ChatUpdateEvent>.empty(),
),
 messageUpdatesStreamProvider.overrideWith((ref) => const Stream<MessageUpdateEvent>.empty(),
),
],
 child: MaterialApp(home: HomeScreen(chatsRepository: repository,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
 group('HomeScreen additional coverage', () {
 // ========= Empty / Loading States =========

 testWidgets('shows empty state icon and helper text', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
 expect(find.text('Tap Bluetooth button below to scan/broadcast.'),
 findsOneWidget,
);
 });

 testWidgets('loading indicator disappears once chats arrive', (tester,
) async {
 final gate = Completer<List<ChatListItem>>();
 final repo = _FakeChatsRepository()..pendingGetAllChats = gate;
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pump();

 expect(find.byType(CircularProgressIndicator), findsOneWidget);

 gate.complete([_chat('c1')]);
 await tester.pumpAndSettle();

 expect(find.byType(CircularProgressIndicator), findsNothing);
 expect(find.text('Contact c1'), findsOneWidget);
 });

 // ========= Username / AppBar =========

 testWidgets('appBar shows username and tapping triggers edit', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
 username: 'Bob',
);
 await tester.pumpAndSettle();

 expect(find.text('Bob'), findsOneWidget);

 await tester.tap(find.text('Bob'));
 await tester.pumpAndSettle();

 expect(facade.lastEditedName, 'Bob');
 });

 testWidgets('appBar shows PakConnect when username is empty', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
 usernameNotifier: _EmptyUsernameNotifier(),
);
 await tester.pumpAndSettle();

 expect(find.text('PakConnect'), findsOneWidget);
 });

 // ========= Chat list rendering =========

 testWidgets('renders multiple chat tiles in list', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([
 _chat('a'),
 _chat('b'),
 _chat('c'),
]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('Contact a'), findsOneWidget);
 expect(find.text('Contact b'), findsOneWidget);
 expect(find.text('Contact c'), findsOneWidget);
 });

 testWidgets('chat tile shows unread count badge', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('u1', unreadCount: 5)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('5'), findsOneWidget);
 });

 testWidgets('chat tile shows unsent message warning', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('u1', hasUnsentMessages: true)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('Message failed to send'), findsOneWidget);
 expect(find.byIcon(Icons.error_outline), findsOneWidget);
 });

 testWidgets('chat tile shows last message text', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('lm', lastMessage: 'See you later')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('See you later'), findsOneWidget);
 });

 testWidgets('chat tile with connected status shows Active now', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('cn1')]);
 final cms = _FakeChatManagementService();
 final facade = _ConnectedHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('Active now'), findsOneWidget);
 });

 testWidgets('chat tile with nearby status shows Nearby', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('nb1')]);
 final cms = _FakeChatManagementService();
 final facade = _NearbyHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('Nearby'), findsOneWidget);
 expect(find.byIcon(Icons.bluetooth_searching), findsWidgets);
 });

 // ========= Tapping a chat tile =========

 testWidgets('tapping a chat tile calls openChat on facade', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('tap-chat')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.tap(find.text('Contact tap-chat'));
 await tester.pumpAndSettle();

 expect(facade.openedChats.length, 1);
 expect(facade.openedChats.first.chatId, const ChatId('tap-chat'));
 });

 // ========= Swipe actions =========

 testWidgets('swipe left-to-right shows archive background', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('sw-a')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 // Start a drag from left-to-right (startToEnd = archive)
 final chatTile = find.text('Contact sw-a');
 expect(chatTile, findsOneWidget);

 await tester.drag(chatTile, const Offset(300, 0));
 await tester.pump();

 expect(find.text('Archive'), findsOneWidget);
 });

 testWidgets('swipe right-to-left shows delete background', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('sw-d')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 final chatTile = find.text('Contact sw-d');
 await tester.drag(chatTile, const Offset(-300, 0));
 await tester.pump();

 expect(find.text('Delete'), findsOneWidget);
 });

 // ========= Context menu (long press) =========

 testWidgets('long-press shows context menu with archive and delete', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('lp-chat')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact lp-chat'));
 await tester.pumpAndSettle();

 expect(find.text('Archive Chat'), findsOneWidget);
 expect(find.text('Delete Chat'), findsOneWidget);
 });

 testWidgets('context menu shows Pin Chat when not pinned', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('pin-chat')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact pin-chat'));
 await tester.pumpAndSettle();

 expect(find.text('Pin Chat'), findsOneWidget);
 });

 testWidgets('context menu shows Unpin Chat when pinned', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('pinned-chat')]);
 final cms = _FakeChatManagementService()
 ..pinned.add(const ChatId('pinned-chat'));
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact pinned-chat'));
 await tester.pumpAndSettle();

 expect(find.text('Unpin Chat'), findsOneWidget);
 });

 testWidgets('context menu shows Mark as Read when unread > 0', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('unread-chat', unreadCount: 3)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact unread-chat'));
 await tester.pumpAndSettle();

 expect(find.text('Mark as Read'), findsOneWidget);
 });

 testWidgets('context menu shows Mark as Unread when unread == 0', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('read-chat', unreadCount: 0)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact read-chat'));
 await tester.pumpAndSettle();

 expect(find.text('Mark as Unread'), findsOneWidget);
 });

 testWidgets('selecting Pin Chat from context menu calls toggleChatPin', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('pin-action')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact pin-action'));
 await tester.pumpAndSettle();

 await tester.tap(find.text('Pin Chat'));
 await tester.pumpAndSettle();

 expect(facade.pinnedChats.length, 1);
 });

 testWidgets('selecting Archive Chat from context menu archives after confirmation',
 (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('ctx-archive')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact ctx-archive'));
 await tester.pumpAndSettle();

 await tester.tap(find.text('Archive Chat'));
 await tester.pumpAndSettle();

 expect(facade.archivedChats.length, 1);
 },
);

 testWidgets('selecting Delete Chat from context menu deletes after confirmation',
 (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('ctx-delete')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact ctx-delete'));
 await tester.pumpAndSettle();

 await tester.tap(find.text('Delete Chat'));
 await tester.pumpAndSettle();

 expect(facade.deletedChats.length, 1);
 },
);

 testWidgets('selecting Mark as Read from context menu marks read', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('mr-chat', unreadCount: 2)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact mr-chat'));
 await tester.pumpAndSettle();

 await tester.tap(find.text('Mark as Read'));
 await tester.pumpAndSettle();

 expect(facade.markedReadChats, contains(const ChatId('mr-chat')));
 });

 // ========= Search =========

 testWidgets('search bar opens on search icon and filters by query', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 // Search bar not visible initially
 expect(find.text('Search chats...'), findsNothing);

 // Tap search icon
 await tester.tap(find.byIcon(Icons.search).first);
 await tester.pumpAndSettle();

 // Search bar should now be visible
 expect(find.text('Search chats...'), findsOneWidget);
 });

 testWidgets('entering text in search bar passes query to repository', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.tap(find.byIcon(Icons.search).first);
 await tester.pumpAndSettle();

 await tester.enterText(find.byType(TextField), 'bob');
 await tester.pumpAndSettle();

 expect(repo.seenSearchQueries, contains('bob'));
 });

 testWidgets('clear button collapses search bar', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 // Open search
 await tester.tap(find.byIcon(Icons.search).first);
 await tester.pumpAndSettle();
 expect(find.text('Search chats...'), findsOneWidget);

 // Enter text then clear
 await tester.enterText(find.byType(TextField), 'test');
 await tester.pumpAndSettle();

 await tester.tap(find.byIcon(Icons.clear));
 await tester.pumpAndSettle();

 expect(find.text('Search chats...'), findsNothing);
 });

 // ========= Menu =========

 testWidgets('menu Profile action opens profile', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await _openMenuAndSelect(tester, 'Profile');
 expect(facade.openProfileCalls, 1);
 });

 testWidgets('menu Contacts action opens contacts', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await _openMenuAndSelect(tester, 'Contacts');
 expect(facade.openContactsCalls, 1);
 });

 testWidgets('menu Archived Chats action opens archives', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await _openMenuAndSelect(tester, 'Archived Chats');
 expect(facade.openArchivesCalls, 1);
 });

 testWidgets('menu Settings action opens settings', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await _openMenuAndSelect(tester, 'Settings');
 expect(facade.openSettingsCalls, 1);
 });

 // ========= Tab switching =========

 testWidgets('switching to Mesh Relay tab hides FAB', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 // FAB visible on Chats tab
 expect(find.byType(FloatingActionButton), findsOneWidget);

 // Switch to Mesh Relay
 await tester.tap(find.text('Mesh Relay'));
 await tester.pumpAndSettle();

 // FAB should be hidden
 expect(find.byType(FloatingActionButton), findsNothing);
 });

 testWidgets('switching back to Chats tab shows FAB again', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.tap(find.text('Mesh Relay'));
 await tester.pumpAndSettle();
 expect(find.byType(FloatingActionButton), findsNothing);

 await tester.tap(find.text('Chats'));
 await tester.pumpAndSettle();
 expect(find.byType(FloatingActionButton), findsOneWidget);
 });

 testWidgets('Mesh Relay tab shows RelayQueueWidget content', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.tap(find.text('Mesh Relay'));
 await tester.pumpAndSettle();

 expect(find.textContaining('Relay Queue'), findsOneWidget);
 });

 // ========= FAB / Discovery Overlay =========

 testWidgets('FAB opens discovery overlay and close button dismisses it', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.tap(find.byIcon(Icons.bluetooth_searching));
 await tester.pumpAndSettle();

 expect(find.byType(DiscoveryOverlay), findsOneWidget);
 });

 testWidgets('FAB has correct tooltip', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton),
);
 expect(fab.tooltip, 'Discover nearby devices');
 });

 // ========= BLE status banner =========

 testWidgets('no BLE banner when Bluetooth is powered on', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
 bleState: BluetoothLowEnergyState.poweredOn,
);
 await tester.pumpAndSettle();

 expect(find.byIcon(Icons.bluetooth_disabled), findsNothing);
 });

 testWidgets('BLE banner shows when Bluetooth is unauthorized', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
 bleState: BluetoothLowEnergyState.unauthorized,
);
 await tester.pumpAndSettle();

 expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
 expect(find.text('Bluetooth unauthorized - Allow Permission!'),
 findsOneWidget,
);
 });

 // ========= Unread badge on search icon =========

 testWidgets('unread badge shows count from unread stream', (tester,
) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 // Emit unread count
 facade.emitUnreadCount(7);
 await tester.pumpAndSettle();

 expect(find.text('7'), findsOneWidget);
 });

 testWidgets('unread badge shows 99+ for high count', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 facade.emitUnreadCount(150);
 await tester.pumpAndSettle();

 expect(find.text('99+'), findsOneWidget);
 });

 testWidgets('unread badge hidden when count is 0', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 facade.emitUnreadCount(0);
 await tester.pumpAndSettle();

 // Should not find any count badge
 expect(find.text('0'), findsNothing);
 });

 // ========= Tab icons =========

 testWidgets('tab bar shows Chats and Mesh Relay tabs', (tester) async {
 final repo = _FakeChatsRepository();
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('Chats'), findsOneWidget);
 expect(find.text('Mesh Relay'), findsOneWidget);
 expect(find.byIcon(Icons.chat), findsOneWidget);
 expect(find.byIcon(Icons.device_hub), findsOneWidget);
 });

 // ========= RefreshIndicator =========

 testWidgets('RefreshIndicator wraps the chat list', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('r1')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 // Verify that a RefreshIndicator is rendered around the chat list
 expect(find.byType(RefreshIndicator), findsOneWidget);
 expect(find.text('Contact r1'), findsOneWidget);
 });

 // ========= Chat tile with no last message =========

 testWidgets('chat tile without last message omits subtitle text', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([
 _chat('no-msg', lastMessage: null, lastMessageTime: null),
]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 expect(find.text('Contact no-msg'), findsOneWidget);
 // Should not find the default 'hello' text
 expect(find.text('hello'), findsNothing);
 });

 // ========= archive confirmation denied =========

 testWidgets('archive from context menu does not archive when confirmation denied',
 (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('no-archive')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade()..archiveConfirmResult = false;
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact no-archive'));
 await tester.pumpAndSettle();

 await tester.tap(find.text('Archive Chat'));
 await tester.pumpAndSettle();

 expect(facade.archivedChats, isEmpty);
 },
);

 testWidgets('delete from context menu does not delete when confirmation denied',
 (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('no-delete')]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade()..deleteConfirmResult = false;
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 await tester.longPress(find.text('Contact no-delete'));
 await tester.pumpAndSettle();

 await tester.tap(find.text('Delete Chat'));
 await tester.pumpAndSettle();

 expect(facade.deletedChats, isEmpty);
 },
);

 // ========= Chat tile text styling for unread =========

 testWidgets('chat name is bold when unread count > 0', (tester) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('bold-chat', unreadCount: 2)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 final titleText = tester.widget<Text>(find.text('Contact bold-chat'));
 expect(titleText.style?.fontWeight, FontWeight.bold);
 });

 testWidgets('chat name is normal weight when unread count is 0', (tester,
) async {
 final repo = _FakeChatsRepository()
 ..scriptedResponses.add([_chat('normal-chat', unreadCount: 0)]);
 final cms = _FakeChatManagementService();
 final facade = _FakeHomeScreenFacade();
 final mesh = _FakeMeshNetworkingService();

 await _pumpHomeScreen(tester,
 repository: repo,
 chatManagementService: cms,
 facade: facade,
 meshService: mesh,
);
 await tester.pumpAndSettle();

 final titleText = tester.widget<Text>(find.text('Contact normal-chat'));
 expect(titleText.style?.fontWeight, FontWeight.normal);
 });
 });
}
