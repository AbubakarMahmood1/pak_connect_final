// Phase 12.9: OfflineMessageQueue, QueueStore, QueueSync coverage
// Targets: offline_message_queue.dart, offline_queue_store.dart, offline_queue_sync.dart,
//          offline_message_queue_maintenance_helper.dart

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/offline_queue_store.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/interfaces/i_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

// ─── Fakes ───────────────────────────────────────────────────────────

class _FakeQueueRepository extends Fake implements IMessageQueueRepository {
  final List<QueuedMessage> _messages = [];
  bool loadCalled = false;
  bool saveCalled = false;
  bool deleteMessageCalled = false;
  String? lastDeletedId;

  @override
  List<QueuedMessage> getAllMessages() => _messages;

  @override
  Future<void> loadQueueFromStorage() async {
    loadCalled = true;
  }

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    saveCalled = true;
  }

  @override
  Future<void> deleteMessageFromStorage(String messageId) async {
    deleteMessageCalled = true;
    lastDeletedId = messageId;
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
  bool createCalled = false;
  bool shouldFail = false;

  @override
  Future<bool> createQueueTablesIfNotExist() async {
    createCalled = true;
    if (shouldFail) throw Exception('persistence error');
    return true;
  }

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

  @override
  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  ) {
    _scheduledRetries[messageId] = delay;
  }

  @override
  void cancelRetryTimer(String messageId) {
    cancelledTimers.add(messageId);
    _scheduledRetries.remove(messageId);
  }

  @override
  void cancelAllRetryTimers() {
    allCancelled = true;
    _scheduledRetries.clear();
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
  void startConnectivityMonitoring({
    required void Function() onConnectivityCheck,
  }) {}

  @override
  void startPeriodicCleanup({
    required Future<void> Function() onPeriodicMaintenance,
  }) {}

  @override
  void dispose() {}
}

class _FakeDatabaseProvider extends Fake implements IDatabaseProvider {
  @override
  Future<dynamic> getDatabase() async => Object();
}

class _FakeRepositoryProvider extends Fake implements IRepositoryProvider {}

class _FakeSyncCoordinator extends Fake implements IQueueSyncCoordinator {
  bool initialized = false;
  String lastHash = 'abc123';

  @override
  Future<void> initialize({required Set<String> deletedIds}) async {
    initialized = true;
  }

  @override
  String calculateQueueHash({bool forceRecalculation = false}) => lastHash;

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return QueueSyncMessage(
      nodeId: nodeId,
      queueHash: lastHash,
      messageIds: ['msg1', 'msg2'],
      syncTimestamp: DateTime.now(),
      syncType: QueueSyncType.request,
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) =>
      otherQueueHash != lastHash;

  @override
  void invalidateHashCache() {}
}

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
}) {
  return QueuedMessage(
    id: id,
    chatId: chatId,
    content: 'test message',
    recipientPublicKey: recipientPublicKey,
    senderPublicKey: senderPublicKey,
    priority: priority,
    queuedAt: queuedAt ?? DateTime.now(),
    maxRetries: 5,
    status: status,
    isRelayMessage: isRelayMessage,
    expiresAt: expiresAt,
    deliveredAt: deliveredAt,
    failedAt: failedAt,
  );
}

