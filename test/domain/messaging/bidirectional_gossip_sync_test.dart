import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/messaging/gossip_sync_manager.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';

/// Phase 1 integration tests: Bidirectional gossip sync + QueuedMessage send fix.
///
/// Verifies:
/// - GossipSyncManager sends excess queued messages via callback (Gap 2 fix)
/// - QueueSyncManager reverse-sends excess after processSyncResponse (Gap 3 fix)
/// - Two managers with different message sets converge in one sync round
void main() {
  group('Phase 1: Bidirectional Gossip Sync', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    group('GossipSyncManager - onSendQueuedMessagesToPeer callback', () {
      late GossipSyncManager manager;
      late _TestQueue mockQueue;

      setUp(() {
        mockQueue = _TestQueue();
        manager = GossipSyncManager(
          myNodeId: 'node_A',
          messageQueue: mockQueue,
        );
      });

      tearDown(() => manager.stop());

      test('invokes callback with excess queued messages', () async {
        // Arrange: queue has messages that peer doesn't
        final msg = _makeQueuedMessage('excess_1', 'chat_1');
        mockQueue.addMessage(msg);

        final sentBatches = <(List<QueuedMessage>, String)>[];
        manager.onSendQueuedMessagesToPeer = (messages, peerId) {
          sentBatches.add((List.of(messages), peerId));
        };

        // Peer sends sync request with empty list → our message is excess
        final syncRequest = QueueSyncMessage.createRequest(
          messageIds: [],
          nodeId: 'node_B',
          queueHash: 'different_hash',
        );

        // Act
        await manager.handleSyncRequest(
          fromPeerID: 'node_B',
          syncRequest: syncRequest,
        );

        // Assert
        expect(sentBatches, hasLength(1));
        expect(sentBatches[0].$1, hasLength(1));
        expect(sentBatches[0].$1.first.id, 'excess_1');
        expect(sentBatches[0].$2, 'node_B');
      });

      test('does not invoke callback when no excess messages', () async {
        // Arrange: empty queue
        final sentBatches = <(List<QueuedMessage>, String)>[];
        manager.onSendQueuedMessagesToPeer = (messages, peerId) {
          sentBatches.add((messages, peerId));
        };

        final syncRequest = QueueSyncMessage.createRequest(
          messageIds: [],
          nodeId: 'node_B',
          queueHash: 'different_hash',
        );

        // Act
        await manager.handleSyncRequest(
          fromPeerID: 'node_B',
          syncRequest: syncRequest,
        );

        // Assert
        expect(sentBatches, isEmpty);
      });

      test('logs warning when callback is null', () async {
        // Arrange: queue has excess but no callback configured
        final msg = _makeQueuedMessage('orphan_1', 'chat_1');
        mockQueue.addMessage(msg);
        // onSendQueuedMessagesToPeer deliberately left null

        final syncRequest = QueueSyncMessage.createRequest(
          messageIds: [],
          nodeId: 'node_B',
          queueHash: 'different_hash',
        );

        // Act
        await manager.handleSyncRequest(
          fromPeerID: 'node_B',
          syncRequest: syncRequest,
        );

        // Assert: should log warning
        final warningLogs = logRecords
            .where((r) => r.level == Level.WARNING)
            .where((r) => r.message.contains('no send callback'))
            .toList();
        expect(warningLogs, isNotEmpty);
      });

      test('skips callback when hashes match', () async {
        mockQueue.addMessage(_makeQueuedMessage('msg_1', 'chat_1'));
        final hash = mockQueue.calculateQueueHash();

        final sentBatches = <(List<QueuedMessage>, String)>[];
        manager.onSendQueuedMessagesToPeer = (messages, peerId) {
          sentBatches.add((messages, peerId));
        };

        // Peer sends same hash → fast path, no sync needed
        final syncRequest = QueueSyncMessage.createRequest(
          messageIds: ['msg_1'],
          nodeId: 'node_B',
          queueHash: hash,
        );

        await manager.handleSyncRequest(
          fromPeerID: 'node_B',
          syncRequest: syncRequest,
        );

        expect(sentBatches, isEmpty, reason: 'Hash match → skip sync');
      });
    });

    group('QueueSyncManager - bidirectional reverse-send', () {
      late QueueSyncManager syncManager;
      late _TestQueue queue;

      setUp(() async {
        queue = _TestQueue();
        syncManager = QueueSyncManager(
          messageQueue: queue,
          nodeId: 'node_A',
        );
      });

      tearDown(() => syncManager.dispose());

      test('reverse-sends excess messages after processSyncResponse', () async {
        // Arrange: node A has msg_A, peer B sent us msg_B
        final msgA = _makeQueuedMessage('msg_A', 'chat_1');
        queue.addMessage(msgA);

        final sentBatches = <(List<QueuedMessage>, String)>[];
        await syncManager.initialize(
          onSendMessages: (messages, toNodeId) {
            sentBatches.add((List.of(messages), toNodeId));
          },
        );

        // Peer B's response includes msg_B in its message list
        final responseMessage = QueueSyncMessage.createRequest(
          messageIds: ['msg_B'],
          nodeId: 'node_B',
          queueHash: 'peer_hash',
        );

        final receivedMsgB = _makeQueuedMessage('msg_B', 'chat_1');

        // Act
        await syncManager.processSyncResponse(
          responseMessage,
          [receivedMsgB],
          'node_B',
        );

        // Assert: node A should have reverse-sent msg_A to node B
        expect(sentBatches, hasLength(1));
        expect(sentBatches[0].$1.any((m) => m.id == 'msg_A'), isTrue);
        expect(sentBatches[0].$2, 'node_B');
      });

      test('does not reverse-send when no excess', () async {
        // Arrange: both nodes have same messages
        final msg = _makeQueuedMessage('msg_shared', 'chat_1');
        queue.addMessage(msg);

        final sentBatches = <(List<QueuedMessage>, String)>[];
        await syncManager.initialize(
          onSendMessages: (messages, toNodeId) {
            sentBatches.add((messages, toNodeId));
          },
        );

        // Peer's response already lists msg_shared → no excess
        final responseMessage = QueueSyncMessage.createRequest(
          messageIds: ['msg_shared'],
          nodeId: 'node_B',
          queueHash: 'peer_hash',
        );

        await syncManager.processSyncResponse(
          responseMessage,
          [],
          'node_B',
        );

        expect(sentBatches, isEmpty);
      });

      test('handleSyncRequest sends excess to requester', () async {
        // Arrange: node A has msg_A, peer B does not
        final msgA = _makeQueuedMessage('msg_A', 'chat_1');
        queue.addMessage(msgA);

        final sentBatches = <(List<QueuedMessage>, String)>[];
        await syncManager.initialize(
          onSendMessages: (messages, toNodeId) {
            sentBatches.add((List.of(messages), toNodeId));
          },
        );

        // Peer B sends sync request (empty list → our msg_A is excess)
        final syncRequest = QueueSyncMessage.createRequest(
          messageIds: [],
          nodeId: 'node_B',
          queueHash: 'different_hash',
        );

        await syncManager.handleSyncRequest(syncRequest, 'node_B');

        // Assert: A should dispatch excess to B
        expect(sentBatches, hasLength(1));
        expect(sentBatches[0].$1.any((m) => m.id == 'msg_A'), isTrue);
      });
    });

    group('End-to-end bidirectional convergence', () {
      test(
        'two nodes with disjoint messages converge after one sync round',
        () async {
          // Setup two in-memory queues (simulating two devices)
          final queueA = _TestQueue();
          final queueB = _TestQueue();

          // Node A has messages 1,2; Node B has messages 3,4
          final msg1 = _makeQueuedMessage('msg_1', 'chat');
          final msg2 = _makeQueuedMessage('msg_2', 'chat');
          final msg3 = _makeQueuedMessage('msg_3', 'chat');
          final msg4 = _makeQueuedMessage('msg_4', 'chat');

          queueA.addMessage(msg1);
          queueA.addMessage(msg2);
          queueB.addMessage(msg3);
          queueB.addMessage(msg4);

          // Create sync managers
          final managerA = QueueSyncManager(
            messageQueue: queueA,
            nodeId: 'node_A',
          );
          final managerB = QueueSyncManager(
            messageQueue: queueB,
            nodeId: 'node_B',
          );

          // Wire callbacks: messages sent by A go to B's queue and vice versa
          await managerA.initialize(
            onSendMessages: (messages, toNodeId) {
              for (final m in messages) {
                queueB.addMessage(m);
              }
            },
          );

          await managerB.initialize(
            onSendMessages: (messages, toNodeId) {
              for (final m in messages) {
                queueA.addMessage(m);
              }
            },
          );

          // Step 1: Node A sends sync request to Node B
          final syncRequestFromA = queueA.createSyncMessage('node_A');

          // Step 2: Node B handles A's request (sends B's excess to A)
          final responseFromB = await managerB.handleSyncRequest(
            syncRequestFromA,
            'node_A',
          );

          // Step 3: Node A processes B's response (adds B's messages, reverse-sends A's excess to B)
          if (responseFromB.type == QueueSyncResponseType.success &&
              responseFromB.responseMessage != null) {
            await managerA.processSyncResponse(
              responseFromB.responseMessage!,
              responseFromB.excessMessages ?? [],
              'node_B',
            );
          }

          // Assert: both queues should now have all 4 messages
          final aIds = queueA.allMessageIds..sort();
          final bIds = queueB.allMessageIds..sort();

          expect(aIds, containsAll(['msg_1', 'msg_2', 'msg_3', 'msg_4']));
          expect(bIds, containsAll(['msg_1', 'msg_2', 'msg_3', 'msg_4']));

          managerA.dispose();
          managerB.dispose();
        },
      );

      test(
        'two nodes with overlapping messages converge without duplicates',
        () async {
          final queueA = _TestQueue();
          final queueB = _TestQueue();

          // Shared: msg_shared. Only A: msg_A. Only B: msg_B.
          final shared = _makeQueuedMessage('msg_shared', 'chat');
          final msgA = _makeQueuedMessage('msg_A', 'chat');
          final msgB = _makeQueuedMessage('msg_B', 'chat');

          queueA.addMessage(shared);
          queueA.addMessage(msgA);
          queueB.addMessage(_makeQueuedMessage('msg_shared', 'chat')); // same id
          queueB.addMessage(msgB);

          final managerA = QueueSyncManager(
            messageQueue: queueA,
            nodeId: 'node_A',
          );
          final managerB = QueueSyncManager(
            messageQueue: queueB,
            nodeId: 'node_B',
          );

          await managerA.initialize(
            onSendMessages: (messages, toNodeId) {
              for (final m in messages) {
                queueB.addMessage(m);
              }
            },
          );

          await managerB.initialize(
            onSendMessages: (messages, toNodeId) {
              for (final m in messages) {
                queueA.addMessage(m);
              }
            },
          );

          // Sync round
          final syncRequest = queueA.createSyncMessage('node_A');
          final response = await managerB.handleSyncRequest(
            syncRequest,
            'node_A',
          );

          if (response.type == QueueSyncResponseType.success &&
              response.responseMessage != null) {
            await managerA.processSyncResponse(
              response.responseMessage!,
              response.excessMessages ?? [],
              'node_B',
            );
          }

          // Both should have exactly 3 unique messages
          final aIds = queueA.allMessageIds..sort();
          final bIds = queueB.allMessageIds..sort();

          expect(aIds, ['msg_A', 'msg_B', 'msg_shared']);
          expect(bIds, ['msg_A', 'msg_B', 'msg_shared']);

          managerA.dispose();
          managerB.dispose();
        },
      );

      test('deleted messages are not resurrected during sync', () async {
        final queueA = _TestQueue();
        final queueB = _TestQueue();

        // A has msg_1 (active). B deleted msg_1.
        queueA.addMessage(_makeQueuedMessage('msg_1', 'chat'));
        await queueB.markMessageDeleted('msg_1');

        final managerB = QueueSyncManager(
          messageQueue: queueB,
          nodeId: 'node_B',
        );

        await managerB.initialize(
          onSendMessages: (messages, toNodeId) {
            for (final m in messages) {
              queueA.addMessage(m);
            }
          },
        );

        // B receives A's excess (msg_1)
        final received = [_makeQueuedMessage('msg_1', 'chat')];
        final responseMessage = QueueSyncMessage.createRequest(
          messageIds: ['msg_1'],
          nodeId: 'node_A',
          queueHash: 'a_hash',
        );

        await managerB.processSyncResponse(
          responseMessage,
          received,
          'node_A',
        );

        // msg_1 should NOT appear in B's queue (deletion is final)
        expect(queueB.allMessageIds, isEmpty);

        managerB.dispose();
      });
    });
  });
}

