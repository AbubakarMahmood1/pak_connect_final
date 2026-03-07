/// Phase 13c — MeshNetworkingProvider coverage for uncovered lines.
///
/// Covers the 82 uncovered lines across:
///   - MeshRuntimeNotifier.build() (lines 76-127) — stream listeners, state updates
///   - meshRuntimeProvider definition (lines 130-132)
///   - Bluetooth bridge providers (lines 139-168)
///   - meshNetworkingServiceProvider DI resolution (lines 173-189)
///   - Binary payload providers (lines 193-215)
///   - Stream bridge providers (lines 222-234)
///   - Topology providers (lines 237-246)
///   - meshRoutingServiceProvider (lines 251-255)

import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/bluetooth_state_models.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/models/network_topology.dart';
import 'package:pak_connect/domain/routing/topology_manager.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/presentation/providers/runtime_providers.dart';

// =============================================================================
// FAKE SERVICES
// =============================================================================

class _FakeMeshService implements IMeshNetworkingService {
  final statusCtrl = StreamController<MeshNetworkStatus>.broadcast();
  final relayCtrl = StreamController<RelayStatistics>.broadcast();
  final queueCtrl = StreamController<QueueSyncManagerStats>.broadcast();
  final deliveryCtrl = StreamController<String>.broadcast();
  final binaryCtrl = StreamController<ReceivedBinaryEvent>.broadcast();

  MeshNetworkStatistics stats = const MeshNetworkStatistics(
    nodeId: 'node-test',
    isInitialized: true,
    spamPreventionActive: false,
    queueSyncActive: false,
  );

  MeshSendResult nextSendResult = MeshSendResult.direct('msg-1');
  bool throwOnSend = false;
  bool throwOnSync = false;
  Map<String, QueueSyncResult> syncResult = {};
  List<PendingBinaryTransfer> pendingTransfers = [];
  int refreshCalls = 0;

  @override
  Stream<MeshNetworkStatus> get meshStatus => statusCtrl.stream;
  @override
  Stream<RelayStatistics> get relayStats => relayCtrl.stream;
  @override
  Stream<QueueSyncManagerStats> get queueStats => queueCtrl.stream;
  @override
  Stream<String> get messageDeliveryStream => deliveryCtrl.stream;
  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream => binaryCtrl.stream;

  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (throwOnSend) throw Exception('send failed');
    return nextSendResult;
  }

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
    if (throwOnSync) throw Exception('sync failed');
    return syncResult;
  }

  @override
  MeshNetworkStatistics getNetworkStatistics() => stats;

  @override
  void refreshMeshStatus() => refreshCalls++;

  @override
  Future<void> initialize({String? nodeId}) async {}

  @override
  void dispose() {}

  @override
  Future<bool> retryMessage(String messageId) async => true;

  @override
  Future<bool> removeMessage(String messageId) async => true;

  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async =>
      true;

  @override
  Future<int> retryAllMessages() async => 0;

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) => [];

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => pendingTransfers;

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
  }) async =>
      'tx-new';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async =>
      true;

  void closeAll() {
    statusCtrl.close();
    relayCtrl.close();
    queueCtrl.close();
    deliveryCtrl.close();
    binaryCtrl.close();
  }
}

/// Minimal fake IConnectionService for Bluetooth bridge providers.
class _FakeConnectionService implements IConnectionService {
  final btStateCtrl = StreamController<BluetoothStateInfo>.broadcast();
  final btMsgCtrl = StreamController<BluetoothStatusMessage>.broadcast();
  bool isReady = true;

  @override
  Stream<BluetoothStateInfo> get bluetoothStateStream => btStateCtrl.stream;
  @override
  Stream<BluetoothStatusMessage> get bluetoothMessageStream => btMsgCtrl.stream;
  @override
  bool get isBluetoothReady => isReady;

  void close() {
    btStateCtrl.close();
    btMsgCtrl.close();
  }

  // Unused interface methods — stub implementations.
  @override
  dynamic noSuchMethod(Invocation inv) => null;
}

// =============================================================================
// HELPERS
// =============================================================================

MeshNetworkStatus _status({
  bool isInitialized = true,
  bool isConnected = false,
  String? currentNodeId,
  MeshNetworkStatistics? statistics,
}) =>
    MeshNetworkStatus(
      isInitialized: isInitialized,
      isConnected: isConnected,
      currentNodeId: currentNodeId,
      statistics: statistics ??
          const MeshNetworkStatistics(
            nodeId: 'test',
            isInitialized: true,
            spamPreventionActive: false,
            queueSyncActive: false,
          ),
    );

