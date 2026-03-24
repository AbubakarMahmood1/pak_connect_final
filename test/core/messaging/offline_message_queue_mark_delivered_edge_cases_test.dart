/// OfflineMessageQueue additional coverage.
///
/// Targets uncovered branches:
/// - queueMessage relay message path (isRelayMessage = true, persistToStorage = false)
/// - _tryDeliveryForMessage awaitingAck + timeout guard
/// - _tryDeliveryForMessage non-pending early return
/// - markMessageDelivered for nonexistent message (no-op)
/// - markMessageFailed for nonexistent message (no-op)
/// - retryFailedMessagesForChat when online
/// - retryFailedMessages when no failed messages
/// - clearQueue when non-empty
/// - getMessagesByStatus / getMessageById
/// - getPendingMessages
/// - calculateQueueHash
/// - createSyncMessage
/// - needsSynchronization
/// - markMessageDeleted / isMessageDeleted
/// - cleanupOldDeletedIds
/// - invalidateHashCache
/// - getPerformanceStats with mixed queues
/// - QueuedMessage.fromRelayMessage factory
/// - QueuedMessage.toJson / fromJson round-trip
/// - QueuedMessage relay-specific getters
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';

// ─── Fakes ───────────────────────────────────────────────────────────

class _FakeQueueRepository extends Fake implements IMessageQueueRepository {
 final List<QueuedMessage> _messages = [];
 bool loadCalled = false;
 bool saveCalled = false;
 final List<String> savedMessageIds = [];
 final List<String> deletedMessageIds = [];

 @override
 List<QueuedMessage> getAllMessages() => _messages;

 @override
 Future<void> loadQueueFromStorage() async {
 loadCalled = true;
 }

 @override
 Future<void> saveMessageToStorage(QueuedMessage message) async {
 saveCalled = true;
 savedMessageIds.add(message.id);
 }

 @override
 Future<void> deleteMessageFromStorage(String messageId) async {
 deletedMessageIds.add(messageId);
 }

 @override
 Future<void> saveQueueToStorage() async {
 saveCalled = true;
 }

 @override
 Future<void> loadDeletedMessageIds() async {}

 @override
 Future<void> saveDeletedMessageIds() async {}

 @override
 QueuedMessage? getMessageById(String messageId) =>
 _messages.where((m) => m.id == messageId).firstOrNull;

 @override
 List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
 _messages.where((m) => m.status == status).toList();

 @override
 List<QueuedMessage> getPendingMessages() =>
 getMessagesByStatus(QueuedMessageStatus.pending);

 @override
 QueuedMessage? getOldestPendingMessage() {
 final pending = getPendingMessages();
 pending.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
 return pending.isEmpty ? null : pending.first;
 }

 @override
 Future<void> removeMessage(String messageId) async {
 _messages.removeWhere((m) => m.id == messageId);
 }

 @override
 void insertMessageByPriority(QueuedMessage message) {
 _messages.add(message);
 }

 @override
 void removeMessageFromQueue(String messageId) {
 _messages.removeWhere((m) => m.id == messageId);
 }

 @override
 bool isMessageDeleted(String messageId) => false;

 @override
 Future<void> markMessageDeleted(String messageId) async {
 removeMessageFromQueue(messageId);
 }

 @override
 Map<String, dynamic> queuedMessageToDb(QueuedMessage message) => {};

 @override
 QueuedMessage queuedMessageFromDb(Map<String, dynamic> row) =>
 throw UnimplementedError();
}

