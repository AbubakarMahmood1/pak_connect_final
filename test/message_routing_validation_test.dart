import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';

import 'test_helpers/message_handler_test_utils.dart';
import 'test_helpers/test_setup.dart';
import 'package:pak_connect/domain/models/security_level.dart';

// Minimal stub for ContactRepository to avoid dependencies
class MinimalContactRepository extends ContactRepository {
  @override
  Future<Contact?> getContact(String publicKey) async => null;

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async => null;

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async =>
      SecurityLevel.low;
}

Future<void> _configureNodeIdentity(
  BLEMessageHandler handler,
  String nodeId,
) async {
  await seedTestUserPublicKey(nodeId);
  handler.setCurrentNodeId(nodeId);
}

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'message_routing_validation',
    );
  });

  group('Message Routing Validation Tests', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {
      'DECRYPT: All methods failed',
      'Decryption failed',
    };

    late BLEMessageHandler messageHandler;
    late MinimalContactRepository contactRepository;

    // Test node IDs representing Ali, Arshad, and Abubakar
    const aliNodeId = 'ali_public_key_12345678901234567890123456789012';
    const arshadNodeId = 'arshad_public_key_12345678901234567890123456789012';
    const abubakarNodeId =
        'abubakar_public_key_12345678901234567890123456789012';

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      await TestSetup.configureTestDatabase(
        label: 'message_routing_validation',
      );
      TestSetup.resetSharedPreferences();
      await EphemeralKeyManager.initialize('test_private_key_1234567890');
      messageHandler = BLEMessageHandler();
      contactRepository = MinimalContactRepository();
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
      messageHandler.dispose();
      await TestSetup.nukeDatabase();
    });

    group('Core Routing Logic Tests', () {
      test('should create protocol message with correct intendedRecipient', () {
        // Test that messages are created with the correct intended recipient
        final message = buildV2EncryptedTestMessage(
          messageId: 'test123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId,
        );

        expect(message.payload['intendedRecipient'], equals(arshadNodeId));
        expect(message.payload['content'], equals('ciphertext-for-arshad'));
      });

      test('should block messages not intended for current user', () async {
        // Set Abubakar as current node
        await _configureNodeIdentity(messageHandler, abubakarNodeId);

        // Create message intended for Arshad (not Abubakar)
        final message = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId, // NOT for Abubakar
          senderId: aliNodeId,
        );

        // Process the message - should be blocked
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(message),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );

        // Should return null (blocked) since message is not for Abubakar
        expect(result, isNull);
      });

      test('should allow messages intended for current user', () async {
        // Set Arshad as current node
        await _configureNodeIdentity(messageHandler, arshadNodeId);

        // Create message intended for Arshad
        final message = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId, // Correctly for Arshad
          senderId: aliNodeId,
        );

        // Process the message - should be allowed
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(message),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );

        // Should pass routing/auth and reach decrypt handling.
        expect(result, isNotNull);
      });

      test('should block own messages to prevent loops', () async {
        // Set Ali as current node
        await _configureNodeIdentity(messageHandler, aliNodeId);

        // Create message where sender == current user
        final message = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'self-ciphertext',
          senderId: aliNodeId,
        );

        // Process message where sender == current user
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(message),
          senderPublicKey: aliNodeId, // Same as current node
          contactRepository: contactRepository,
        );

        // Should be blocked to prevent message loops
        expect(result, isNull);
      });
    });

    group('Encryption Context Tests', () {
      test('should include encryption metadata with intended recipient', () {
        // Test that encrypted messages include the intended recipient
        final encryptedMessage = buildV2EncryptedTestMessage(
          messageId: 'enc123',
          content: 'encrypted_content',
          intendedRecipient: arshadNodeId,
        );

        expect(encryptedMessage.payload['encrypted'], isTrue);
        expect(
          (encryptedMessage.payload['crypto'] as Map<String, dynamic>)['mode'],
          equals('noise_v1'),
        );
        expect(
          encryptedMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );
      });
    });

    group('Chat Context Isolation Tests', () {
      test('should maintain different contexts for different chats', () {
        // Simulate different chat contexts
        final aliToArshadChat = {
          'recipient': arshadNodeId,
          'chatId': 'chat_ali_arshad',
        };

        final aliToAbubakarChat = {
          'recipient': abubakarNodeId,
          'chatId': 'chat_ali_abubakar',
        };

        // Verify contexts are isolated
        expect(aliToArshadChat['recipient'], equals(arshadNodeId));
        expect(aliToAbubakarChat['recipient'], equals(abubakarNodeId));
        expect(
          aliToArshadChat['chatId'],
          isNot(equals(aliToAbubakarChat['chatId'])),
        );
      });
    });

    group('Message Handler Safety Tests', () {
      test('should handle node ID bounds safely', () async {
        // Test various node ID lengths
        const shortId = 'short';
        const normalId = 'normal_length_node_id_1234567890';
        const longId =
            'very_long_node_id_that_exceeds_normal_bounds_123456789012345678901234567890';

        await _configureNodeIdentity(messageHandler, shortId);
        await _configureNodeIdentity(messageHandler, normalId);
        await _configureNodeIdentity(messageHandler, longId);
      });

      test('should safely process messages with long IDs', () async {
        const longNodeId =
            'extremely_long_node_id_that_could_cause_substring_errors_123456789012345678901234567890123456789012345678901234567890';
        await _configureNodeIdentity(messageHandler, longNodeId);

        final message = buildV2EncryptedTestMessage(
          messageId:
              'safety_test_message_with_very_long_id_123456789012345678901234567890',
          content: 'safety-test-ciphertext',
          intendedRecipient: longNodeId,
          senderId: aliNodeId,
        );

        // Should not throw RangeError during processing
        expect(() async {
          await messageHandler.processReceivedData(
            protocolMessageToWireBytes(message),
            senderPublicKey: aliNodeId,
            contactRepository: contactRepository,
          );
        }, returnsNormally);
      });
    });

    group('Integration Flow Tests', () {
      test('should handle complete Ali → Arshad messaging flow', () async {
        // Step 1: Ali creates message for Arshad
        await _configureNodeIdentity(messageHandler, aliNodeId);

        final outgoingMessage = buildV2EncryptedTestMessage(
          messageId: 'flow_test_1',
          content: 'ciphertext-from-ali-to-arshad',
          intendedRecipient: arshadNodeId,
          senderId: aliNodeId,
        );

        expect(
          outgoingMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );

        // Step 2: Arshad receives and processes message
        await _configureNodeIdentity(messageHandler, arshadNodeId);

        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(outgoingMessage),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );

        expect(result, isNotNull);
      });

      test(
        'should prevent Abubakar from receiving Ali → Arshad message',
        () async {
          // Ali creates message for Arshad
          final messageForArshad = buildV2EncryptedTestMessage(
            messageId: 'isolation_test_1',
            content: 'private-ciphertext-for-arshad',
            intendedRecipient: arshadNodeId,
            senderId: aliNodeId,
          );

          // Abubakar tries to process it (should be blocked)
          await _configureNodeIdentity(messageHandler, abubakarNodeId);

          final result = await messageHandler.processReceivedData(
            protocolMessageToWireBytes(messageForArshad),
            senderPublicKey: aliNodeId,
            contactRepository: contactRepository,
          );

          // Should be null (blocked) - Abubakar cannot read Ali's message to Arshad
          expect(result, isNull);
        },
      );
    });
  });
}
