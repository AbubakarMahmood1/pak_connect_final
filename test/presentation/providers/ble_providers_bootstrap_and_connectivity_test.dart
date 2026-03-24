import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
 show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/presentation/providers/runtime_providers.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _ReadyBootstrapNotifier extends AppBootstrapNotifier {
 @override
 Future<AppBootstrapState> build() async {
 return const AppBootstrapState(status: AppBootstrapStatus.ready);
 }
}

class _InitializingBootstrapNotifier extends AppBootstrapNotifier {
 @override
 Future<AppBootstrapState> build() async {
 return const AppBootstrapState(status: AppBootstrapStatus.initializing);
 }
}

class _TestUsernameNotifier extends UsernameNotifier {
 _TestUsernameNotifier(this.value);

 final String value;

 @override
 Future<String> build() async => value;
}

class _ErrorUsernameNotifier extends UsernameNotifier {
 @override
 Future<String> build() async => throw StateError('username boom');
}

class _InitializableConnectionService extends MockConnectionService {
 bool isInitialized = false;
 int initializeCalls = 0;

 Future<void> initialize() async {
 initializeCalls++;
 isInitialized = true;
 }
}

class _FakeCentral implements Central {
 _FakeCentral(String uuid) : _uuid = UUID.fromString(uuid);

 final UUID _uuid;

 @override
 UUID get uuid => _uuid;
}

class _ConnectionManagerWithStream {
 _ConnectionManagerWithStream(this.stream);

 final Stream<List<BLEServerConnection>> stream;

 Stream<List<BLEServerConnection>> get serverConnectionsStream => stream;
}

class _ConnectionServiceWithManager extends MockConnectionService {
 _ConnectionServiceWithManager(this.connectionManager);

 final _ConnectionManagerWithStream connectionManager;
}

class _FakeMeshService implements IMeshNetworkingService {
 @override
 Stream<ReceivedBinaryEvent> get binaryPayloadStream => const Stream.empty();

 @override
 Future<void> initialize({String? nodeId}) async {}

 @override
 Stream<String> get messageDeliveryStream => const Stream.empty();

 @override
 Stream<MeshNetworkStatus> get meshStatus => const Stream.empty();

 @override
 Stream<QueueSyncManagerStats> get queueStats => const Stream.empty();

 @override
 Stream<RelayStatistics> get relayStats => const Stream.empty();

 @override
 Future<MeshSendResult> sendMeshMessage({
 required String content,
 required String recipientPublicKey,
 MessagePriority priority = MessagePriority.normal,
 }) async {
 return MeshSendResult.direct('msg-1');
 }

 @override
 Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async =>
 <String, QueueSyncResult>{};

 @override
 Future<bool> removeMessage(String messageId) async => true;

 @override
 Future<int> retryAllMessages() async => 0;

 @override
 Future<bool> retryMessage(String messageId) async => true;

 @override
 Future<bool> setPriority(String messageId, MessagePriority priority) async =>
 true;

 @override
 Future<String> sendBinaryMedia({
 required Uint8List data,
 required String recipientId,
 int originalType = 0x90,
 Map<String, dynamic>? metadata,
 }) async {
 return 'transfer-1';
 }

 @override
 Future<bool> retryBinaryMedia({
 required String transferId,
 String? recipientId,
 int? originalType,
 }) async {
 return true;
 }

 @override
 List<PendingBinaryTransfer> getPendingBinaryTransfers() =>
 const <PendingBinaryTransfer>[];

 @override
 List<QueuedMessage> getQueuedMessagesForChat(String chatId) =>
 const <QueuedMessage>[];

 @override
 MeshNetworkStatistics getNetworkStatistics() => const MeshNetworkStatistics(nodeId: 'node-a',
 isInitialized: true,
 relayStatistics: RelayStatistics(totalRelayed: 5,
 totalDropped: 0,
 totalDeliveredToSelf: 2,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.1,
 relayEfficiency: 0.9,
 activeRelayMessages: 1,
 networkSize: 3,
 currentRelayProbability: 0.9,
),
 queueStatistics: null,
 syncStatistics: null,
 spamStatistics: null,
 spamPreventionActive: true,
 queueSyncActive: true,
);

 @override
 void refreshMeshStatus() {}

 @override
 void dispose() {}
}

MeshNetworkStatus _meshStatus() {
 return const MeshNetworkStatus(isInitialized: true,
 currentNodeId: 'node-a',
 isConnected: true,
 statistics: MeshNetworkStatistics(nodeId: 'node-a',
 isInitialized: true,
 relayStatistics: null,
 queueStatistics: null,
 syncStatistics: null,
 spamStatistics: null,
 spamPreventionActive: true,
 queueSyncActive: true,
),
 queueMessages: <QueuedMessage>[],
);
}

