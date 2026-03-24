/// Tests for RelaySendPipeline, RelayDecisionEngine, QueuePolicyManager
/// Covers: relayToNextHop (success, TTL exhaustion, error), broadcastToNeighbors
/// (success, loop filtering, empty valid neighbors, per-neighbor failures),
/// isDuplicate/isDuplicateId, calculateRelayProbability thresholds,
/// isMessageForCurrentNode (ephemeral, persistent, broadcast, empty),
/// shouldProbabilisticallySkip, chooseNextHop (routing service, loop detection),
/// chooseNextHopId, QueuePolicyManager methods
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/relay_send_pipeline.dart';
import 'package:pak_connect/core/messaging/relay_decision_engine.dart';
import 'package:pak_connect/core/services/queue_policy_manager.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/constants/special_recipients.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
 // ──────────────────────────── RelaySendPipeline ────────────────────────────
 group('RelaySendPipeline', () {
 late RelaySendPipeline pipeline;
 late SpamPreventionManager spamPrevention;
 late _FakeOfflineQueue queue;
 final logger = Logger('TestRelaySendPipeline');

 setUp(() {
 queue = _FakeOfflineQueue();
 spamPrevention = SpamPreventionManager();
 spamPrevention.bypassAllChecksForTests(enable: true);
 pipeline = RelaySendPipeline(logger: logger,
 messageQueue: queue,
 spamPrevention: spamPrevention,
);
 });

 test('relayToNextHop succeeds and calls onRelayMessage', () async {
 MeshRelayMessage? captured;
 String? capturedHop;

 final msg = _buildRelay(recipient: 'dest', ttl: 5, hopCount: 1);
 final ok = await pipeline.relayToNextHop(relayMessage: msg,
 nextHopNodeId: 'hop_1',
 onRelayMessage: (m, h) {
 captured = m;
 capturedHop = h;
 },
);
 expect(ok, isTrue);
 expect(captured, isNotNull);
 expect(capturedHop, 'hop_1');
 expect(queue.queuedCount, 1);
 });

 test('relayToNextHop calls onRelayMessageIds', () async {
 MessageId? capturedId;
 final msg = _buildRelay(recipient: 'dest', ttl: 5, hopCount: 1);
 await pipeline.relayToNextHop(relayMessage: msg,
 nextHopNodeId: 'hop_1',
 onRelayMessageIds: (id, m, h) => capturedId = id,
);
 expect(capturedId, isNotNull);
 });

 test('relayToNextHop returns false on TTL exhausted nextHop', () async {
 final msg = _buildRelay(recipient: 'dest',
 ttl: 2,
 hopCount: 2,
 routingPath: ['a', 'b'],
);
 final ok = await pipeline.relayToNextHop(relayMessage: msg,
 nextHopNodeId: 'hop_1',
);
 expect(ok, isFalse);
 });

 test('broadcastToNeighbors filters loop nodes', () async {
 final msg = _buildRelay(recipient: 'dest',
 ttl: 5,
 hopCount: 1,
 routingPath: ['origin', 'node_a'],
);
 // node_a is in path → filtered out
 final count = await pipeline.broadcastToNeighbors(relayMessage: msg,
 availableNeighbors: ['node_a', 'node_b', 'node_c'],
);
 expect(count, 2); // node_b and node_c only
 });

 test('broadcastToNeighbors returns 0 for all-loop neighbors', () async {
 final msg = _buildRelay(recipient: 'dest',
 ttl: 5,
 hopCount: 1,
 routingPath: ['origin', 'a', 'b'],
);
 final count = await pipeline.broadcastToNeighbors(relayMessage: msg,
 availableNeighbors: ['a', 'b'],
);
 expect(count, 0);
 });

 test('broadcastToNeighbors calls callbacks for each success', () async {
 var callCount = 0;
 final msg = _buildRelay(recipient: 'dest', ttl: 5, hopCount: 1);
 await pipeline.broadcastToNeighbors(relayMessage: msg,
 availableNeighbors: ['n1', 'n2'],
 onRelayMessage: (_, _) => callCount++,
);
 expect(callCount, 2);
 });
 });

 // ──────────────────────── RelayDecisionEngine ─────────────────────────────
 group('RelayDecisionEngine', () {
 late RelayDecisionEngine engine;
 late _FakeSeenStore seenStore;
 final logger = Logger('TestDecisionEngine');

 setUp(() {
 seenStore = _FakeSeenStore();
 engine = RelayDecisionEngine(logger: logger,
 seenMessageStore: seenStore,
 currentNodeId: 'my_node',
);
 });

 test('isDuplicate returns true for delivered messages', () {
 seenStore.deliver('msg_1');
 expect(engine.isDuplicate('msg_1'), isTrue);
 expect(engine.isDuplicate('msg_2'), isFalse);
 });

 test('isDuplicateId wraps string check', () {
 seenStore.deliver('msg_x');
 expect(engine.isDuplicateId(const MessageId('msg_x')), isTrue);
 });

 test('calculateRelayProbability returns 1.0 for small networks', () {
 expect(engine.calculateRelayProbability(), 1.0);
 });

 test('calculateRelayProbability returns 1.0 for ≤30 nodes (broadcast mode)',
 () {
 final analyzer = _FakeTopologyAnalyzer(30);
 engine.updateContext(currentNodeId: 'my_node',
 topologyAnalyzer: analyzer,
);
 expect(engine.calculateRelayProbability(), 1.0);
 },
);

 test('calculateRelayProbability returns 0.7 for ~50 nodes', () {
 final analyzer = _FakeTopologyAnalyzer(50);
 engine.updateContext(currentNodeId: 'my_node',
 topologyAnalyzer: analyzer,
);
 expect(engine.calculateRelayProbability(), 0.7);
 });

 test('calculateRelayProbability returns 0.55 for ~100 nodes', () {
 final analyzer = _FakeTopologyAnalyzer(100);
 engine.updateContext(currentNodeId: 'my_node',
 topologyAnalyzer: analyzer,
);
 expect(engine.calculateRelayProbability(), 0.55);
 });

 test('calculateRelayProbability returns 0.4 for >100 nodes', () {
 final analyzer = _FakeTopologyAnalyzer(200);
 engine.updateContext(currentNodeId: 'my_node',
 topologyAnalyzer: analyzer,
);
 expect(engine.calculateRelayProbability(), 0.4);
 });

 test('isMessageForCurrentNode matches node ID', () async {
 expect(await engine.isMessageForCurrentNode('my_node'), isTrue);
 });

 test('isMessageForCurrentNode matches persistent ID when configured',
 () async {
 engine.updateContext(currentNodeId: 'my_node',
 myPersistentId: 'persistent_abc',
);
 expect(await engine.isMessageForCurrentNode('persistent_abc'), isTrue);
 },
);

 test('isMessageForCurrentNode returns true for broadcast', () async {
 expect(await engine.isMessageForCurrentNode(SpecialRecipients.broadcast),
 isTrue,
);
 });

 test('isMessageForCurrentNode returns false for empty recipient', () async {
 expect(await engine.isMessageForCurrentNode(''), isFalse);
 });

 test('isMessageForCurrentNode returns false for other node', () async {
 expect(await engine.isMessageForCurrentNode('other_node'), isFalse);
 });

 test('shouldProbabilisticallySkip never skips when isForUs', () {
 expect(engine.shouldProbabilisticallySkip(isForUs: true,
 relayProbability: 0.0,
),
 isFalse,
);
 });

 test('shouldProbabilisticallySkip never skips at probability 1.0', () {
 expect(engine.shouldProbabilisticallySkip(isForUs: false,
 relayProbability: 1.0,
),
 isFalse,
);
 });

 test('chooseNextHop returns null for empty hops', () async {
 final msg = _buildRelay(recipient: 'dest');
 final hop = await engine.chooseNextHop(relayMessage: msg,
 availableHops: [],
);
 expect(hop, isNull);
 });

 test('chooseNextHop filters loop nodes', () async {
 final msg = _buildRelay(recipient: 'dest',
 routingPath: ['origin', 'loop_node'],
);
 final hop = await engine.chooseNextHop(relayMessage: msg,
 availableHops: ['loop_node'],
);
 expect(hop, isNull); // all hops are in path
 });

 test('chooseNextHop returns valid hop', () async {
 final msg = _buildRelay(recipient: 'dest');
 final hop = await engine.chooseNextHop(relayMessage: msg,
 availableHops: ['valid_hop'],
);
 expect(hop, 'valid_hop');
 });

 test('chooseNextHop uses routing service when available', () async {
 final routingService = _FakeRoutingService('best_hop');
 engine.updateContext(currentNodeId: 'my_node',
 routingService: routingService,
);
 final msg = _buildRelay(recipient: 'dest');
 final hop = await engine.chooseNextHop(relayMessage: msg,
 availableHops: ['best_hop', 'other_hop'],
);
 expect(hop, 'best_hop');
 });

 test('chooseNextHopId wraps string result', () async {
 final msg = _buildRelay(recipient: 'dest');
 final hop = await engine.chooseNextHopId(relayMessage: msg,
 availableHops: [const ChatId('hop_1')],
);
 expect(hop, const ChatId('hop_1'));
 });

 test('chooseNextHopId returns null for no hops', () async {
 final msg = _buildRelay(recipient: 'dest');
 final hop = await engine.chooseNextHopId(relayMessage: msg,
 availableHops: [],
);
 expect(hop, isNull);
 });

 test('updateContext preserves persistent ID when omitted', () async {
 engine.updateContext(currentNodeId: 'node_1',
 myPersistentId: 'persistent_abc',
);
 expect(await engine.isMessageForCurrentNode('node_1'), isTrue);
 expect(await engine.isMessageForCurrentNode('persistent_abc'), isTrue);

 engine.updateContext(currentNodeId: 'node_2');
 expect(await engine.isMessageForCurrentNode('node_1'), isFalse);
 expect(await engine.isMessageForCurrentNode('node_2'), isTrue);
 expect(await engine.isMessageForCurrentNode('persistent_abc'), isTrue);
 });
 });

 // ───────────────────────── QueuePolicyManager ─────────────────────────────
 group('QueuePolicyManager', () {
 test('isContactFavorite returns false with no repository', () async {
 final manager = QueuePolicyManager();
 expect(await manager.isContactFavorite('pk'), isFalse);
 });

 test('isContactFavorite delegates to repository', () async {
 final manager = QueuePolicyManager(repositoryProvider: _FakeRepoProvider(favoriteKeys: {'fav_pk'}),
);
 expect(await manager.isContactFavorite('fav_pk'), isTrue);
 expect(await manager.isContactFavorite('other'), isFalse);
 });

 test('getQueueLimit returns 500 for favorites, 100 for regular', () async {
 final manager = QueuePolicyManager(repositoryProvider: _FakeRepoProvider(favoriteKeys: {'fav'}),
);
 expect(await manager.getQueueLimit('fav'), 500);
 expect(await manager.getQueueLimit('reg'), 100);
 });

 test('applyFavoritesPriorityBoost boosts normal to high for favorites',
 () async {
 final manager = QueuePolicyManager(repositoryProvider: _FakeRepoProvider(favoriteKeys: {'fav'}),
);
 final result = await manager.applyFavoritesPriorityBoost(recipientPublicKey: 'fav',
 currentPriority: MessagePriority.normal,
);
 expect(result.wasBoosted, isTrue);
 expect(result.priority, MessagePriority.high);
 expect(result.isFavorite, isTrue);
 },
);

 test('applyFavoritesPriorityBoost boosts low to high for favorites',
 () async {
 final manager = QueuePolicyManager(repositoryProvider: _FakeRepoProvider(favoriteKeys: {'fav'}),
);
 final result = await manager.applyFavoritesPriorityBoost(recipientPublicKey: 'fav',
 currentPriority: MessagePriority.low,
);
 expect(result.wasBoosted, isTrue);
 expect(result.priority, MessagePriority.high);
 },
);

 test('applyFavoritesPriorityBoost does not boost urgent', () async {
 final manager = QueuePolicyManager(repositoryProvider: _FakeRepoProvider(favoriteKeys: {'fav'}),
);
 final result = await manager.applyFavoritesPriorityBoost(recipientPublicKey: 'fav',
 currentPriority: MessagePriority.urgent,
);
 expect(result.wasBoosted, isFalse);
 expect(result.priority, MessagePriority.urgent);
 });

 test('applyFavoritesPriorityBoost does not boost non-favorites', () async {
 final manager = QueuePolicyManager(repositoryProvider: _FakeRepoProvider(favoriteKeys: {}),
);
 final result = await manager.applyFavoritesPriorityBoost(recipientPublicKey: 'regular',
 currentPriority: MessagePriority.normal,
);
 expect(result.wasBoosted, isFalse);
 expect(result.isFavorite, isFalse);
 });

 test('validateQueueLimit allows when under limit', () async {
 final manager = QueuePolicyManager();
 final result = await manager.validateQueueLimit(recipientPublicKey: 'pk',
 allMessages: [],
);
 expect(result.isValid, isTrue);
 expect(result.currentCount, 0);
 expect(result.limit, 100);
 });

 test('validateQueueLimit blocks when at limit', () async {
 final manager = QueuePolicyManager();
 final messages = List.generate(100,
 (i) => _buildQueuedMessage('pk', QueuedMessageStatus.pending),
);
 final result = await manager.validateQueueLimit(recipientPublicKey: 'pk',
 allMessages: messages,
);
 expect(result.isValid, isFalse);
 expect(result.currentCount, 100);
 });

 test('validateQueueLimit ignores delivered/failed messages', () async {
 final manager = QueuePolicyManager();
 final messages = [
 _buildQueuedMessage('pk', QueuedMessageStatus.delivered),
 _buildQueuedMessage('pk', QueuedMessageStatus.failed),
 _buildQueuedMessage('pk', QueuedMessageStatus.pending),
];
 final result = await manager.validateQueueLimit(recipientPublicKey: 'pk',
 allMessages: messages,
);
 expect(result.isValid, isTrue);
 expect(result.currentCount, 1);
 });

 test('getStatistics counts peers correctly', () {
 final manager = QueuePolicyManager();
 final messages = [
 _buildQueuedMessage('pk1', QueuedMessageStatus.pending),
 _buildQueuedMessage('pk1', QueuedMessageStatus.pending),
 _buildQueuedMessage('pk2', QueuedMessageStatus.pending),
 _buildQueuedMessage('pk3', QueuedMessageStatus.delivered),
];
 final stats = manager.getStatistics(allMessages: messages);
 expect(stats.totalPeers, 2); // pk1 and pk2 (pk3 is delivered)
 expect(stats.hasRepositoryProvider, isFalse);
 });

 test('QueueLimitValidation getters work', () {
 const v = QueueLimitValidation(isValid: false,
 currentCount: 100,
 limit: 100,
 isFavorite: true,
);
 expect(v.limitType, 'favorite');
 expect(v.errorMessage, contains('favorite'));
 expect(v.errorMessage, contains('100/100'));
 });

 test('PolicyStatistics toString works', () {
 const s = PolicyStatistics(totalPeers: 5,
 maxMessagesPerPeer: 10,
 avgMessagesPerPeer: 4.2,
 hasRepositoryProvider: true,
);
 expect(s.toString(), contains('peers: 5'));
 });

 test('isContactFavorite handles repository error gracefully', () async {
 final manager = QueuePolicyManager(repositoryProvider: _ThrowingRepoProvider(),
);
 expect(await manager.isContactFavorite('pk'), isFalse);
 });
 });
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

