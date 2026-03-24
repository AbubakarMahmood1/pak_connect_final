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
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';

/// Supplementary tests for mesh networking provider
/// Covers: MeshNetworkingUIState getters, MeshNetworkHealth assessment,
/// MeshRuntimeState, BinaryPayloadInbox, health edge cases
void main() {
 late List<LogRecord> logRecords;

 setUp(() {
 logRecords = [];
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logRecords.add);
 });

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

 group('MeshRuntimeState', () {
 test('initial() creates uninitialized state', () {
 final state = MeshRuntimeState.initial();
 expect(state.status.isInitialized, false);
 expect(state.relayStatistics, isNull);
 expect(state.queueStatistics, isNull);
 });

 test('copyWith preserves unchanged fields', () {
 final initial = MeshRuntimeState.initial();
 const relay = RelayStatistics(totalRelayed: 10,
 totalDropped: 1,
 totalDeliveredToSelf: 3,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.1,
 relayEfficiency: 0.9,
 activeRelayMessages: 2,
 networkSize: 5,
 currentRelayProbability: 0.7,
);

 final updated = initial.copyWith(relayStatistics: relay);
 expect(updated.relayStatistics, relay);
 expect(updated.status.isInitialized, false); // preserved
 expect(updated.queueStatistics, isNull); // preserved
 });

 test('copyWith updates status', () {
 final initial = MeshRuntimeState.initial();
 final newStatus = makeStatus();
 final updated = initial.copyWith(status: newStatus);
 expect(updated.status.isInitialized, true);
 });
 });

 group('MeshNetworkingUIState — getters', () {
 test('isReady reflects networkStatus.isInitialized', () {
 final ready = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(isInitialized: true)),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 expect(ready.isReady, true);

 final notReady = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(isInitialized: false)),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 expect(notReady.isReady, false);
 });

 test('isReady returns false when loading', () {
 const loading = MeshNetworkingUIState(networkStatus: AsyncValue.loading(),
 relayStats: AsyncValue.data(null),
 queueStats: AsyncValue.data(null),
);
 expect(loading.isReady, false);
 });

 test('isConnected reflects networkStatus', () {
 final connected = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(isConnected: true),
),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 expect(connected.isConnected, true);
 });

 test('currentNodeId from status', () {
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(nodeId: 'my-node-42')),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 expect(state.currentNodeId, 'my-node-42');
 });

 test('relayEfficiencyPercent from relayStats', () {
 const relay = RelayStatistics(totalRelayed: 10,
 totalDropped: 1,
 totalDeliveredToSelf: 3,
 totalBlocked: 0,
 totalProbabilisticSkip: 0,
 spamScore: 0.0,
 relayEfficiency: 0.85,
 activeRelayMessages: 0,
 networkSize: 3,
 currentRelayProbability: 0.7,
);
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus()),
 relayStats: const AsyncValue.data(relay),
 queueStats: const AsyncValue.data(null),
);
 expect(state.relayEfficiencyPercent, closeTo(85.0, 0.01));
 });

 test('relayEfficiencyPercent defaults to 0 when null', () {
 const state = MeshNetworkingUIState(networkStatus: AsyncValue.loading(),
 relayStats: AsyncValue.data(null),
 queueStats: AsyncValue.data(null),
);
 expect(state.relayEfficiencyPercent, 0.0);
 });

 test('totalRelayed and totalBlocked from relayStats', () {
 const relay = RelayStatistics(totalRelayed: 42,
 totalDropped: 3,
 totalDeliveredToSelf: 10,
 totalBlocked: 5,
 totalProbabilisticSkip: 0,
 spamScore: 0.1,
 relayEfficiency: 0.9,
 activeRelayMessages: 1,
 networkSize: 4,
 currentRelayProbability: 0.8,
);
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus()),
 relayStats: const AsyncValue.data(relay),
 queueStats: const AsyncValue.data(null),
);
 expect(state.totalRelayed, 42);
 expect(state.totalBlocked, 5);
 });

 test('pendingMessages from queueStatistics', () {
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(queueStats: const QueueStatistics(totalQueued: 20,
 totalDelivered: 15,
 totalFailed: 1,
 pendingMessages: 4,
 sendingMessages: 1,
 retryingMessages: 0,
 failedMessages: 1,
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 200),
),
)),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 expect(state.pendingMessages, 4);
 });

 test('queueHealthPercent from statistics', () {
 final state = MeshNetworkingUIState(networkStatus: AsyncValue.data(makeStatus(queueStats: const QueueStatistics(totalQueued: 100,
 totalDelivered: 90,
 totalFailed: 5,
 pendingMessages: 5,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 5,
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 300),
),
)),
 relayStats: const AsyncValue.data(null),
 queueStats: const AsyncValue.data(null),
);
 // queueHealthScore is computed from QueueStatistics
 expect(state.queueHealthPercent, greaterThanOrEqualTo(0));
 });
 });

 group('MeshNetworkHealth — health assessment', () {
 test('healthStatus categories', () {
 expect(const MeshNetworkHealth(overallHealth: 0.9,
 relayEfficiency: 0.9,
 queueHealth: 0.9,
 spamBlockRate: 0.0,
 isHealthy: true,
 issues: [],
).healthStatus,
 'Excellent',
);
 expect(const MeshNetworkHealth(overallHealth: 0.7,
 relayEfficiency: 0.7,
 queueHealth: 0.7,
 spamBlockRate: 0.0,
 isHealthy: true,
 issues: [],
).healthStatus,
 'Good',
);
 expect(const MeshNetworkHealth(overallHealth: 0.5,
 relayEfficiency: 0.5,
 queueHealth: 0.5,
 spamBlockRate: 0.0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Fair',
);
 expect(const MeshNetworkHealth(overallHealth: 0.3,
 relayEfficiency: 0.3,
 queueHealth: 0.3,
 spamBlockRate: 0.0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Poor',
);
 expect(const MeshNetworkHealth(overallHealth: 0.1,
 relayEfficiency: 0.1,
 queueHealth: 0.1,
 spamBlockRate: 0.0,
 isHealthy: false,
 issues: [],
).healthStatus,
 'Critical',
);
 });

 test('healthColor categories', () {
 expect(const MeshNetworkHealth(overallHealth: 0.8,
 relayEfficiency: 0.8,
 queueHealth: 0.8,
 spamBlockRate: 0.0,
 isHealthy: true,
 issues: [],
).healthColor,
 'green',
);
 expect(const MeshNetworkHealth(overallHealth: 0.6,
 relayEfficiency: 0.6,
 queueHealth: 0.6,
 spamBlockRate: 0.0,
 isHealthy: false,
 issues: [],
).healthColor,
 'orange',
);
 expect(const MeshNetworkHealth(overallHealth: 0.3,
 relayEfficiency: 0.3,
 queueHealth: 0.3,
 spamBlockRate: 0.0,
 isHealthy: false,
 issues: [],
).healthColor,
 'red',
);
 });
 });

 group('MeshNetworkingController — health computation', () {
 test('getNetworkHealth with all features active', () {
 final service = _FakeMeshService();
 service.stats = MeshNetworkStatistics(nodeId: 'node-a',
 isInitialized: true,
 relayStatistics: const RelayStatistics(totalRelayed: 100,
 totalDropped: 2,
 totalDeliveredToSelf: 20,
 totalBlocked: 1,
 totalProbabilisticSkip: 0,
 spamScore: 0.05,
 relayEfficiency: 0.95,
 activeRelayMessages: 5,
 networkSize: 10,
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
 syncStatistics: null,
 spamStatistics: null,
 spamPreventionActive: true,
 queueSyncActive: true,
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();

 expect(health.overallHealth, greaterThan(0.7));
 expect(health.isHealthy, true);
 expect(health.relayEfficiency, 0.95);
 expect(health.issues, isEmpty);
 });

 test('getNetworkHealth flags uninitialized mesh', () {
 final service = _FakeMeshService();
 service.stats = const MeshNetworkStatistics(nodeId: 'unknown',
 isInitialized: false,
 relayStatistics: null,
 queueStatistics: null,
 syncStatistics: null,
 spamStatistics: null,
 spamPreventionActive: false,
 queueSyncActive: false,
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();

 expect(health.isHealthy, false);
 expect(health.issues, contains('Mesh networking not initialized'));
 expect(health.issues, contains('Spam prevention not active'));
 expect(health.issues, contains('Queue synchronization not active'));
 });

 test('getNetworkHealth flags high drop rate', () {
 final service = _FakeMeshService();
 service.stats = MeshNetworkStatistics(nodeId: 'node-a',
 isInitialized: true,
 relayStatistics: const RelayStatistics(totalRelayed: 10,
 totalDropped: 20, // >50% of relayed
 totalDeliveredToSelf: 2,
 totalBlocked: 1,
 totalProbabilisticSkip: 0,
 spamScore: 0.5,
 relayEfficiency: 0.3,
 activeRelayMessages: 0,
 networkSize: 3,
 currentRelayProbability: 0.5,
),
 queueStatistics: null,
 syncStatistics: null,
 spamStatistics: null,
 spamPreventionActive: true,
 queueSyncActive: true,
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();

 expect(health.issues, contains('High message drop rate'));
 });

 test('getNetworkHealth flags many failed queue messages', () {
 final service = _FakeMeshService();
 service.stats = MeshNetworkStatistics(nodeId: 'node-a',
 isInitialized: true,
 relayStatistics: null,
 queueStatistics: const QueueStatistics(totalQueued: 100,
 totalDelivered: 80,
 totalFailed: 15,
 pendingMessages: 5,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 15, // >10 triggers issue
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 300),
),
 syncStatistics: null,
 spamStatistics: null,
 spamPreventionActive: true,
 queueSyncActive: true,
);

 final controller = MeshNetworkingController(service);
 final health = controller.getNetworkHealth();

 expect(health.issues, contains('Many failed messages in queue'));
 });

 test('sendMeshMessage handles exception', () async {
 final service = _FakeMeshService();
 service.throwOnSend = true;

 final controller = MeshNetworkingController(service);
 final result = await controller.sendMeshMessage(content: 'hello',
 recipientPublicKey: 'recipient_key_abc',
);

 expect(result.type, MeshSendType.error);
 });

 test('syncQueuesWithPeers handles exception', () async {
 final service = _FakeMeshService();
 service.throwOnSync = true;

 final controller = MeshNetworkingController(service);
 final result = await controller.syncQueuesWithPeers();

 expect(result.containsKey('error'), true);
 });
 });

 group('BinaryPayloadInbox', () {
 test('addPayload stores event by transferId', () {
 final inbox = BinaryPayloadInbox();
 final event = ReceivedBinaryEvent(transferId: 'tx-1',
 fragmentId: 'frag-1',
 originalType: 1,
 filePath: '/tmp/test.bin',
 size: 3,
 ttl: 5,
 senderNodeId: 'sender-key',
);

 inbox.addPayload(event);
 expect(inbox.state.containsKey('tx-1'), true);
 expect(inbox.state['tx-1']!.senderNodeId, 'sender-key');
 });

 test('clearPayload removes event', () {
 final inbox = BinaryPayloadInbox();
 final event = ReceivedBinaryEvent(transferId: 'tx-2',
 fragmentId: 'frag-2',
 originalType: 1,
 filePath: '/tmp/image.png',
 size: 6,
 ttl: 5,
);

 inbox.addPayload(event);
 expect(inbox.state.length, 1);

 inbox.clearPayload('tx-2');
 expect(inbox.state.isEmpty, true);
 });

 test('clearPayload for nonexistent key is no-op', () {
 final inbox = BinaryPayloadInbox();
 inbox.clearPayload('nonexistent');
 expect(inbox.state.isEmpty, true);
 });

 test('multiple payloads coexist', () {
 final inbox = BinaryPayloadInbox();
 for (int i = 0; i < 5; i++) {
 inbox.addPayload(ReceivedBinaryEvent(transferId: 'tx-$i',
 fragmentId: 'frag-$i',
 originalType: 1,
 filePath: '/tmp/file-$i.bin',
 size: i + 1,
 ttl: 5,
 senderNodeId: 'sender-$i',
));
 }
 expect(inbox.state.length, 5);

 inbox.clearPayload('tx-2');
 expect(inbox.state.length, 4);
 expect(inbox.state.containsKey('tx-2'), false);
 });
 });
}

/// Minimal fake of IMeshNetworkingService for controller tests
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

 @override
 MeshNetworkStatistics getNetworkStatistics() => stats;

 @override
 Future<MeshSendResult> sendMeshMessage({
 required String content,
 required String recipientPublicKey,
 MessagePriority priority = MessagePriority.normal,
 }) async {
 if (throwOnSend) throw Exception('send failed');
 return MeshSendResult.direct('msg-ok');
 }

 @override
 Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
 if (throwOnSync) throw Exception('sync failed');
 return {};
 }

 @override
 void refreshMeshStatus() {}

 @override
 List<PendingBinaryTransfer> getPendingBinaryTransfers() => [];

 // Stream getters — return empty streams for controller tests
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
