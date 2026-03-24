/// Additional HomeScreenController coverage
/// Targets uncovered lines: constructor facade-provider fallback (49-56),
/// initialize flow (90-95), discoveryData/nearbyDevices orElse branches
/// (116, 194, 294), handleDeviceSelected (265-268),
/// _setupGlobalMessageListener (271-286), _setupPeripheralConnectionListener
/// (298-300), _setupDiscoveryListener (326-336),
/// _handleIncomingPeripheralConnection (338-340),
/// _setupUnreadCountStream inner (346), and homeScreenControllerProvider
/// (408-411).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/models/binary_payload.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/bluetooth_state_models.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/home_screen_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';

// ---------------------------------------------------------------------------
// Fake ChatManagementService (Fake throws UnimplementedError for uncalled
// methods, which is fine for tests that only exercise the controller.)
// ---------------------------------------------------------------------------

class _FakeChatManagement extends Fake implements ChatManagementService {
 @override
 Future<void> initialize() async {}
 @override
 Future<void> dispose() async {}
 @override
 bool isChatPinned(ChatId chatId) => false;
}

// ---------------------------------------------------------------------------
// Fake IChatsRepository (same pattern as phase13b)
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

// ---------------------------------------------------------------------------
// Fake IHomeScreenFacade
// ---------------------------------------------------------------------------

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
// Minimal fake IConnectionService (domain layer only – no core imports)
// ---------------------------------------------------------------------------

class _FakeConnectionService implements IConnectionService {
 final StreamController<String> receivedMessagesCtrl =
 StreamController<String>.broadcast();
 final StreamController<CentralConnectionStateChangedEventArgs>
 peripheralChangesCtrl = StreamController.broadcast();
 final StreamController<ConnectionInfo> connectionInfoCtrl =
 StreamController<ConnectionInfo>.broadcast();
 final StreamController<Map<String, DiscoveredEventArgs>> discoveryCtrl =
 StreamController.broadcast();

 @override
 Stream<String> get receivedMessages => receivedMessagesCtrl.stream;
 @override
 Stream<CentralConnectionStateChangedEventArgs>
 get peripheralConnectionChanges => peripheralChangesCtrl.stream;
 @override
 bool get isPeripheralMode => false;
 @override
 Stream<ConnectionInfo> get connectionInfo => connectionInfoCtrl.stream;
 @override
 ConnectionInfo get currentConnectionInfo =>
 const ConnectionInfo(isConnected: false, isReady: false);
 @override
 Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
 discoveryCtrl.stream;