MeshRelayMessage _buildRelay({
 required String recipient,
 String msgId = 'msg_001',
 int ttl = 5,
 int hopCount = 1,
 List<String>? routingPath,
}) {
 final metadata = RelayMetadata(ttl: ttl,
 hopCount: hopCount,
 routingPath: routingPath ?? const ['origin_node'],
 messageHash: 'sha256hash',
 priority: MessagePriority.normal,
 relayTimestamp: DateTime.now(),
 originalSender: 'origin_node',
 finalRecipient: recipient,
);
 return MeshRelayMessage(originalMessageId: msgId,
 originalContent: 'Hello mesh',
 relayMetadata: metadata,
 relayNodeId: 'origin_node',
 relayedAt: DateTime.now(),
);
}

QueuedMessage _buildQueuedMessage(String recipientKey,
 QueuedMessageStatus status,
) {
 return QueuedMessage(id: 'qm_${DateTime.now().microsecondsSinceEpoch}',
 chatId: 'chat_1',
 content: 'test',
 recipientPublicKey: recipientKey,
 senderPublicKey: 'sender',
 priority: MessagePriority.normal,
 status: status,
 queuedAt: DateTime.now(),
 maxRetries: 5,
);
}

// ─── Fakes ──────────────────────────────────────────────────────────────────

