import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';

import 'test_helpers/message_handler_test_utils.dart';
import 'test_helpers/test_setup.dart';
import 'package:pak_connect/domain/models/security_level.dart';

// Simple stub for ContactRepository
class StubContactRepository extends ContactRepository {
  @override
  Future<Contact?> getContact(String publicKey) async => null;

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async => null;

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async =>
      SecurityLevel.low;
}

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'message_encryption_routing',
    );
  });

  group('Message Encryption and Routing Tests', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {
      'DECRYPT: All methods failed',
      'Decryption failed',
    };

    late BLEMessageHandler messageHandler;
    late StubContactRepository stubContactRepository;

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
        label: 'message_encryption_routing',
      );
      TestSetup.resetSharedPreferences();
      await EphemeralKeyManager.initialize('test_private_key_1234567890');
      await seedTestUserPublicKey(arshadNodeId);
      messageHandler = BLEMessageHandler();
      stubContactRepository = StubContactRepository();
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

    group('1. Direct Messaging Tests (Ali → Arshad)', () {
      test('should create message with correct intended recipient', () async {
        // Set Ali as current node
        messageHandler.setCurrentNodeId(aliNodeId);

        // Create a direct message from Ali to Arshad
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId,
        );

        // Verify the intended recipient is correctly set
        expect(
          protocolMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );
        expect(
          protocolMessage.payload['content'],
          equals('ciphertext-for-arshad'),
        );
      });

      test('should process message when intended for current user', () async {
        // Set Arshad as current node (recipient)
        messageHandler.setCurrentNodeId(arshadNodeId);

        // Create a hardened v2 direct message from Ali to Arshad.
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId,
          senderId: aliNodeId,
        );

        // Process the message
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Routing/auth should allow the message through even if test crypto
        // material is not decryptable in this harness.
        expect(result, isNotNull);
      });

      test('should block message when NOT intended for current user', () async {
        // Set Abubakar as current node (NOT the intended recipient)
        await seedTestUserPublicKey(abubakarNodeId);
        messageHandler.setCurrentNodeId(abubakarNodeId);

        // Create message from Ali to Arshad (Abubakar should not receive this)
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId,
          senderId: aliNodeId,
        );

        // Process the message
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should return null (blocked) since message is not intended for Abubakar
        expect(result, isNull);
      });

      test('should block own messages from appearing as incoming', () async {
        // Set Ali as current node
        messageHandler.setCurrentNodeId(aliNodeId);

        // Create message from Ali (sender == current user)
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'self-ciphertext',
          senderId: aliNodeId,
        );

        // Process the message (sender is Ali, current user is also Ali)
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: aliNodeId, // Same as current user
          contactRepository: stubContactRepository,
        );

        // Should return null (blocked) to prevent message loops
        expect(result, isNull);
      });
    });

    group('2. Message Encryption Tests', () {
      test('should use intended recipient key for encryption', () async {
        // Create protocol message with encryption
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'encrypted_hello_arshad',
          intendedRecipient: arshadNodeId,
        );

        // Verify encryption metadata
        expect(protocolMessage.payload['encrypted'], isTrue);
        expect(
          (protocolMessage.payload['crypto'] as Map<String, dynamic>)['mode'],
          equals('noise_v1'),
        );
        expect(
          protocolMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );
      });

      test(
        'should process encrypted message when intended for current user',
        () async {
          // Set Arshad as current node (recipient)
          messageHandler.setCurrentNodeId(arshadNodeId);

          // Create encrypted message from Ali to Arshad
          final protocolMessage = buildV2EncryptedTestMessage(
            messageId: 'msg123',
            content: 'encrypted_content',
            intendedRecipient: arshadNodeId,
            senderId: aliNodeId,
          );

          // Process the encrypted message
          final result = await messageHandler.processReceivedData(
            protocolMessageToWireBytes(protocolMessage),
            senderPublicKey: aliNodeId,
            contactRepository: stubContactRepository,
          );

          // The actual decrypt may fail in tests, but the message should not be
          // discarded by routing or signature policy.
          expect(result, isNotNull);
        },
      );
    });

    group('3. Relay Messaging Tests (Ali → Abubakar via Arshad)', () {
      test(
        'should create relay message with correct final recipient',
        () async {
          // Create relay message from Ali to Abubakar (final recipient)
          final relayMessage = ProtocolMessage.meshRelay(
            originalMessageId: 'relay123',
            originalSender: aliNodeId,
            finalRecipient: abubakarNodeId, // Final destination
            relayMetadata: {
              'hopCount': 1,
              'routePath': [aliNodeId, arshadNodeId],
              'priority': 'normal',
            },
            originalPayload: {
              'innerProtocolMessage': buildRelayInnerProtocolMessagePayload(
                messageId: 'relay-inner-1',
                content: 'relay-ciphertext',
                recipientId: abubakarNodeId,
                senderId: aliNodeId,
              ),
            },
            originalMessageType: ProtocolMessageType.textMessage,
          );

          // Verify relay message structure
          expect(relayMessage.meshRelayOriginalSender, equals(aliNodeId));
          expect(relayMessage.meshRelayFinalRecipient, equals(abubakarNodeId));
          expect(relayMessage.meshRelayOriginalMessageId, equals('relay123'));
        },
      );

      test(
        'should process relay message when current node is final recipient',
        () async {
          // Set Abubakar as current node (final recipient)
          messageHandler.setCurrentNodeId(abubakarNodeId);

          // Create relay message that reached Abubakar
          final protocolMessage = ProtocolMessage(
            type: ProtocolMessageType.meshRelay,
            payload: {
              'originalMessageId': 'relay123',
              'originalSender': aliNodeId,
              'finalRecipient': abubakarNodeId,
              'relayMetadata': {
                'hopCount': 2,
                'routePath': [aliNodeId, arshadNodeId, abubakarNodeId],
              },
              'originalPayload': {
                'innerProtocolMessage': buildRelayInnerProtocolMessagePayload(
                  messageId: 'relay-inner-2',
                  content: 'relay-ciphertext',
                  recipientId: abubakarNodeId,
                  senderId: aliNodeId,
                ),
              },
            },
            timestamp: DateTime.now(),
            version: 2,
          );

          // Process the relay message
          final result = await messageHandler.processReceivedData(
            protocolMessageToWireBytes(protocolMessage),
            senderPublicKey: arshadNodeId, // Came from Arshad (relay node)
            contactRepository: stubContactRepository,
          );

          // Should process since Abubakar is the final recipient
          // Relay messages return null but are processed by MeshRelayEngine
          expect(
            result,
            isNull,
          ); // Returns null for relay messages but processes them
        },
      );
    });

    group('4. Chat Screen Context Isolation Tests', () {
      test(
        'should maintain separate recipient contexts for different chats',
        () {
          // Simulate different chat screens with different recipients
          final aliToArshadContext = {
            'chatId': 'chat_ali_arshad',
            'contactPublicKey': arshadNodeId,
            'recipientName': 'Arshad',
          };

          final aliToAbubakarContext = {
            'chatId': 'chat_ali_abubakar',
            'contactPublicKey': abubakarNodeId,
            'recipientName': 'Abubakar',
          };

          // Verify contexts are different
          expect(aliToArshadContext['contactPublicKey'], equals(arshadNodeId));
          expect(
            aliToAbubakarContext['contactPublicKey'],
            equals(abubakarNodeId),
          );
          expect(
            aliToArshadContext['chatId'],
            isNot(equals(aliToAbubakarContext['chatId'])),
          );
        },
      );

      test('should use correct recipient key based on chat context', () {
        // Create messages with different recipients based on chat context
        final messageToArshad = buildV2EncryptedTestMessage(
          messageId: 'msg1',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId,
        );

        final messageToAbubakar = buildV2EncryptedTestMessage(
          messageId: 'msg2',
          content: 'ciphertext-for-abubakar',
          intendedRecipient: abubakarNodeId,
        );

        // Verify different recipients
        expect(
          messageToArshad.payload['intendedRecipient'],
          equals(arshadNodeId),
        );
        expect(
          messageToAbubakar.payload['intendedRecipient'],
          equals(abubakarNodeId),
        );
      });
    });

    group('5. Message Loop and Incorrect Delivery Prevention', () {
      test('should prevent message loops in direct messages', () async {
        // Set Ali as current node
        messageHandler.setCurrentNodeId(aliNodeId);

        // Create message where sender == current user (potential loop)
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'loop-ciphertext',
          senderId: aliNodeId,
        );

        // Process message from Ali (sender == current user)
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: aliNodeId, // Same as current node
          contactRepository: stubContactRepository,
        );

        // Should be blocked (null) to prevent loops
        expect(result, isNull);
      });

      test('should prevent incorrect delivery to wrong recipient', () async {
        // Set Abubakar as current node
        await seedTestUserPublicKey(abubakarNodeId);
        messageHandler.setCurrentNodeId(abubakarNodeId);

        // Create message intended for Arshad (not Abubakar)
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'secret-ciphertext',
          intendedRecipient: arshadNodeId, // Not for Abubakar
          senderId: aliNodeId,
        );

        // Abubakar shouldn't receive message intended for Arshad
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should be blocked (null) as message is not for Abubakar
        expect(result, isNull);
      });

      test('should allow correct delivery to intended recipient', () async {
        // Set Arshad as current node (correct recipient)
        messageHandler.setCurrentNodeId(arshadNodeId);

        // Create message intended for Arshad
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'msg123',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadNodeId, // Correctly intended for Arshad
          senderId: aliNodeId,
        );

        // Arshad should receive message intended for him
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should not be blocked by routing/security prechecks.
        expect(result, isNotNull);
      });
    });

    group('6. Integration Tests', () {
      test('should handle complete direct messaging flow', () async {
        // Ali sends to Arshad - complete flow test
        messageHandler.setCurrentNodeId(aliNodeId);

        // 1. Create message (as Ali would send)
        final outgoingMessage = buildV2EncryptedTestMessage(
          messageId: 'integration_test_1',
          content: 'integration-ciphertext',
          intendedRecipient: arshadNodeId,
          senderId: aliNodeId,
        );

        expect(
          outgoingMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );

        // 2. Simulate message received by Arshad
        messageHandler.setCurrentNodeId(arshadNodeId);

        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(outgoingMessage),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should reach Arshad's inbound path without being dropped.
        expect(result, isNotNull);
      });

      test('should handle encrypted message flow', () async {
        // Test encrypted message from Ali to Arshad
        messageHandler.setCurrentNodeId(arshadNodeId);

        final encryptedMessage = buildV2EncryptedTestMessage(
          messageId: 'encrypted_test_1',
          content: 'mock_encrypted_content',
          intendedRecipient: arshadNodeId,
          senderId: aliNodeId,
        );

        // Process encrypted message
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(encryptedMessage),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // The hardened path should process the message rather than reject it as
        // legacy/plaintext traffic.
        expect(result, isNotNull);
      });
    });

    group('7. Message Handler Node ID Validation', () {
      test('should handle node ID bounds correctly', () {
        // Test various node ID lengths to ensure no RangeError
        const shortNodeId = 'short';
        const normalNodeId = 'normal_length_node_id_12345678901234567890';
        const longNodeId =
            'very_long_node_id_that_exceeds_normal_bounds_12345678901234567890123456789012345678901234567890';

        expect(
          () => messageHandler.setCurrentNodeId(shortNodeId),
          returnsNormally,
        );
        expect(
          () => messageHandler.setCurrentNodeId(normalNodeId),
          returnsNormally,
        );
        expect(
          () => messageHandler.setCurrentNodeId(longNodeId),
          returnsNormally,
        );
      });

      test('should safely truncate node IDs in logging', () async {
        // Set a very long node ID
        const longNodeId =
            'very_long_node_id_that_could_cause_substring_errors_12345678901234567890123456789012345678901234567890';
        messageHandler.setCurrentNodeId(longNodeId);

        // Create and process a message to trigger logging that uses substring operations
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'bounds_test_message',
            'content': 'testing-bounds-ciphertext',
            'encrypted': true,
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
            'intendedRecipient': longNodeId,
          },
          signature: 'placeholder-signature',
          timestamp: DateTime.now(),
        );

        // Should not throw RangeError during processing
        expect(() async {
          await messageHandler.processReceivedData(
            protocolMessageToWireBytes(protocolMessage),
            senderPublicKey: aliNodeId,
            contactRepository: stubContactRepository,
          );
        }, returnsNormally);
      });
    });
  });
}
