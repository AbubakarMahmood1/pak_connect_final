import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

void main() {
  group('Mesh Relay Integration Tests', () {
    test('ProtocolMessage enum extensions work correctly', () {
      // Test that new message types are properly integrated
      expect(
        ProtocolMessageType.values.contains(ProtocolMessageType.meshRelay),
        true,
      );
      expect(
        ProtocolMessageType.values.contains(ProtocolMessageType.queueSync),
        true,
      );
      expect(
        ProtocolMessageType.values.contains(ProtocolMessageType.relayAck),
        true,
      );

      // Test serialization with new message types
      final meshRelayMessage = ProtocolMessage.meshRelay(
        originalMessageId: 'test-msg-123',
        originalSender: 'sender-public-key',
        finalRecipient: 'recipient-public-key',
        relayMetadata: {
          'ttl': 10,
          'hopCount': 2,
          'routingPath': ['node1', 'node2'],
          'messageHash': 'hash123',
        },
        originalPayload: {'content': 'Hello World'},
      );

      // Test serialization and deserialization
      final bytes = meshRelayMessage.toBytes();
      final deserializedMessage = ProtocolMessage.fromBytes(bytes);

      expect(deserializedMessage.type, ProtocolMessageType.meshRelay);
      expect(deserializedMessage.meshRelayOriginalMessageId, 'test-msg-123');
      expect(deserializedMessage.meshRelayOriginalSender, 'sender-public-key');
      expect(
        deserializedMessage.meshRelayFinalRecipient,
        'recipient-public-key',
      );
    });

    test('QueueSync message creation and serialization', () {
      final syncMessage = QueueSyncMessage(
        queueHash: 'queue-hash-123',
        messageIds: ['msg1', 'msg2', 'msg3'],
        syncTimestamp: DateTime.now(),
        nodeId: 'node-123',
        syncType: QueueSyncType.request,
      );

      final protocolMessage = ProtocolMessage.queueSync(
        queueMessage: syncMessage,
      );

      expect(protocolMessage.type, ProtocolMessageType.queueSync);
      expect(protocolMessage.queueSyncMessage?.queueHash, 'queue-hash-123');
      expect(protocolMessage.queueSyncMessage?.messageIds, [
        'msg1',
        'msg2',
        'msg3',
      ]);

      // Test serialization
      final bytes = protocolMessage.toBytes();
      final deserialized = ProtocolMessage.fromBytes(bytes);
      expect(deserialized.queueSyncMessage?.messageIds, [
        'msg1',
        'msg2',
        'msg3',
      ]);
    });

    test('RelayAck message creation and serialization', () {
      final relayAckMessage = ProtocolMessage.relayAck(
        originalMessageId: 'original-123',
        relayNode: 'relay-node-456',
        delivered: true,
      );

      expect(relayAckMessage.type, ProtocolMessageType.relayAck);
      expect(relayAckMessage.relayAckOriginalMessageId, 'original-123');
      expect(relayAckMessage.relayAckRelayNode, 'relay-node-456');
      expect(relayAckMessage.relayAckDelivered, true);
    });

    test('RelayMetadata creation and TTL handling', () {
      // Test different priority levels
      final urgentMetadata = RelayMetadata.create(
        originalMessageContent: 'Urgent message',
        priority: MessagePriority.urgent,
        originalSender: 'sender1',
        finalRecipient: 'recipient1',
        currentNodeId: 'node1',
      );
      expect(urgentMetadata.ttl, 20); // Urgent = 20 hops

      final lowMetadata = RelayMetadata.create(
        originalMessageContent: 'Low priority message',
        priority: MessagePriority.low,
        originalSender: 'sender2',
        finalRecipient: 'recipient2',
        currentNodeId: 'node2',
      );
      expect(lowMetadata.ttl, 5); // Low = 5 hops

      // Test hop progression
      final nextHop = urgentMetadata.nextHop('node2');
      expect(nextHop.hopCount, 2);
      expect(nextHop.routingPath, ['node1', 'node2']);
      expect(nextHop.canRelay, true);
    });

    test('Loop detection in RelayMetadata', () {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Test message',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'recipient',
        currentNodeId: 'node1',
      );

      final nextHop = metadata.nextHop('node2');

      // Should throw exception when trying to add node already in path
      expect(() => nextHop.nextHop('node1'), throwsA(isA<RelayException>()));
    });

    test('TTL exhaustion handling', () {
      final metadata = RelayMetadata(
        ttl: 2,
        hopCount: 2,
        routingPath: ['node1', 'node2'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: 'sender',
        finalRecipient: 'recipient',
      );

      expect(metadata.canRelay, false);
      expect(() => metadata.nextHop('node3'), throwsA(isA<RelayException>()));
    });

    test('MeshRelayMessage creation and forwarding', () {
      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-123',
        originalContent: 'Hello World',
        metadata: RelayMetadata.create(
          originalMessageContent: 'Hello World',
          priority: MessagePriority.normal,
          originalSender: 'sender',
          finalRecipient: 'recipient',
          currentNodeId: 'relay1',
        ),
        relayNodeId: 'relay1',
      );

      expect(relayMessage.canRelay, true);
      expect(relayMessage.relayMetadata.hopCount, 1);

      // Test forwarding
      final forwarded = relayMessage.nextHop('relay2');
      expect(forwarded.relayMetadata.hopCount, 2);
      expect(forwarded.relayNodeId, 'relay2');
    });

    test('QueuedMessage backward compatibility', () {
      // Test that existing QueuedMessage creation still works
      final originalMessage = QueuedMessage(
        id: 'msg-456',
        chatId: 'chat-123',
        content: 'Regular message',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 3,
      );

      // Should have default values for relay fields
      expect(originalMessage.isRelayMessage, false);
      expect(originalMessage.relayMetadata, null);
      expect(originalMessage.canRelay, false);

      // Test JSON serialization with backward compatibility
      final json = originalMessage.toJson();
      expect(json['isRelayMessage'], false);
      expect(
        json.containsKey('relayMetadata'),
        false,
      ); // Should not be included if null

      // Test deserialization (should work with old JSON without relay fields)
      final oldJsonFormat = {
        'id': 'msg-789',
        'chatId': 'chat-456',
        'content': 'Old format message',
        'recipientPublicKey': 'recipient',
        'senderPublicKey': 'sender',
        'priority': 1, // normal
        'queuedAt': DateTime.now().millisecondsSinceEpoch,
        'maxRetries': 3,
        'replyToMessageId': null,
        'attachments': [],
        'status': 0, // pending
        'attempts': 0,
      };

      final deserializedOld = QueuedMessage.fromJson(oldJsonFormat);
      expect(deserializedOld.isRelayMessage, false); // Should default to false
      expect(deserializedOld.relayMetadata, null);
      expect(deserializedOld.senderRateCount, 0); // Should default to 0
    });

    test('QueuedMessage relay functionality', () {
      // Create a relay message
      final meshRelayMsg = MeshRelayMessage.createRelay(
        originalMessageId: 'orig-123',
        originalContent: 'Relay test message',
        metadata: RelayMetadata.create(
          originalMessageContent: 'Relay test message',
          priority: MessagePriority.high,
          originalSender: 'sender',
          finalRecipient: 'recipient',
          currentNodeId: 'relay1',
        ),
        relayNodeId: 'relay1',
      );

      final queuedRelay = QueuedMessage.fromRelayMessage(
        relayMessage: meshRelayMsg,
        chatId: 'chat-relay',
        maxRetries: 5,
      );

      expect(queuedRelay.isRelayMessage, true);
      expect(queuedRelay.canRelay, true);
      expect(queuedRelay.relayHopCount, 1);
      expect(queuedRelay.originalMessageId, 'orig-123');

      // Test creating next hop
      final nextHopQueued = queuedRelay.createNextHopRelay('relay2');
      expect(nextHopQueued.relayHopCount, 2);
      expect(nextHopQueued.relayNodeId, 'relay2');
    });

    test('QueueSyncMessage functionality', () {
      final syncMessage = QueueSyncMessage.createRequest(
        messageIds: ['msg1', 'msg2', 'msg3'],
        nodeId: 'node-123',
        messageHashes: {'msg1': 'hash1', 'msg2': 'hash2', 'msg3': 'hash3'},
      );

      expect(syncMessage.syncType, QueueSyncType.request);
      expect(syncMessage.messageIds.length, 3);

      // Test queue hash comparison
      final otherSync = QueueSyncMessage.createRequest(
        messageIds: ['msg1', 'msg2', 'msg3'], // Same messages
        nodeId: 'node-456',
      );

      expect(syncMessage.isQueueSynchronized(otherSync.queueHash), true);

      // Test missing messages detection
      final syncWithMore = QueueSyncMessage.createRequest(
        messageIds: ['msg1', 'msg2', 'msg3', 'msg4'],
        nodeId: 'node-789',
      );

      final missing = syncMessage.getMissingMessages(syncWithMore.messageIds);
      expect(missing, ['msg4']);
    });

    test('End-to-end relay flow simulation', () {
      // 1. Create relay metadata
      final relayMetadata = RelayMetadata.create(
        originalMessageContent: 'Hello from mesh network!',
        priority: MessagePriority.normal,
        originalSender: 'alice-key',
        finalRecipient: 'bob-key',
        currentNodeId: 'relay-node-1',
      );

      // 2. Create mesh relay message
      final meshRelay = MeshRelayMessage.createRelay(
        originalMessageId: 'original-msg',
        originalContent: 'Hello from mesh network!',
        metadata: relayMetadata,
        relayNodeId: 'relay-node-1',
      );

      // 3. Convert to protocol message for transmission
      final relayProtocolMsg = ProtocolMessage.meshRelay(
        originalMessageId: meshRelay.originalMessageId,
        originalSender: meshRelay.relayMetadata.originalSender,
        finalRecipient: meshRelay.relayMetadata.finalRecipient,
        relayMetadata: meshRelay.relayMetadata.toJson(),
        originalPayload: {'content': meshRelay.originalContent},
      );

      // 5. Simulate transmission and reception
      final transmitted = relayProtocolMsg.toBytes();
      final received = ProtocolMessage.fromBytes(transmitted);

      // 6. Verify relay information is preserved
      expect(received.type, ProtocolMessageType.meshRelay);
      expect(received.meshRelayOriginalMessageId, 'original-msg');
      expect(received.meshRelayOriginalSender, 'alice-key');
      expect(received.meshRelayFinalRecipient, 'bob-key');

      // 7. Test relay continuation at next node
      final receivedMetadata = RelayMetadata.fromJson(
        received.meshRelayMetadata!,
      );
      expect(receivedMetadata.canRelay, true);
      expect(receivedMetadata.hopCount, 1);

      final nextHopMetadata = receivedMetadata.nextHop('relay-node-2');
      expect(nextHopMetadata.hopCount, 2);
      expect(nextHopMetadata.routingPath, ['relay-node-1', 'relay-node-2']);
    });
  });
}