class _FakeSeenStore implements ISeenMessageStore {
 final Set<String> _delivered = {};
 void deliver(String id) => _delivered.add(id);

 @override
 Future<void> initialize() async {}
 @override
 bool hasDelivered(String messageId) => _delivered.contains(messageId);
 @override
 bool hasRead(String messageId) => false;
 @override
 Future<void> markDelivered(String messageId) async =>
 _delivered.add(messageId);
 @override
 Future<void> markRead(String messageId) async {}
 @override
 Map<String, dynamic> getStatistics() => {};
 @override
 Future<void> clear() async => _delivered.clear();
 @override
 Future<void> performMaintenance() async {}
}

class _FakeOfflineQueue implements OfflineMessageQueueContract {
 int queuedCount = 0;

 @override
 set onMessageQueued(Function(QueuedMessage)? callback) {}
 @override
 set onMessageDelivered(Function(QueuedMessage)? callback) {}
 @override
 set onMessageFailed(Function(QueuedMessage, String)? callback) {}
 @override
 set onStatsUpdated(Function(QueueStatistics)? callback) {}
 @override
 set onSendMessage(Function(String)? callback) {}
 @override
 set onConnectivityCheck(Function()? callback) {}

 @override
 Future<void> initialize({
 Function(QueuedMessage)? onMessageQueued,
 Function(QueuedMessage)? onMessageDelivered,
 Function(QueuedMessage, String)? onMessageFailed,
 Function(QueueStatistics)? onStatsUpdated,
 Function(String)? onSendMessage,
 Function()? onConnectivityCheck,
 }) async {}

