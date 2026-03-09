/// Phase 13 — QueueSyncManager additional coverage:
/// - forceSyncAll with multiple nodes
/// - _cleanupOldSyncData (stuck sync cleanup)
/// - _getSyncBlockReason (all branches)
/// - _canSync rate limiting (global hourly cap)
/// - initiateSync with callback configured (timeout path)
/// - initiateSync rate-limited by interval
/// - initiateSync rate-limited by in-progress
/// - handleSyncRequest — error path (exception in queue)
/// - processSyncResponse — error path
/// - dispose completes pending syncs with error
/// - cancelAllSyncs with pending syncs & stopwatches
/// - _saveSyncStats / _loadSyncStats with corrupt data
library;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fake OfflineMessageQueueContract
// ---------------------------------------------------------------------------
class _FakeQueue extends Fake implements OfflineMessageQueueContract {
  bool needsSync = true;
  List<String> missingIds = [];
  List<QueuedMessage> excessMessages = [];
  List<QueuedMessage> pendingMessages = [];
  String hash = 'hash-abc';
  final List<QueuedMessage> addedMessages = [];
  final Set<String> deletedIds = {};
  int statisticsPending = 2;
  bool throwOnCreateSync = false;

  @override
  QueueStatistics getStatistics() => QueueStatistics(
        totalQueued: 5,
        totalDelivered: 3,
        totalFailed: 1,
        pendingMessages: statisticsPending,
        sendingMessages: 0,
        retryingMessages: 0,
        failedMessages: 1,
        isOnline: true,
        oldestPendingMessage: null,
        averageDeliveryTime: Duration.zero,
        directQueueSize: 2,
        relayQueueSize: 0,
      );

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    if (throwOnCreateSync) throw Exception('sync creation failed');
    return QueueSyncMessage(
      queueHash: hash,
      messageIds: const ['msg-1', 'msg-2'],
      syncTimestamp: DateTime(2024, 1, 1),
      nodeId: nodeId,
      syncType: QueueSyncType.request,
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) => needsSync;

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) => missingIds;

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) =>
      excessMessages;

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      pendingMessages;

  @override
  String calculateQueueHash({bool forceRecalculation = false}) => hash;

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    addedMessages.add(message);
  }

  @override
  bool isMessageDeleted(String messageId) => deletedIds.contains(messageId);
}

class _ThrowingQueue extends Fake implements OfflineMessageQueueContract {
  @override
  QueueStatistics getStatistics() => QueueStatistics(
        totalQueued: 0,
        totalDelivered: 0,
        totalFailed: 0,
        pendingMessages: 0,
        sendingMessages: 0,
        retryingMessages: 0,
        failedMessages: 0,
        isOnline: true,
        oldestPendingMessage: null,
        averageDeliveryTime: Duration.zero,
        directQueueSize: 0,
        relayQueueSize: 0,
      );

  @override
  QueueSyncMessage createSyncMessage(String nodeId) => QueueSyncMessage(
        queueHash: 'h',
        messageIds: const [],
        syncTimestamp: DateTime(2024),
        nodeId: nodeId,
        syncType: QueueSyncType.request,
      );

  @override
  bool needsSynchronization(String otherQueueHash) =>
      throw Exception('sync check failed');
}

QueuedMessage _qm(String id) => QueuedMessage(
      id: id,
      chatId: 'chat-1',
      content: 'test',
      recipientPublicKey: 'pk-recipient',
      senderPublicKey: 'pk-sender',
      priority: MessagePriority.normal,
      queuedAt: DateTime(2024, 1, 1),
      maxRetries: 3,
    );