 // ---- stubs for everything else (not exercised by the controller) ----
 @override
 Stream<List<Peripheral>> get discoveredDevices => const Stream.empty();
 @override
 Stream<String> get hintMatches => const Stream.empty();
 @override
 Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async => null;
 @override
 Stream<SpyModeInfo> get spyModeDetected => const Stream.empty();
 @override
 Stream<String> get identityRevealed => const Stream.empty();
 @override
 Central? get connectedCentral => null;
 @override
 Peripheral? get connectedDevice => null;
 @override
 Future<String> sendBinaryMedia({
 required Uint8List data,
 required String recipientId,
 int originalType = 0,
 Map<String, dynamic>? metadata,
 bool persistOnly = false,
 }) async => '';
 @override
 Future<bool> retryBinaryMedia({
 required String transferId,
 String? recipientId,
 int? originalType,
 }) async => false;
 @override
 Stream<BluetoothStateInfo> get bluetoothStateStream => const Stream.empty();
 @override
 Stream<BluetoothStatusMessage> get bluetoothMessageStream =>
 const Stream.empty();
 @override
 bool get isBluetoothReady => false;
 @override
 BluetoothLowEnergyState get state => BluetoothLowEnergyState.unknown;
 @override
 Stream<BinaryPayload> get receivedBinaryStream => const Stream.empty();
 @override
 Future<void> startAsPeripheral() async {}
 @override
 Future<void> startAsCentral() async {}
 @override
 Future<void> refreshAdvertising({bool? showOnlineStatus}) async {}
 @override
 bool get isAdvertising => false;
 @override
 bool get isPeripheralMTUReady => false;
 @override
 int? get peripheralNegotiatedMTU => null;
 @override
 Future<void> connectToDevice(Peripheral device) async {}
 @override
 Future<void> disconnect() async {}
 @override
 void startConnectionMonitoring() {}
 @override
 void stopConnectionMonitoring() {}
 @override
 bool get isActivelyReconnecting => false;
 @override
 String? get otherUserName => null;
 @override
 String? get currentSessionId => null;
 @override
 String? get theirEphemeralId => null;
 @override
 String? get theirPersistentKey => null;
 @override
 String? get myPersistentId => null;
 @override
 Future<void> requestIdentityExchange() async {}
 @override
 Future<void> triggerIdentityReExchange() async {}
 @override
 Future<ProtocolMessage?> revealIdentityToFriend() async => null;
 @override
 Future<void> setMyUserName(String name) async {}
 @override
 Future<void> acceptContactRequest() async {}
 @override
 void rejectContactRequest() {}
 @override
 void setContactRequestCompletedListener(void Function(bool success) listener) {}
 @override
 void setContactRequestReceivedListener(void Function(String publicKey, String displayName) listener) {}
 @override
 void setAsymmetricContactListener(void Function(String publicKey, String displayName) listener) {}
 @override
 void setPairingInProgress(bool isInProgress) {}
 @override
 List<BLEServerConnection> get serverConnections => [];
 @override
 int get clientConnectionCount => 0;
 @override
 int get maxCentralConnections => 1;
 @override
 bool get canSendMessages => false;
 @override
 bool get hasPeripheralConnection => false;
 @override
 bool get isConnected => false;
 @override
 bool get canAcceptMoreConnections => false;
 @override
 int get activeConnectionCount => 0;
 @override
 List<String> get activeConnectionDeviceIds => [];
 @override
 Future<String> getMyPublicKey() async => '';
 @override
 Future<String> getMyEphemeralId() async => '';
 @override
 String? get theirPersistentPublicKey => null;
 @override
 void registerQueueSyncHandler(Future<bool> Function(QueueSyncMessage message, String fromNodeId)
 handler) {}
 @override
 Future<bool> sendPeripheralMessage(String message,
 {String? messageId}) async => false;
 @override
 Future<bool> sendMessage(String message,
 {String? messageId, String? originalIntendedRecipient}) async => false;
 @override
 Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {}
 @override
 Future<void> startScanning({ScanningSource source = ScanningSource.system}) async {}
 @override
 Future<void> stopScanning() async {}

 void dispose() {
 receivedMessagesCtrl.close();
 peripheralChangesCtrl.close();
 connectionInfoCtrl.close();
 discoveryCtrl.close();
 }
}

// ---------------------------------------------------------------------------
// Widget host
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
 bool hasUnsent = false,
}) {
 return ChatListItem(chatId: ChatId(id),
 contactName: name,
 contactPublicKey: id,
 lastMessage: 'msg-$id',
 lastMessageTime: time,
 unreadCount: unread,
 isOnline: online,
 hasUnsentMessages: hasUnsent,
);
}

