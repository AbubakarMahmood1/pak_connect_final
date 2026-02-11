// Comprehensive end-to-end tests for A→B→C mesh relay functionality
// Tests the complete store-and-forward relay logic with spam prevention

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import '../../test_helpers/test_setup.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';
import '../../test_helpers/test_seen_message_store.dart';
import 'package:pak_connect/domain/models/security_level.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'mesh_relay_flow',
      useRealServiceLocator: true,
      configureDiWithMocks: false,
    );
  });

  setUp(() async {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.configureTestDatabase(label: 'mesh_relay_flow');
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
    await TestSetup.nukeDatabase();
  });

  group('Mesh Relay Flow Tests', () {
    late ContactRepository contactRepository;
    late OfflineMessageQueueContract messageQueue;
    late SpamPreventionManager spamPrevention;
    late MeshRelayEngine relayEngine;
    late BLEMessageHandler messageHandler;
    late ISeenMessageStore seenStore;

    // Test node identities
    const String nodeA = 'node_a_public_key_12345678901234567890123456789012';
    const String nodeB = 'node_b_public_key_12345678901234567890123456789012';
    const String nodeC = 'node_c_public_key_12345678901234567890123456789012';

    setUp(() async {
      contactRepository = ContactRepository();
      messageQueue = InMemoryOfflineMessageQueue();
      spamPrevention = SpamPreventionManager();
      messageHandler = BLEMessageHandler();
      seenStore = TestSeenMessageStore();

      await messageQueue.initialize();
      await spamPrevention.initialize();

      relayEngine = MeshRelayEngine(
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
        seenMessageStore: seenStore,
      );
    });

    Future<void> initRelayAs(String nodeId) async {
      await seenStore.clear();
      await spamPrevention.resetForTests();
      await relayEngine.initialize(currentNodeId: nodeId);
    }

    Future<MeshRelayMessage?> createRelayFromNode(
      String senderNodeId, {
      required String messageId,
      required String content,
      required String finalRecipient,
      MessagePriority priority = MessagePriority.normal,
    }) async {
      final tempQueue = InMemoryOfflineMessageQueue();
      await tempQueue.initialize();
      final tempSpam = SpamPreventionManager();
      await tempSpam.initialize();
      final tempEngine = MeshRelayEngine(
        messageQueue: tempQueue,
        spamPrevention: tempSpam,
        seenMessageStore: TestSeenMessageStore(),
      );
      await tempEngine.initialize(currentNodeId: senderNodeId);
      final relay = await tempEngine.createOutgoingRelay(
        originalMessageId: messageId,
        originalContent: content,
        finalRecipientPublicKey: finalRecipient,
        priority: priority,
      );
      tempQueue.dispose();
      tempSpam.dispose();
      return relay;
    }

    tearDown(() async {
      try {
        messageQueue.dispose();
        spamPrevention.dispose();
        messageHandler.dispose();
        relayEngine.clearStatistics();
        spamPrevention.clearStatistics();
        await MessageSecurity.clearProcessedMessages();
      } catch (e) {
        // Ignore cleanup errors in tests
      }
    });

    test('Basic A→B→C Relay Flow', () async {
      // Test scenario: Node A sends message to Node C via Node B

      // Step 1: Node A creates outgoing relay message to Node C
      final outgoingRelay = await createRelayFromNode(
        nodeA,
        messageId: 'test_msg_001',
        content: 'Hello from A to C via B!',
        finalRecipient: nodeC,
        priority: MessagePriority.normal,
      );
      await initRelayAs(nodeB);

      expect(outgoingRelay, isNotNull);
      expect(
        outgoingRelay!.relayMetadata.originalSender,
        equals(nodeA),
      ); // Fixed: should be nodeA
      expect(outgoingRelay.relayMetadata.finalRecipient, equals(nodeC));
      expect(outgoingRelay.relayMetadata.hopCount, equals(1));
      expect(
        outgoingRelay.relayMetadata.ttl,
        equals(4),
      ); // Normal priority TTL (max hops = 4)

      // Step 2: Node B receives and processes the relay message
      await initRelayAs(nodeB); // Reinitialize as nodeB
      final List<String> availableHops = [
        nodeC,
      ]; // Node C is directly reachable

      final processResult = await relayEngine.processIncomingRelay(
        relayMessage: outgoingRelay,
        fromNodeId: nodeA,
        availableNextHops: availableHops,
      );

      // Should be relayed to Node C
      expect(processResult.isRelayed, isTrue);
      expect(processResult.nextHopNodeId, equals(nodeC));

      // Step 3: Test final delivery to Node C
      await initRelayAs(nodeC);

      final deliveryResult = await relayEngine.processIncomingRelay(
        relayMessage: outgoingRelay.nextHop(
          nodeB,
        ), // Fixed: use nodeB as relay hop
        fromNodeId: nodeB,
        availableNextHops: [],
      );

      expect(deliveryResult.isDelivered, isTrue);
      expect(deliveryResult.content, equals('Hello from A to C via B!'));
    });

    test('Spam Prevention - Rate Limiting', () async {
      await initRelayAs(nodeB);

      final results = <RelayProcessingResult>[];
      for (int i = 0; i < 15; i++) {
        final relay = await createRelayFromNode(
          nodeA,
          messageId: 'spam_msg_$i',
          content: 'Spam message $i',
          finalRecipient: nodeC,
        );

        if (relay == null) continue;
        final result = await relayEngine.processIncomingRelay(
          relayMessage: relay,
          fromNodeId: nodeA,
          availableNextHops: [nodeC],
        );
        results.add(result);
      }

      // First 10 should be allowed, rest should be blocked
      final blocked = results.where((r) => r.isBlocked).length;
      expect(
        blocked,
        greaterThan(0),
      ); // Some should be blocked due to rate limiting

      final stats = spamPrevention.getStatistics();
      expect(stats.totalBlocked, greaterThan(0));
    });

    test('TTL and Hop Limiting', () async {
      final relay = await createRelayFromNode(
        nodeA,
        messageId: 'ttl_test',
        content: 'Test TTL limits',
        finalRecipient: nodeC,
        priority: MessagePriority.low,
      );
      await initRelayAs(nodeB);

      expect(relay!.relayMetadata.ttl, equals(3));

      var currentRelay = relay;
      bool exceptionThrown = false;
      for (int hop = 1; hop <= 4; hop++) {
        final hopNodeId = 'intermediate_node_$hop';
        try {
          currentRelay = currentRelay.nextHop(hopNodeId);
        } catch (e) {
          exceptionThrown = true;
          expect(e, isA<RelayException>());
          expect(hop, equals(3));
          break;
        }
      }

      expect(exceptionThrown, isTrue);
    });

    test('Loop Detection and Prevention', () async {
      await initRelayAs(nodeB);

      // Create relay message that already has nodeB in the path
      final metadata = RelayMetadata(
        ttl: 10,
        hopCount: 2,
        routingPath: [nodeA, nodeB], // NodeB already in path
        messageHash: 'test_hash_loop',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: nodeA,
        finalRecipient: nodeC,
      );

      final loopRelay = MeshRelayMessage(
        originalMessageId: 'loop_test',
        originalContent: 'Loop test message',
        relayMetadata: metadata,
        relayNodeId: nodeA,
        relayedAt: DateTime.now(),
      );

      final result = await relayEngine.processIncomingRelay(
        relayMessage: loopRelay,
        fromNodeId: nodeA,
        availableNextHops: [nodeC],
      );

      // Should be blocked due to loop detection
      expect(result.isBlocked, isTrue);
      expect(result.reason, anyOf(contains('loop'), contains('Loop')));
    });

    test('Message Size Validation', () async {
      final largeContent = 'x' * 12000; // 12KB content
      final largeRelay = await createRelayFromNode(
        nodeA,
        messageId: 'large_msg',
        content: largeContent,
        finalRecipient: nodeC,
      );
      await initRelayAs(nodeB);

      if (largeRelay != null) {
        final result = await relayEngine.processIncomingRelay(
          relayMessage: largeRelay,
          fromNodeId: nodeA,
          availableNextHops: [nodeC],
        );

        expect(result.isBlocked, isTrue);
      } else {
        expect(largeRelay, isNull);
      }
    });

    test('Duplicate Message Detection', () async {
      final relay = await createRelayFromNode(
        nodeA,
        messageId: 'duplicate_test',
        content: 'Duplicate test message',
        finalRecipient: nodeC,
      );
      await initRelayAs(nodeB);

      final firstResult = await relayEngine.processIncomingRelay(
        relayMessage: relay!,
        fromNodeId: nodeA,
        availableNextHops: [nodeC],
      );
      expect(firstResult.isSuccess, isTrue);

      final duplicateResult = await relayEngine.processIncomingRelay(
        relayMessage: relay,
        fromNodeId: nodeA,
        availableNextHops: [nodeC],
      );
      expect(duplicateResult.isBlocked, isTrue);
      expect(
        duplicateResult.reason,
        anyOf(contains('duplicate'), contains('Duplicate')),
      );
    });

    test('Recipient Detection Optimization', () async {
      await initRelayAs(nodeB);

      // Add contacts to test decryption optimization
      await contactRepository.saveContactWithSecurity(
        nodeA,
        'Node A',
        SecurityLevel.high,
      );
      await contactRepository.saveContactWithSecurity(
        nodeC,
        'Node C',
        SecurityLevel.medium,
      );

      // Test decryption decision for message where B is final recipient
      final shouldDecrypt1 = await relayEngine.shouldAttemptDecryption(
        finalRecipientPublicKey: nodeB, // We are the recipient
        originalSenderPublicKey: nodeA,
      );
      expect(shouldDecrypt1, isTrue);

      // Test decryption decision for message where B is not the recipient but knows sender
      final shouldDecrypt2 = await relayEngine.shouldAttemptDecryption(
        finalRecipientPublicKey: nodeC,
        originalSenderPublicKey: nodeA, // We know this sender
      );
      expect(shouldDecrypt2, isTrue);

      // Test decryption decision for unknown sender/recipient
      final shouldDecrypt3 = await relayEngine.shouldAttemptDecryption(
        finalRecipientPublicKey: 'unknown_recipient',
        originalSenderPublicKey: 'unknown_sender',
      );
      expect(shouldDecrypt3, isFalse); // Should not waste resources
    });

    test('Priority-Based TTL Assignment', () async {
      await initRelayAs(nodeB);

      // Test different priority levels
      final urgentRelay = await relayEngine.createOutgoingRelay(
        originalMessageId: 'urgent',
        originalContent: 'Urgent message',
        finalRecipientPublicKey: nodeC,
        priority: MessagePriority.urgent,
      );
      expect(urgentRelay!.relayMetadata.ttl, equals(5));

      final highRelay = await relayEngine.createOutgoingRelay(
        originalMessageId: 'high',
        originalContent: 'High priority message',
        finalRecipientPublicKey: nodeC,
        priority: MessagePriority.high,
      );
      expect(highRelay!.relayMetadata.ttl, equals(5));

      final normalRelay = await relayEngine.createOutgoingRelay(
        originalMessageId: 'normal',
        originalContent: 'Normal message',
        finalRecipientPublicKey: nodeC,
        priority: MessagePriority.normal,
      );
      expect(normalRelay!.relayMetadata.ttl, equals(4));

      final lowRelay = await relayEngine.createOutgoingRelay(
        originalMessageId: 'low',
        originalContent: 'Low priority message',
        finalRecipientPublicKey: nodeC,
        priority: MessagePriority.low,
      );
      expect(lowRelay!.relayMetadata.ttl, equals(3));
    });

    test('Trust Scoring System', () async {
      await initRelayAs(nodeB);

      // Create multiple successful relays to build trust
      for (int i = 0; i < 5; i++) {
        final relay = await createRelayFromNode(
          nodeA,
          messageId: 'trust_build_$i',
          content: 'Trust building message $i',
          finalRecipient: nodeC,
        );

        await relayEngine.processIncomingRelay(
          relayMessage: relay!,
          fromNodeId: nodeA,
          availableNextHops: [nodeC],
        );

        // Record successful relay operation
        await spamPrevention.recordRelayOperation(
          fromNodeId: nodeA,
          toNodeId: nodeC,
          messageHash: relay.relayMetadata.messageHash,
          messageSize: relay.messageSize,
        );
      }

      final stats = spamPrevention.getStatistics();
      expect(stats.totalAllowed, equals(5));
    });

    test('Multi-Hop Relay Chain A→B→C', () async {
      // Simulate complete A→B→C relay chain

      // Node A creates outgoing message
      final originalRelay = await createRelayFromNode(
        nodeA,
        messageId: 'multi_hop_test',
        content: 'Hello from A to C!',
        finalRecipient: nodeC,
      );
      await initRelayAs(nodeB);

      expect(originalRelay, isNotNull);
      expect(originalRelay!.relayMetadata.originalSender, equals(nodeA));
      expect(originalRelay.relayMetadata.hopCount, equals(1));

      // Node B receives and processes
      await initRelayAs(nodeB);
      final relayResult = await relayEngine.processIncomingRelay(
        relayMessage: originalRelay,
        fromNodeId: nodeA,
        availableNextHops: [nodeC],
      );

      expect(relayResult.isRelayed, isTrue);
      expect(relayResult.nextHopNodeId, equals(nodeC));

      // Node C receives final message
      await initRelayAs(nodeC);
      final nextHopMessage = originalRelay.nextHop(nodeB);
      final deliveryResult = await relayEngine.processIncomingRelay(
        relayMessage: nextHopMessage,
        fromNodeId: nodeB,
        availableNextHops: [],
      );

      expect(deliveryResult.isDelivered, isTrue);
      expect(deliveryResult.content, equals('Hello from A to C!'));

      // Verify hop count increased correctly
      expect(nextHopMessage.relayMetadata.hopCount, equals(2));
      expect(nextHopMessage.relayMetadata.routingPath, contains(nodeA));
      expect(nextHopMessage.relayMetadata.routingPath, contains(nodeB));
    });

    test('Error Handling and Edge Cases', () async {
      await initRelayAs(nodeB);

      // Test with null/empty values
      final nullRelay = await relayEngine.createOutgoingRelay(
        originalMessageId: '',
        originalContent: '',
        finalRecipientPublicKey: '',
      );
      if (nullRelay != null) {
        final invalidResult = await relayEngine.processIncomingRelay(
          relayMessage: nullRelay,
          fromNodeId: nodeA,
          availableNextHops: [nodeC],
        );
        expect(invalidResult.isBlocked, isTrue);
      }

      // Test with invalid hop configuration
      final validRelay = await createRelayFromNode(
        nodeA,
        messageId: 'valid_test',
        content: 'Valid message',
        finalRecipient: nodeC,
      );

      // Process with empty next hops
      final noHopResult = await relayEngine.processIncomingRelay(
        relayMessage: validRelay!,
        fromNodeId: nodeA,
        availableNextHops: [], // No next hops available
      );

      expect(noHopResult.type, equals(RelayProcessingType.dropped));
      expect(noHopResult.reason, contains('No neighbors available'));
    });

    test('Integration with BLE Message Handler', () async {
      // Test integration with BLE message handler
      await messageHandler.initializeRelaySystem(
        currentNodeId: nodeB,
        messageQueue: messageQueue,
        onRelayMessageReceived: (messageId, content, sender) {
          // Callback registered but not tested in this test
        },
      );

      // Create outgoing relay
      final relay = await messageHandler.createOutgoingRelay(
        originalMessageId: 'integration_test',
        originalContent: 'Integration test message',
        finalRecipientPublicKey: nodeC,
      );

      expect(relay, isNotNull);

      // Test decryption optimization
      await contactRepository.saveContactWithSecurity(
        nodeA,
        'Node A',
        SecurityLevel.high,
      );
      final shouldDecrypt = await messageHandler.shouldAttemptDecryption(
        finalRecipientPublicKey: nodeB,
        originalSenderPublicKey: nodeA,
      );
      expect(shouldDecrypt, isTrue);

      // Get relay statistics
      final stats = messageHandler.getRelayStatistics();
      expect(stats, isNotNull);
    });
  });
}