 @override
 Future<String> queueMessage({
 required String chatId,
 required String content,
 required String recipientPublicKey,
 required String senderPublicKey,
 MessagePriority priority = MessagePriority.normal,
 String? replyToMessageId,
 List<String> attachments = const [],
 bool isRelayMessage = false,
 RelayMetadata? relayMetadata,
 String? originalMessageId,
 String? relayNodeId,
 String? messageHash,
 bool persistToStorage = true,
 }) async {
 queuedCount++;
 return 'queued_id';
 }

 @override
 Future<MessageId> queueMessageWithIds({
 required ChatId chatId,
 required String content,
 required ChatId recipientId,
 required ChatId senderId,
 MessagePriority priority = MessagePriority.normal,
 MessageId? replyToMessageId,
 List<String> attachments = const [],
 bool isRelayMessage = false,
 RelayMetadata? relayMetadata,
 String? originalMessageId,
 String? relayNodeId,
 String? messageHash,
 bool persistToStorage = true,
 }) async {
 queuedCount++;
 return const MessageId('queued_id');
 }

 @override
 Future<int> removeMessagesForChat(String chatId) async => 0;
 @override
 Future<void> setOnline() async {}
 @override
 void setOffline() {}
 @override
 Future<void> markMessageDelivered(String messageId) async {}
 @override
 Future<void> markMessageFailed(String messageId, String reason) async {}
 @override
 QueueStatistics getStatistics() => const QueueStatistics(totalQueued: 0,
 totalDelivered: 0,
 totalFailed: 0,
 pendingMessages: 0,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 0,
 isOnline: false,
 averageDeliveryTime: Duration.zero,
);
 @override
 Future<void> retryFailedMessages() async {}
 @override
 Future<void> retryFailedMessagesForChat(String chatId) async {}
 @override
 Future<void> clearQueue() async {}
 @override
 List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) => [];
 @override
 QueuedMessage? getMessageById(String messageId) => null;
 @override
 List<QueuedMessage> getPendingMessages() => [];
 @override
 Future<void> removeMessage(String messageId) async {}
 @override
 Future<void> flushQueueForPeer(String peerPublicKey) async {}
 @override
 Future<bool> changePriority(String messageId, MessagePriority p) async =>
 false;
 @override
 String calculateQueueHash({bool forceRecalculation = false}) => 'hash';
 @override
 QueueSyncMessage createSyncMessage(String nodeId) =>
 throw UnimplementedError();
 @override
 bool needsSynchronization(String otherQueueHash) => false;
 @override
 Future<void> addSyncedMessage(QueuedMessage message) async {}
 @override
 List<String> getMissingMessageIds(List<String> otherMessageIds) => [];
 @override
 List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) => [];
 @override
 Future<void> markMessageDeleted(String messageId) async {}
 @override
 bool isMessageDeleted(String messageId) => false;
 @override
 Future<void> cleanupOldDeletedIds() async {}
 @override
 void invalidateHashCache() {}
 @override
 Map<String, dynamic> getPerformanceStats() => {};
 @override
 void dispose() {}
}

