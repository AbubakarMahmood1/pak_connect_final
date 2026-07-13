import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';

import 'test_helpers/message_handler_test_utils.dart';
import 'test_helpers/test_setup.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'p2p_message_routing_fix',
    );
  });

  group('P2P Message Routing Fix Tests', () {
    late BLEMessageHandler handler;
    late ContactRepository mockContactRepository;

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      await TestSetup.configureTestDatabase(label: 'p2p_message_routing_fix');
      TestSetup.resetSharedPreferences();
      await EphemeralKeyManager.initialize('test_private_key_1234567890');
      await seedTestUserPublicKey('our_node_123');
      handler = BLEMessageHandler();
      mockContactRepository = ContactRepository();
      handler.setCurrentNodeId('our_node_123');
    });

    tearDown(() async {
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
      handler.dispose();
      await TestSetup.nukeDatabase();
    });

    test(
      'Direct P2P message without routing info should be accepted',
      () async {
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_1',
          content: 'ciphertext-p2p',
          senderId: 'sender_key_456',
        );

        final messageBytes = protocolMessageToWireBytes(protocolMessage);
        final result = await handler.processReceivedData(
          messageBytes,
          senderPublicKey: 'sender_key_456',
          contactRepository: mockContactRepository,
        );

        // The hardened v2 path should not discard the message before crypto.
        expect(result, isNotNull);
      },
    );

    test(
      'Direct P2P message addressed to someone else should be blocked',
      () async {
        // Create a message with intendedRecipient (P2P with routing)
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_2',
          content: 'ciphertext-with-routing',
          intendedRecipient: 'recipient_key_789', // Different from our node ID
          senderId: 'sender_key_456',
        );

        final messageBytes = protocolMessageToWireBytes(protocolMessage);
        final result = await handler.processReceivedData(
          messageBytes,
          senderPublicKey: 'sender_key_456',
          contactRepository: mockContactRepository,
        );

        // Should block because routing indicates someone else
        expect(result, isNull);
      },
    );

    test(
      'Mesh message explicitly addressed to our node ID should be accepted',
      () async {
        // Create a message with intendedRecipient matching our node ID
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_3',
          content: 'mesh-message-ciphertext',
          intendedRecipient: 'our_node_123', // Matches our node ID
          senderId: 'sender_key_456',
        );

        final messageBytes = protocolMessageToWireBytes(protocolMessage);
        final result = await handler.processReceivedData(
          messageBytes,
          senderPublicKey: 'sender_key_456',
          contactRepository: mockContactRepository,
        );

        // Should accept the mesh message through routing/auth checks.
        expect(result, isNotNull);
      },
    );

    test('Message from ourselves should be blocked', () async {
      final protocolMessage = buildV2EncryptedTestMessage(
        messageId: 'test_msg_4',
        content: 'self-ciphertext',
        intendedRecipient: 'some_recipient',
        senderId: 'our_node_123',
      );

      final messageBytes = protocolMessageToWireBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: 'our_node_123', // Same as our node ID
        contactRepository: mockContactRepository,
      );

      // Should block our own message
      expect(result, isNull);
    });

    test('Message from ourselves without routing should be blocked', () async {
      final protocolMessage = buildV2EncryptedTestMessage(
        messageId: 'test_msg_5',
        content: 'direct-self-ciphertext',
        senderId: 'our_node_123',
      );

      final messageBytes = protocolMessageToWireBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: 'our_node_123', // Same as our node ID
        contactRepository: mockContactRepository,
      );

      // Should block our own message even without routing info
      expect(result, isNull);
    });

    test(
      'Encrypted P2P message for different recipient should be discarded',
      () async {
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_6',
          content: 'encrypted_payload_here',
          intendedRecipient: 'recipient_public_key',
          senderId: 'sender_key_456',
        );

        final messageBytes = protocolMessageToWireBytes(protocolMessage);
        final result = await handler.processReceivedData(
          messageBytes,
          senderPublicKey: 'sender_key_456',
          contactRepository: mockContactRepository,
        );

        // Should be discarded because routing says it's for someone else
        expect(result, isNull);
      },
    );
  });

  group('Routing Logic Edge Cases', () {
    late BLEMessageHandler handler;
    late ContactRepository mockContactRepository;

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      await TestSetup.configureTestDatabase(
        label: 'p2p_message_routing_fix_edge',
      );
      TestSetup.resetSharedPreferences();
      await EphemeralKeyManager.initialize('test_private_key_1234567890');
      await seedTestUserPublicKey('our_node_123');
      handler = BLEMessageHandler();
      mockContactRepository = ContactRepository();
    });

    tearDown(() async {
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
      handler.dispose();
      await TestSetup.nukeDatabase();
    });

    test('Message processing without node ID set should work', () async {
      // Don't set our node ID but ensure persistent identity matches recipient
      await seedTestUserPublicKey('some_recipient');

      final protocolMessage = buildV2EncryptedTestMessage(
        messageId: 'test_msg_7',
        content: 'ciphertext-without-node-id',
        intendedRecipient: 'some_recipient',
        senderId: 'sender_key_456',
      );

      final messageBytes = protocolMessageToWireBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: 'sender_key_456',
        contactRepository: mockContactRepository,
      );

      // Should process the message despite missing node ID.
      expect(result, isNotNull);
    });

    test('Message with null sender should be processed', () async {
      handler.setCurrentNodeId('our_node_123');

      final protocolMessage = buildV2EncryptedTestMessage(
        messageId: 'test_msg_8',
        content: 'null-sender-ciphertext',
      );

      final messageBytes = protocolMessageToWireBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: null, // Null sender
        contactRepository: mockContactRepository,
      );

      // The message should return a user-facing crypto failure instead of
      // being dropped for legacy/plaintext reasons.
      expect(result, isNotNull);
    });
  });
}