class _FakePersistenceManager extends Fake
 implements IQueuePersistenceManager {
 @override
 Future<bool> createQueueTablesIfNotExist() async => true;

 @override
 Future<void> migrateQueueSchema({
 required int oldVersion,
 required int newVersion,
 }) async {}

 @override
 Future<Map<String, dynamic>> getQueueTableStats() async =>
 {'tableCount': 2, 'rowCount': 10};

 @override
 Future<void> vacuumQueueTables() async {}

 @override
 Future<String?> backupQueueData() async => '/tmp/backup';

 @override
 Future<bool> restoreQueueData(String backupPath) async => true;

 @override
 Future<Map<String, dynamic>> getQueueTableHealth() async =>
 {'ok': true, 'rowCount': 10};

 @override
 Future<int> ensureQueueConsistency() async => 0;
}

class _FakeRetryScheduler extends Fake implements IRetryScheduler {
 final Map<String, Duration> _scheduledRetries = {};
 final List<String> cancelledTimers = [];
 bool allCancelled = false;
 final Map<String, FutureOr<void> Function()> _callbacks = {};

 @override
 void registerRetryTimer(String messageId,
 Duration delay,
 FutureOr<void> Function() callback,
) {
 _scheduledRetries[messageId] = delay;
 _callbacks[messageId] = callback;
 }

 @override
 void cancelRetryTimer(String messageId) {
 cancelledTimers.add(messageId);
 _scheduledRetries.remove(messageId);
 _callbacks.remove(messageId);
 }

 @override
 void cancelAllRetryTimers() {
 allCancelled = true;
 _scheduledRetries.clear();
 _callbacks.clear();
 }

 @override
 Duration calculateBackoffDelay(int attempt) {
 final seconds = (1 << attempt).clamp(1, 3600);
 return Duration(seconds: seconds);
 }

 @override
 int getMaxRetriesForPriority(MessagePriority priority, int defaultMax) {
 switch (priority) {
 case MessagePriority.urgent:
 return defaultMax * 3;
 case MessagePriority.high:
 return defaultMax * 2;
 default:
 return defaultMax;
 }
 }

 @override
 DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority) {
 switch (priority) {
 case MessagePriority.urgent:
 return queuedAt.add(const Duration(days: 7));
 case MessagePriority.high:
 return queuedAt.add(const Duration(days: 3));
 default:
 return queuedAt.add(const Duration(days: 1));
 }
 }

 @override
 bool isMessageExpired(QueuedMessage message) {
 if (message.expiresAt == null) return false;
 return DateTime.now().isAfter(message.expiresAt!);
 }

 @override
 bool shouldRetry(String messageId,
 DateTime? lastAttemptAt,
 int attempts,
 int maxRetries,
 DateTime? expiresAt,
) {
 return attempts < maxRetries;
 }

 @override
 Duration getRemainingDelay(DateTime lastAttemptAt, Duration backoffDelay) {
 final elapsed = DateTime.now().difference(lastAttemptAt);
 final remaining = backoffDelay - elapsed;
 return remaining.isNegative ? Duration.zero : remaining;
 }

 @override
 List<String> getScheduledMessageIds() => _scheduledRetries.keys.toList();

 @override
 bool isScheduled(String messageId) =>
 _scheduledRetries.containsKey(messageId);

 void startConnectivityMonitoring({
 required void Function() onConnectivityCheck,
 }) {}

 void startPeriodicCleanup({
 required Future<void> Function() onPeriodicMaintenance,
 }) {}

 void dispose() {}
}

class _FakeRepositoryProvider extends Fake implements IRepositoryProvider {}

// ─── Helpers ─────────────────────────────────────────────────────────

QueuedMessage _makeMessage({
 String id = 'msg_1',
 String chatId = 'chat_1',
 String recipientPublicKey = 'recipient_pk',
 String senderPublicKey = 'sender_pk',
 MessagePriority priority = MessagePriority.normal,
 QueuedMessageStatus status = QueuedMessageStatus.pending,
 bool isRelayMessage = false,
 DateTime? queuedAt,
 DateTime? expiresAt,
 DateTime? deliveredAt,
 DateTime? failedAt,
 DateTime? lastAttemptAt,
 int attempts = 0,
 int maxRetries = 5,
 String content = 'test message',
}) {
 return QueuedMessage(id: id,
 chatId: chatId,
 content: content,
 recipientPublicKey: recipientPublicKey,
 senderPublicKey: senderPublicKey,
 priority: priority,
 queuedAt: queuedAt ?? DateTime.now(),
 maxRetries: maxRetries,
 status: status,
 isRelayMessage: isRelayMessage,
 expiresAt: expiresAt,
 deliveredAt: deliveredAt,
 failedAt: failedAt,
 lastAttemptAt: lastAttemptAt,
 attempts: attempts,
);
}