class _FakeTopologyAnalyzer extends NetworkTopologyAnalyzer {
 final int _size;
 _FakeTopologyAnalyzer(this._size);

 @override
 int getNetworkSize() => _size;
}

class _FakeRoutingService implements IMeshRoutingService {
 final String _suggestedHop;
 _FakeRoutingService(this._suggestedHop);

 @override
 Future<RoutingDecision> determineOptimalRoute({
 required String finalRecipient,
 required List<String> availableHops,
 required MessagePriority priority,
 RouteOptimizationStrategy strategy = RouteOptimizationStrategy.balanced,
 }) async {
 if (availableHops.contains(_suggestedHop)) {
 return RoutingDecision.relay(_suggestedHop, [_suggestedHop], 0.9);
 }
 return RoutingDecision.failed('No match');
 }

 @override
 dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeRepoProvider implements IRepositoryProvider {
 final Set<String> favoriteKeys;
 _FakeRepoProvider({this.favoriteKeys = const {}});

 @override
 IContactRepository get contactRepository =>
 _FakeContactRepo(favoriteKeys: favoriteKeys);

 @override
 dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ThrowingRepoProvider implements IRepositoryProvider {
 @override
 IContactRepository get contactRepository => _ThrowingContactRepo();

 @override
 dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeContactRepo extends Fake implements IContactRepository {
 final Set<String> favoriteKeys;
 _FakeContactRepo({this.favoriteKeys = const {}});

 @override
 Future<bool> isContactFavorite(String publicKey) async =>
 favoriteKeys.contains(publicKey);
}

class _ThrowingContactRepo extends Fake implements IContactRepository {
 @override
 Future<bool> isContactFavorite(String publicKey) async =>
 throw Exception('repo error');
}
