/// Phase 11.4 — QueueSyncManager tests: construction, getStats,
/// initialize, handleSyncRequest, processSyncResponse, rate-limiting,
/// dispose, cancelAllSyncs, and initiateSync error paths.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fake OfflineMessageQueueContract
// ---------------------------------------------------------------------------
class _FakeQueue extends Fake implements OfflineMessageQueueContract {
  bool _needsSync = true;
  List<String> _missingIds = [];
  List<QueuedMessage> _excessMessages = [];
  List<QueuedMessage> _pendingMessages = [];
  String _hash = 'hash-abc';
  final List<QueuedMessage> addedMessages = [];
  final Set<String> deletedIds = {};

  @override
  QueueStatistics getStatistics() => QueueStatistics(
        totalQueued: 5,
        totalDelivered: 3,
        totalFailed: 1,
        pendingMessages: 2,
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
  QueueSyncMessage createSyncMessage(String nodeId) => QueueSyncMessage(
        queueHash: _hash,
        messageIds: const ['msg-1', 'msg-2'],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: nodeId,
        syncType: QueueSyncType.request,
      );

  @override
  bool needsSynchronization(String otherQueueHash) => _needsSync;

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) => _missingIds;

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) =>
      _excessMessages;

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      _pendingMessages;

  @override
  String calculateQueueHash({bool forceRecalculation = false}) => _hash;

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    addedMessages.add(message);
  }

  @override
  bool isMessageDeleted(String messageId) => deletedIds.contains(messageId);
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
  // Construction
  // -----------------------------------------------------------------------
  group('QueueSyncManager construction', () {
    test('creates without error', () {
      expect(manager, isNotNull);
    });
  });

  // -----------------------------------------------------------------------
  // getStats
  // -----------------------------------------------------------------------
  group('getStats', () {
    test('returns zero stats before any syncs', () {
      final stats = manager.getStats();
      expect(stats.totalSyncRequests, 0);
      expect(stats.successfulSyncs, 0);
      expect(stats.failedSyncs, 0);
      expect(stats.messagesTransferred, 0);
      expect(stats.activeSyncs, 0);
      expect(stats.successRate, 0.0);
      expect(stats.recentSyncCount, 0);
    });
  });

  // -----------------------------------------------------------------------
  // initialize
  // -----------------------------------------------------------------------
  group('initialize', () {
    test('registers callbacks', () async {
      await manager.initialize(
        onSyncRequest: (_, __) {},
        onSendMessages: (_, __) {},
        onSyncCompleted: (_, __) {},
        onSyncFailed: (_, __) {},
      );
      expect(manager.onSyncRequest, isNotNull);
    });

    test('loads stats from empty prefs', () async {
      await manager.initialize();
      final stats = manager.getStats();
      expect(stats.totalSyncRequests, 0);
    });

    test('loads stats from populated prefs', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'queue_sync_stats_v1',
        '{"totalSyncRequests":10,"successfulSyncs":8,"failedSyncs":2,"messagesTransferred":50}',
      );
      final m2 = QueueSyncManager(messageQueue: fakeQueue, nodeId: 'n2');
      await m2.initialize();
      final stats = m2.getStats();
      expect(stats.totalSyncRequests, 10);
      expect(stats.successfulSyncs, 8);
      expect(stats.failedSyncs, 2);
      expect(stats.messagesTransferred, 50);
      m2.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // handleSyncRequest
  // -----------------------------------------------------------------------
  group('handleSyncRequest', () {
    test('returns alreadySynced when queues match', () async {
      await manager.initialize();
      fakeQueue._needsSync = false;

      final msg = QueueSyncMessage(
        queueHash: 'hash-abc',
        messageIds: const ['msg-1'],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.request,
      );

      final response = await manager.handleSyncRequest(msg, 'other-node');
      expect(response.type, QueueSyncResponseType.alreadySynced);
      expect(response.success, isTrue);
    });

    test('returns success with missing/excess messages', () async {
      fakeQueue._needsSync = true;
      fakeQueue._missingIds = ['missing-1'];
      fakeQueue._excessMessages = [_qm('excess-1')];
      fakeQueue._pendingMessages = [_qm('pending-1')];

      final sendCalls = <(List<QueuedMessage>, String)>[];
      await manager.initialize(
        onSendMessages: (msgs, nodeId) => sendCalls.add((msgs, nodeId)),
      );

      final msg = QueueSyncMessage(
        queueHash: 'hash-other',
        messageIds: const ['msg-1'],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.request,
      );

      final response = await manager.handleSyncRequest(msg, 'other-node');
      expect(response.type, QueueSyncResponseType.success);
      expect(response.missingMessages, ['missing-1']);
      expect(response.excessMessages, isNotEmpty);
      expect(sendCalls, hasLength(1));
    });

    test('alreadySynced when no missing and no excess', () async {
      await manager.initialize();
      fakeQueue._needsSync = true;
      fakeQueue._missingIds = [];
      fakeQueue._excessMessages = [];

      final msg = QueueSyncMessage(
        queueHash: 'hash-other',
        messageIds: const ['msg-1'],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.request,
      );

      final response = await manager.handleSyncRequest(msg, 'other-node');
      expect(response.type, QueueSyncResponseType.alreadySynced);
    });

    test('logs warning when excess but no send callback', () async {
      await manager.initialize(); // no onSendMessages
      fakeQueue._needsSync = true;
      fakeQueue._missingIds = ['m1'];
      fakeQueue._excessMessages = [_qm('excess-1')];
      fakeQueue._pendingMessages = [_qm('p1')];

      final msg = QueueSyncMessage(
        queueHash: 'hash-other',
        messageIds: const ['msg-1'],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.request,
      );

      final response = await manager.handleSyncRequest(msg, 'other-node');
      expect(response.type, QueueSyncResponseType.success);
    });
  });

  // -----------------------------------------------------------------------
  // processSyncResponse
  // -----------------------------------------------------------------------
  group('processSyncResponse', () {
    test('adds new messages and skips deleted', () async {
      await manager.initialize();
      fakeQueue.deletedIds.add('deleted-1');
      fakeQueue._pendingMessages = [];

      final responseMsg = QueueSyncMessage(
        queueHash: 'hash-resp',
        messageIds: const [],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.response,
      );

      final result = await manager.processSyncResponse(
        responseMsg,
        [_qm('new-1'), _qm('deleted-1')],
        'other-node',
      );

      expect(result.success, isTrue);
      expect(result.messagesReceived, 1);
      expect(result.messagesSkipped, 1);
      expect(fakeQueue.addedMessages.length, 1);
      expect(fakeQueue.addedMessages.first.id, 'new-1');
    });

    test('updates existing messages', () async {
      await manager.initialize();
      fakeQueue._pendingMessages = [_qm('existing-1')];

      final responseMsg = QueueSyncMessage(
        queueHash: 'hash-resp',
        messageIds: const [],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.response,
      );

      final result = await manager.processSyncResponse(
        responseMsg,
        [_qm('existing-1')],
        'other-node',
      );

      expect(result.success, isTrue);
      expect(result.messagesUpdated, 1);
      expect(result.messagesReceived, 0);
    });

    test('empty message list returns success', () async {
      await manager.initialize();

      final responseMsg = QueueSyncMessage(
        queueHash: 'hash-resp',
        messageIds: const [],
        syncTimestamp: DateTime(2024, 1, 1),
        nodeId: 'other-node',
        syncType: QueueSyncType.response,
      );

      final result = await manager.processSyncResponse(
        responseMsg,
        [],
        'other-node',
      );

      expect(result.success, isTrue);
      expect(result.messagesReceived, 0);
    });
  });

  // -----------------------------------------------------------------------
  // initiateSync
  // -----------------------------------------------------------------------
  group('initiateSync', () {
    test('fails when no sync callback configured', () async {
      await manager.initialize(); // no onSyncRequest
      final result = await manager.initiateSync('target-node');
      expect(result.success, isFalse);
    });
  });

  // -----------------------------------------------------------------------
  // dispose & cancelAllSyncs
  // -----------------------------------------------------------------------
  group('dispose', () {
    test('double dispose is safe', () {
      manager.dispose();
      manager.dispose();
    });
  });

  group('cancelAllSyncs', () {
    test('clears all sync state', () async {
      await manager.initialize();
      manager.cancelAllSyncs(reason: 'test cleanup');
      final stats = manager.getStats();
      expect(stats.activeSyncs, 0);
    });

    test('without reason', () async {
      await manager.initialize();
      manager.cancelAllSyncs();
    });
  });

  // -----------------------------------------------------------------------
  // Data class factories
  // -----------------------------------------------------------------------
  group('QueueSyncResult factories', () {
    test('success', () {
      final r = QueueSyncResult.success(
        messagesReceived: 5,
        messagesUpdated: 2,
        messagesSkipped: 1,
        finalHash: 'h1',
        syncDuration: const Duration(seconds: 3),
      );
      expect(r.success, isTrue);
      expect(r.type, QueueSyncResultType.success);
    });

    test('alreadySynced', () {
      expect(QueueSyncResult.alreadySynced().type,
          QueueSyncResultType.alreadySynced);
    });

    test('rateLimited', () {
      final r = QueueSyncResult.rateLimited('too many');
      expect(r.type, QueueSyncResultType.rateLimited);
      expect(r.error, 'too many');
    });

    test('timeout', () {
      expect(QueueSyncResult.timeout().type, QueueSyncResultType.timeout);
    });

    test('error', () {
      expect(QueueSyncResult.error('boom').error, 'boom');
    });

    test('copyWithDuration', () {
      final r = QueueSyncResult.success(
        messagesReceived: 1,
        messagesUpdated: 0,
        messagesSkipped: 0,
        finalHash: 'h',
        syncDuration: Duration.zero,
      );
      final copy = r.copyWithDuration(const Duration(seconds: 5));
      expect(copy.syncDuration, const Duration(seconds: 5));
      expect(copy.messagesReceived, 1);
    });
  });

  group('QueueSyncResponse factories', () {
    test('success', () {
      final msg = QueueSyncMessage(
        queueHash: 'h',
        messageIds: const [],
        syncTimestamp: DateTime(2024),
        nodeId: 'n',
        syncType: QueueSyncType.response,
      );
      final r = QueueSyncResponse.success(
        responseMessage: msg,
        missingMessages: ['m1'],
        excessMessages: [_qm('e1')],
      );
      expect(r.success, isTrue);
    });

    test('alreadySynced', () {
      expect(QueueSyncResponse.alreadySynced().type,
          QueueSyncResponseType.alreadySynced);
    });

    test('rateLimited', () {
      expect(QueueSyncResponse.rateLimited('x').type,
          QueueSyncResponseType.rateLimited);
    });

    test('error', () {
      expect(QueueSyncResponse.error('x').type, QueueSyncResponseType.error);
    });
  });

  group('QueueSyncManagerStats', () {
    test('toString', () {
      const stats = QueueSyncManagerStats(
        totalSyncRequests: 100,
        successfulSyncs: 90,
        failedSyncs: 10,
        messagesTransferred: 500,
        activeSyncs: 2,
        successRate: 0.9,
        recentSyncCount: 5,
      );
      expect(stats.toString(), contains('90.0%'));
    });
  });
}
