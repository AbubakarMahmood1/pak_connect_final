import 'dart:async';

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

/// Supplementary tests for mesh_networking_provider.dart
/// Targets uncovered branches: sendMeshMessage success path,
/// syncQueuesWithPeers success, _getNetworkIssues edge cases (high spam
/// block rate, poor queue health), MeshNetworkHealth boundary values,
/// MeshNetworkingUIState error/loading fallbacks, BinaryPayloadInbox
/// overwrites, MeshRuntimeState.copyWith with queueStatistics.
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
 MeshNetworkStatistics(nodeId: 'node-x',
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
 String? nodeId = 'node-1',
 QueueStatistics? queueStats,
 RelayStatistics? relayStats,
 }) {
 return MeshNetworkStatus(isInitialized: isInitialized,
 currentNodeId: nodeId,
 isConnected: isConnected,
 queueMessages: const [],
 statistics: MeshNetworkStatistics(nodeId: nodeId ?? 'unknown',
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
 // MeshNetworkingController — sendMeshMessage success path
 // ---------------------------------------------------------------------------
 group('MeshNetworkingController — sendMeshMessage success', () {
 test('returns direct result on success', () async {
 final service = _FakeMeshService();
 service.nextSendResult = MeshSendResult.direct('msg-ok-123');

 final controller = MeshNetworkingController(service);
 final result = await controller.sendMeshMessage(content: 'hello world',
 recipientPublicKey: 'recipient_key_abcdef01',
);

 expect(result.type, MeshSendType.direct);
 expect(result.messageId, 'msg-ok-123');
 expect(result.isSuccess, true);
 });

 test('returns relay result on relay success', () async {
 final service = _FakeMeshService();
 service.nextSendResult = MeshSendResult.relay('msg-relay-1', 'hop-node');

 final controller = MeshNetworkingController(service);
 final result = await controller.sendMeshMessage(content: 'mesh relay test',
 recipientPublicKey: 'remote_key_12345678',
 priority: MessagePriority.high,
);

 expect(result.type, MeshSendType.relay);
 expect(result.isRelay, true);
 expect(result.nextHop, 'hop-node');
 });

 test('returns error result when service throws', () async {
 final service = _FakeMeshService();
 service.throwOnSend = true;

 final controller = MeshNetworkingController(service);
 final result = await controller.sendMeshMessage(content: 'fail',
 recipientPublicKey: 'recipient_key_abcdef01',
);

 expect(result.type, MeshSendType.error);
 expect(result.isSuccess, false);
 });
 });

 // ---------------------------------------------------------------------------
 // MeshNetworkingController — syncQueuesWithPeers success
 // ---------------------------------------------------------------------------
 group('MeshNetworkingController — syncQueuesWithPeers success', () {
 test('returns sync results on success', () async {
 final service = _FakeMeshService();
 service.syncResult = {
 'peer-a': QueueSyncResult.alreadySynced(),
 };

 final controller = MeshNetworkingController(service);
 final result = await controller.syncQueuesWithPeers();

 expect(result.containsKey('peer-a'), true);
 expect(result['peer-a']!.type, QueueSyncResultType.alreadySynced);
 });

 test('returns error map when service throws', () async {
 final service = _FakeMeshService();
 service.throwOnSync = true;

 final controller = MeshNetworkingController(service);
 final result = await controller.syncQueuesWithPeers();

 expect(result.containsKey('error'), true);
 });
 });

 // ---------------------------------------------------------------------------
 // MeshNetworkingController — _getNetworkIssues edge cases
 // ---------------------------------------------------------------------------
 group('MeshNetworkingController — _getNetworkIssues', () {
 test('flags high spam block rate', () {
 final service = _FakeMeshService();
 service.stats = stats(relayStatistics: const RelayStatistics(totalRelayed: 50,
 totalDropped: 2,
 totalDeliveredToSelf: 10,
 totalBlocked: 30, // >30% of totalProcessed (62)
 totalProbabilisticSkip: 0,
 spamScore: 0.5,
 relayEfficiency: 0.8,
 activeRelayMessages: 1,
 networkSize: 4,
 currentRelayProbability: 0.7,
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.issues, contains('High spam block rate'));
 });

 test('flags poor queue health score', () {
 final service = _FakeMeshService();
 service.stats = stats(queueStatistics: const QueueStatistics(totalQueued: 100,
 totalDelivered: 10,
 totalFailed: 80,
 pendingMessages: 50,
 sendingMessages: 10,
 retryingMessages: 10,
 failedMessages: 80,
 isOnline: false,
 averageDeliveryTime: Duration(seconds: 30),
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.issues, contains('Poor queue health'));
 });

 test('no issues with healthy relay & queue', () {
 final service = _FakeMeshService();
 service.stats = stats(relayStatistics: const RelayStatistics(totalRelayed: 100,
 totalDropped: 5,
 totalDeliveredToSelf: 20,
 totalBlocked: 2,
 totalProbabilisticSkip: 0,
 spamScore: 0.02,
 relayEfficiency: 0.95,
 activeRelayMessages: 3,
 networkSize: 8,
 currentRelayProbability: 0.9,
),
 queueStatistics: const QueueStatistics(totalQueued: 50,
 totalDelivered: 48,
 totalFailed: 1,
 pendingMessages: 1,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 1,
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 100),
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.issues, isEmpty);
 expect(health.isHealthy, true);
 });

 test('only flags drop rate when drops exceed 50% of relayed', () {
 final service = _FakeMeshService();
 // totalDropped = 5, totalRelayed = 10 → 50% exactly — NOT triggered
 service.stats = stats(relayStatistics: const RelayStatistics(totalRelayed: 10,
 totalDropped: 5,
 totalDeliveredToSelf: 0,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.0,
 relayEfficiency: 0.5,
 activeRelayMessages: 0,
 networkSize: 2,
 currentRelayProbability: 0.5,
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.issues.contains('High message drop rate'), false);

 // Now exceed the threshold
 service.stats = stats(relayStatistics: const RelayStatistics(totalRelayed: 10,
 totalDropped: 6, // > 50% of 10
 totalDeliveredToSelf: 0,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.0,
 relayEfficiency: 0.5,
 activeRelayMessages: 0,
 networkSize: 2,
 currentRelayProbability: 0.5,
),
);

 final health2 = controller.getNetworkHealth();
 expect(health2.issues, contains('High message drop rate'));
 });

 test('only flags failed queue messages when > 10', () {
 final service = _FakeMeshService();
 service.stats = stats(queueStatistics: const QueueStatistics(totalQueued: 50,
 totalDelivered: 40,
 totalFailed: 10,
 pendingMessages: 0,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 10, // exactly 10, NOT triggered
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 200),
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.issues.contains('Many failed messages in queue'), false);

 service.stats = stats(queueStatistics: const QueueStatistics(totalQueued: 50,
 totalDelivered: 39,
 totalFailed: 11,
 pendingMessages: 0,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 11, // > 10
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 200),
),
);

 final health2 = controller.getNetworkHealth();
 expect(health2.issues, contains('Many failed messages in queue'));
 });
 });

 // ---------------------------------------------------------------------------
 // MeshNetworkingController — getNetworkHealth scoring
 // ---------------------------------------------------------------------------
 group('MeshNetworkingController — health scoring', () {
 test('uninitialized mesh yields low health', () {
 final service = _FakeMeshService();
 service.stats = stats(isInitialized: false,
 spamPreventionActive: false,
 queueSyncActive: false,
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();

 expect(health.overallHealth, lessThan(0.3));
 expect(health.isHealthy, false);
 });

 test('all features active with perfect relay/queue', () {
 final service = _FakeMeshService();
 service.stats = stats(relayStatistics: const RelayStatistics(totalRelayed: 100,
 totalDropped: 0,
 totalDeliveredToSelf: 0,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.0,
 relayEfficiency: 1.0,
 activeRelayMessages: 0,
 networkSize: 5,
 currentRelayProbability: 1.0,
),
 queueStatistics: const QueueStatistics(totalQueued: 50,
 totalDelivered: 50,
 totalFailed: 0,
 pendingMessages: 0,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 0,
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 50),
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();

 // 0.3 (init) + 0.2 (spam) + 0.2 (queueSync) + 0.2 (relay=1.0) + 0.1*health
 expect(health.overallHealth, greaterThan(0.9));
 expect(health.isHealthy, true);
 });

 test('spamBlockRate comes from statistics.spamStatistics', () {
 final service = _FakeMeshService();
 service.stats = stats(spamStatistics: const SpamPreventionStatistics(totalAllowed: 90,
 totalBlocked: 10,
 blockRate: 0.1,
 averageSpamScore: 0.2,
 activeTrustScores: 5,
 processedHashes: 100,
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.spamBlockRate, 0.1);
 });
 });

 // ---------------------------------------------------------------------------
 // MeshNetworkHealth — boundary values
 // ---------------------------------------------------------------------------
 group('MeshNetworkHealth — boundary values', () {
 test('healthStatus at exact boundaries', () {
 // 0.8 → Excellent
 expect(const MeshNetworkHealth(overallHealth: 0.8,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: true,
 issues: [],
).healthStatus,
 'Excellent',
);
 // 0.6 → Good
 expect(const MeshNetworkHealth(overallHealth: 0.6,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Good',
);
 // 0.4 → Fair
 expect(const MeshNetworkHealth(overallHealth: 0.4,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Fair',
);
 // 0.2 → Poor
 expect(const MeshNetworkHealth(overallHealth: 0.2,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Poor',
);
 // 0.0 → Critical
 expect(const MeshNetworkHealth(overallHealth: 0.0,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Critical',
);
 });

 test('healthColor at exact boundaries', () {
 expect(const MeshNetworkHealth(overallHealth: 0.7,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: true,
 issues: [],
).healthColor,
 'green',
);
 expect(const MeshNetworkHealth(overallHealth: 0.5,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthColor,
 'orange',
);
 expect(const MeshNetworkHealth(overallHealth: 0.49,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthColor,
 'red',
);
 });

 test('healthStatus just below boundaries', () {
 expect(const MeshNetworkHealth(overallHealth: 0.79,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Good',
);
 expect(const MeshNetworkHealth(overallHealth: 0.59,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Fair',
);
 expect(const MeshNetworkHealth(overallHealth: 0.39,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Poor',
);
 expect(const MeshNetworkHealth(overallHealth: 0.19,
 relayEfficiency: 0,
 queueHealth: 0,
 spamBlockRate: 0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Critical',
);
 });
 });

 // ---------------------------------------------------------------------------
 // MeshNetworkingUIState — error / loading fallbacks
 // ---------------------------------------------------------------------------
 group('MeshNetworkingUIState — fallback values', () {
 test('error state returns safe defaults', () {
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.error(Exception('boom'), StackTrace.current),
 relayStats: AsyncValue.error(Exception('boom'), StackTrace.current),
 queueStats: AsyncValue.error(Exception('boom'), StackTrace.current),
);
 expect(state.isReady, false);
 expect(state.isConnected, false);
 expect(state.currentNodeId, isNull);
 expect(state.relayEfficiencyPercent, 0.0);
 expect(state.queueHealthPercent, 0.0);
 expect(state.totalRelayed, 0);
 expect(state.totalBlocked, 0);
 expect(state.pendingMessages, 0);
 });

 test('loading state returns safe defaults', () {
 const state = MeshNetworkingUIState(networkStatus: AsyncValue.loading(),
 relayStats: AsyncValue.loading(),
 queueStats: AsyncValue.loading(),
);
 expect(state.isReady, false);
 expect(state.isConnected, false);
 expect(state.currentNodeId, isNull);
 expect(state.relayEfficiencyPercent, 0.0);
 expect(state.totalRelayed, 0);
 expect(state.totalBlocked, 0);
 expect(state.pendingMessages, 0);
 });

 test('null currentNodeId', () {
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(nodeId: null, isInitialized: false),
),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 expect(state.currentNodeId, isNull);
 expect(state.isReady, false);
 });
 });

 // ---------------------------------------------------------------------------
 // MeshRuntimeState — additional copyWith paths
 // ---------------------------------------------------------------------------
 group('MeshRuntimeState — copyWith queueStatistics', () {
 test('copyWith sets queueStatistics', () {
 final initial = MeshRuntimeState.initial();
 const qStats = QueueSyncManagerStats(totalSyncRequests: 10,
 successfulSyncs: 8,
 failedSyncs: 2,
 messagesTransferred: 50,
 activeSyncs: 1,
 successRate: 0.8,
 recentSyncCount: 3,
);
 final updated = initial.copyWith(queueStatistics: qStats);
 expect(updated.queueStatistics, qStats);
 expect(updated.relayStatistics, isNull);
 });

 test('copyWith with all fields', () {
 const relay = RelayStatistics(totalRelayed: 5,
 totalDropped: 0,
 totalDeliveredToSelf: 1,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.0,
 relayEfficiency: 1.0,
 activeRelayMessages: 0,
 networkSize: 2,
 currentRelayProbability: 1.0,
);
 const qStats = QueueSyncManagerStats(totalSyncRequests: 1,
 successfulSyncs: 1,
 failedSyncs: 0,
 messagesTransferred: 10,
 activeSyncs: 0,
 successRate: 1.0,
 recentSyncCount: 1,
);
 final status = makeStatus(nodeId: 'combined', isConnected: true);

 final initial = MeshRuntimeState.initial();
 final updated = initial.copyWith(status: status,
 relayStatistics: relay,
 queueStatistics: qStats,
);

 expect(updated.status.currentNodeId, 'combined');
 expect(updated.relayStatistics!.totalRelayed, 5);
 expect(updated.queueStatistics!.successfulSyncs, 1);
 });
 });

 // ---------------------------------------------------------------------------
 // BinaryPayloadInbox — overwrite & edge cases
 // ---------------------------------------------------------------------------
 group('BinaryPayloadInbox — additional cases', () {
 test('adding same transferId overwrites previous', () {
 final inbox = BinaryPayloadInbox();
 inbox.addPayload(ReceivedBinaryEvent(transferId: 'tx-dup',
 fragmentId: 'frag-1',
 originalType: 1,
 filePath: '/tmp/old.bin',
 size: 100,
 ttl: 5,
 senderNodeId: 'sender-old',
));
 inbox.addPayload(ReceivedBinaryEvent(transferId: 'tx-dup',
 fragmentId: 'frag-2',
 originalType: 2,
 filePath: '/tmp/new.bin',
 size: 200,
 ttl: 3,
 senderNodeId: 'sender-new',
));

 expect(inbox.state.length, 1);
 expect(inbox.state['tx-dup']!.senderNodeId, 'sender-new');
 expect(inbox.state['tx-dup']!.size, 200);
 });

 test('clearPayload then add works', () {
 final inbox = BinaryPayloadInbox();
 inbox.addPayload(ReceivedBinaryEvent(transferId: 'tx-cycle',
 fragmentId: 'f1',
 originalType: 1,
 filePath: '/tmp/a.bin',
 size: 10,
 ttl: 5,
));
 inbox.clearPayload('tx-cycle');
 expect(inbox.state.isEmpty, true);

 inbox.addPayload(ReceivedBinaryEvent(transferId: 'tx-cycle',
 fragmentId: 'f2',
 originalType: 1,
 filePath: '/tmp/b.bin',
 size: 20,
 ttl: 5,
));
 expect(inbox.state.length, 1);
 expect(inbox.state['tx-cycle']!.size, 20);
 });

 test('state is immutable snapshot (new map each mutation)', () {
 final inbox = BinaryPayloadInbox();
 final snap1 = inbox.state;

 inbox.addPayload(ReceivedBinaryEvent(transferId: 'tx-snap',
 fragmentId: 'f1',
 originalType: 1,
 filePath: '/tmp/snap.bin',
 size: 1,
 ttl: 5,
));

 final snap2 = inbox.state;
 expect(identical(snap1, snap2), false);
 expect(snap1.isEmpty, true);
 expect(snap2.length, 1);
 });
 });

 // ---------------------------------------------------------------------------
 // MeshNetworkingController — getNetworkHealth with spam stats
 // ---------------------------------------------------------------------------
 group('MeshNetworkingController — getNetworkHealth spamBlockRate', () {
 test('spamBlockRate is zero when no spam stats', () {
 final service = _FakeMeshService();
 service.stats = stats();

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.spamBlockRate, 0.0);
 });

 test('queueHealth is zero when no queue stats', () {
 final service = _FakeMeshService();
 service.stats = stats();

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.queueHealth, 0.0);
 });

 test('relayEfficiency reflects actual stat', () {
 final service = _FakeMeshService();
 service.stats = stats(relayStatistics: const RelayStatistics(totalRelayed: 20,
 totalDropped: 0,
 totalDeliveredToSelf: 5,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.0,
 relayEfficiency: 0.72,
 activeRelayMessages: 1,
 networkSize: 3,
 currentRelayProbability: 0.6,
),
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();
 expect(health.relayEfficiency, 0.72);
 });
 });
}

// =============================================================================
// Fake service for controller tests
// =============================================================================

class _FakeMeshService implements IMeshNetworkingService {
 MeshNetworkStatistics stats = const MeshNetworkStatistics(nodeId: 'fake-node',
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