void main() {
 group('ble_providers ', () {
 test('bleServiceInitializedProvider enforces ready bootstrap', () async {
 final service = _InitializableConnectionService();
 final container = ProviderContainer(overrides: [
 bleServiceProvider.overrideWithValue(service),
 appBootstrapProvider.overrideWith(() => _InitializingBootstrapNotifier(),
),
],
);
 addTearDown(container.dispose);

 await expectLater(container.read(bleServiceInitializedProvider.future),
 throwsA(isA<StateError>()),
);
 });

 test('bleServiceInitializedProvider initializes uninitialized services',
 () async {
 final service = _InitializableConnectionService();
 final container = ProviderContainer(overrides: [
 bleServiceProvider.overrideWithValue(service),
 appBootstrapProvider.overrideWith(() => _ReadyBootstrapNotifier()),
],
);
 addTearDown(container.dispose);

 final resolved = await container.read(bleServiceInitializedProvider.future,
);
 expect(resolved, same(service));
 expect(service.initializeCalls, 1);
 expect(service.isInitialized, isTrue);
 },
);

 test('usernameProvider exposes data and error states', () async {
 final dataContainer = ProviderContainer(overrides: [
 usernameProvider.overrideWith(() => _TestUsernameNotifier('Alice')),
],
);
 addTearDown(dataContainer.dispose);

 final valueCompleter = Completer<String>();
 final valueSub = dataContainer.listen<AsyncValue<String>>(usernameProvider,
 (previous, next) {
 next.whenData((value) {
 if (!valueCompleter.isCompleted) {
 valueCompleter.complete(value);
 }
 });
 },
 fireImmediately: true,
);
 addTearDown(valueSub.close);

 expect(await valueCompleter.future, 'Alice');

 final errorContainer = ProviderContainer(overrides: [
 usernameProvider.overrideWith(() => _ErrorUsernameNotifier()),
],
);
 addTearDown(errorContainer.dispose);

 final errorCompleter = Completer<Object>();
 final errorSub = errorContainer.listen<AsyncValue<String>>(usernameProvider,
 (previous, next) {
 next.when(data: (_) {},
 loading: () {},
 error: (error, _) {
 if (!errorCompleter.isCompleted) {
 errorCompleter.complete(error);
 }
 },
);
 },
 fireImmediately: true,
);
 addTearDown(errorSub.close);

 expect(await errorCompleter.future, isA<StateError>());
 });

 test('serverConnectionsStreamProvider forwards manager stream values',
 () async {
 final central = _FakeCentral('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
 final connections = <BLEServerConnection>[
 BLEServerConnection(address: 'AA:BB:CC:DD',
 central: central,
 connectedAt: DateTime(2026, 3, 5),
),
];
 final serviceWithManager = _ConnectionServiceWithManager(_ConnectionManagerWithStream(Stream.value(connections)),
);

 final container = ProviderContainer(overrides: [
 connectionServiceProvider.overrideWithValue(serviceWithManager),
],
);
 addTearDown(container.dispose);

 final completer = Completer<List<BLEServerConnection>>();
 final sub = container.listen<AsyncValue<List<BLEServerConnection>>>(serverConnectionsStreamProvider,
 (previous, next) {
 next.whenData((value) {
 if (!completer.isCompleted) {
 completer.complete(value);
 }
 });
 },
 fireImmediately: true,
);
 addTearDown(sub.close);

 expect(await completer.future, connections);
 },
);

 test('connectivity and network health providers compute aggregates', () {
 final meshService = _FakeMeshService();
 final container = ProviderContainer(overrides: [
 connectionInfoProvider.overrideWith((ref) => const AsyncValue.data(ConnectionInfo(isConnected: true, isReady: true),
),
),
 meshNetworkStatusProvider.overrideWith((ref) => AsyncValue.data(_meshStatus()),
),
 bleStateProvider.overrideWith((ref) => const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
),
 meshNetworkingServiceProvider.overrideWithValue(meshService),
],
);
 addTearDown(container.dispose);

 final connectivity = container.read(connectivityStatusProvider);
 expect(connectivity.connectionHealth, 1.0);
 expect(connectivity.statusDescription, 'Excellent');
 expect(connectivity.activeCapabilities, [
 'Bluetooth',
 'Direct Messaging',
 'Mesh Relay',
]);

 final health = container.read(networkHealthProvider);
 expect(health.overallHealth, greaterThan(0.9));
 expect(health.isHealthy, isTrue);
 expect(health.statusMessage, 'Network Excellent');
 });
 });
}