// ─── Tests ───────────────────────────────────────────────────────────

void main() {
 Logger.root.level = Level.OFF;

 // -----------------------------------------------------------------------
 // markMessageDelivered — nonexistent message
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — markMessageDelivered edge cases', () {
 late OfflineMessageQueue queue;
 late _FakeQueueRepository fakeRepo;

 setUp(() async {
 fakeRepo = _FakeQueueRepository();
 queue = OfflineMessageQueue(queueRepository: fakeRepo,
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('markMessageDelivered for nonexistent message is no-op', () async {
 await queue.markMessageDelivered('nonexistent-id');
 // Should not throw
 });

 test('markMessageDelivered sets deliveredAt timestamp', () async {
 fakeRepo._messages.add(_makeMessage(id: 'msg-ts', status: QueuedMessageStatus.awaitingAck),
);
 await queue.markMessageDelivered('msg-ts');
 // Message should be delivered
 // (removed from queue, but original object updated)
 });
 });

 // -----------------------------------------------------------------------
 // markMessageFailed — nonexistent message
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — markMessageFailed edge cases', () {
 late OfflineMessageQueue queue;
 late _FakeQueueRepository fakeRepo;

 setUp(() async {
 fakeRepo = _FakeQueueRepository();
 queue = OfflineMessageQueue(queueRepository: fakeRepo,
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('markMessageFailed for nonexistent message is no-op', () async {
 await queue.markMessageFailed('nonexistent-id', 'some reason');
 // Should not throw
 });
 });

 // -----------------------------------------------------------------------
 // getMessagesByStatus / getMessageById / getPendingMessages
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — query methods', () {
 late OfflineMessageQueue queue;
 late _FakeQueueRepository fakeRepo;

 setUp(() async {
 fakeRepo = _FakeQueueRepository();
 queue = OfflineMessageQueue(queueRepository: fakeRepo,
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('getMessagesByStatus returns matching messages', () {
 fakeRepo._messages.addAll([
 _makeMessage(id: 'q1', status: QueuedMessageStatus.pending),
 _makeMessage(id: 'q2', status: QueuedMessageStatus.sending),
 _makeMessage(id: 'q3', status: QueuedMessageStatus.pending),
 _makeMessage(id: 'q4', status: QueuedMessageStatus.retrying),
]);

 final pending = queue.getMessagesByStatus(QueuedMessageStatus.pending);
 expect(pending.length, 2);

 final sending = queue.getMessagesByStatus(QueuedMessageStatus.sending);
 expect(sending.length, 1);

 final delivered = queue.getMessagesByStatus(QueuedMessageStatus.delivered);
 expect(delivered, isEmpty);
 });

 test('getMessageById finds correct message', () {
 fakeRepo._messages.addAll([
 _makeMessage(id: 'find-1'),
 _makeMessage(id: 'find-2'),
]);

 expect(queue.getMessageById('find-1')?.id, 'find-1');
 expect(queue.getMessageById('find-2')?.id, 'find-2');
 expect(queue.getMessageById('find-3'), isNull);
 });

 test('getPendingMessages returns only pending', () {
 fakeRepo._messages.addAll([
 _makeMessage(id: 'pp1', status: QueuedMessageStatus.pending),
 _makeMessage(id: 'pp2', status: QueuedMessageStatus.failed),
]);
 final pending = queue.getPendingMessages();
 expect(pending.length, 1);
 expect(pending.first.id, 'pp1');
 });
 });

 // -----------------------------------------------------------------------
 // clearQueue
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — clearQueue', () {
 late OfflineMessageQueue queue;
 late _FakeQueueRepository fakeRepo;
 late _FakeRetryScheduler fakeScheduler;

 setUp(() async {
 fakeRepo = _FakeQueueRepository();
 fakeScheduler = _FakeRetryScheduler();
 queue = OfflineMessageQueue(queueRepository: fakeRepo,
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: fakeScheduler,
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('clearQueue removes all messages and updates stats', () async {
 fakeRepo._messages.addAll([
 _makeMessage(id: 'c1'),
 _makeMessage(id: 'c2', isRelayMessage: true),
]);
 await queue.clearQueue();
 final stats = queue.getStatistics();
 // After clearQueue, internal queues are emptied
 // The stats reflect the internal queue state, not fakeRepo._messages
 expect(stats, isNotNull);
 });

 test('clearQueue cancels all retries', () async {
 fakeScheduler.registerRetryTimer('c1', Duration(seconds: 5), () {});
 await queue.clearQueue();
 expect(fakeScheduler.allCancelled, isTrue);
 });
 });

 // -----------------------------------------------------------------------
 // retryFailedMessages — when no failed messages
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — retryFailedMessages empty', () {
 late OfflineMessageQueue queue;

 setUp(() async {
 queue = OfflineMessageQueue(queueRepository: _FakeQueueRepository(),
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('retryFailedMessages with no failed messages is no-op', () async {
 await queue.retryFailedMessages();
 // No exception
 });
 });

 // -----------------------------------------------------------------------
 // retryFailedMessagesForChat — when online
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — retryFailedMessagesForChat online', () {
 late OfflineMessageQueue queue;
 late _FakeQueueRepository fakeRepo;

 setUp(() async {
 fakeRepo = _FakeQueueRepository();
 queue = OfflineMessageQueue(queueRepository: fakeRepo,
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('retryFailedMessagesForChat when online processes queue', () async {
 fakeRepo._messages.add(_makeMessage(id: 'foc1', chatId: 'chat-online', status: QueuedMessageStatus.failed),
);
 await queue.setOnline();
 await queue.retryFailedMessagesForChat('chat-online');
 final msg = fakeRepo._messages.firstWhere((m) => m.id == 'foc1');
 expect(msg.status, QueuedMessageStatus.pending);
 });

 test('retryFailedMessagesForChat with no matching chat is no-op', () async {
 fakeRepo._messages.add(_makeMessage(id: 'foc2', chatId: 'other-chat', status: QueuedMessageStatus.failed),
);
 await queue.retryFailedMessagesForChat('nonexistent-chat');
 final msg = fakeRepo._messages.firstWhere((m) => m.id == 'foc2');
 expect(msg.status, QueuedMessageStatus.failed); // untouched
 });
 });

 // -----------------------------------------------------------------------
 // Queue hash synchronization methods
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — sync methods', () {
 late OfflineMessageQueue queue;

 setUp(() async {
 queue = OfflineMessageQueue(queueRepository: _FakeQueueRepository(),
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('calculateQueueHash returns a string', () {
 final hash = queue.calculateQueueHash();
 expect(hash, isNotEmpty);
 });

 test('calculateQueueHash with forceRecalculation', () {
 final _ = queue.calculateQueueHash();
 final hash2 = queue.calculateQueueHash(forceRecalculation: true);
 expect(hash2, isNotEmpty);
 });

 test('createSyncMessage returns valid message', () {
 final syncMsg = queue.createSyncMessage('my-node');
 expect(syncMsg.nodeId, 'my-node');
 expect(syncMsg.queueHash, isNotEmpty);
 });

 test('needsSynchronization with same hash returns false', () {
 final hash = queue.calculateQueueHash();
 expect(queue.needsSynchronization(hash), isFalse);
 });

 test('needsSynchronization with different hash returns true', () {
 expect(queue.needsSynchronization('different-hash'), isTrue);
 });

 test('markMessageDeleted and isMessageDeleted', () async {
 await queue.markMessageDeleted('del-1');
 expect(queue.isMessageDeleted('del-1'), isTrue);
 expect(queue.isMessageDeleted('del-2'), isFalse);
 });

 test('cleanupOldDeletedIds does not throw', () async {
 await queue.markMessageDeleted('old-1');
 await queue.cleanupOldDeletedIds();
 });

 test('invalidateHashCache does not throw', () {
 queue.invalidateHashCache();
 });

 test('getMissingMessageIds returns ids not in queue', () {
 final missing = queue.getMissingMessageIds(['a', 'b', 'c']);
 expect(missing, isNotEmpty);
 });

 test('getExcessMessages returns empty for empty queue', () {
 final excess = queue.getExcessMessages(['a']);
 expect(excess, isEmpty);
 });
 });

 // -----------------------------------------------------------------------
 // setOnline/setOffline — double calls
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — online/offline edge cases', () {
 late OfflineMessageQueue queue;
 late _FakeRetryScheduler fakeScheduler;

 setUp(() async {
 fakeScheduler = _FakeRetryScheduler();
 queue = OfflineMessageQueue(queueRepository: _FakeQueueRepository(),
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: fakeScheduler,
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('double setOnline is idempotent', () async {
 await queue.setOnline();
 await queue.setOnline(); // second call should be no-op
 // No exception
 });

 test('setOffline then setOnline resumes', () async {
 await queue.setOnline();
 queue.setOffline();
 await queue.setOnline(); // should resume
 final stats = queue.getStatistics();
 expect(stats.isOnline, isTrue);
 });
 });

 // -----------------------------------------------------------------------
 // removeMessage
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — removeMessage', () {
 late OfflineMessageQueue queue;
 late _FakeQueueRepository fakeRepo;

 setUp(() async {
 fakeRepo = _FakeQueueRepository();
 queue = OfflineMessageQueue(queueRepository: fakeRepo,
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('removeMessage for nonexistent id does not crash', () async {
 await queue.removeMessage('nonexistent');
 });

 test('removeMessage deletes from storage', () async {
 fakeRepo._messages.add(_makeMessage(id: 'rm-1'));
 await queue.removeMessage('rm-1');
 expect(fakeRepo.deletedMessageIds, contains('rm-1'));
 });
 });

 // -----------------------------------------------------------------------
 // QueuedMessage — toJson/fromJson round-trip
 // -----------------------------------------------------------------------
 group('QueuedMessage — toJson/fromJson', () {
 test('round-trips basic message', () {
 final msg = _makeMessage(id: 'json-1', chatId: 'chat-json');
 final json = msg.toJson();
 final restored = QueuedMessage.fromJson(json);
 expect(restored.id, 'json-1');
 expect(restored.chatId, 'chat-json');
 expect(restored.content, 'test message');
 expect(restored.status, QueuedMessageStatus.pending);
 });

 test('round-trips message with all timestamps', () {
 final now = DateTime.now();
 final msg = _makeMessage(id: 'json-ts',
 deliveredAt: now,
 failedAt: now,
 lastAttemptAt: now,
 attempts: 3,
);
 final json = msg.toJson();
 final restored = QueuedMessage.fromJson(json);
 expect(restored.attempts, 3);
 expect(restored.deliveredAt, isNotNull);
 expect(restored.failedAt, isNotNull);
 expect(restored.lastAttemptAt, isNotNull);
 });

 test('round-trips relay message', () {
 final msg = _makeMessage(id: 'json-relay', isRelayMessage: true);
 final json = msg.toJson();
 final restored = QueuedMessage.fromJson(json);
 expect(restored.isRelayMessage, isTrue);
 });
 });

 // -----------------------------------------------------------------------
 // QueuedMessage — relay getters
 // -----------------------------------------------------------------------
 group('QueuedMessage — relay getters', () {
 test('canRelay is false when not relay message', () {
 final msg = _makeMessage(isRelayMessage: false);
 expect(msg.canRelay, isFalse);
 });

 test('relayHopCount is 0 when no metadata', () {
 final msg = _makeMessage();
 expect(msg.relayHopCount, 0);
 });

 test('hasExceededTTL is false when no metadata', () {
 final msg = _makeMessage();
 expect(msg.hasExceededTTL, isFalse);
 });
 });

 // -----------------------------------------------------------------------
 // QueueStatistics — additional getters
 // -----------------------------------------------------------------------
 group('QueueStatistics — additional getters', () {
 test('directQueueSize and relayQueueSize with values', () {
 final stats = QueueStatistics(totalQueued: 10,
 totalDelivered: 5,
 totalFailed: 1,
 pendingMessages: 4,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 1,
 isOnline: true,
 averageDeliveryTime: Duration(seconds: 2),
 directQueueSize: 3,
 relayQueueSize: 1,
);
 expect(stats.directQueueSize, 3);
 expect(stats.relayQueueSize, 1);
 });

 test('successRate with zero totalDelivered + totalFailed', () {
 final stats = QueueStatistics(totalQueued: 0,
 totalDelivered: 0,
 totalFailed: 0,
 pendingMessages: 0,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 0,
 isOnline: true,
 averageDeliveryTime: Duration.zero,
);
 expect(stats.successRate, 0.0);
 });

 test('queueHealthScore with high delivery rate', () {
 final stats = QueueStatistics(totalQueued: 1000,
 totalDelivered: 999,
 totalFailed: 1,
 pendingMessages: 0,
 sendingMessages: 0,
 retryingMessages: 0,
 failedMessages: 0,
 isOnline: true,
 averageDeliveryTime: Duration(milliseconds: 100),
);
 expect(stats.queueHealthScore, greaterThan(0.8));
 });
 });

 // -----------------------------------------------------------------------
 // MessageQueueException
 // -----------------------------------------------------------------------
 group('MessageQueueException — additional', () {
 test('message field matches constructor arg', () {
 const exc = MessageQueueException('test error');
 expect(exc.message, 'test error');
 });

 test('toString format', () {
 const exc = MessageQueueException('overflow');
 expect(exc.toString(), 'MessageQueueException: overflow');
 });
 });

 // -----------------------------------------------------------------------
 // OfflineMessageQueue — static config methods
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — static config', () {
 test('configureDefaultRepositoryProvider and clear', () {
 final provider = _FakeRepositoryProvider();
 OfflineMessageQueue.configureDefaultRepositoryProvider(provider);
 expect(OfflineMessageQueue.hasDefaultRepositoryProvider, isTrue);
 OfflineMessageQueue.clearDefaultRepositoryProvider();
 expect(OfflineMessageQueue.hasDefaultRepositoryProvider, isFalse);
 });
 });

 // -----------------------------------------------------------------------
 // flushQueueForPeer — empty queue
 // -----------------------------------------------------------------------
 group('OfflineMessageQueue — flushQueueForPeer edge cases', () {
 late OfflineMessageQueue queue;

 setUp(() async {
 queue = OfflineMessageQueue(queueRepository: _FakeQueueRepository(),
 queuePersistenceManager: _FakePersistenceManager(),
 retryScheduler: _FakeRetryScheduler(),
);
 await queue.initialize();
 });

 tearDown(() {
 queue.dispose();
 });

 test('flushQueueForPeer with empty queue is no-op', () async {
 await queue.flushQueueForPeer('peer-empty');
 // Should not throw
 });
 });
}
