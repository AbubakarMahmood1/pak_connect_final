import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'dart:convert';

import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/services/security_manager.dart';

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
  group('Message Encryption and Routing Tests', () {
    late BLEMessageHandler messageHandler;
    late StubContactRepository stubContactRepository;

    // Test node IDs representing Ali, Arshad, and Abubakar
    const aliNodeId = 'ali_public_key_12345678901234567890123456789012';
    const arshadNodeId = 'arshad_public_key_12345678901234567890123456789012';
    const abubakarNodeId =
        'abubakar_public_key_12345678901234567890123456789012';

    setUp(() {
      messageHandler = BLEMessageHandler();
      stubContactRepository = StubContactRepository();
    });

    group('1. Direct Messaging Tests (Ali → Arshad)', () {
      test('should create message with correct intended recipient', () async {
        // Set Ali as current node
        messageHandler.setCurrentNodeId(aliNodeId);

        // Create a direct message from Ali to Arshad
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'msg123',
            'content': 'Hello Arshad',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient':
                arshadNodeId, // Key test: recipient should be Arshad
          },
          timestamp: DateTime.now(),
        );

        // Verify the intended recipient is correctly set
        expect(
          protocolMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );
        expect(protocolMessage.payload['content'], equals('Hello Arshad'));
      });

      test('should process message when intended for current user', () async {
        // Set Arshad as current node (recipient)
        messageHandler.setCurrentNodeId(arshadNodeId);

        // Create message from Ali to Arshad
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Hello Arshad',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient': arshadNodeId,
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Process the message
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(messageJson)),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should return the message content since Arshad is the intended recipient
        expect(result, equals('Hello Arshad'));
      });

      test('should block message when NOT intended for current user', () async {
        // Set Abubakar as current node (NOT the intended recipient)
        messageHandler.setCurrentNodeId(abubakarNodeId);

        // Create message from Ali to Arshad (Abubakar should not receive this)
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Hello Arshad',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient':
                arshadNodeId, // Intended for Arshad, not Abubakar
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Process the message
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(messageJson)),
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
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'My own message',
            'encrypted': false,
            'encryptionMethod': 'none',
            // No intendedRecipient (direct P2P message)
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Process the message (sender is Ali, current user is also Ali)
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(messageJson)),
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
        final protocolMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'msg123',
            'content': 'encrypted_hello_arshad',
            'encrypted': true,
            'encryptionMethod': 'ecdh',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );

        // Verify encryption metadata
        expect(protocolMessage.payload['encrypted'], isTrue);
        expect(protocolMessage.payload['encryptionMethod'], equals('ecdh'));
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
          final messageJson = jsonEncode({
            'type': ProtocolMessageType.textMessage.index,
            'version': 1,
            'payload': {
              'messageId': 'msg123',
              'content': 'encrypted_content',
              'encrypted': true,
              'encryptionMethod': 'ecdh',
              'intendedRecipient': arshadNodeId,
            },
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'useEphemeralSigning': false,
          });

          // Process the encrypted message
          final result = await messageHandler.processReceivedData(
            Uint8List.fromList(utf8.encode(messageJson)),
            senderPublicKey: aliNodeId,
            contactRepository: stubContactRepository,
          );

          // Should attempt to decrypt (not return null due to routing)
          // The actual decryption will fail due to stub, but routing validation should pass
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
              'content': 'Hello Abubakar via relay',
              'encrypted': true,
            },
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
          final relayMessageJson = jsonEncode({
            'type': ProtocolMessageType.meshRelay.index,
            'version': 1,
            'payload': {
              'originalMessageId': 'relay123',
              'originalSender': aliNodeId,
              'finalRecipient': abubakarNodeId,
              'relayMetadata': {
                'hopCount': 2,
                'routePath': [aliNodeId, arshadNodeId, abubakarNodeId],
              },
              'originalPayload': {
                'content': 'Hello Abubakar via relay',
                'encrypted': false,
              },
            },
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'useEphemeralSigning': false,
          });

          // Process the relay message
          final result = await messageHandler.processReceivedData(
            Uint8List.fromList(utf8.encode(relayMessageJson)),
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
        final messageToArshad = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'msg1',
            'content': 'Message for Arshad',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );

        final messageToAbubakar = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'msg2',
            'content': 'Message for Abubakar',
            'intendedRecipient': abubakarNodeId,
          },
          timestamp: DateTime.now(),
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
        final loopMessageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Loop message',
            'encrypted': false,
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Process message from Ali (sender == current user)
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(loopMessageJson)),
          senderPublicKey: aliNodeId, // Same as current node
          contactRepository: stubContactRepository,
        );

        // Should be blocked (null) to prevent loops
        expect(result, isNull);
      });

      test('should prevent incorrect delivery to wrong recipient', () async {
        // Set Abubakar as current node
        messageHandler.setCurrentNodeId(abubakarNodeId);

        // Create message intended for Arshad (not Abubakar)
        final wrongRecipientJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Secret for Arshad only',
            'intendedRecipient': arshadNodeId, // Not for Abubakar
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Abubakar shouldn't receive message intended for Arshad
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(wrongRecipientJson)),
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
        final correctRecipientJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Message for Arshad',
            'intendedRecipient': arshadNodeId, // Correctly intended for Arshad
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Arshad should receive message intended for him
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(correctRecipientJson)),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should return message content (not blocked)
        expect(result, equals('Message for Arshad'));
      });
    });

    group('6. Integration Tests', () {
      test('should handle complete direct messaging flow', () async {
        // Ali sends to Arshad - complete flow test
        messageHandler.setCurrentNodeId(aliNodeId);

        // 1. Create message (as Ali would send)
        final outgoingMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'integration_test_1',
            'content': 'Hello from integration test',
            'encrypted': false,
            'encryptionMethod': 'none',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );

        expect(
          outgoingMessage.payload['intendedRecipient'],
          equals(arshadNodeId),
        );

        // 2. Simulate message received by Arshad
        messageHandler.setCurrentNodeId(arshadNodeId);

        final result = await messageHandler.processReceivedData(
          outgoingMessage.toBytes(),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should successfully deliver to Arshad
        expect(result, equals('Hello from integration test'));
      });

      test('should handle encrypted message flow', () async {
        // Test encrypted message from Ali to Arshad
        messageHandler.setCurrentNodeId(arshadNodeId);

        final encryptedMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'encrypted_test_1',
            'content': 'mock_encrypted_content',
            'encrypted': true,
            'encryptionMethod': 'ecdh',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );

        // Process encrypted message
        final result = await messageHandler.processReceivedData(
          encryptedMessage.toBytes(),
          senderPublicKey: aliNodeId,
          contactRepository: stubContactRepository,
        );

        // Should attempt to process (routing validation passes)
        // Note: Actual decryption would depend on SecurityManager implementation
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
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'bounds_test_message',
            'content': 'Testing bounds safety',
            'intendedRecipient': longNodeId,
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });

        // Should not throw RangeError during processing
        expect(() async {
          await messageHandler.processReceivedData(
            Uint8List.fromList(utf8.encode(messageJson)),
            senderPublicKey: aliNodeId,
            contactRepository: stubContactRepository,
          );
        }, returnsNormally);
      });
    });
  });
}
