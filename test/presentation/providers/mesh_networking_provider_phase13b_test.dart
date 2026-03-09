/// Phase 13b — MeshNetworkingProvider additional coverage.
///
/// Targets uncovered branches:
///   - MeshNetworkingController.sendMeshMessage with custom priority
///   - MeshNetworkingController.syncQueuesWithPeers empty result
///   - MeshNetworkingController.getNetworkHealth all-disabled features
///   - MeshNetworkingController._getNetworkIssues with no relay/queue stats
///   - MeshNetworkHealth healthStatus exact boundary values
///   - MeshNetworkHealth healthColor edge cases
///   - MeshNetworkingUIState with data values
///   - MeshRuntimeState.initial() defaults
///   - MeshRuntimeState.copyWith partial overrides
///   - BinaryPayloadInbox clearPayload nonexistent key
///   - BinaryPayloadInbox multiple payloads
///   - MeshNetworkStatus model access
///   - MeshNetworkStatistics field access
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/domain/services/spam_prevention_manager.dart'
    show SpamPreventionStatistics;
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';

void main() {
  Logger.root.level = Level.OFF;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  MeshNetworkStatistics stats({
    bool isInitialized = true,
    bool spamPreventionActive = true,
    bool queueSyncActive = true,
    RelayStatistics? relayStatistics,
    QueueStatistics? queueStatistics,
    SpamPreventionStatistics? spamStatistics,
  }) =>
      MeshNetworkStatistics(
        nodeId: 'node-b',
        isInitialized: isInitialized,
        relayStatistics: relayStatistics,
        queueStatistics: queueStatistics,
        syncStatistics: null,
        spamStatistics: spamStatistics,
        spamPreventionActive: spamPreventionActive,
        queueSyncActive: queueSyncActive,
      );

  MeshNetworkStatus makeStatus({
    bool isInitialized = true,
    bool isConnected = true,
    String? nodeId = 'node-b',
    QueueStatistics? queueStats,
    RelayStatistics? relayStats,
  }) {
    return MeshNetworkStatus(
      isInitialized: isInitialized,
      currentNodeId: nodeId,
      isConnected: isConnected,
      queueMessages: const [],
      statistics: MeshNetworkStatistics(
        nodeId: nodeId ?? 'unknown',
        isInitialized: isInitialized,
        relayStatistics: relayStats,
        queueStatistics: queueStats,
        syncStatistics: null,
        spamStatistics: null,
        spamPreventionActive: true,
        queueSyncActive: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MeshNetworkingController — sendMeshMessage with priorities
  // ---------------------------------------------------------------------------
  group('MeshNetworkingController — sendMeshMessage priority variations', () {
    test('sends with urgent priority', () async {
      final service = _FakeMeshService();
      service.nextSendResult = MeshSendResult.direct('msg-urgent');

      final controller = MeshNetworkingController(service);
      final result = await controller.sendMeshMessage(
        content: 'urgent!',
        recipientPublicKey: 'key_abcdef0123456789',
        priority: MessagePriority.urgent,
      );

      expect(result.type, MeshSendType.direct);
      expect(result.messageId, 'msg-urgent');
    });

    test('sends with low priority via relay', () async {
      final service = _FakeMeshService();
      service.nextSendResult = MeshSendResult.relay('msg-low', 'hop-1');

      final controller = MeshNetworkingController(service);
      final result = await controller.sendMeshMessage(
        content: 'no rush',
        recipientPublicKey: 'key_abcdef0123456789',
        priority: MessagePriority.low,
      );

      expect(result.type, MeshSendType.relay);
      expect(result.isSuccess, true);
    });

    test('error result is not success', () async {
      final service = _FakeMeshService();
      service.nextSendResult = MeshSendResult.error('offline');

      final controller = MeshNetworkingController(service);
      final result = await controller.sendMeshMessage(
        content: 'offline',
        recipientPublicKey: 'key_abcdef0123456789',
      );

      expect(result.type, MeshSendType.error);
      expect(result.isSuccess, false);
    });
  });

  // ---------------------------------------------------------------------------
  // MeshNetworkingController — syncQueuesWithPeers variations
  // ---------------------------------------------------------------------------
  group('MeshNetworkingController — syncQueuesWithPeers edge cases', () {
    test('returns empty map when no peers', () async {
      final service = _FakeMeshService();
      service.syncResult = {};

      final controller = MeshNetworkingController(service);
      final result = await controller.syncQueuesWithPeers();
      expect(result, isEmpty);
    });

    test('handles multiple sync results', () async {
      final service = _FakeMeshService();
      service.syncResult = {
        'peer-a': QueueSyncResult.alreadySynced(),
        'peer-b': QueueSyncResult.error('timeout'),
      };

      final controller = MeshNetworkingController(service);
      final result = await controller.syncQueuesWithPeers();
      expect(result.length, 2);
      expect(result['peer-a']!.type, QueueSyncResultType.alreadySynced);
      expect(result['peer-b']!.type, QueueSyncResultType.error);
    });
  });

  // ---------------------------------------------------------------------------
  // MeshNetworkingController — getNetworkHealth with all features disabled
  // ---------------------------------------------------------------------------
  group('MeshNetworkingController — getNetworkHealth feature flags', () {
    test('all features disabled yields minimal health', () {
      final service = _FakeMeshService();
      service.stats = stats(
        isInitialized: false,
        spamPreventionActive: false,
        queueSyncActive: false,
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      expect(health.overallHealth, lessThan(0.3));
      expect(health.isHealthy, false);
      expect(health.issues, contains('Mesh networking not initialized'));
      expect(health.issues, contains('Spam prevention not active'));
      expect(health.issues, contains('Queue synchronization not active'));
    });

    test('only initialized yields 0.3 base', () {
      final service = _FakeMeshService();
      service.stats = stats(
        isInitialized: true,
        spamPreventionActive: false,
        queueSyncActive: false,
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      // 0.3 (init) + 0.0 (relay*0.2) + 0.0 (queue*0.1)
      expect(health.overallHealth, greaterThanOrEqualTo(0.3));
      expect(health.issues, isNot(contains('Mesh networking not initialized')));
      expect(health.issues, contains('Spam prevention not active'));
    });

    test('relay efficiency contributes to health', () {
      final service = _FakeMeshService();
      service.stats = stats(
        relayStatistics: const RelayStatistics(
          totalRelayed: 100,
          totalDropped: 0,
          totalDeliveredToSelf: 10,
          totalBlocked: 0,
          totalProbabilisticSkip: 0,
          spamScore: 0.0,
          relayEfficiency: 0.5,
          activeRelayMessages: 1,
          networkSize: 3,
          currentRelayProbability: 0.5,
        ),
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      expect(health.relayEfficiency, 0.5);
    });

    test('queue health contributes to health score', () {
      final service = _FakeMeshService();
      service.stats = stats(
        queueStatistics: const QueueStatistics(
          totalQueued: 100,
          totalDelivered: 90,
          totalFailed: 5,
          pendingMessages: 5,
          sendingMessages: 0,
          retryingMessages: 0,
          failedMessages: 5,
          isOnline: true,
          averageDeliveryTime: Duration(seconds: 1),
        ),
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      expect(health.queueHealth, greaterThan(0.0));
    });
  });

  // ---------------------------------------------------------------------------
  // MeshNetworkHealth — healthStatus and healthColor at additional values
  // ---------------------------------------------------------------------------
  group('MeshNetworkHealth — additional boundary tests', () {
    test('healthStatus at 1.0', () {
      const h = MeshNetworkHealth(
        overallHealth: 1.0,
        relayEfficiency: 1.0,
        queueHealth: 1.0,
        spamBlockRate: 0.0,
        isHealthy: true,
        issues: [],
      );
      expect(h.healthStatus, 'Excellent');
      expect(h.healthColor, 'green');
    });

    test('healthStatus at 0.69', () {
      const h = MeshNetworkHealth(
        overallHealth: 0.69,
        relayEfficiency: 0,
        queueHealth: 0,
        spamBlockRate: 0,
        isHealthy: false,
        issues: [],
      );
      expect(h.healthStatus, 'Good');
      expect(h.healthColor, 'orange');
    });

    test('healthColor red at 0.0', () {
      const h = MeshNetworkHealth(
        overallHealth: 0.0,
        relayEfficiency: 0,
        queueHealth: 0,
        spamBlockRate: 0,
        isHealthy: false,
        issues: [],
      );
      expect(h.healthColor, 'red');
    });

    test('healthColor orange at exactly 0.5', () {
      const h = MeshNetworkHealth(
        overallHealth: 0.5,
        relayEfficiency: 0,
        queueHealth: 0,
        spamBlockRate: 0,
        isHealthy: false,
        issues: [],
      );
      expect(h.healthColor, 'orange');
    });

    test('issues list is preserved', () {
      const h = MeshNetworkHealth(
        overallHealth: 0.3,
        relayEfficiency: 0,
        queueHealth: 0,
        spamBlockRate: 0,
        isHealthy: false,
        issues: ['issue1', 'issue2'],
      );
      expect(h.issues.length, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // MeshNetworkingUIState — with populated data
  // ---------------------------------------------------------------------------
  group('MeshNetworkingUIState — populated data', () {
    test('all getters with valid data', () {
      final status = makeStatus(
        nodeId: 'my-node',
        isInitialized: true,
        isConnected: true,
        queueStats: const QueueStatistics(
          totalQueued: 100,
          totalDelivered: 80,
          totalFailed: 5,
          pendingMessages: 15,
          sendingMessages: 0,
          retryingMessages: 0,
          failedMessages: 5,
          isOnline: true,
          averageDeliveryTime: Duration(seconds: 2),
        ),
      );

      const relay = RelayStatistics(
        totalRelayed: 50,
        totalDropped: 2,
        totalDeliveredToSelf: 5,
        totalBlocked: 3,
        totalProbabilisticSkip: 0,
        spamScore: 0.05,
        relayEfficiency: 0.9,
        activeRelayMessages: 2,
        networkSize: 6,
        currentRelayProbability: 0.8,
      );

      final state = MeshNetworkingUIState(
        networkStatus: AsyncValue.data(status),
        relayStats: const AsyncValue.data(relay),
        queueStats: const AsyncValue.data(null),
      );

      expect(state.isReady, true);
      expect(state.isConnected, true);
      expect(state.currentNodeId, 'my-node');
      expect(state.relayEfficiencyPercent, closeTo(90.0, 0.01));
      expect(state.totalRelayed, 50);
      expect(state.totalBlocked, 3);
      expect(state.pendingMessages, 15);
    });

    test('relayEfficiencyPercent zero when relay is null', () {
      const state = MeshNetworkingUIState(
        networkStatus: AsyncValue.loading(),
        relayStats: AsyncValue.data(null),
        queueStats: AsyncValue.data(null),
      );
      expect(state.relayEfficiencyPercent, 0.0);
    });

    test('queueHealthPercent from statistics', () {
      final status = makeStatus(
        queueStats: const QueueStatistics(
          totalQueued: 100,
          totalDelivered: 95,
          totalFailed: 2,
          pendingMessages: 3,
          sendingMessages: 0,
          retryingMessages: 0,
          failedMessages: 2,
          isOnline: true,
          averageDeliveryTime: Duration(seconds: 1),
        ),
      );
      final state = MeshNetworkingUIState(
        networkStatus: AsyncValue.data(status),
        relayStats: const AsyncValue.data(null),
        queueStats: const AsyncValue.data(null),
      );
      expect(state.queueHealthPercent, greaterThan(0));
    });
  });

  // ---------------------------------------------------------------------------
  // MeshRuntimeState — defaults and copyWith
  // ---------------------------------------------------------------------------
  group('MeshRuntimeState — defaults', () {
    test('initial state has uninitialized status', () {
      final state = MeshRuntimeState.initial();
      expect(state.status.isInitialized, false);
      expect(state.relayStatistics, isNull);
      expect(state.queueStatistics, isNull);
    });

    test('initial status has unknown nodeId', () {
      final state = MeshRuntimeState.initial();
      expect(state.status.statistics.nodeId, 'unknown');
    });

    test('copyWith preserves unmodified fields', () {
      final state = MeshRuntimeState.initial();
      const relay = RelayStatistics(
        totalRelayed: 10,
        totalDropped: 1,
        totalDeliveredToSelf: 2,
        totalBlocked: 0,
        totalProbabilisticSkip: 0,
        spamScore: 0.0,
        relayEfficiency: 0.9,
        activeRelayMessages: 0,
        networkSize: 2,
        currentRelayProbability: 0.5,
      );

      final updated = state.copyWith(relayStatistics: relay);
      expect(updated.relayStatistics, relay);
      expect(updated.status.isInitialized, false); // preserved
      expect(updated.queueStatistics, isNull); // preserved
    });

    test('copyWith with only status', () {
      final state = MeshRuntimeState.initial();
      final newStatus = makeStatus(nodeId: 'new-node');
      final updated = state.copyWith(status: newStatus);
      expect(updated.status.currentNodeId, 'new-node');
    });
  });

  // ---------------------------------------------------------------------------
  // BinaryPayloadInbox — edge cases
  // ---------------------------------------------------------------------------
  group('BinaryPayloadInbox — edge cases', () {
    test('clearPayload on nonexistent key is no-op', () {
      final inbox = BinaryPayloadInbox();
      inbox.clearPayload('nonexistent');
      expect(inbox.state, isEmpty);
    });

    test('add multiple distinct payloads', () {
      final inbox = BinaryPayloadInbox();
      inbox.addPayload(ReceivedBinaryEvent(
        transferId: 'tx-1',
        fragmentId: 'f1',
        originalType: 1,
        filePath: '/tmp/1.bin',
        size: 100,
        ttl: 5,
      ));
      inbox.addPayload(ReceivedBinaryEvent(
        transferId: 'tx-2',
        fragmentId: 'f2',
        originalType: 2,
        filePath: '/tmp/2.bin',
        size: 200,
        ttl: 5,
      ));
      expect(inbox.state.length, 2);
      expect(inbox.state.containsKey('tx-1'), true);
      expect(inbox.state.containsKey('tx-2'), true);
    });

    test('clear one of multiple payloads', () {
      final inbox = BinaryPayloadInbox();
      inbox.addPayload(ReceivedBinaryEvent(
        transferId: 'tx-a',
        fragmentId: 'f1',
        originalType: 1,
        filePath: '/tmp/a.bin',
        size: 10,
        ttl: 5,
      ));
      inbox.addPayload(ReceivedBinaryEvent(
        transferId: 'tx-b',
        fragmentId: 'f2',
        originalType: 2,
        filePath: '/tmp/b.bin',
        size: 20,
        ttl: 5,
      ));
      inbox.clearPayload('tx-a');
      expect(inbox.state.length, 1);
      expect(inbox.state.containsKey('tx-b'), true);
    });

    test('overwrite then clear', () {
      final inbox = BinaryPayloadInbox();
      inbox.addPayload(ReceivedBinaryEvent(
        transferId: 'tx-ow',
        fragmentId: 'f1',
        originalType: 1,
        filePath: '/tmp/old.bin',
        size: 10,
        ttl: 5,
      ));
      inbox.addPayload(ReceivedBinaryEvent(
        transferId: 'tx-ow',
        fragmentId: 'f2',
        originalType: 2,
        filePath: '/tmp/new.bin',
        size: 20,
        ttl: 5,
      ));
      expect(inbox.state.length, 1);
      inbox.clearPayload('tx-ow');
      expect(inbox.state, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // _getNetworkIssues — combinations of null stats
  // ---------------------------------------------------------------------------
  group('MeshNetworkingController — _getNetworkIssues null stats', () {
    test('null relay and queue stats produce only feature issues', () {
      final service = _FakeMeshService();
      service.stats = stats(
        isInitialized: true,
        spamPreventionActive: true,
        queueSyncActive: true,
        relayStatistics: null,
        queueStatistics: null,
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      expect(health.issues, isEmpty);
    });

    test('only relay stats null does not crash', () {
      final service = _FakeMeshService();
      service.stats = stats(
        relayStatistics: null,
        queueStatistics: const QueueStatistics(
          totalQueued: 10,
          totalDelivered: 10,
          totalFailed: 0,
          pendingMessages: 0,
          sendingMessages: 0,
          retryingMessages: 0,
          failedMessages: 0,
          isOnline: true,
          averageDeliveryTime: Duration(seconds: 1),
        ),
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      expect(health.relayEfficiency, 0.0);
    });

    test('only queue stats null does not crash', () {
      final service = _FakeMeshService();
      service.stats = stats(
        relayStatistics: const RelayStatistics(
          totalRelayed: 10,
          totalDropped: 0,
          totalDeliveredToSelf: 2,
          totalBlocked: 0,
          totalProbabilisticSkip: 0,
          spamScore: 0.0,
          relayEfficiency: 0.8,
          activeRelayMessages: 0,
          networkSize: 2,
          currentRelayProbability: 0.5,
        ),
        queueStatistics: null,
      );

      final controller = MeshNetworkingController(service);
      final health = controller.getNetworkHealth();
      expect(health.queueHealth, 0.0);
    });
  });
}

// =============================================================================
// Fake service for controller tests
// =============================================================================

class _FakeMeshService implements IMeshNetworkingService {
  MeshNetworkStatistics stats = const MeshNetworkStatistics(
    nodeId: 'fake-b',
    isInitialized: true,
    relayStatistics: null,
    queueStatistics: null,
    syncStatistics: null,
    spamStatistics: null,
    spamPreventionActive: false,
    queueSyncActive: false,
  );
  bool throwOnSend = false;
  bool throwOnSync = false;
  MeshSendResult nextSendResult = MeshSendResult.direct('msg-ok');
  Map<String, QueueSyncResult> syncResult = {};

  @override
  MeshNetworkStatistics getNetworkStatistics() => stats;

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
  void refreshMeshStatus() {}

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => [];

  @override
  Stream<MeshNetworkStatus> get meshStatus => const Stream.empty();
  @override
  Stream<RelayStatistics> get relayStats => const Stream.empty();
  @override
  Stream<QueueSyncManagerStats> get queueStats => const Stream.empty();
  Stream<String> get deliveryNotifications => const Stream.empty();
  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