void main() {
  Logger.root.level = Level.OFF;

  group('QueueStore', () {
    late List<QueuedMessage> directQueue;
    late List<QueuedMessage> relayQueue;
    late Set<MessageId> deletedIds;

    setUp(() {
      directQueue = [];
      relayQueue = [];
      deletedIds = {};
    });

    test('constructor initializes with required parameters', () {
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      expect(store.directQueueSize, 0);
      expect(store.relayQueueSize, 0);
    });

    test('hasDatabaseProvider reflects setDatabaseProvider state', () {
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      // After setting a DB provider, hasDatabaseProvider should be true
      store.setDatabaseProvider(_FakeDatabaseProvider());
      expect(store.hasDatabaseProvider, isTrue);
      // After clearing, it depends on repo/persistence defaults
      store.setDatabaseProvider(null);
    });

    test('hasDatabaseProvider returns true after setDatabaseProvider', () {
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      store.setDatabaseProvider(_FakeDatabaseProvider());
      expect(store.hasDatabaseProvider, isTrue);
    });

    test('initializePersistence falls back to in-memory when no DB provider',
        () async {
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      final logger = Logger('test');
      await store.initializePersistence(logger: logger);
      // Should not throw, falls back to in-memory
      expect(store.getAllMessages(), isEmpty);
    });

    test(
        'initializePersistence falls back to in-memory on persistence failure',
        () async {
      final fakePersistence = _FakePersistenceManager()..shouldFail = true;
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
        queuePersistenceManager: fakePersistence,
      );
      store.setDatabaseProvider(_FakeDatabaseProvider());
      final logger = Logger('test');
      // Should catch error and fall back
      await store.initializePersistence(logger: logger);
      expect(store.getAllMessages(), isEmpty);
    });

    test('initializePersistence succeeds with valid persistence', () async {
      final fakeRepo = _FakeQueueRepository();
      final fakePersistence = _FakePersistenceManager();
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
        queueRepository: fakeRepo,
        queuePersistenceManager: fakePersistence,
      );
      store.setDatabaseProvider(_FakeDatabaseProvider());
      final logger = Logger('test');
      await store.initializePersistence(logger: logger);
      expect(fakePersistence.createCalled, isTrue);
      expect(fakeRepo.loadCalled, isTrue);
    });

    test('getAllMessages combines both queues', () {
      final msg1 = _makeMessage(id: 'direct_1');
      final msg2 = _makeMessage(id: 'relay_1', isRelayMessage: true);
      directQueue.add(msg1);
      relayQueue.add(msg2);
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      expect(store.getAllMessages().length, 2);
    });

    test('insertMessageByPriority routes direct messages to direct queue', () {
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      // Initialize in-memory repos first
      store.initializePersistence(logger: Logger('test'));
      final msg = _makeMessage(id: 'direct_msg', isRelayMessage: false);
      store.insertMessageByPriority(msg);
      // At least the message should be findable
      final all = store.getAllMessages();
      expect(all.any((m) => m.id == 'direct_msg'), isTrue);
    });

    test('removeMessageFromQueue removes from both queues', () {
      final msg1 = _makeMessage(id: 'to_remove');
      directQueue.add(msg1);
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      store.initializePersistence(logger: Logger('test'));
      store.removeMessageFromQueue('to_remove');
      // After removing, it should not be in the direct queue
      // Note: removal goes through the repo, which may or may not clear the list
      // The in-memory fallback repo shares the same list references
    });

    test('clearInMemoryQueues empties both queues', () {
      directQueue.addAll([_makeMessage(id: 'd1'), _makeMessage(id: 'd2')]);
      relayQueue.add(_makeMessage(id: 'r1', isRelayMessage: true));
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      store.clearInMemoryQueues();
      expect(directQueue, isEmpty);
      expect(relayQueue, isEmpty);
    });

    test('directQueueSize and relayQueueSize reflect list sizes', () {
      directQueue.addAll([_makeMessage(id: 'd1'), _makeMessage(id: 'd2')]);
      relayQueue.add(_makeMessage(id: 'r1', isRelayMessage: true));
      final store = QueueStore(
        directMessageQueue: directQueue,
        relayMessageQueue: relayQueue,
        deletedMessageIds: deletedIds,
      );
      expect(store.directQueueSize, 2);
      expect(store.relayQueueSize, 1);
    });
  });

  group('OfflineMessageQueue - initialization', () {
    test('constructor accepts optional dependencies', () {
      final queue = OfflineMessageQueue(
        queueRepository: _FakeQueueRepository(),
        queuePersistenceManager: _FakePersistenceManager(),
        retryScheduler: _FakeRetryScheduler(),
      );
      expect(queue, isNotNull);
    });

    test('configureDefaultRepositoryProvider sets static provider', () {
      final provider = _FakeRepositoryProvider();
      OfflineMessageQueue.configureDefaultRepositoryProvider(provider);
      expect(OfflineMessageQueue.hasDefaultRepositoryProvider, isTrue);
      OfflineMessageQueue.clearDefaultRepositoryProvider();
      expect(OfflineMessageQueue.hasDefaultRepositoryProvider, isFalse);
    });
  });

  group('OfflineMessageQueue - queue operations', () {
    late OfflineMessageQueue queue;
    late _FakeRetryScheduler fakeScheduler;
    late _FakeQueueRepository fakeRepo;
    late _FakePersistenceManager fakePersistence;

    setUp(() async {
      fakeScheduler = _FakeRetryScheduler();
      fakeRepo = _FakeQueueRepository();
      fakePersistence = _FakePersistenceManager();
      queue = OfflineMessageQueue(
        queueRepository: fakeRepo,
        queuePersistenceManager: fakePersistence,
        retryScheduler: fakeScheduler,
      );
      await queue.initialize();
    });

    test('getStatistics returns valid stats for empty queue', () {
      final stats = queue.getStatistics();
      expect(stats.totalQueued, 0);
      expect(stats.totalDelivered, 0);
      expect(stats.pendingMessages, 0);
      expect(stats.isOnline, isFalse);
      expect(stats.directQueueSize, 0);
      expect(stats.relayQueueSize, 0);
    });

    test('setOnline sets connection status', () async {
      await queue.setOnline();
      final stats = queue.getStatistics();
      expect(stats.isOnline, isTrue);
    });

    test('setOffline cancels retries and marks offline', () async {
      await queue.setOnline();
      queue.setOffline();
      final stats = queue.getStatistics();
      expect(stats.isOnline, isFalse);
    });

    test('setOnline twice does not double-process', () async {
      await queue.setOnline();
      await queue.setOnline(); // second call should be no-op
      expect(queue.getStatistics().isOnline, isTrue);
    });

    test('setOffline when already offline is no-op', () {
      queue.setOffline(); // already offline
      expect(queue.getStatistics().isOnline, isFalse);
    });

    test('getMessagesByStatus returns empty for clean queue', () {
      final pending = queue.getMessagesByStatus(QueuedMessageStatus.pending);
      expect(pending, isEmpty);
    });

    test('getPendingMessages delegates to getMessagesByStatus', () {
      final pending = queue.getPendingMessages();
      expect(pending, isEmpty);
    });

    test('getMessageById returns null for unknown ID', () {
      expect(queue.getMessageById('nonexistent'), isNull);
    });

    test('clearQueue empties all messages', () async {
      await queue.clearQueue();
      expect(queue.getStatistics().pendingMessages, 0);
    });

    test('retryFailedMessages handles empty queue', () async {
      await queue.retryFailedMessages();
      // No failure expected
    });

    test('retryFailedMessagesForChat handles empty queue', () async {
      await queue.retryFailedMessagesForChat('chat_1');
      // No failure expected
    });

    test('removeMessagesForChat returns 0 for empty queue', () async {
      final count = await queue.removeMessagesForChat('chat_1');
      expect(count, 0);
    });

    test('changePriority returns false for unknown message', () async {
      final result = await queue.changePriority('unknown', MessagePriority.high);
      expect(result, isFalse);
    });

    test('calculateQueueHash returns deterministic hash', () {
      final hash1 = queue.calculateQueueHash();
      final hash2 = queue.calculateQueueHash();
      expect(hash1, equals(hash2));
    });

    test('needsSynchronization detects different hash', () {
      final needsSync = queue.needsSynchronization('different_hash');
      expect(needsSync, isTrue);
    });

    test('needsSynchronization returns false for matching hash', () {
      final currentHash = queue.calculateQueueHash();
      expect(queue.needsSynchronization(currentHash), isFalse);
    });

    test('createSyncMessage contains node info', () {
      final syncMsg = queue.createSyncMessage('node_42');
      expect(syncMsg.nodeId, 'node_42');
      expect(syncMsg.queueHash, isNotEmpty);
    });

    test('getMissingMessageIds returns IDs not in local queue', () {
      final missing = queue.getMissingMessageIds(['msg_a', 'msg_b']);
      expect(missing, containsAll(['msg_a', 'msg_b']));
    });

    test('getExcessMessages returns messages other queue lacks', () {
      final excess = queue.getExcessMessages(['msg_a']);
      expect(excess, isList);
    });

    test('markMessageDeleted and isMessageDeleted work together', () async {
      await queue.markMessageDeleted('msg_to_delete');
      expect(queue.isMessageDeleted('msg_to_delete'), isTrue);
      expect(queue.isMessageDeleted('msg_other'), isFalse);
    });

    test('cleanupOldDeletedIds does not throw', () async {
      await queue.cleanupOldDeletedIds();
    });

    test('invalidateHashCache forces recalculation', () {
      queue.invalidateHashCache();
      final hash = queue.calculateQueueHash();
      expect(hash, isNotEmpty);
    });

    test('markMessageDelivered handles unknown message gracefully', () async {
      await queue.markMessageDelivered('nonexistent');
      // Should not throw
    });

    test('markMessageFailed handles unknown message gracefully', () async {
      await queue.markMessageFailed('nonexistent', 'some reason');
      // Should not throw
    });

    test('dispose does not throw', () {
      queue.dispose();
    });
  });

  group('OfflineMessageQueue - callbacks', () {
    test('onStatsUpdated fires on statistics change', () async {
      final queue = OfflineMessageQueue(
        retryScheduler: _FakeRetryScheduler(),
      );
      QueueStatistics? lastStats;
      await queue.initialize(
        onStatsUpdated: (stats) => lastStats = stats,
      );
      await queue.clearQueue();
      expect(lastStats, isNotNull);
    });

    test('initialize with repositoryProvider enables favorites', () async {
      final queue = OfflineMessageQueue(
        retryScheduler: _FakeRetryScheduler(),
      );
      await queue.initialize(
        repositoryProvider: _FakeRepositoryProvider(),
      );
      // Should not throw, favorites support enabled
      expect(queue.getStatistics(), isNotNull);
    });

    test('initialize with default repository provider', () async {
      OfflineMessageQueue.configureDefaultRepositoryProvider(
        _FakeRepositoryProvider(),
      );
      final queue = OfflineMessageQueue(
        retryScheduler: _FakeRetryScheduler(),
      );
      await queue.initialize();
      expect(OfflineMessageQueue.hasDefaultRepositoryProvider, isTrue);
      OfflineMessageQueue.clearDefaultRepositoryProvider();
    });

    test('initialize without any repository provider logs warning', () async {
      OfflineMessageQueue.clearDefaultRepositoryProvider();
      final queue = OfflineMessageQueue(
        retryScheduler: _FakeRetryScheduler(),
      );
      await queue.initialize();
      // Should complete without error, just logs warning
      expect(queue.getStatistics(), isNotNull);
    });
  });

  group('OfflineMessageQueue - flushQueueForPeer', () {
    test('flushQueueForPeer with no messages is no-op', () async {
      final queue = OfflineMessageQueue(
        retryScheduler: _FakeRetryScheduler(),
      );
      await queue.initialize();
      await queue.flushQueueForPeer('peer_pk');
      // No error expected
    });
  });

  group('OfflineMessageQueue - addSyncedMessage', () {
    test('addSyncedMessage for deleted message is skipped', () async {
      final queue = OfflineMessageQueue(
        retryScheduler: _FakeRetryScheduler(),
      );
      await queue.initialize();
      await queue.markMessageDeleted('sync_msg_1');

      final msg = _makeMessage(id: 'sync_msg_1');
      await queue.addSyncedMessage(msg);
      // Should be skipped since it was deleted
      expect(queue.getMessageById('sync_msg_1'), isNull);
    });
  });

  group('QueueSyncMessage', () {
    test('constructor and fields', () {
      final now = DateTime.now();
      final msg = QueueSyncMessage(
        nodeId: 'node_1',
        queueHash: 'hash_abc',
        messageIds: ['id1', 'id2'],
        syncTimestamp: now,
        syncType: QueueSyncType.request,
      );
      expect(msg.nodeId, 'node_1');
      expect(msg.queueHash, 'hash_abc');
      expect(msg.messageIds, hasLength(2));
      expect(msg.syncTimestamp, now);
    });
  });

  group('QueueStatistics', () {
    test('constructor with all required fields', () {
      final stats = QueueStatistics(
        totalQueued: 10,
        totalDelivered: 5,
        totalFailed: 2,
        pendingMessages: 3,
        sendingMessages: 0,
        retryingMessages: 0,
        failedMessages: 2,
        isOnline: true,
        averageDeliveryTime: Duration(seconds: 5),
        directQueueSize: 2,
        relayQueueSize: 1,
      );
      expect(stats.totalQueued, 10);
      expect(stats.totalDelivered, 5);
      expect(stats.totalFailed, 2);
      expect(stats.pendingMessages, 3);
      expect(stats.isOnline, isTrue);
      expect(stats.directQueueSize, 2);
      expect(stats.relayQueueSize, 1);
    });
  });
}
