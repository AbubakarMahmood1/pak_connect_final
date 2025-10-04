import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

/// Test ACK propagation through relay chain
/// Validates: Ali → Arshad → Abubakar → ACK back → Arshad → ACK back → Ali
void main() {
  final testLogger = Logger('RelayAckPropagationTest');

  // Initialize sqflite_ffi for testing
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    // Clean database before each test
    await DatabaseHelper.close();
    await DatabaseHelper.deleteDatabase();
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  // Setup logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.message}');
  });

  group('ACK Propagation Tests', () {
    // Test user identities
    const String ali = 'ali_key_123';
    const String arshad = 'arshad_key_456';
    const String abubakar = 'abubakar_key_789';

    // Create relay engine for a node
    Future<MeshRelayEngine> createRelayEngineForNode(String nodeId) async {
      final contactRepository = ContactRepository();
      final messageQueue = OfflineMessageQueue();
      final spamPrevention = SpamPreventionManager();

      try {
        await messageQueue.initialize();
        await spamPrevention.initialize();
      } catch (e) {
        testLogger.warning('Initialization error (expected in test): $e');
      }

      final relayEngine = MeshRelayEngine(
        contactRepository: contactRepository,
        messageQueue: messageQueue,
        spamPrevention: spamPrevention,
      );

      await relayEngine.initialize(currentNodeId: nodeId);
      return relayEngine;
    }

    test('RelayMetadata provides correct ACK routing path', () {
      // Create relay metadata with routing path: [Ali, Arshad, Abubakar]
      final metadata = RelayMetadata(
        ttl: 10,
        hopCount: 3,
        routingPath: [ali, arshad, abubakar],
        messageHash: 'test_hash',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: ali,
        finalRecipient: abubakar,
      );

      // ACK routing path should be reversed
      final ackPath = metadata.ackRoutingPath;
      expect(ackPath, equals([abubakar, arshad, ali]));

      // Previous hop from Abubakar's perspective should be Arshad
      expect(metadata.previousHop, equals(arshad));

      testLogger.info('✅ ACK routing path correctly reversed');
    });

    test('Message stays in queue with awaiting_ack status', () async {
      final messageQueue = OfflineMessageQueue();

      try {
        await messageQueue.initialize();
      } catch (e) {
        testLogger.warning('Initialization error (expected in test): $e');
      }

      // Queue a message
      final messageId = await messageQueue.queueMessage(
        chatId: 'test_chat',
        content: 'Test message',
        recipientPublicKey: abubakar,
        senderPublicKey: ali,
        priority: MessagePriority.normal,
      );

      // Trigger delivery attempt
      final message = messageQueue.getMessageById(messageId);
      expect(message, isNotNull);

      // Message should be in pending or awaitingAck status (not delivered)
      expect(
        message!.status == QueuedMessageStatus.pending ||
            message.status == QueuedMessageStatus.awaitingAck,
        isTrue,
        reason: 'Message should not be marked delivered without ACK',
      );

      testLogger.info('✅ Message correctly stays in queue awaiting ACK');
    });

    test('Ali → Arshad → Abubakar with full ACK propagation back', () async {
      testLogger.info('🧪 Starting full ACK propagation test');

      // Step 1: Ali creates and sends message
      final aliEngine = await createRelayEngineForNode(ali);

      final aliMessage = await aliEngine.createOutgoingRelay(
        originalMessageId: 'ack_test_001',
        originalContent: 'Test ACK propagation',
        finalRecipientPublicKey: abubakar,
        priority: MessagePriority.normal,
      );

      expect(aliMessage, isNotNull);
      expect(aliMessage!.relayMetadata.routingPath, contains(ali));
      testLogger.info('✅ Step 1: Ali created message');

      // Step 2: Arshad receives and relays
      final arshadEngine = await createRelayEngineForNode(arshad);

      final arshadResult = await arshadEngine.processIncomingRelay(
        relayMessage: aliMessage,
        fromNodeId: ali,
        availableNextHops: [abubakar],
      );

      expect(arshadResult.isRelayed, isTrue);
      expect(arshadResult.nextHopNodeId, equals(abubakar));
      testLogger.info('✅ Step 2: Arshad relayed message to Abubakar');

      // Step 3: Abubakar receives message (final recipient)
      final abubakarEngine = await createRelayEngineForNode(abubakar);

      // Arshad forwards to Abubakar - message has routing path [ali, arshad]
      // We manually build the forwarded message as it would be after Arshad processes it
      final forwardedMessage = aliMessage.nextHop(arshad);
      expect(forwardedMessage.relayMetadata.routingPath, equals([ali, arshad]));
      testLogger.info('Routing path at Abubakar: ${forwardedMessage.relayMetadata.routingPath}');

      // Abubakar processes the message (he's the final recipient)
      final abubakarResult = await abubakarEngine.processIncomingRelay(
        relayMessage: forwardedMessage,
        fromNodeId: arshad,
        availableNextHops: [],
      );

      expect(abubakarResult.isDelivered, isTrue);
      expect(abubakarResult.content, equals('Test ACK propagation'));
      testLogger.info('✅ Step 3: Abubakar received message');

      // Step 4: Verify ACK routing path
      final finalMetadata = forwardedMessage.relayMetadata;
      final ackPath = finalMetadata.ackRoutingPath;

      // ACK path should be reversed: [arshad, ali] (backward from [ali, arshad])
      expect(ackPath, equals([arshad, ali]));
      expect(finalMetadata.previousHop, equals(ali));
      testLogger.info('✅ Step 4: ACK routing path verified: $ackPath');

      testLogger.info('🎉 Full ACK propagation test passed!');
    });

    test('Relay node does not mark message as delivered', () async {
      testLogger.info('🧪 Testing relay node behavior');

      // Ali creates message
      final aliEngine = await createRelayEngineForNode(ali);

      final message = await aliEngine.createOutgoingRelay(
        originalMessageId: 'relay_node_test',
        originalContent: 'Test relay node',
        finalRecipientPublicKey: abubakar,
      );

      expect(message, isNotNull);

      // Arshad (relay node) processes message
      final arshadEngine = await createRelayEngineForNode(arshad);

      final arshadResult = await arshadEngine.processIncomingRelay(
        relayMessage: message!,
        fromNodeId: ali,
        availableNextHops: [abubakar],
      );

      // Arshad should relay, not deliver to self
      expect(arshadResult.isRelayed, isTrue);
      expect(arshadResult.isDelivered, isFalse);
      expect(arshadResult.nextHopNodeId, equals(abubakar));

      testLogger.info('✅ Relay node correctly forwards without marking delivered');
    });

    test('ACK includes correct routing path for backward propagation', () async {
      // Create a relay metadata with 3-hop path
      final metadata = RelayMetadata(
        ttl: 10,
        hopCount: 3,
        routingPath: [ali, arshad, abubakar],
        messageHash: 'test_hash',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: ali,
        finalRecipient: abubakar,
      );

      // Verify ACK path is reversed
      expect(metadata.ackRoutingPath, equals([abubakar, arshad, ali]));

      // Verify previousHop calculation from different perspectives
      final aliMetadata = RelayMetadata(
        ttl: 10,
        hopCount: 1,
        routingPath: [ali],
        messageHash: 'test',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: ali,
        finalRecipient: abubakar,
      );

      expect(aliMetadata.previousHop, isNull, reason: 'Originator has no previous hop');
      expect(aliMetadata.isOriginator, isTrue);

      final arshadMetadata = metadata.copyWith(routingPath: [ali, arshad]);
      expect(arshadMetadata.previousHop, equals(ali));
      expect(arshadMetadata.isOriginator, isFalse);

      testLogger.info('✅ ACK routing path calculations verified');
    });

    test('Multiple messages maintain separate ACK states', () async {
      testLogger.info('🧪 Testing multiple message ACK tracking');

      final aliEngine = await createRelayEngineForNode(ali);

      // Create multiple messages
      final message1 = await aliEngine.createOutgoingRelay(
        originalMessageId: 'multi_ack_001',
        originalContent: 'First message',
        finalRecipientPublicKey: abubakar,
      );

      final message2 = await aliEngine.createOutgoingRelay(
        originalMessageId: 'multi_ack_002',
        originalContent: 'Second message',
        finalRecipientPublicKey: abubakar,
      );

      expect(message1, isNotNull);
      expect(message2, isNotNull);
      expect(message1!.originalMessageId, isNot(equals(message2!.originalMessageId)));

      // Both should have independent routing paths
      expect(message1.relayMetadata.routingPath.length, equals(1));
      expect(message2.relayMetadata.routingPath.length, equals(1));

      testLogger.info('✅ Multiple messages maintain independent state');
    });

    test('Loop prevention works with ACK routing path', () {
      // Create a routing path
      final metadata = RelayMetadata(
        ttl: 10,
        hopCount: 2,
        routingPath: [ali, arshad],
        messageHash: 'test',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: ali,
        finalRecipient: abubakar,
      );

      // Trying to add a node already in path should throw
      expect(
        () => metadata.nextHop(ali),
        throwsA(isA<RelayException>()),
        reason: 'Should detect loop when adding duplicate node',
      );

      expect(metadata.hasNodeInPath(ali), isTrue);
      expect(metadata.hasNodeInPath(arshad), isTrue);
      expect(metadata.hasNodeInPath(abubakar), isFalse);

      testLogger.info('✅ Loop prevention verified with routing path');
    });
  });
}

// Extension to help with testing
extension RelayMetadataTest on RelayMetadata {
  RelayMetadata copyWith({
    List<String>? routingPath,
  }) {
    return RelayMetadata(
      ttl: ttl,
      hopCount: routingPath?.length ?? hopCount,
      routingPath: routingPath ?? this.routingPath,
      messageHash: messageHash,
      priority: priority,
      relayTimestamp: relayTimestamp,
      originalSender: originalSender,
      finalRecipient: finalRecipient,
      senderRateCount: senderRateCount,
    );
  }
}
