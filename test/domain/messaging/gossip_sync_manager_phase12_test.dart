import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/messaging/gossip_sync_manager.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';

/// Phase 12.2: Supplementary tests for GossipSyncManager
/// Covers: battery emergency mode, direct announcement triggering,
///   LRU eviction, statistics, capacity enforcement
void main() {
  late List<LogRecord> logRecords;
  late GossipSyncManager manager;
  late MockOfflineMessageQueue mockQueue;
  final testNodeId = 'node_phase12';

  setUp(() {
    logRecords = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    mockQueue = MockOfflineMessageQueue();
    manager = GossipSyncManager(
      myNodeId: testNodeId,
      messageQueue: mockQueue,
    );
  });

  tearDown(() {
    manager.stop();
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .toList();
    expect(severeErrors, isEmpty,
        reason:
            'Unexpected SEVERE:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}');
  });

  MeshRelayMessage createMessage(
    String msgId,
    String sender,
    String recipient, {
    int hopCount = 1,
  }) {
    final metadata = RelayMetadata(
      ttl: 5,
      hopCount: hopCount,
      routingPath: [sender],
      messageHash: 'hash_$msgId',
      priority: MessagePriority.normal,
      relayTimestamp: DateTime.now(),
      originalSender: sender,
      finalRecipient: recipient,
    );
    return MeshRelayMessage(
      originalMessageId: msgId,
      originalContent: 'test',
      relayMetadata: metadata,
      relayNodeId: sender,
      relayedAt: DateTime.now(),
    );
  }

  group('GossipSyncManager — battery emergency mode', () {
    test('updateBatteryState tracks level and charging', () {
      manager.updateBatteryState(level: 50, isCharging: false);
      final stats = manager.getStatistics();
      expect(stats['batteryLevel'], 50);
      expect(stats['isCharging'], false);
    });

    test('critical battery skips periodic sync', () async {
      manager.updateBatteryState(level: 5, isCharging: false);

      // Track an announcement so sync has something to send
      final msg = createMessage('msg_bat', 'sender_1', 'recipient_1');
      manager.trackPublicMessage(
        messageId: 'msg_bat',
        message: msg,
        messageType: MessageType.announce,
      );

      QueueSyncMessage? captured;
      manager.onSendSyncRequest = (req) => captured = req;

      // Trigger periodic sync (via scheduleInitialSync with no delay)
      await manager.scheduleInitialSync(delay: Duration.zero);

      // Should be skipped due to emergency mode
      expect(captured, isNull);
    });

    test('charging at low battery does NOT skip sync', () async {
      manager.updateBatteryState(level: 5, isCharging: true);
      mockQueue.setMockHash('hash_123');

      final msg = createMessage('msg_charge', 'sender_1', 'recipient_1');
      manager.trackPublicMessage(
        messageId: 'msg_charge',
        message: msg,
        messageType: MessageType.announce,
      );

      QueueSyncMessage? captured;
      manager.onSendSyncRequest = (req) => captured = req;

      await manager.scheduleInitialSync(delay: Duration.zero);

      // Should NOT skip because we're charging
      expect(captured, isNotNull);
    });

    test('resumed sync after battery recovery logs info', () async {
      manager.updateBatteryState(level: 5, isCharging: false);

      // Skip a sync first
      await manager.scheduleInitialSync(delay: Duration.zero);

      // Now recover battery
      manager.updateBatteryState(level: 50, isCharging: false);
      mockQueue.setMockHash('hash_abc');

      final msg = createMessage('msg_recover', 'sender_1', 'recipient_1');
      manager.trackPublicMessage(
        messageId: 'msg_recover',
        message: msg,
        messageType: MessageType.announce,
      );

      QueueSyncMessage? captured;
      manager.onSendSyncRequest = (req) => captured = req;

      await manager.scheduleInitialSync(delay: Duration.zero);

      expect(captured, isNotNull);
      // Check that resume was logged
      final resumeLogs = logRecords
          .where((r) => r.message.contains('Resumed periodic sync'))
          .toList();
      expect(resumeLogs, isNotEmpty);
    });
  });

  group('GossipSyncManager — direct announcement triggering', () {
    test('first-hop announcement triggers onDirectAnnouncement once', () {
      final announced = <String>[];
      manager.onDirectAnnouncement = (nodeId) => announced.add(nodeId);

      final msg = createMessage('direct_1', 'sender_direct', 'recv', hopCount: 0);
      manager.trackPublicMessage(
        messageId: 'direct_1',
        message: msg,
        messageType: MessageType.announce,
      );

      expect(announced, ['sender_direct']);

      // Second announcement from same sender should NOT trigger again
      final msg2 = createMessage('direct_2', 'sender_direct', 'recv', hopCount: 0);
      manager.trackPublicMessage(
        messageId: 'direct_2',
        message: msg2,
        messageType: MessageType.announce,
      );
      expect(announced.length, 1);
    });

    test('multi-hop announcement does NOT trigger direct callback', () {
      final announced = <String>[];
      manager.onDirectAnnouncement = (nodeId) => announced.add(nodeId);

      final msg = createMessage('multi_hop', 'far_sender', 'recv', hopCount: 3);
      manager.trackPublicMessage(
        messageId: 'multi_hop',
        message: msg,
        messageType: MessageType.announce,
      );

      expect(announced, isEmpty);
    });
  });

  group('GossipSyncManager — LRU capacity enforcement', () {
    test('evicts oldest when exceeding maxSeenCapacity', () {
      // Track 1001 unique senders (maxSeenCapacity = 1000)
      for (int i = 0; i < 1001; i++) {
        final msg = createMessage('msg_$i', 'sender_$i', 'recv');
        manager.trackPublicMessage(
          messageId: 'msg_$i',
          message: msg,
          messageType: MessageType.announce,
        );
      }

      final stats = manager.getStatistics();
      // Should be capped at 1000
      expect(stats['trackedAnnouncements'], 1000);
    });
  });

  group('GossipSyncManager — statistics', () {
    test('getStatistics returns comprehensive data', () async {
      await manager.start();
      manager.updateBatteryState(level: 75, isCharging: true);

      final msg = createMessage('stat_msg', 'stat_sender', 'recv');
      manager.trackPublicMessage(
        messageId: 'stat_msg',
        message: msg,
        messageType: MessageType.announce,
      );

      final stats = manager.getStatistics();
      expect(stats['isRunning'], true);
      expect(stats['trackedAnnouncements'], 1);
      expect(stats['batteryLevel'], 75);
      expect(stats['isCharging'], true);
      expect(stats['skippedSyncsCount'], 0);
      expect(stats['emergencyMode'], false);
      expect(stats.containsKey('queueHash'), true);
    });
  });

  group('GossipSyncManager — sync with empty queue and no announcements', () {
    test('skips sync when nothing to advertise', () async {
      mockQueue.setMockHash('empty_hash');

      QueueSyncMessage? captured;
      manager.onSendSyncRequest = (req) => captured = req;

      await manager.scheduleInitialSync(delay: Duration.zero);

      // Should not send (no queued messages, no announcements)
      expect(captured, isNull);
    });
  });

  group('GossipSyncManager — start/stop idempotency', () {
    test('double start is safe', () async {
      await manager.start();
      await manager.start(); // second call should be no-op
      expect(manager.isRunning, true);
    });

    test('stop when not running is safe', () {
      manager.stop();
      expect(manager.isRunning, false);
    });
  });
}

/// Minimal mock of OfflineMessageQueueContract for gossip sync tests
class MockOfflineMessageQueue extends Fake
    implements OfflineMessageQueueContract {
  String _mockHash = 'mock_hash_default';

  void setMockHash(String hash) => _mockHash = hash;

  @override
  QueueStatistics getStatistics() => QueueStatistics(
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

  @override
  String calculateQueueHash({bool forceRecalculation = false}) => _mockHash;

  @override
  bool needsSynchronization(String otherQueueHash) =>
      _mockHash != otherQueueHash;

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) => [];

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) => [];

  @override
  QueueSyncMessage createSyncMessage(String nodeId) =>
      QueueSyncMessage.createRequest(
        messageIds: [],
        nodeId: nodeId,
        queueHash: _mockHash,
      );
}
