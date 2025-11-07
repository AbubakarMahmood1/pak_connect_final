import 'package:test/test.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';

void main() {
  group('Message Routing Fix Tests', () {
    late BLEMessageHandler messageHandler;
    late ContactRepository contactRepository;

    const String aliPublicKey = 'ali_public_key_12345';
    const String arshadPublicKey = 'arshad_public_key_67890';

    setUp(() {
      messageHandler = BLEMessageHandler();
      contactRepository = ContactRepository();

      // Set Ali as the current user
      messageHandler.setCurrentNodeId(aliPublicKey);
    });

    test('Should block own messages from appearing as incoming', () async {
      // Create a message from Ali (should be blocked)
      final protocolMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {
          'messageId': 'test_msg_1',
          'content': 'Hello Arshad!',
          'encrypted': false,
          'encryptionMethod': 'none',
          // No intendedRecipient - this is a direct P2P message
        },
        timestamp: DateTime.now(),
      );

      final messageBytes = protocolMessage.toBytes();

      // Process the message as if it came from Ali (same as current user)
      final result = await messageHandler.processReceivedData(
        messageBytes,
        senderPublicKey: aliPublicKey, // Same as current user
        contactRepository: contactRepository,
      );

      // Should return null (blocked) since it's from the current user
      expect(result, isNull, reason: 'Own messages should be blocked');
    });

    test(
      'Should allow legitimate direct messages between different users',
      () async {
        // Create a message from Arshad to Ali
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_2',
            'content': 'Hello Ali!',
            'encrypted': false,
            'encryptionMethod': 'none',
            // No intendedRecipient - this is a direct P2P message
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessage.toBytes();

        // Process the message as if it came from Arshad (different user)
        final result = await messageHandler.processReceivedData(
          messageBytes,
          senderPublicKey: arshadPublicKey, // Different from current user
          contactRepository: contactRepository,
        );

        // Should return the message content (allowed)
        expect(
          result,
          equals('Hello Ali!'),
          reason: 'Direct messages from other users should be processed',
        );
      },
    );

    test(
      'Should block messages with intendedRecipient not matching current user',
      () async {
        // Create a message intended for Arshad (not current user Ali)
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_3',
            'content': 'Message for Arshad only',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient': arshadPublicKey, // Not for Ali
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessage.toBytes();

        // Process the message (should be blocked since not intended for Ali)
        final result = await messageHandler.processReceivedData(
          messageBytes,
          senderPublicKey: 'some_other_user',
          contactRepository: contactRepository,
        );

        // Should return null (blocked) since it's not intended for current user
        expect(
          result,
          isNull,
          reason: 'Messages intended for other users should be blocked',
        );
      },
    );

    test(
      'Should allow messages with intendedRecipient matching current user',
      () async {
        // Create a message intended for Ali (current user)
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test_msg_4',
            'content': 'Message specifically for Ali',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient': aliPublicKey, // For Ali (current user)
          },
          timestamp: DateTime.now(),
        );

        final messageBytes = protocolMessage.toBytes();

        // Process the message (should be allowed since intended for Ali)
        final result = await messageHandler.processReceivedData(
          messageBytes,
          senderPublicKey: arshadPublicKey,
          contactRepository: contactRepository,
        );

        // Should return the message content (allowed)
        expect(
          result,
          equals('Message specifically for Ali'),
          reason: 'Messages intended for current user should be processed',
        );
      },
    );

    tearDown(() {
      messageHandler.dispose();
    });
  });
}