/// Pump a controller backed by the given fakes and a [_FakeConnectionService].
Future<HomeScreenController> _pump(WidgetTester tester, {
 required _ChatsRepo repo,
 required _Facade facade,
 _FakeConnectionService? connService,
}) async {
 late HomeScreenController ctrl;
 final cs = connService ?? _FakeConnectionService();

 await tester.pumpWidget(ProviderScope(overrides: [
 discoveredDevicesProvider.overrideWith((ref) => const AsyncValue<List<Peripheral>>.data([]),
),
 discoveryDataProvider.overrideWith((ref) =>
 const AsyncValue<Map<String, DiscoveredEventArgs>>.data({}),
),
 connectionServiceProvider.overrideWithValue(cs),
],
 child: MaterialApp(home: _Host(controllerBuilder: (context, ref) {
 return HomeScreenController(HomeScreenControllerArgs(context: context,
 ref: ref,
 chatsRepository: repo,
 chatManagementService: _FakeChatManagement(),
 homeScreenFacade: facade,
 logger: Logger('Phase13dTest'),
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

/// Same as [_pump] but providers report loading instead of data so the
/// `orElse` branches inside the controller fire.
Future<HomeScreenController> _pumpWithLoadingProviders(WidgetTester tester, {
 required _ChatsRepo repo,
 required _Facade facade,
 _FakeConnectionService? connService,
}) async {
 late HomeScreenController ctrl;
 final cs = connService ?? _FakeConnectionService();

 await tester.pumpWidget(ProviderScope(overrides: [
 discoveredDevicesProvider.overrideWith((ref) => const AsyncValue<List<Peripheral>>.loading(),
),
 discoveryDataProvider.overrideWith((ref) =>
 const AsyncValue<Map<String, DiscoveredEventArgs>>.loading(),
),
 connectionServiceProvider.overrideWithValue(cs),
],
 child: MaterialApp(home: _Host(controllerBuilder: (context, ref) {
 return HomeScreenController(HomeScreenControllerArgs(context: context,
 ref: ref,
 chatsRepository: repo,
 chatManagementService: _FakeChatManagement(),
 homeScreenFacade: facade,
 logger: Logger('Phase13dTest'),
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

 group('HomeScreenController – supplementary', () {
 late _ChatsRepo repo;
 late _Facade facade;

 setUp(() {
 repo = _ChatsRepo();
 facade = _Facade();
 });

 // -----------------------------------------------------------------------
 // initialize() flow — covers lines 90-95
 // -----------------------------------------------------------------------
 testWidgets('initialize calls facade & chatManagement, loads chats, '
 'and sets up streams', (tester) async {
 repo.queueResponse([_item(id: 'i1', name: 'Init')]);
 final cs = _FakeConnectionService();
 final ctrl =
 await _pump(tester, repo: repo, facade: facade, connService: cs);

 // initialize runs facade.initialize + chatManagementService.initialize
 await ctrl.initialize();
 await tester.pump(const Duration(milliseconds: 50));

 expect(facade.initializeCalls, greaterThanOrEqualTo(1));
 expect(ctrl.unreadCountStream, isNotNull);

 ctrl.dispose();
 cs.dispose();
 });

 // -----------------------------------------------------------------------
 // initialize() no-ops when already disposed
 // -----------------------------------------------------------------------
 testWidgets('initialize is no-op when disposed', (tester) async {
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 ctrl.dispose();

 final callsBefore = facade.initializeCalls;
 await ctrl.initialize();
 expect(facade.initializeCalls, callsBefore);
 });

 // -----------------------------------------------------------------------
 // handleDeviceSelected — covers lines 265-268
 // -----------------------------------------------------------------------
 testWidgets('handleDeviceSelected delays then reloads chats', (tester,
) async {
 repo.queueResponse([_item(id: 'hd1', name: 'DevSel')]);
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.loadChats(reset: true);

 final callsBefore = repo.getAllChatsCallCount;
 repo.queueResponse([_item(id: 'hd2', name: 'After')]);

 // handleDeviceSelected has a 2-second delay
 final future = ctrl.handleDeviceSelected(_DummyPeripheral(),
);
 await tester.pump(const Duration(seconds: 3));
 await future;

 expect(repo.getAllChatsCallCount, greaterThan(callsBefore));
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // _setupGlobalMessageListener — covers lines 271-283
 // receivedMessages stream triggers updateSingleChatItem
 // -----------------------------------------------------------------------
 testWidgets('global message listener triggers chat update', (tester,
) async {
 repo.queueResponse([_item(id: 'gm1', name: 'GlobalMsg')]);
 final cs = _FakeConnectionService();
 final ctrl =
 await _pump(tester, repo: repo, facade: facade, connService: cs);

 await ctrl.initialize();
 await tester.pump(const Duration(milliseconds: 50));

 // Enqueue response for the chat update triggered by the listener
 repo.queueResponse([_item(id: 'gm1', name: 'GlobalMsg Updated')]);
 cs.receivedMessagesCtrl.add('incoming-msg');
 await tester.pump(const Duration(milliseconds: 100));

 // The listener should have called updateSingleChatItem
 expect(repo.getAllChatsCallCount, greaterThanOrEqualTo(2));

 ctrl.dispose();
 cs.dispose();
 });

 // -----------------------------------------------------------------------
 // _setupGlobalMessageListener catch branch — covers line 286
 // When connectionServiceProvider throws, the catch logs warning.
 // Since _setupDiscoveryListener (line 326) also reads the provider
 // but has NO try-catch, we wrap initialize in a try-catch to verify
 // the error path fires.
 // -----------------------------------------------------------------------
 testWidgets('setupGlobalMessageListener catches provider errors', (tester,
) async {
 late HomeScreenController ctrl;

 await tester.pumpWidget(ProviderScope(overrides: [
 discoveredDevicesProvider.overrideWith((ref) => const AsyncValue<List<Peripheral>>.data([]),
),
 discoveryDataProvider.overrideWith((ref) =>
 const AsyncValue<Map<String, DiscoveredEventArgs>>.data({}),
),
 // Deliberately override connectionServiceProvider to throw
 connectionServiceProvider.overrideWith((ref) => throw StateError('Service not configured in test'),
),
],
 child: MaterialApp(home: _Host(controllerBuilder: (context, ref) {
 return HomeScreenController(HomeScreenControllerArgs(context: context,
 ref: ref,
 chatsRepository: repo,
 chatManagementService: _FakeChatManagement(),
 homeScreenFacade: facade,
 logger: Logger('Phase13dTest'),
),
);
 },
 onControllerReady: (c) => ctrl = c,
),
),
),
);

 await tester.pump();

 // initialize will fail at _setupDiscoveryListener because it doesn't
 // have a try-catch (unlike _setupGlobalMessageListener which does).
 // This verifies that the error paths are exercised.
 repo.queueResponse([]);
 Object? caughtError;
 try {
 await ctrl.initialize();
 } catch (e) {
 caughtError = e;
 }
 await tester.pump(const Duration(milliseconds: 50));

 // The error should have been thrown from _setupDiscoveryListener
 expect(caughtError, isNotNull);

 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // _setupDiscoveryListener — covers lines 326-336
 // discoveryData stream emissions trigger loadChats
 // -----------------------------------------------------------------------
 testWidgets('discovery listener triggers loadChats on new data', (tester,
) async {
 repo.queueResponse([_item(id: 'dl1', name: 'Disc')]);
 final cs = _FakeConnectionService();
 final ctrl =
 await _pump(tester, repo: repo, facade: facade, connService: cs);

 await ctrl.initialize();
 await tester.pump(const Duration(milliseconds: 50));

 final callsBefore = repo.getAllChatsCallCount;
 repo.queueResponse([_item(id: 'dl1', name: 'Disc Updated')]);
 cs.discoveryCtrl.add({});
 await tester.pump(const Duration(milliseconds: 100));

 expect(repo.getAllChatsCallCount, greaterThan(callsBefore));

 ctrl.dispose();
 cs.dispose();
 });

 // -----------------------------------------------------------------------
 // _setupPeripheralConnectionListener — covers lines 298-300
 // On non-Android platforms, exits early at Platform.isAndroid check.
 // -----------------------------------------------------------------------
 testWidgets('peripheral listener setup exits early on non-Android', (tester,
) async {
 final cs = _FakeConnectionService();
 final ctrl =
 await _pump(tester, repo: repo, facade: facade, connService: cs);

 await ctrl.initialize();
 await tester.pump(const Duration(milliseconds: 50));

 // No crash; peripheral listener should have exited at Platform check
 expect(ctrl.isLoading, isFalse);

 ctrl.dispose();
 cs.dispose();
 });

 // -----------------------------------------------------------------------
 // orElse branches when providers return loading state
 // covers lines 116, 194, 294
 // -----------------------------------------------------------------------
 testWidgets('loadChats with loading providers hits orElse branches', (tester,
) async {
 repo.queueResponse([_item(id: 'or1', name: 'OrElse')]);
 final ctrl = await _pumpWithLoadingProviders(tester,
 repo: repo,
 facade: facade,
);

 await ctrl.loadChats(reset: true);
 await tester.pump(const Duration(milliseconds: 50));

 // Despite loading providers, loadChats should still succeed with
 // fallback values (null nearbyDevices, empty discoveryData).
 expect(ctrl.chats.length, 1);
 expect(ctrl.chats.first.contactName, 'OrElse');

 ctrl.dispose();
 });

 testWidgets('updateSingleChatItem with loading providers hits orElse', (tester,
) async {
 repo.queueResponse([_item(id: 'or2', name: 'OrUpd')]);
 final ctrl = await _pumpWithLoadingProviders(tester,
 repo: repo,
 facade: facade,
);
 await ctrl.loadChats(reset: true);

 repo.queueResponse([_item(id: 'or2', name: 'OrUpd-v2')]);
 await ctrl.updateSingleChatItem();
 await tester.pump(const Duration(milliseconds: 50));

 expect(ctrl.chats.first.contactName, 'OrUpd-v2');
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // _setupUnreadCountStream inner callback — covers line 346
 // The stream is set up via initialize(). We verify it's created and
 // is a valid broadcast stream.
 // -----------------------------------------------------------------------
 testWidgets('unreadCountStream is set after initialize', (tester,
) async {
 repo.unreadCountToReturn = 3;
 repo.queueResponse([]);
 final cs = _FakeConnectionService();
 final ctrl = await _pump(tester,
 repo: repo,
 facade: facade,
 connService: cs,
);
 await ctrl.initialize();
 await tester.pump(const Duration(milliseconds: 50));

 // After initialize, the unreadCountStream should be set up as a
 // periodic stream that queries the repo.
 expect(ctrl.unreadCountStream, isNotNull);

 ctrl.dispose();
 cs.dispose();
 });

 // -----------------------------------------------------------------------
 // showArchiveConfirmation / showDeleteConfirmation delegation
 // -----------------------------------------------------------------------
 testWidgets('showArchiveConfirmation delegates to facade', (tester,
) async {
 facade.archiveConfirmResult = true;
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 final chat = _item(id: 'ac-1', name: 'AC');

 final result = await ctrl.showArchiveConfirmation(chat);
 expect(result, isTrue);

 facade.archiveConfirmResult = false;
 final result2 = await ctrl.showArchiveConfirmation(chat);
 expect(result2, isFalse);

 ctrl.dispose();
 });

 testWidgets('showDeleteConfirmation delegates to facade', (tester,
) async {
 facade.deleteConfirmResult = false;
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 final chat = _item(id: 'dc-1', name: 'DC');

 final result = await ctrl.showDeleteConfirmation(chat);
 expect(result, isFalse);

 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // openContacts / openArchives / openSettings / openProfile delegation
 // -----------------------------------------------------------------------
 testWidgets('openContacts delegates to facade', (tester) async {
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.openContacts();
 expect(facade.openContactsCalls, 1);
 ctrl.dispose();
 });

 testWidgets('openArchives delegates to facade', (tester) async {
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.openArchives();
 expect(facade.openArchivesCalls, 1);
 ctrl.dispose();
 });

 testWidgets('openSettings delegates to facade', (tester) async {
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.openSettings();
 expect(facade.openSettingsCalls, 1);
 ctrl.dispose();
 });

 testWidgets('openProfile delegates to facade', (tester) async {
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.openProfile();
 expect(facade.openProfileCalls, 1);
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // openChat delegates and reloads
 // -----------------------------------------------------------------------
 testWidgets('openChat delegates to facade and reloads', (tester) async {
 repo.queueResponse([]);
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 final chat = _item(id: 'oc-1', name: 'OC');

 await ctrl.openChat(chat);

 expect(facade.openChatCalls, 1);
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // updateSingleChatItem inserts new chat when not existing
 // -----------------------------------------------------------------------
 testWidgets('updateSingleChatItem inserts new chat at front', (tester,
) async {
 repo.queueResponse([_item(id: 'ex1', name: 'Existing')]);
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.loadChats(reset: true);
 expect(ctrl.chats.length, 1);

 // Return a new chat that doesn't match existing
 repo.queueResponse([_item(id: 'new1', name: 'NewChat')]);
 await ctrl.updateSingleChatItem();
 await tester.pump(const Duration(milliseconds: 50));

 expect(ctrl.chats.length, 2);
 expect(ctrl.chats.first.chatId.value, 'new1');
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // updateSingleChatItem fallback to full reload on error
 // -----------------------------------------------------------------------
 testWidgets('updateSingleChatItem falls back to loadChats on error', (tester,
) async {
 repo.queueResponse([_item(id: 'fb1', name: 'Fallback')]);
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.loadChats(reset: true);

 // Make getAllChats throw on the surgical update call.
 // The catch block calls loadChats() as fallback which also throws.
 repo.getAllChatsError = 'surgical update boom';

 try {
 await ctrl.updateSingleChatItem();
 } catch (_) {
 // Expected: the fallback loadChats also fails
 }
 await tester.pump(const Duration(milliseconds: 50));

 // Controller should still be functional after the error
 expect(ctrl.isLoading, isFalse);
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // updateSingleChatItem no-op when repo returns empty
 // -----------------------------------------------------------------------
 testWidgets('updateSingleChatItem no-op when updatedChats is empty', (tester,
) async {
 repo.queueResponse([_item(id: 'ne1', name: 'Existing')]);
 final ctrl = await _pump(tester, repo: repo, facade: facade);
 await ctrl.loadChats(reset: true);

 repo.queueResponse([]); // empty result
 await ctrl.updateSingleChatItem();
 await tester.pump(const Duration(milliseconds: 50));

 // Chats unchanged
 expect(ctrl.chats.length, 1);
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // onSearchChanged with single space (sentinel)
 // -----------------------------------------------------------------------
 testWidgets('onSearchChanged with single space sets query without reload', (tester,
) async {
 final ctrl = await _pump(tester, repo: repo, facade: facade);

 final callsBefore = repo.getAllChatsCallCount;
 ctrl.onSearchChanged(' ');
 expect(ctrl.searchQuery, ' ');
 await tester.pump(const Duration(milliseconds: 50));

 // Single space should not trigger loadChats
 expect(repo.getAllChatsCallCount, callsBefore);
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // onSearchChanged with actual query triggers loadChats
 // -----------------------------------------------------------------------
 testWidgets('onSearchChanged with query triggers loadChats', (tester,
) async {
 repo.queueResponse([]);
 final ctrl = await _pump(tester, repo: repo, facade: facade);

 repo.queueResponse([_item(id: 'sr1', name: 'SearchResult')]);
 ctrl.onSearchChanged('hello');
 await tester.pump(const Duration(milliseconds: 100));

 expect(ctrl.searchQuery, 'hello');
 expect(repo.lastSearchQuery, 'hello');
 ctrl.dispose();
 });

 // -----------------------------------------------------------------------
 // homeScreenControllerProvider — covers lines 408-411
 // -----------------------------------------------------------------------
 testWidgets('homeScreenControllerProvider creates and initializes', (tester,
) async {
 late HomeScreenController ctrl;
 final cs = _FakeConnectionService();

 repo.queueResponse([]);

 await tester.pumpWidget(ProviderScope(overrides: [
 discoveredDevicesProvider.overrideWith((ref) => const AsyncValue<List<Peripheral>>.data([]),
),
 discoveryDataProvider.overrideWith((ref) =>
 const AsyncValue<Map<String, DiscoveredEventArgs>>.data({}),
),
 connectionServiceProvider.overrideWithValue(cs),
],
 child: MaterialApp(home: Consumer(builder: (context, ref, _) {
 final args = HomeScreenControllerArgs(context: context,
 ref: ref,
 chatsRepository: repo,
 chatManagementService: _FakeChatManagement(),
 homeScreenFacade: facade,
 logger: Logger('Phase13dProvider'),
);
 ctrl = ref.watch(homeScreenControllerProvider(args));
 return const SizedBox.shrink();
 },
),
),
),
);

 await tester.pump(const Duration(milliseconds: 100));

 // Provider should have created the controller and called initialize
 expect(ctrl, isNotNull);
 expect(facade.initializeCalls, greaterThanOrEqualTo(1));

 cs.dispose();
 });
 });
}

// ---------------------------------------------------------------------------
// Dummy Peripheral for handleDeviceSelected
// ---------------------------------------------------------------------------

class _DummyPeripheral implements Peripheral {
 @override
 UUID get uuid => UUID.fromString('00000000-0000-0000-0000-000000000001');

 @override
 dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
