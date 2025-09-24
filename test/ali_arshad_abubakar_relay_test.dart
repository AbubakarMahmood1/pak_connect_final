import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

void main() {
  // Setup logging
  Logger.root.level = Level.WARNING; // Reduce logging to avoid noise
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.message}');
  });

  group('Ali → Arshad → Abubakar Relay Test', () {
    // Test user identities (shorter to avoid truncation issues)
    const String ali = 'ali_key_123';
    const String arshad = 'arshad_key_456';
    const String abubakar = 'abubakar_key_789';
    
    // Create separate instances for each node simulation
    Future<MeshRelayEngine> createRelayEngineForNode(String nodeId) async {
      final contactRepository = ContactRepository();
      final messageQueue = OfflineMessageQueue();
      final spamPrevention = SpamPreventionManager();
      
      try {
        await messageQueue.initialize();
        await spamPrevention.initialize();
      } catch (e) {
        // Ignore SharedPreferences errors in test environment
        print('Warning: ${e.toString()}');
      }
      
      final relayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );
      
      await relayEngine.initialize(currentNodeId: nodeId);
      return relayEngine;
    }

    test('Ali sends message to Abubakar via Arshad', () async {
      // Step 1: Ali creates outgoing relay message to Abubakar
      final aliEngine = await createRelayEngineForNode(ali);
      
      final aliMessage = await aliEngine.createOutgoingRelay(
        originalMessageId: 'ali_to_abubakar_001',
        originalContent: 'Hello Abubakar from Ali!',
        finalRecipientPublicKey: abubakar,
        priority: MessagePriority.normal,
      );
      
      expect(aliMessage, isNotNull, reason: 'Ali should be able to create relay message');
      expect(aliMessage!.relayMetadata.finalRecipient, equals(abubakar));
      expect(aliMessage.relayMetadata.originalSender, equals(ali));
      expect(aliMessage.originalContent, equals('Hello Abubakar from Ali!'));
      
      // Step 2: Arshad processes the relay message
      final arshadEngine = await createRelayEngineForNode(arshad);
      final availableHops = [abubakar]; // Abubakar is directly reachable from Arshad
      
      final processResult = await arshadEngine.processIncomingRelay(
        relayMessage: aliMessage,
        fromNodeId: ali,
        availableNextHops: availableHops,
      );
      
      expect(processResult.isRelayed, isTrue, reason: 'Arshad should relay the message');
      expect(processResult.nextHopNodeId, equals(abubakar), reason: 'Message should be relayed to Abubakar');
      
      // Step 3: Abubakar receives the forwarded message
      final abubakarEngine = await createRelayEngineForNode(abubakar);
      
      final forwardedMessage = aliMessage.nextHop(arshad);
      final deliveryResult = await abubakarEngine.processIncomingRelay(
        relayMessage: forwardedMessage,
        fromNodeId: arshad,
        availableNextHops: [],
      );
      
      expect(deliveryResult.isDelivered, isTrue, reason: 'Abubakar should receive the message');
      expect(deliveryResult.content, equals('Hello Abubakar from Ali!'),
        reason: 'Content should be preserved through relay');
      
      print('✅ Ali → Arshad → Abubakar relay test passed!');
    });

    test('Relay node does not process messages not intended for them', () async {
      // Ali creates message to Abubakar
      final aliEngine = await createRelayEngineForNode(ali);
      
      final relayMessage = await aliEngine.createOutgoingRelay(
        originalMessageId: 'test_routing_001',
        originalContent: 'This message is for Abubakar only',
        finalRecipientPublicKey: abubakar,
        priority: MessagePriority.normal,
      );
      
      expect(relayMessage, isNotNull);
      expect(relayMessage!.relayMetadata.originalSender, equals(ali));
      expect(relayMessage.relayMetadata.finalRecipient, equals(abubakar));
      
      // Arshad processes this message
      final arshadEngine = await createRelayEngineForNode(arshad);
      
      final processResult = await arshadEngine.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: ali,
        availableNextHops: [abubakar],
      );
      
      expect(processResult.isRelayed, isTrue, reason: 'Message should be relayed, not delivered to Arshad');
      expect(processResult.isDelivered, isFalse, reason: 'Arshad should not process message intended for Abubakar');
      expect(processResult.nextHopNodeId, equals(abubakar), reason: 'Should be forwarded to correct recipient');
      
      print('✅ Relay routing validation test passed!');
    });

    test('Final recipient receives relayed message correctly', () async {
      // Ali creates the message
      final aliEngine = await createRelayEngineForNode(ali);
      
      final originalMessage = await aliEngine.createOutgoingRelay(
        originalMessageId: 'final_delivery_test',
        originalContent: 'Final delivery test message',
        finalRecipientPublicKey: abubakar,
      );
      
      expect(originalMessage, isNotNull);
      expect(originalMessage!.relayMetadata.originalSender, equals(ali));
      
      // Simulate the message being forwarded through Arshad
      final relayedMessage = originalMessage.nextHop(arshad);
      
      // Abubakar processes the relayed message
      final abubakarEngine = await createRelayEngineForNode(abubakar);
      
      final deliveryResult = await abubakarEngine.processIncomingRelay(
        relayMessage: relayedMessage,
        fromNodeId: arshad,
        availableNextHops: [],
      );
      
      expect(deliveryResult.isDelivered, isTrue, reason: 'Final recipient should receive message');
      expect(deliveryResult.content, equals('Final delivery test message'),
        reason: 'Original content should be preserved');
      expect(deliveryResult.isRelayed, isFalse, reason: 'Final recipient should not relay further');
      
      print('✅ Final recipient delivery test passed!');
    });

    test('Relay statistics are updated correctly', () async {
      // Ali creates messages
      final aliEngine = await createRelayEngineForNode(ali);
      
      final messages = <MeshRelayMessage>[];
      for (int i = 0; i < 3; i++) {
        final message = await aliEngine.createOutgoingRelay(
          originalMessageId: 'stats_test_$i',
          originalContent: 'Test message $i',
          finalRecipientPublicKey: abubakar,
        );
        expect(message, isNotNull);
        messages.add(message!);
      }
      
      // Arshad processes relay operations
      final arshadEngine = await createRelayEngineForNode(arshad);
      
      for (final message in messages) {
        await arshadEngine.processIncomingRelay(
          relayMessage: message,
          fromNodeId: ali,
          availableNextHops: [abubakar],
        );
      }
      
      final stats = arshadEngine.getStatistics();
      expect(stats.totalRelayed, equals(3), reason: 'Should count relayed messages');
      expect(stats.relayEfficiency, greaterThan(0.0), reason: 'Should have positive efficiency');
      
      print('✅ Relay statistics test passed!');
    });
  });
}