// =============================================================================
// Test helpers
// =============================================================================

/// Test queue that extends InMemoryOfflineMessageQueue with direct message
/// insertion (bypassing queueMessage's auto-ID generation).
class _TestQueue extends InMemoryOfflineMessageQueue {
  final Map<String, QueuedMessage> _directMessages = {};
  final Set<String> _directDeleted = {};

  void addMessage(QueuedMessage message) {
    if (_directDeleted.contains(message.id)) return;
    _directMessages.putIfAbsent(message.id, () => message);
  }

  List<String> get allMessageIds => _directMessages.keys.toList();

  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    final ids = _directMessages.keys.toList()..sort();
    final deleted = _directDeleted.toList()..sort();
    return [...ids, ...deleted].join(':');
  }

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return QueueSyncMessage.createRequest(
      messageIds: _directMessages.keys.toList(),
      nodeId: nodeId,
      queueHash: calculateQueueHash(),
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) {
    return calculateQueueHash() != otherQueueHash;
  }

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    if (_directDeleted.contains(message.id)) return;
    _directMessages.putIfAbsent(message.id, () => message);
  }

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    final local = _directMessages.keys.toSet();
    return otherMessageIds.where((id) => !local.contains(id)).toList();
  }

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final other = otherMessageIds.toSet();
    return _directMessages.values
        .where((m) => !other.contains(m.id))
        .toList();
  }

  @override
  bool isMessageDeleted(String messageId) {
    return _directDeleted.contains(messageId);
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    _directDeleted.add(messageId);
    _directMessages.remove(messageId);
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return _directMessages.values
        .where((m) => m.status == status)
        .toList();
  }

  @override
  QueueStatistics getStatistics() {
    return QueueStatistics(
      totalQueued: _directMessages.length,
      totalDelivered: 0,
      totalFailed: 0,
      pendingMessages: _directMessages.length,
      sendingMessages: 0,
      retryingMessages: 0,
      failedMessages: 0,
      isOnline: true,
      averageDeliveryTime: Duration.zero,
    );
  }

  @override
  QueuedMessage? getMessageById(String messageId) {
    return _directMessages[messageId];
  }
}

QueuedMessage _makeQueuedMessage(String id, String chatId) {
  return QueuedMessage(
    id: id,
    chatId: chatId,
    content: 'test content for $id',
    recipientPublicKey: 'recipient_key',
    senderPublicKey: 'sender_key',
    priority: MessagePriority.normal,
    queuedAt: DateTime.now(),
    maxRetries: 3,
  );
}
