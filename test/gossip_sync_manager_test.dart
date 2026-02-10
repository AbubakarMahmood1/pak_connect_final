import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/gossip_sync_manager.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';

void main() {
  group('GossipSyncManager', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    late GossipSyncManager manager;
    late MockOfflineMessageQueue mockQueue;
    final testNodeId = 'test_node_123';

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      mockQueue = MockOfflineMessageQueue();
      manager = GossipSyncManager(
        myNodeId: testNodeId,
        messageQueue: mockQueue,
      );
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
      manager.stop();
    });

    test('starts and stops correctly', () {
      manager.start();
      final stats = manager.getStatistics();
      expect(stats['isRunning'], true);

      manager.stop();
      final statsAfterStop = manager.getStatistics();
      expect(statsAfterStop['isRunning'], false);
    });

    test('tracks announcements (only latest per sender)', () {
      final message1 = _createTestMessage('msg_1', 'sender_1', 'recipient_1');
      final message2 = _createTestMessage('msg_2', 'sender_1', 'recipient_1');

      manager.trackPublicMessage(
        messageId: 'msg_1',
        message: message1,
        messageType: MessageType.announce,
      );

      manager.trackPublicMessage(
        messageId: 'msg_2',
        message: message2,
        messageType: MessageType.announce,
      );

      final stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 1); // Only latest
    });

    test('ignores broadcast messages (handled by queue)', () {
      final message = _createTestMessage('msg_1', 'sender_1', 'recipient_1');

      manager.trackPublicMessage(
        messageId: 'msg_1',
        message: message,
        messageType: MessageType.broadcast,
      );

      final stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 0); // Broadcast ignored
    });

    test('ignores stale announcements', () {
      // Create old message (13 hours ago - past stale timeout)
      final oldTimestamp = DateTime.now().subtract(Duration(hours: 13));
      final metadata = RelayMetadata.create(
        originalMessageContent: 'test',
        priority: MessagePriority.normal,
        originalSender: 'sender_1',
        finalRecipient: 'recipient_1',
        currentNodeId: 'sender_1',
      );

      final oldMessage = MeshRelayMessage(
        originalMessageId: 'old_msg',
        originalContent: 'test',
        relayMetadata: metadata,
        relayNodeId: 'sender_1',
        relayedAt: oldTimestamp,
      );

      manager.trackPublicMessage(
        messageId: 'old_msg',
        message: oldMessage,
        messageType: MessageType.announce,
      );

      final stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 0); // Should be ignored
    });

    test('uses hash-based sync optimization', () async {
      // Mock queue returns matching hash
      mockQueue.setMockHash('test_hash_123');

      final syncRequest = QueueSyncMessage.createRequest(
        messageIds: ['msg_1'],
        nodeId: 'peer_1',
        queueHash: 'test_hash_123', // Same hash
      );

      final sentMessages = <MeshRelayMessage>[];
      manager.onSendMessageToPeer = (peerID, message) {
        sentMessages.add(message);
      };

      await manager.handleSyncRequest(
        fromPeerID: 'peer_1',
        syncRequest: syncRequest,
      );

      // Should not send any messages (hash match)
      expect(sentMessages.length, 0);
    });

    test('sends announcements when peer missing them', () async {
      // Set a known hash for the mock queue
      mockQueue.setMockHash('my_hash_123');

      final announcement = _createTestMessage(
        'announce_1',
        'sender_1',
        'recipient_1',
      );

      manager.trackPublicMessage(
        messageId: 'announce_1',
        message: announcement,
        messageType: MessageType.announce,
      );

      // Verify announcement was tracked
      final stats = manager.getStatistics();
      expect(
        stats['trackedAnnouncements'],
        1,
        reason: 'Announcement should be tracked',
      );

      // Peer doesn't have any messages (empty list) and has different hash
      final syncRequest = QueueSyncMessage.createRequest(
        messageIds: [],
        nodeId: 'peer_1',
        queueHash: 'peer_hash_empty', // Different hash to trigger sync
      );

      final sentMessages = <MeshRelayMessage>[];
      manager.onSendMessageToPeer = (peerID, message) {
        sentMessages.add(message);
      };

      await manager.handleSyncRequest(
        fromPeerID: 'peer_1',
        syncRequest: syncRequest,
      );

      // Should send the announcement since peer doesn't have it
      expect(sentMessages.length, 1, reason: 'Should send 1 announcement');
      expect(sentMessages[0].originalMessageId, 'announce_1');
    });

    test('builds sync request with queue hash', () {
      mockQueue.setMockHash('queue_hash_abc');

      QueueSyncMessage? capturedRequest;
      manager.onSendSyncRequest = (syncRequest) {
        capturedRequest = syncRequest;
      };

      manager.start();

      // Trigger manual sync
      manager.scheduleInitialSync(delay: Duration.zero);

      // Wait a bit for async execution
      Future.delayed(Duration(milliseconds: 100), () {
        expect(capturedRequest, isNotNull);
        expect(capturedRequest!.queueHash, 'queue_hash_abc');
      });
    });

    test('removes announcement for peer', () {
      final announcement = _createTestMessage(
        'announce_1',
        'sender_1',
        'recipient_1',
      );

      manager.trackPublicMessage(
        messageId: 'announce_1',
        message: announcement,
        messageType: MessageType.announce,
      );

      var stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 1);

      // Remove peer
      manager.removeAnnouncementForPeer('sender_1');

      stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 0);
    });

    test('clears tracked announcements', () {
      final message1 = _createTestMessage('msg_1', 'sender_1', 'recipient_1');
      final message2 = _createTestMessage('msg_2', 'sender_2', 'recipient_2');

      manager.trackPublicMessage(
        messageId: 'msg_1',
        message: message1,
        messageType: MessageType.announce,
      );

      manager.trackPublicMessage(
        messageId: 'msg_2',
        message: message2,
        messageType: MessageType.announce,
      );

      var stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 2);

      manager.clear();

      stats = manager.getStatistics();
      expect(stats['trackedAnnouncements'], 0);
    });
  });
}

/// Mock OfflineMessageQueue for testing
class MockOfflineMessageQueue extends OfflineMessageQueue {
  String _mockHash = 'mock_hash_123';
  final List<QueuedMessage> _mockMessages = [];

  void setMockHash(String hash) {
    _mockHash = hash;
  }

  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    return _mockHash;
  }

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return QueueSyncMessage.createRequest(
      messageIds: _mockMessages.map((m) => m.id).toList(),
      nodeId: nodeId,
      queueHash: _mockHash,
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) {
    return _mockHash != otherQueueHash;
  }

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    return [];
  }

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    return [];
  }

  @override
  QueueStatistics getStatistics() {
    return QueueStatistics(
      totalQueued: 0,
      totalDelivered: 0,
      totalFailed: 0,
      pendingMessages: 0,
      sendingMessages: 0,
      retryingMessages: 0,
      failedMessages: 0,
      isOnline: false,
      averageDeliveryTime: Duration.zero,
    );
  }
}

/// Helper to create test relay message
MeshRelayMessage _createTestMessage(
  String messageId,
  String sender,
  String recipient,
) {
  final metadata = RelayMetadata.create(
    originalMessageContent: 'test content',
    priority: MessagePriority.normal,
    originalSender: sender,
    finalRecipient: recipient,
    currentNodeId: sender,
  );

  return MeshRelayMessage(
    originalMessageId: messageId,
    originalContent: 'test content',
    relayMetadata: metadata,
    relayNodeId: sender,
    relayedAt: DateTime.now(),
  );
}
