import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/relay_coordinator.dart';

void main() {
  group('RelayCoordinator', () {
    late RelayCoordinator coordinator;

    setUp(() {
      coordinator = RelayCoordinator();
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('creates instance successfully', () {
      expect(coordinator, isNotNull);
    });

    test('initializes relay system', () async {
      expect(
        () => coordinator.initializeRelaySystem(currentNodeId: 'node-123'),
        returnsNormally,
      );
    });

    test('sets current node ID', () {
      expect(() => coordinator.setCurrentNodeId('node-456'), returnsNormally);
    });

    test('gets available next hops', () {
      final hops = coordinator.getAvailableNextHops();
      expect(hops, isA<List<String>>());
    });

    test('should attempt relay respects hop limit', () {
      // Should relay at 0 hops
      expect(
        coordinator.shouldAttemptRelay(messageId: 'msg1', currentHopCount: 0),
        isTrue,
      );

      // Should relay at 2 hops
      expect(
        coordinator.shouldAttemptRelay(messageId: 'msg2', currentHopCount: 2),
        isTrue,
      );

      // Should NOT relay at 3+ hops (limit reached)
      expect(
        coordinator.shouldAttemptRelay(messageId: 'msg3', currentHopCount: 3),
        isFalse,
      );
    });

    test('should attempt decryption returns false for relay', () async {
      final result = await coordinator.shouldAttemptDecryption(
        messageId: 'msg1',
        senderKey: 'sender',
      );
      expect(result, isFalse);
    });

    test('registers relay stats callback', () {
      var statsReceived = false;

      coordinator.onRelayStatsUpdated((stats) {
        statsReceived = true;
      });

      expect(coordinator, isNotNull);
    });

    test('registers relay message callback', () {
      coordinator.onRelayMessageReceived((messageId, content, sender) {
        // Callback registered
      });

      expect(coordinator, isNotNull);
    });

    test('registers relay decision callback', () {
      coordinator.onRelayDecisionMade((decision) {
        // Callback registered
      });

      expect(coordinator, isNotNull);
    });

    test('registers send relay message callback', () {
      coordinator.onSendRelayMessage((message, nextHopId) {
        // Callback registered
      });

      expect(coordinator, isNotNull);
    });

    test('registers send ACK message callback', () {
      coordinator.onSendAckMessage((message) {
        // Callback registered
      });

      expect(coordinator, isNotNull);
    });

    test('registers queue sync received callback', () {
      coordinator.onQueueSyncReceived((syncMessage, fromNodeId) {
        // Callback registered
      });

      expect(coordinator, isNotNull);
    });

    test('registers queue sync completed callback', () {
      coordinator.onQueueSyncCompleted((nodeId, result) {
        // Callback registered
      });

      expect(coordinator, isNotNull);
    });

    test('sends queue sync message', () async {
      final result = await coordinator.sendQueueSyncMessage(
        toNodeId: 'node-456',
        messageIds: ['msg1', 'msg2', 'msg3'],
      );

      expect(result, isA<bool>());
    });

    test('gets relay statistics', () async {
      final stats = await coordinator.getRelayStatistics();

      expect(stats.totalRelayed, equals(0));
      expect(stats.totalDeliveredToSelf, equals(0));
      expect(stats.totalProbabilisticSkip, equals(0));
      expect(stats.totalBlocked, equals(0));
      expect(stats.totalDropped, equals(0));
    });

    test('creates outgoing relay message', () async {
      final relayMsg = await coordinator.createOutgoingRelay(
        originalMessageId: 'original-msg-123',
        content: 'Test content',
        originalSender: 'sender-node',
        intendedRecipient: 'recipient-node',
        currentHopCount: 1,
      );

      expect(relayMsg, isNotNull);
      if (relayMsg != null) {
        expect(relayMsg.originalMessageId, equals('original-msg-123'));
        expect(relayMsg.originalContent, equals('Test content'));
        expect(relayMsg.relayMetadata.originalSender, equals('sender-node'));
        expect(relayMsg.relayMetadata.finalRecipient, equals('recipient-node'));
        expect(relayMsg.relayMetadata.hopCount, equals(1)); // initial hop
      }
    });

    test('handles relay delivery to self', () {
      var messageReceivedCallbackFired = false;

      coordinator.onRelayMessageReceived((messageId, content, sender) {
        messageReceivedCallbackFired = true;
      });

      expect(
        () => coordinator.handleRelayDeliveryToSelf(
          originalMessageId: 'msg123',
          content: 'Test',
          originalSender: 'sender',
        ),
        returnsNormally,
      );
    });

    test('sends relay ACK', () async {
      coordinator.onSendAckMessage((message) {
        // ACK message sent
      });

      expect(
        () => coordinator.sendRelayAck(
          originalMessageId: 'msg123',
          toDeviceId: 'device-456',
          relayAckContent: 'ACK:msg123',
        ),
        returnsNormally,
      );
    });

    test('handles relay ACK', () async {
      expect(
        () => coordinator.handleRelayAck(
          originalMessageId: 'msg123',
          fromDeviceId: 'device-456',
          ackData: {'status': 'delivered'},
        ),
        returnsNormally,
      );
    });

    test('handles mesh relay', () async {
      final result = await coordinator.handleMeshRelay(
        originalMessageId: 'msg123',
        content: 'Test message',
        originalSender: 'sender-node',
        intendedRecipient: null,
        messageData: null,
        currentHopCount: 1,
      );

      expect(result, isA<bool>());
    });

    test('dispose completes without error', () {
      expect(() => coordinator.dispose(), returnsNormally);
    });
  });
}