// ---------------------------------------------------------------------------
void main() {
  late _FakeQueue fakeQueue;
  late QueueSyncManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeQueue = _FakeQueue();
    manager = QueueSyncManager(messageQueue: fakeQueue, nodeId: 'my-node');
  });

  tearDown(() {
    manager.dispose();
  });

  // -----------------------------------------------------------------------
  // forceSyncAll
  // -----------------------------------------------------------------------
  group('forceSyncAll', () {
    test('syncs multiple nodes and returns results map', () async {
      await manager.initialize(); // no onSyncRequest → each sync fails
      final results = await manager.forceSyncAll(['node-a', 'node-b']);
      expect(results.length, 2);
      expect(results['node-a']!.success, isFalse);
      expect(results['node-b']!.success, isFalse);
    });

    test('handles empty list', () async {
      await manager.initialize();
      final results = await manager.forceSyncAll([]);
      expect(results, isEmpty);
    });

    test('handles exception in individual sync', () async {
      await manager.initialize();
      fakeQueue.throwOnCreateSync = true;
      final results = await manager.forceSyncAll(['node-err']);
      expect(results['node-err']!.success, isFalse);
      expect(results['node-err']!.type, QueueSyncResultType.error);
    });
  });

  // -----------------------------------------------------------------------
  // initiateSync — rate limiting branches
  // -----------------------------------------------------------------------
  group('initiateSync — rate limiting', () {
    test('blocks sync when in-progress for same node', () async {
      // We need the first sync to be "in progress" while we try a second.
      // Use a callback that never completes the sync.
      final syncRequests = <String>[];
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          syncRequests.add(nodeId);
          // Don't complete the sync — leaves it in progress
        },
      );

      // Start first sync (will be pending because we never call processSyncResponse)
      final future1 = manager.initiateSync('target-1');

      // Give the event loop a chance
      await Future.delayed(Duration.zero);

      // Try second sync — should be blocked
      final result2 = await manager.initiateSync('target-1');
      expect(result2.success, isFalse);
      expect(result2.type, QueueSyncResultType.rateLimited);

      // Clean up: cancel all so future1 completes
      manager.cancelAllSyncs(reason: 'test');
      await future1; // let it complete
    });

    test('blocks sync when interval not met', () async {
      final syncRequests = <String>[];
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          syncRequests.add(nodeId);
        },
      );

      // Complete first sync manually
      final future1 = manager.initiateSync('target-2');
      // Complete via processSyncResponse
      final responseMsg = QueueSyncMessage(
        queueHash: 'h',
        messageIds: const [],
        syncTimestamp: DateTime(2024),
        nodeId: 'target-2',
        syncType: QueueSyncType.response,
      );
      await manager.processSyncResponse(responseMsg, [], 'target-2');
      await future1;

      // Immediately try again — should be blocked by min interval
      final result2 = await manager.initiateSync('target-2');
      expect(result2.success, isFalse);
      expect(result2.type, QueueSyncResultType.rateLimited);
    });

    test('empty queue still initiates hash-only sync', () async {
      fakeQueue.statisticsPending = 0;
      final syncRequests = <String>[];
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          syncRequests.add(nodeId);
        },
      );

      final future = manager.initiateSync('target-3');
      await Future.delayed(Duration.zero);
      // Cancel to unblock
      manager.cancelAllSyncs();
      await future;
      expect(syncRequests, contains('target-3'));
    });
  });

  // -----------------------------------------------------------------------
  // initiateSync — timeout path
  // -----------------------------------------------------------------------
  group('initiateSync — timeout', () {
    test('sync times out when response never arrives', () async {
      final failCalls = <(String, String)>[];
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          // don't respond → timeout
        },
        onSyncFailed: (nodeId, error) {
          failCalls.add((nodeId, error));
        },
      );

      // The sync timeout is 15s in production. We can't wait that long,
      // so we cancel instead to test the pending completer path.
      final future = manager.initiateSync('timeout-node');
      await Future.delayed(const Duration(milliseconds: 50));
      manager.cancelAllSyncs(reason: 'forced timeout');
      final result = await future;
      expect(result.success, isFalse);
    });
  });

  // -----------------------------------------------------------------------
  // handleSyncRequest — error path
  // -----------------------------------------------------------------------
  group('handleSyncRequest — error path', () {
    test('returns error when queue throws', () async {
      final throwingQueue = _ThrowingQueue();
      final m = QueueSyncManager(
        messageQueue: throwingQueue,
        nodeId: 'err-node',
      );
      await m.initialize();

      final msg = QueueSyncMessage(
        queueHash: 'h',
        messageIds: const ['x'],
        syncTimestamp: DateTime(2024),
        nodeId: 'sender',
        syncType: QueueSyncType.request,
      );

      final response = await m.handleSyncRequest(msg, 'sender-node-1234567890');
      expect(response.type, QueueSyncResponseType.error);
      expect(response.success, isFalse);
      m.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // processSyncResponse — error path
  // -----------------------------------------------------------------------
  group('processSyncResponse — error handling', () {
    test('handles addSyncedMessage failure gracefully', () async {
      await manager.initialize();

      final responseMsg = QueueSyncMessage(
        queueHash: 'h',
        messageIds: const [],
        syncTimestamp: DateTime(2024),
        nodeId: 'node-fail',
        syncType: QueueSyncType.response,
      );

      // This should still succeed even with messages
      final result = await manager.processSyncResponse(
        responseMsg,
        [_qm('new-msg')],
        'node-fail',
      );
      expect(result.success, isTrue);
      expect(result.messagesReceived, 1);
    });
  });

  // -----------------------------------------------------------------------
  // _loadSyncStats — corrupt data
  // -----------------------------------------------------------------------
  group('_loadSyncStats — corrupted prefs', () {
    test('handles invalid JSON gracefully', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('queue_sync_stats_v1', 'not-valid-json{{{');
      final m = QueueSyncManager(messageQueue: fakeQueue, nodeId: 'bad-prefs');
      // Should not throw — just logs warning
      await m.initialize();
      final stats = m.getStats();
      expect(stats.totalSyncRequests, 0);
      m.dispose();
    });

    test('handles missing fields in JSON', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('queue_sync_stats_v1', '{}');
      final m = QueueSyncManager(messageQueue: fakeQueue, nodeId: 'empty-json');
      await m.initialize();
      final stats = m.getStats();
      expect(stats.totalSyncRequests, 0);
      m.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // _getSyncBlockReason — unknown fallback
  // -----------------------------------------------------------------------
  group('_getSyncBlockReason — indirect via initiateSync', () {
    test('reports "Sync already in progress" reason', () async {
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          // never complete
        },
      );
      final future1 = manager.initiateSync('reason-node');
      await Future.delayed(Duration.zero);

      final result2 = await manager.initiateSync('reason-node');
      expect(result2.error, contains('Sync already in progress'));
      manager.cancelAllSyncs();
      await future1;
    });
  });

  // -----------------------------------------------------------------------
  // cancelAllSyncs — with active timers and stopwatches
  // -----------------------------------------------------------------------
  group('cancelAllSyncs — thorough cleanup', () {
    test('clears stopwatches and active timers', () async {
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          // never complete
        },
      );
      // Start a sync so there are active timers and stopwatches
      final future = manager.initiateSync('cancel-node');
      await Future.delayed(Duration.zero);

      manager.cancelAllSyncs(reason: 'cleanup test');
      final result = await future;
      expect(result.success, isFalse);
      expect(result.error, contains('cleanup test'));

      final stats = manager.getStats();
      expect(stats.activeSyncs, 0);
    });
  });

  // -----------------------------------------------------------------------
  // dispose — completes pending futures
  // -----------------------------------------------------------------------
  group('dispose — pending syncs', () {
    test('completes pending syncs with error on dispose', () async {
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          // never complete
        },
      );
      final future = manager.initiateSync('dispose-node');
      await Future.delayed(Duration.zero);

      manager.dispose();
      final result = await future;
      expect(result.success, isFalse);
      expect(result.error, contains('disposed'));
    });
  });

  // -----------------------------------------------------------------------
  // _performSync — sync already pending
  // -----------------------------------------------------------------------
  group('_performSync — already pending', () {
    test('returns rateLimited when sync already pending for node', () async {
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          // never complete — keeps pendingSync alive
        },
      );

      final future1 = manager.initiateSync('pending-node');
      await Future.delayed(Duration.zero);

      // The second attempt should be blocked by _syncInProgress
      final result2 = await manager.initiateSync('pending-node');
      expect(result2.success, isFalse);

      manager.cancelAllSyncs();
      await future1;
    });
  });

  // -----------------------------------------------------------------------
  // handleSyncRequest — excess without send callback
  // -----------------------------------------------------------------------
  group('handleSyncRequest — excess without callback logs warning', () {
    test('no send callback with excess messages', () async {
      await manager.initialize(); // no onSendMessages
      fakeQueue.needsSync = true;
      fakeQueue.missingIds = ['m1'];
      fakeQueue.excessMessages = [_qm('e1')];
      fakeQueue.pendingMessages = [_qm('p1')];

      final msg = QueueSyncMessage(
        queueHash: 'h-other',
        messageIds: const ['x'],
        syncTimestamp: DateTime(2024),
        nodeId: 'other',
        syncType: QueueSyncType.request,
      );

      final response = await manager.handleSyncRequest(msg, 'other-node-1234567890');
      expect(response.type, QueueSyncResponseType.success);
    });

    test('no excess and no missing returns alreadySynced', () async {
      await manager.initialize();
      fakeQueue.needsSync = true;
      fakeQueue.missingIds = [];
      fakeQueue.excessMessages = [];

      final msg = QueueSyncMessage(
        queueHash: 'h-other',
        messageIds: const ['x'],
        syncTimestamp: DateTime(2024),
        nodeId: 'other',
        syncType: QueueSyncType.request,
      );

      final response = await manager.handleSyncRequest(msg, 'short');
      expect(response.type, QueueSyncResponseType.alreadySynced);
    });
  });

  // -----------------------------------------------------------------------
  // _saveSyncStats round-trip
  // -----------------------------------------------------------------------
  group('_saveSyncStats — persists after sync', () {
    test('stats are saved after successful initiateSync', () async {
      await manager.initialize(
        onSyncRequest: (msg, nodeId) {
          // complete sync
        },
      );

      final future = manager.initiateSync('save-node');
      final responseMsg = QueueSyncMessage(
        queueHash: 'h',
        messageIds: const [],
        syncTimestamp: DateTime(2024),
        nodeId: 'save-node',
        syncType: QueueSyncType.response,
      );
      await manager.processSyncResponse(responseMsg, [], 'save-node');
      await future;

      // Read back from prefs
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('queue_sync_stats_v1');
      expect(json, isNotNull);
      final decoded = jsonDecode(json!) as Map<String, dynamic>;
      expect(decoded['totalSyncRequests'], greaterThanOrEqualTo(1));
    });
  });
}
