// Tests for Phase 2: BLE Integration and Message Type Filtering
// Verifies message type passing from BLE layer to relay engine

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/relay_config_manager.dart';
import 'package:pak_connect/core/messaging/relay_policy.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

void main() {
  group('Phase 2: ProtocolMessage Message Type Serialization', () {
    test('Should serialize and deserialize meshRelay with message type', () {
      final originalType = ProtocolMessageType.textMessage;

      final message = ProtocolMessage.meshRelay(
        originalMessageId: 'test-msg-123',
        originalSender: 'sender-abc',
        finalRecipient: 'recipient-xyz',
        relayMetadata: {
          'ttl': 10,
          'hopCount': 1,
          'routingPath': ['node1'],
          'messageHash': 'hash123',
          'priority': 2,
          'relayTimestamp': DateTime.now().millisecondsSinceEpoch,
          'originalSender': 'sender-abc',
          'finalRecipient': 'recipient-xyz',
          'senderRateCount': 0,
        },
        originalPayload: {'content': 'Hello World'},
        originalMessageType: originalType,
      );

      // Serialize to bytes
      final bytes = message.toBytes();

      // Deserialize
      final decoded = ProtocolMessage.fromBytes(bytes);

      expect(decoded.type, equals(ProtocolMessageType.meshRelay));
      expect(decoded.meshRelayOriginalMessageType, equals(originalType));
      expect(decoded.meshRelayOriginalMessageId, equals('test-msg-123'));
    });

    test(
      'Should handle meshRelay without message type (backward compatibility)',
      () {
        final message = ProtocolMessage.meshRelay(
          originalMessageId: 'test-msg-123',
          originalSender: 'sender-abc',
          finalRecipient: 'recipient-xyz',
          relayMetadata: {
            'ttl': 10,
            'hopCount': 1,
            'routingPath': ['node1'],
            'messageHash': 'hash123',
            'priority': 2,
            'relayTimestamp': DateTime.now().millisecondsSinceEpoch,
            'originalSender': 'sender-abc',
            'finalRecipient': 'recipient-xyz',
            'senderRateCount': 0,
          },
          originalPayload: {'content': 'Hello World'},
        );

        final bytes = message.toBytes();
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.type, equals(ProtocolMessageType.meshRelay));
        expect(decoded.meshRelayOriginalMessageType, isNull);
      },
    );

    test('Should preserve all message types through serialization', () {
      final testTypes = [
        ProtocolMessageType.textMessage,
        ProtocolMessageType.meshRelay,
        ProtocolMessageType.queueSync,
        ProtocolMessageType.relayAck,
      ];

      for (final originalType in testTypes) {
        final message = ProtocolMessage.meshRelay(
          originalMessageId: 'test-msg',
          originalSender: 'sender',
          finalRecipient: 'recipient',
          relayMetadata: {
            'ttl': 10,
            'hopCount': 1,
            'routingPath': ['node1'],
            'messageHash': 'hash',
            'priority': 2,
            'relayTimestamp': DateTime.now().millisecondsSinceEpoch,
            'originalSender': 'sender',
            'finalRecipient': 'recipient',
            'senderRateCount': 0,
          },
          originalPayload: {'content': 'Test'},
          originalMessageType: originalType,
        );

        final bytes = message.toBytes();
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(
          decoded.meshRelayOriginalMessageType,
          equals(originalType),
          reason: 'Failed to preserve ${originalType.name}',
        );
      }
    });
  });

  group('Phase 2: MeshRelayMessage Message Type Handling', () {
    test('Should create and preserve message type', () {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Test message',
        priority: MessagePriority.normal,
        originalSender: 'sender123',
        finalRecipient: 'recipient456',
        currentNodeId: 'sender123',
      );

      final message = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-001',
        originalContent: 'Test message',
        metadata: metadata,
        relayNodeId: 'relay-node',
        originalMessageType: ProtocolMessageType.textMessage,
      );

      expect(
        message.originalMessageType,
        equals(ProtocolMessageType.textMessage),
      );
    });

    test('Should preserve message type through nextHop', () {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Test',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'recipient',
        currentNodeId: 'node1',
      );

      final originalMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-001',
        originalContent: 'Test',
        metadata: metadata,
        relayNodeId: 'node1',
        originalMessageType: ProtocolMessageType.textMessage,
      );

      final nextHopMessage = originalMessage.nextHop('node2');

      expect(
        nextHopMessage.originalMessageType,
        equals(ProtocolMessageType.textMessage),
      );
      expect(nextHopMessage.relayMetadata.hopCount, equals(2));
    });

    test('Should serialize and deserialize with message type', () {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Test',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'recipient',
        currentNodeId: 'node1',
      );

      final original = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-001',
        originalContent: 'Test',
        metadata: metadata,
        relayNodeId: 'node1',
        originalMessageType: ProtocolMessageType.queueSync,
      );

      final json = original.toJson();
      final decoded = MeshRelayMessage.fromJson(json);

      expect(
        decoded.originalMessageType,
        equals(ProtocolMessageType.queueSync),
      );
      expect(decoded.originalMessageId, equals('msg-001'));
    });

    test('Should handle null message type (backward compatibility)', () {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Test',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'recipient',
        currentNodeId: 'node1',
      );

      final message = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-001',
        originalContent: 'Test',
        metadata: metadata,
        relayNodeId: 'node1',
      );

      expect(message.originalMessageType, isNull);

      final json = message.toJson();
      final decoded = MeshRelayMessage.fromJson(json);

      expect(decoded.originalMessageType, isNull);
    });
  });

  group('Phase 2: Relay Engine Message Type Filtering', () {
    late MeshRelayEngine relayEngine;
    late ContactRepository contactRepo;
    late OfflineMessageQueue messageQueue;
    late SpamPreventionManager spamPrevention;

    setUp(() async {
      contactRepo = ContactRepository();
      messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);
      spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      relayEngine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(currentNodeId: 'node-current');

      // Ensure relay is enabled
      final config = RelayConfigManager.instance;
      await config.resetToDefaults();
      await config.enableRelay();
    });

    test('Should reject non-relay-eligible message types', () async {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Handshake data',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'recipient',
        currentNodeId: 'node1',
      );

      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-handshake',
        originalContent: 'Handshake data',
        metadata: metadata,
        relayNodeId: 'node1',
        originalMessageType: ProtocolMessageType.noiseHandshake1,
      );

      final result = await relayEngine.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: 'node1',
        messageType: ProtocolMessageType.noiseHandshake1,
      );

      expect(result.type, equals(RelayProcessingType.dropped));
      expect(result.reason, contains('cannot be relayed'));
    });

    test('Should allow relay-eligible message types', () async {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Hello',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'node-current', // Address to us
        currentNodeId: 'node1',
      );

      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-text',
        originalContent: 'Hello',
        metadata: metadata,
        relayNodeId: 'node1',
        originalMessageType: ProtocolMessageType.textMessage,
      );

      final result = await relayEngine.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: 'node1',
        messageType: ProtocolMessageType.textMessage,
      );

      // Should be delivered to self OR relayed (not dropped for message type)
      // The key check is that it's not dropped due to message type filtering
      expect(
        result.type,
        isNot(equals(RelayProcessingType.dropped)),
        reason:
            'Text messages should not be dropped due to message type filtering',
      );

      // If it failed with error, check that it's not message type related
      if (result.type == RelayProcessingType.error) {
        expect(
          result.reason,
          isNot(contains('cannot be relayed')),
          reason: 'Error should not be message type related',
        );
      }
    });

    test(
      'Should prevent creating relay for non-eligible message type',
      () async {
        final relayMessage = await relayEngine.createOutgoingRelay(
          originalMessageId: 'msg-001',
          originalContent: 'Pairing request',
          finalRecipientPublicKey: 'recipient',
          originalMessageType: ProtocolMessageType.pairingRequest,
        );

        expect(
          relayMessage,
          isNull,
          reason: 'Should not create relay for pairing messages',
        );
      },
    );

    test('Should allow creating relay for eligible message type', () async {
      final relayMessage = await relayEngine.createOutgoingRelay(
        originalMessageId: 'msg-001',
        originalContent: 'Hello',
        finalRecipientPublicKey: 'recipient',
        originalMessageType: ProtocolMessageType.textMessage,
      );

      expect(relayMessage, isNotNull);
      expect(
        relayMessage!.originalMessageType,
        equals(ProtocolMessageType.textMessage),
      );
    });

    test('Should handle null message type gracefully', () async {
      final metadata = RelayMetadata.create(
        originalMessageContent: 'Test',
        priority: MessagePriority.normal,
        originalSender: 'sender',
        finalRecipient: 'node-current',
        currentNodeId: 'node1',
      );

      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-001',
        originalContent: 'Test',
        metadata: metadata,
        relayNodeId: 'node1',
      );

      // Should process without type filtering when type is null
      final result = await relayEngine.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: 'node1',
      );

      // Should not be dropped for missing message type (might error for other reasons, but not type filtering)
      expect(
        result.type,
        isNot(equals(RelayProcessingType.dropped)),
        reason: 'Should not be dropped when message type is null',
      );

      // If it failed, verify it's not due to message type issues
      if (result.type == RelayProcessingType.dropped ||
          result.type == RelayProcessingType.error) {
        expect(
          result.reason,
          isNot(contains('not relay-eligible')),
          reason: 'Should not fail due to message type when type is null',
        );
      }
    });
  });

  group('Phase 2: Integration Tests', () {
    test(
      'Should preserve message type through multi-hop relay chain',
      () async {
        final contactRepo = ContactRepository();
        final messageQueue = OfflineMessageQueue();
        await messageQueue.initialize(contactRepository: contactRepo);
        final spamPrevention = SpamPreventionManager();
        await spamPrevention.initialize();

        // Create relay engine for node A
        final engineA = MeshRelayEngine(
          contactRepository: contactRepo,
          messageQueue: messageQueue,
          spamPrevention: spamPrevention,
        );
        await engineA.initialize(currentNodeId: 'node-A');

        // Create initial relay message
        final originalMetadata = RelayMetadata.create(
          originalMessageContent: 'Multi-hop test',
          priority: MessagePriority.normal,
          originalSender: 'node-originator',
          finalRecipient: 'node-final',
          currentNodeId: 'node-originator',
        );

        var relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'multi-hop-msg',
          originalContent: 'Multi-hop test',
          metadata: originalMetadata,
          relayNodeId: 'node-originator',
          originalMessageType: ProtocolMessageType.textMessage,
        );

        // Simulate 3 hops
        relayMessage = relayMessage.nextHop('node-A');
        expect(
          relayMessage.originalMessageType,
          equals(ProtocolMessageType.textMessage),
        );
        expect(relayMessage.relayMetadata.hopCount, equals(2));

        relayMessage = relayMessage.nextHop('node-B');
        expect(
          relayMessage.originalMessageType,
          equals(ProtocolMessageType.textMessage),
        );
        expect(relayMessage.relayMetadata.hopCount, equals(3));

        relayMessage = relayMessage.nextHop('node-C');
        expect(
          relayMessage.originalMessageType,
          equals(ProtocolMessageType.textMessage),
        );
        expect(relayMessage.relayMetadata.hopCount, equals(4));

        // Message type should be preserved through entire chain
        expect(
          relayMessage.originalMessageType,
          equals(ProtocolMessageType.textMessage),
        );
      },
    );

    test('All message types should have consistent filtering behavior', () {
      // Test each message type for consistency
      for (final type in ProtocolMessageType.values) {
        final isEligible = RelayPolicy.isRelayEligibleMessageType(type);

        // Check consistency: Same type should always return same result
        for (int i = 0; i < 3; i++) {
          expect(
            RelayPolicy.isRelayEligibleMessageType(type),
            equals(isEligible),
            reason: '${type.name} should have consistent relay eligibility',
          );
        }
      }
    });

    test('Non-eligible types should be rejected at relay engine', () async {
      final contactRepo = ContactRepository();
      final messageQueue = OfflineMessageQueue();
      await messageQueue.initialize(contactRepository: contactRepo);
      final spamPrevention = SpamPreventionManager();
      await spamPrevention.initialize();

      final engine = MeshRelayEngine(
        contactRepository: contactRepo,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );
      await engine.initialize(currentNodeId: 'node-test');

      // Get all non-relayable types
      final nonRelayableTypes = RelayPolicy.getNonRelayableTypes();

      for (final type in nonRelayableTypes) {
        final metadata = RelayMetadata.create(
          originalMessageContent: 'Test ${type.name}',
          priority: MessagePriority.normal,
          originalSender: 'sender',
          finalRecipient: 'recipient',
          currentNodeId: 'node1',
        );

        final relayMessage = MeshRelayMessage.createRelay(
          originalMessageId: 'msg-${type.name}',
          originalContent: 'Test ${type.name}',
          metadata: metadata,
          relayNodeId: 'node1',
          originalMessageType: type,
        );

        final result = await engine.processIncomingRelay(
          relayMessage: relayMessage,
          fromNodeId: 'node1',
          messageType: type,
        );

        expect(
          result.type,
          equals(RelayProcessingType.dropped),
          reason: '${type.name} should be dropped by relay engine',
        );
      }
    });
  });
}
