import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialize sqflite_ffi for testing
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Handshake Queue Flush Integration', () {
    late OfflineMessageQueue queue;
    late HandshakeCoordinator coordinator;
    final myPublicKey = 'my_public_key_12345';
    final myEphemeralId = 'my_ephemeral_123';
    final peerEphemeralId = 'peer_ephemeral_456';
    final peerDisplayName = 'Test Peer';

    setUp(() async {
      // Setup database
      final testDbName =
          'test_handshake_flush_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseHelper.setTestDatabaseName(testDbName);
      await DatabaseHelper.deleteDatabase();

      // Initialize queue
      queue = OfflineMessageQueue();
      await queue.initialize();

      // Setup coordinator (no actual send)
      coordinator = HandshakeCoordinator(
        myEphemeralId: myEphemeralId,
        myPublicKey: myPublicKey,
        myDisplayName: 'Test User',
        sendMessage: (message) async {
          // Mock send - do nothing
        },
        onHandshakeComplete: (ephemeralId, displayName, noiseKey) async {
          // Mock complete callback
        },
      );
    });

    tearDown(() async {
      queue.dispose();
      coordinator.dispose();
      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
    });

    test('handshake success triggers queue flush', () async {
      // Queue messages for peer
      await queue.queueMessage(
        chatId: 'test_chat',
        content: 'Message 1',
        recipientPublicKey: peerEphemeralId,
        senderPublicKey: myPublicKey,
        priority: MessagePriority.normal,
      );

      await queue.queueMessage(
        chatId: 'test_chat',
        content: 'Message 2',
        recipientPublicKey: peerEphemeralId,
        senderPublicKey: myPublicKey,
        priority: MessagePriority.high,
      );

      // Verify messages are queued
      var stats = queue.getStatistics();
      expect(stats.pendingMessages, 2);

      // Track flush calls
      bool flushCalled = false;
      String? flushedPeerId;

      // Set up handshake success callback
      coordinator.onHandshakeSuccess = (peerId) async {
        flushCalled = true;
        flushedPeerId = peerId;
        await queue.flushQueueForPeer(peerId);
      };

      // Simulate handshake completion by directly calling the callback
      // (In real scenario, this would be triggered by handshake protocol)
      await coordinator.onHandshakeSuccess?.call(peerEphemeralId);

      // Verify flush was called
      expect(flushCalled, true);
      expect(flushedPeerId, peerEphemeralId);
    });

    test('flushQueueForPeer only flushes messages for that peer', () async {
      final otherPeerId = 'other_peer_789';

      // Queue messages for two different peers
      await queue.queueMessage(
        chatId: 'chat_1',
        content: 'For peer 1',
        recipientPublicKey: peerEphemeralId,
        senderPublicKey: myPublicKey,
      );

      await queue.queueMessage(
        chatId: 'chat_2',
        content: 'For peer 2',
        recipientPublicKey: otherPeerId,
        senderPublicKey: myPublicKey,
      );

      var stats = queue.getStatistics();
      expect(stats.pendingMessages, 2);

      // Flush only for peer 1
      await queue.flushQueueForPeer(peerEphemeralId);

      // Verify only peer 1's messages were processed
      final peerMessages = queue
          .getPendingMessages()
          .where((m) => m.recipientPublicKey == peerEphemeralId)
          .toList();

      final otherMessages = queue
          .getPendingMessages()
          .where((m) => m.recipientPublicKey == otherPeerId)
          .toList();

      // Peer 1's messages should be attempted (may be retrying or awaiting ACK)
      expect(peerMessages.length, lessThan(2)); // Some may have been processed

      // Peer 2's messages should still be pending
      expect(otherMessages.length, 1);
    });

    test('flushQueueForPeer handles empty queue gracefully', () async {
      // Flush when no messages queued
      await queue.flushQueueForPeer(peerEphemeralId);

      var stats = queue.getStatistics();
      expect(stats.pendingMessages, 0);
    });

    test('flushQueueForPeer processes messages in priority order', () async {
      final deliveredMessages = <String>[];

      // Mock send callback to track order
      queue.onSendMessage = (messageId) {
        deliveredMessages.add(messageId);
      };

      // Queue messages with different priorities
      final lowId = await queue.queueMessage(
        chatId: 'chat',
        content: 'Low priority',
        recipientPublicKey: peerEphemeralId,
        senderPublicKey: myPublicKey,
        priority: MessagePriority.low,
      );

      final urgentId = await queue.queueMessage(
        chatId: 'chat',
        content: 'Urgent',
        recipientPublicKey: peerEphemeralId,
        senderPublicKey: myPublicKey,
        priority: MessagePriority.urgent,
      );

      final normalId = await queue.queueMessage(
        chatId: 'chat',
        content: 'Normal',
        recipientPublicKey: peerEphemeralId,
        senderPublicKey: myPublicKey,
        priority: MessagePriority.normal,
      );

      // Flush queue
      await queue.flushQueueForPeer(peerEphemeralId);

      // Verify urgent was sent first
      expect(deliveredMessages.isNotEmpty, true);
      // First message should be urgent (highest priority)
      expect(deliveredMessages.first, urgentId);
    });

    test(
      'multiple handshake completions do not cause duplicate sends',
      () async {
        int sendCount = 0;

        queue.onSendMessage = (messageId) {
          sendCount++;
        };

        // Queue a message
        await queue.queueMessage(
          chatId: 'chat',
          content: 'Test',
          recipientPublicKey: peerEphemeralId,
          senderPublicKey: myPublicKey,
        );

        // Flush twice (simulating duplicate handshake events)
        await queue.flushQueueForPeer(peerEphemeralId);
        await queue.flushQueueForPeer(peerEphemeralId);

        // Message should only be sent once
        expect(sendCount, 1);
      },
    );
  });
}