const _defaultRelayStats = RelayStatistics(
  totalRelayed: 10,
  totalDropped: 1,
  totalDeliveredToSelf: 2,
  totalBlocked: 0,
  totalProbabilisticSkip: 0,
  spamScore: 0.0,
  relayEfficiency: 0.8,
  activeRelayMessages: 3,
  networkSize: 5,
  currentRelayProbability: 0.7,
);

const _defaultQueueSyncStats = QueueSyncManagerStats(
  totalSyncRequests: 5,
  successfulSyncs: 4,
  failedSyncs: 1,
  messagesTransferred: 20,
  activeSyncs: 0,
  successRate: 0.8,
  recentSyncCount: 3,
);

// =============================================================================
// TESTS
// =============================================================================

void main() {
  Logger.root.level = Level.OFF;

  // ---------------------------------------------------------------------------
  // MeshRuntimeNotifier + meshRuntimeProvider (lines 76-132)
  // ---------------------------------------------------------------------------

  group('MeshRuntimeNotifier', () {
    late _FakeMeshService fakeService;

    setUp(() {
      fakeService = _FakeMeshService();
    });

    tearDown(() {
      fakeService.closeAll();
    });

    ProviderContainer _buildContainer() {
      final container = ProviderContainer(
        overrides: [
          meshNetworkingServiceProvider.overrideWithValue(fakeService),
          appBootstrapProvider.overrideWith(
            () => _ReadyBootstrapNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('build() returns initial state and calls refreshMeshStatus', () async {
      final container = _buildContainer();

      // Reading the provider triggers build().
      final future = container.read(meshRuntimeProvider.future);
      final state = await future;

      expect(state.status.isInitialized, isFalse);
      expect(state.relayStatistics, isNull);
      expect(state.queueStatistics, isNull);
      expect(fakeService.refreshCalls, 1);
    });

    test('meshStatusStream listener updates state', () async {
      final container = _buildContainer();

      // Wait for initial build to complete.
      await container.read(meshRuntimeProvider.future);

      // Emit a new status through the stream.
      final newStatus = _status(isInitialized: true, isConnected: true);
      fakeService.statusCtrl.add(newStatus);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final current = container.read(meshRuntimeProvider).asData?.value;
      expect(current, isNotNull);
      expect(current!.status.isConnected, isTrue);
      expect(current.status.isInitialized, isTrue);
    });

    test('relayStatsStream listener updates relayStatistics', () async {
      final container = _buildContainer();
      await container.read(meshRuntimeProvider.future);

      fakeService.relayCtrl.add(_defaultRelayStats);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final current = container.read(meshRuntimeProvider).asData?.value;
      expect(current, isNotNull);
      expect(current!.relayStatistics, isNotNull);
      expect(current.relayStatistics!.totalRelayed, 10);
    });

    test('queueStatsStream listener updates queueStatistics', () async {
      final container = _buildContainer();
      await container.read(meshRuntimeProvider.future);

      fakeService.queueCtrl.add(_defaultQueueSyncStats);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final current = container.read(meshRuntimeProvider).asData?.value;
      expect(current, isNotNull);
      expect(current!.queueStatistics, isNotNull);
      expect(current.queueStatistics!.successfulSyncs, 4);
    });

    test('all three listeners update concurrently', () async {
      final container = _buildContainer();
      await container.read(meshRuntimeProvider.future);

      // Emit all three at once.
      fakeService.statusCtrl.add(
        _status(isInitialized: true, isConnected: true, currentNodeId: 'abc'),
      );
      fakeService.relayCtrl.add(_defaultRelayStats);
      fakeService.queueCtrl.add(_defaultQueueSyncStats);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final current = container.read(meshRuntimeProvider).asData?.value;
      expect(current, isNotNull);
      expect(current!.status.isConnected, isTrue);
      expect(current.status.currentNodeId, 'abc');
      expect(current.relayStatistics, isNotNull);
      expect(current.queueStatistics, isNotNull);
    });

    test('meshRuntimeProvider is an AsyncNotifierProvider', () {
      // Exercises lines 130-132 (provider definition).
      expect(meshRuntimeProvider, isA<AsyncNotifierProvider>());
    });
  });

  // ---------------------------------------------------------------------------
  // Bluetooth bridge providers (lines 139-168)
  // ---------------------------------------------------------------------------

  group('Bluetooth bridge providers', () {
    late _FakeConnectionService fakeConnection;

    setUp(() {
      fakeConnection = _FakeConnectionService();
    });

    tearDown(() {
      fakeConnection.close();
    });

    ProviderContainer _btContainer() {
      final c = ProviderContainer(
        overrides: [
          connectionServiceProvider.overrideWithValue(fakeConnection),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('bluetoothStateStreamProvider emits state info', () async {
      final container = _btContainer();

      // Subscribe to the stream.
      final sub = container.listen(bluetoothStateStreamProvider, (_, __) {});
      addTearDown(sub.close);

      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOn,
        isReady: true,
        timestamp: DateTime.now(),
      );
      fakeConnection.btStateCtrl.add(info);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = container.read(bluetoothStateStreamProvider);
      expect(result.asData?.value.isReady, isTrue);
    });

    test('bluetoothStatusMessageStreamProvider emits messages', () async {
      final container = _btContainer();

      final sub =
          container.listen(bluetoothStatusMessageStreamProvider, (_, __) {});
      addTearDown(sub.close);

      final msg = BluetoothStatusMessage.ready('Bluetooth ready');
      fakeConnection.btMsgCtrl.add(msg);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = container.read(bluetoothStatusMessageStreamProvider);
      expect(result.asData?.value.message, 'Bluetooth ready');
    });

    test('bluetoothStateProvider wraps stream provider value', () async {
      final container = _btContainer();

      final sub = container.listen(bluetoothStateProvider, (_, __) {});
      addTearDown(sub.close);

      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOn,
        isReady: true,
        timestamp: DateTime.now(),
      );
      fakeConnection.btStateCtrl.add(info);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = container.read(bluetoothStateProvider);
      expect(result.asData?.value.isReady, isTrue);
    });

    test('bluetoothStatusMessageProvider wraps stream provider value',
        () async {
      final container = _btContainer();

      final sub =
          container.listen(bluetoothStatusMessageProvider, (_, __) {});
      addTearDown(sub.close);

      fakeConnection.btMsgCtrl
          .add(BluetoothStatusMessage.disabled('BT off'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = container.read(bluetoothStatusMessageProvider);
      expect(result.asData?.value.type, BluetoothMessageType.disabled);
    });

    test('bluetoothReadyProvider returns true when stream reports ready',
        () async {
      final container = _btContainer();

      final sub =
          container.listen(bluetoothStateStreamProvider, (_, __) {});
      addTearDown(sub.close);

      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOn,
        isReady: true,
        timestamp: DateTime.now(),
      );
      fakeConnection.btStateCtrl.add(info);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final ready = container.read(bluetoothReadyProvider);
      expect(ready, isTrue);
    });

    test(
        'bluetoothReadyProvider falls back to service.isBluetoothReady '
        'when no stream data', () {
      fakeConnection.isReady = false;
      final container = _btContainer();

      final ready = container.read(bluetoothReadyProvider);
      expect(ready, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // meshNetworkingServiceProvider DI resolution (lines 173-189)
  // ---------------------------------------------------------------------------

  group('meshNetworkingServiceProvider', () {
    test('returns service when overridden directly', () {
      final fake = _FakeMeshService();
      final container = ProviderContainer(
        overrides: [
          meshNetworkingServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(meshNetworkingServiceProvider);
      expect(service, same(fake));
      fake.closeAll();
    });

    test('resolves from GetIt when registered', () async {
      final locator = GetIt.instance;
      await locator.reset();
      final fake = _FakeMeshService();
      locator.registerSingleton<IMeshNetworkingService>(fake);
      addTearDown(() async {
        await locator.reset();
        fake.closeAll();
      });

      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWith(() => _ReadyBootstrapNotifier()),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(meshNetworkingServiceProvider);
      expect(service, same(fake));
    });

    test('throws when not registered — loading bootstrap', () async {
      final locator = GetIt.instance;
      await locator.reset();
      addTearDown(() => locator.reset());

      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWith(
            () => _LoadingBootstrapNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Riverpod wraps provider errors in ProviderException.
      Object? caught;
      try {
        container.read(meshNetworkingServiceProvider);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), contains('runtime=initializing'));
    });

    test('throws when not registered — ready bootstrap', () async {
      final locator = GetIt.instance;
      await locator.reset();
      addTearDown(() => locator.reset());

      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWith(() => _ReadyBootstrapNotifier()),
        ],
      );
      addTearDown(container.dispose);

      Object? caught;
      try {
        container.read(meshNetworkingServiceProvider);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(
        caught.toString(),
        contains('IMeshNetworkingService is not registered'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Binary payload providers (lines 193-215)
  // ---------------------------------------------------------------------------

  group('Binary payload providers', () {
    late _FakeMeshService fakeService;

    setUp(() {
      fakeService = _FakeMeshService();
    });

    tearDown(() {
      fakeService.closeAll();
    });

    ProviderContainer _binContainer() {
      final c = ProviderContainer(
        overrides: [
          meshNetworkingServiceProvider.overrideWithValue(fakeService),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('binaryPayloadStreamProvider emits events', () async {
      final container = _binContainer();

      final sub =
          container.listen(binaryPayloadStreamProvider, (_, __) {});
      addTearDown(sub.close);

      final event = ReceivedBinaryEvent(
        fragmentId: 'frag-1',
        originalType: 0x90,
        filePath: '/tmp/test.bin',
        size: 1024,
        transferId: 'tx-1',
        ttl: 3,
      );
      fakeService.binaryCtrl.add(event);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = container.read(binaryPayloadStreamProvider);
      expect(result.asData?.value.transferId, 'tx-1');
    });

    test('binaryPayloadInboxProvider ingests stream events', () async {
      final container = _binContainer();

      // Read the notifier to wire up the subscription.
      container.read(binaryPayloadInboxProvider);

      final event = ReceivedBinaryEvent(
        fragmentId: 'frag-2',
        originalType: 0x90,
        filePath: '/tmp/test2.bin',
        size: 512,
        transferId: 'tx-2',
        ttl: 3,
      );
      fakeService.binaryCtrl.add(event);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final inbox = container.read(binaryPayloadInboxProvider);
      expect(inbox.containsKey('tx-2'), isTrue);
      expect(inbox['tx-2']!.size, 512);
    });

    test('pendingBinaryTransfersProvider returns service transfers', () {
      fakeService.pendingTransfers = [
        PendingBinaryTransfer(
          transferId: 'tx-3',
          recipientId: 'peer-1',
          originalType: 0x90,
        ),
      ];

      final container = _binContainer();
      final transfers = container.read(pendingBinaryTransfersProvider);
      expect(transfers, hasLength(1));
      expect(transfers.first.transferId, 'tx-3');
    });

    test('pendingBinaryTransfersProvider returns empty list', () {
      fakeService.pendingTransfers = [];
      final container = _binContainer();
      final transfers = container.read(pendingBinaryTransfersProvider);
      expect(transfers, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Stream bridge providers (lines 222-234)
  // ---------------------------------------------------------------------------

  group('Stream bridge providers', () {
    late _FakeMeshService fakeService;

    setUp(() {
      fakeService = _FakeMeshService();
    });

    tearDown(() {
      fakeService.closeAll();
    });

    ProviderContainer _streamContainer() {
      final c = ProviderContainer(
        overrides: [
          meshNetworkingServiceProvider.overrideWithValue(fakeService),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('meshStatusStreamProvider emits status events', () async {
      final container = _streamContainer();

      final sub =
          container.listen(meshStatusStreamProvider, (_, __) {});
      addTearDown(sub.close);

      fakeService.statusCtrl.add(_status(isConnected: true));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final val = container.read(meshStatusStreamProvider);
      expect(val.asData?.value.isConnected, isTrue);
    });

    test('relayStatsStreamProvider emits relay stats', () async {
      final container = _streamContainer();

      final sub =
          container.listen(relayStatsStreamProvider, (_, __) {});
      addTearDown(sub.close);

      fakeService.relayCtrl.add(_defaultRelayStats);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final val = container.read(relayStatsStreamProvider);
      expect(val.asData?.value.totalRelayed, 10);
    });

    test('queueStatsStreamProvider emits queue sync stats', () async {
      final container = _streamContainer();

      final sub =
          container.listen(queueStatsStreamProvider, (_, __) {});
      addTearDown(sub.close);

      fakeService.queueCtrl.add(_defaultQueueSyncStats);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final val = container.read(queueStatsStreamProvider);
      expect(val.asData?.value.successfulSyncs, 4);
    });
  });

  // ---------------------------------------------------------------------------
  // Topology providers (lines 237-246)
  // ---------------------------------------------------------------------------

  group('Topology providers', () {
    test('topologyManagerProvider returns a TopologyManager', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final manager = container.read(topologyManagerProvider);
      expect(manager, isA<TopologyManager>());
    });

    test('topologyStreamProvider bridges TopologyManager stream', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Reading the stream provider should not throw.
      final val = container.read(topologyStreamProvider);
      // Initially loading since no data has been emitted.
      expect(val, isA<AsyncLoading<NetworkTopology>>());
    });
  });

  // ---------------------------------------------------------------------------
  // meshRoutingServiceProvider (lines 251-255)
  // ---------------------------------------------------------------------------

  group('meshRoutingServiceProvider', () {
    test('returns null by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final value = container.read(meshRoutingServiceProvider);
      expect(value, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // BinaryPayloadInbox (line coverage for clearPayload path)
  // ---------------------------------------------------------------------------

  group('BinaryPayloadInbox', () {
    test('addPayload stores and clearPayload removes', () {
      final inbox = BinaryPayloadInbox();
      final event = ReceivedBinaryEvent(
        fragmentId: 'f1',
        originalType: 0x90,
        filePath: '/path',
        size: 100,
        transferId: 'tx-100',
        ttl: 2,
      );

      inbox.addPayload(event);
      expect(inbox.state, contains('tx-100'));

      inbox.clearPayload('tx-100');
      expect(inbox.state, isNot(contains('tx-100')));
    });

    test('clearPayload with non-existent key is no-op', () {
      final inbox = BinaryPayloadInbox();
      inbox.clearPayload('does-not-exist');
      expect(inbox.state, isEmpty);
    });

    test('multiple payloads are stored independently', () {
      final inbox = BinaryPayloadInbox();
      for (var i = 0; i < 3; i++) {
        inbox.addPayload(ReceivedBinaryEvent(
          fragmentId: 'f-$i',
          originalType: 0x90,
          filePath: '/p$i',
          size: i * 10,
          transferId: 'tx-$i',
          ttl: 3,
        ));
      }
      expect(inbox.state, hasLength(3));
      expect(inbox.state.keys, containsAll(['tx-0', 'tx-1', 'tx-2']));
    });
  });

  // ---------------------------------------------------------------------------
  // MeshRuntimeState model coverage
  // ---------------------------------------------------------------------------

  group('MeshRuntimeState', () {
    test('initial() defaults', () {
      final s = MeshRuntimeState.initial();
      expect(s.status.isInitialized, isFalse);
      expect(s.status.isConnected, isFalse);
      expect(s.status.statistics.nodeId, 'unknown');
      expect(s.relayStatistics, isNull);
      expect(s.queueStatistics, isNull);
    });

    test('copyWith overrides individual fields', () {
      final base = MeshRuntimeState.initial();

      final withRelay =
          base.copyWith(relayStatistics: _defaultRelayStats);
      expect(withRelay.relayStatistics!.totalRelayed, 10);
      expect(withRelay.queueStatistics, isNull);

      final withQueue =
          base.copyWith(queueStatistics: _defaultQueueSyncStats);
      expect(withQueue.queueStatistics!.successfulSyncs, 4);
      expect(withQueue.relayStatistics, isNull);

      final withStatus = base.copyWith(
        status: _status(isConnected: true, currentNodeId: 'n1'),
      );
      expect(withStatus.status.isConnected, isTrue);
      expect(withStatus.status.currentNodeId, 'n1');
    });
  });
}

// =============================================================================
// HELPERS: Bootstrap override
// =============================================================================

/// A bootstrap notifier that immediately resolves to "ready" state.
class _ReadyBootstrapNotifier extends AppBootstrapNotifier {
  @override
  Future<AppBootstrapState> build() async {
    return const AppBootstrapState(status: AppBootstrapStatus.ready);
  }
}

/// A bootstrap notifier that stays in loading state.
class _LoadingBootstrapNotifier extends AppBootstrapNotifier {
  @override
  Future<AppBootstrapState> build() {
    // Never completes — the provider will remain in AsyncLoading.
    return Completer<AppBootstrapState>().future;
  }
}
