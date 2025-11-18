import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/security/ephemeral_key_manager.dart';

import 'test_helpers/message_handler_test_utils.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'p2p_message_routing_fix',
    );
  });

  group('P2P Message Routing Fix Tests', () {
    late BLEMessageHandler handler;
    late ContactRepository mockContactRepository;

    setUp(() async {
      await TestSetup.configureTestDatabase(label: 'p2p_message_routing_fix');
      TestSetup.resetSharedPreferences();
      await EphemeralKeyManager.initialize('test_private_key_1234567890');
      await seedTestUserPublicKey('our_node_123');
      handler = BLEMessageHandler();
      mockContactRepository = ContactRepository();
      handler.setCurrentNodeId('our_node_123');
    });

    tearDown(() async {
      handler.dispose();
      await TestSetup.nukeDatabase();
    });

    test(
      'Direct P2P message without routing info should be accepted',
      () async {
        // Create a message without intendedRecipient (direct P2P)
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_1',
            'content': 'Hello P2P!',
            'encrypted': false,
            'encryptionMethod': 'none',
            // No intendedRecipient - this is a direct P2P message
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessageToJsonBytes(protocolMessage);
        final result = await handler.processReceivedData(
          messageBytes,
          senderPublicKey: 'sender_key_456',
          contactRepository: mockContactRepository,
        );

        // Should accept the message and return content
        expect(result, equals('Hello P2P!'));
      },
    );

    test(
      'Direct P2P message addressed to someone else should be blocked',
      () async {
        // Create a message with intendedRecipient (P2P with routing)
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_2',
            'content': 'Hello with routing!',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient':
                'recipient_key_789', // Different from our node ID
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessageToJsonBytes(protocolMessage);
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
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_3',
            'content': 'Hello mesh message!',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient': 'our_node_123', // Matches our node ID
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessageToJsonBytes(protocolMessage);
        final result = await handler.processReceivedData(
          messageBytes,
          senderPublicKey: 'sender_key_456',
          contactRepository: mockContactRepository,
        );

        // Should accept the mesh message
        expect(result, equals('Hello mesh message!'));
      },
    );

    test('Message from ourselves should be blocked', () async {
      // Create a message from our own node
      final protocolMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {
          'messageId': 'test_msg_4',
          'content': 'This is my own message!',
          'encrypted': false,
          'encryptionMethod': 'none',
          'intendedRecipient': 'some_recipient',
        },
        timestamp: DateTime.now(),
      );

      final messageBytes = protocolMessageToJsonBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: 'our_node_123', // Same as our node ID
        contactRepository: mockContactRepository,
      );

      // Should block our own message
      expect(result, isNull);
    });

    test('Message from ourselves without routing should be blocked', () async {
      // Create a direct message from our own node
      final protocolMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {
          'messageId': 'test_msg_5',
          'content': 'Direct message from self!',
          'encrypted': false,
          'encryptionMethod': 'none',
          // No intendedRecipient
        },
        timestamp: DateTime.now(),
      );

      final messageBytes = protocolMessageToJsonBytes(protocolMessage);
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
        // Create an encrypted P2P message
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_6',
            'content': 'encrypted_payload_here',
            'encrypted': true,
            'encryptionMethod': 'ecdh',
            'intendedRecipient': 'recipient_public_key',
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessageToJsonBytes(protocolMessage);
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
      handler.dispose();
      await TestSetup.nukeDatabase();
    });

    test('Message processing without node ID set should work', () async {
      // Don't set our node ID but ensure persistent identity matches recipient
      await seedTestUserPublicKey('some_recipient');

      final protocolMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {
          'messageId': 'test_msg_7',
          'content': 'Message without node ID!',
          'encrypted': false,
          'encryptionMethod': 'none',
          'intendedRecipient': 'some_recipient',
        },
        timestamp: DateTime.now(),
      );

      final messageBytes = protocolMessageToJsonBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: 'sender_key_456',
        contactRepository: mockContactRepository,
      );

      // Should process the message despite missing node ID
      expect(result, equals('Message without node ID!'));
    });

    test('Message with null sender should be processed', () async {
      handler.setCurrentNodeId('our_node_123');

      final protocolMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {
          'messageId': 'test_msg_8',
          'content': 'Message with null sender!',
          'encrypted': false,
          'encryptionMethod': 'none',
        },
        timestamp: DateTime.now(),
      );

      final messageBytes = protocolMessageToJsonBytes(protocolMessage);
      final result = await handler.processReceivedData(
        messageBytes,
        senderPublicKey: null, // Null sender
        contactRepository: mockContactRepository,
      );

      // Should process the message
      expect(result, equals('Message with null sender!'));
    });
  });
}
