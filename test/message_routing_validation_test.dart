import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'dart:convert';

import '../lib/data/services/ble_message_handler.dart';
import '../lib/core/models/protocol_message.dart';
import '../lib/core/services/security_manager.dart';
import '../lib/data/repositories/contact_repository.dart';

// Minimal stub for ContactRepository to avoid dependencies
class MinimalContactRepository extends ContactRepository {
  @override
  Future<Contact?> getContact(String publicKey) async => null;
  
  @override
  Future<String?> getCachedSharedSecret(String publicKey) async => null;
  
  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async => SecurityLevel.low;
}

void main() {
  group('Message Routing Validation Tests', () {
    late BLEMessageHandler messageHandler;
    late MinimalContactRepository contactRepository;
    
    // Test node IDs representing Ali, Arshad, and Abubakar
    const aliNodeId = 'ali_public_key_12345678901234567890123456789012';
    const arshadNodeId = 'arshad_public_key_12345678901234567890123456789012';
    const abubakarNodeId = 'abubakar_public_key_12345678901234567890123456789012';
    
    setUp(() {
      messageHandler = BLEMessageHandler();
      contactRepository = MinimalContactRepository();
    });

    group('Core Routing Logic Tests', () {
      test('should create protocol message with correct intendedRecipient', () {
        // Test that messages are created with the correct intended recipient
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'test123',
            'content': 'Hello Arshad',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );
        
        expect(message.payload['intendedRecipient'], equals(arshadNodeId));
        expect(message.payload['content'], equals('Hello Arshad'));
      });
      
      test('should block messages not intended for current user', () async {
        // Set Abubakar as current node
        messageHandler.setCurrentNodeId(abubakarNodeId);
        
        // Create message intended for Arshad (not Abubakar)
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Message for Arshad only',
            'intendedRecipient': arshadNodeId, // NOT for Abubakar
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });
        
        // Process the message - should be blocked
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(messageJson)),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );
        
        // Should return null (blocked) since message is not for Abubakar
        expect(result, isNull);
      });
      
      test('should allow messages intended for current user', () async {
        // Set Arshad as current node
        messageHandler.setCurrentNodeId(arshadNodeId);
        
        // Create message intended for Arshad
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'Message for Arshad',
            'intendedRecipient': arshadNodeId, // Correctly for Arshad
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });
        
        // Process the message - should be allowed
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(messageJson)),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );
        
        // Should return content since message is for Arshad
        expect(result, equals('Message for Arshad'));
      });
      
      test('should block own messages to prevent loops', () async {
        // Set Ali as current node
        messageHandler.setCurrentNodeId(aliNodeId);
        
        // Create message where sender == current user
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'msg123',
            'content': 'My own message',
            'encrypted': false,
            // No intendedRecipient (direct P2P message)
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        });
        
        // Process message where sender == current user
        final result = await messageHandler.processReceivedData(
          Uint8List.fromList(utf8.encode(messageJson)),
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
        final encryptedMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'enc123',
            'content': 'encrypted_content',
            'encrypted': true,
            'encryptionMethod': 'ecdh',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );
        
        expect(encryptedMessage.payload['encrypted'], isTrue);
        expect(encryptedMessage.payload['encryptionMethod'], equals('ecdh'));
        expect(encryptedMessage.payload['intendedRecipient'], equals(arshadNodeId));
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
        expect(aliToArshadChat['chatId'], isNot(equals(aliToAbubakarChat['chatId'])));
      });
    });

    group('Message Handler Safety Tests', () {
      test('should handle node ID bounds safely', () {
        // Test various node ID lengths
        const shortId = 'short';
        const normalId = 'normal_length_node_id_1234567890';
        const longId = 'very_long_node_id_that_exceeds_normal_bounds_123456789012345678901234567890';
        
        // Should not throw exceptions
        expect(() => messageHandler.setCurrentNodeId(shortId), returnsNormally);
        expect(() => messageHandler.setCurrentNodeId(normalId), returnsNormally);
        expect(() => messageHandler.setCurrentNodeId(longId), returnsNormally);
      });
      
      test('should safely process messages with long IDs', () async {
        const longNodeId = 'extremely_long_node_id_that_could_cause_substring_errors_123456789012345678901234567890123456789012345678901234567890';
        messageHandler.setCurrentNodeId(longNodeId);
        
        final messageJson = jsonEncode({
          'type': ProtocolMessageType.textMessage.index,
          'version': 1,
          'payload': {
            'messageId': 'safety_test_message_with_very_long_id_123456789012345678901234567890',
            'content': 'Safety test message',
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
            contactRepository: contactRepository,
          );
        }, returnsNormally);
      });
    });

    group('Integration Flow Tests', () {
      test('should handle complete Ali → Arshad messaging flow', () async {
        // Step 1: Ali creates message for Arshad
        messageHandler.setCurrentNodeId(aliNodeId);
        
        final outgoingMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'flow_test_1',
            'content': 'Hello from Ali to Arshad',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );
        
        expect(outgoingMessage.payload['intendedRecipient'], equals(arshadNodeId));
        
        // Step 2: Arshad receives and processes message
        messageHandler.setCurrentNodeId(arshadNodeId);
        
        final result = await messageHandler.processReceivedData(
          outgoingMessage.toBytes(),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );
        
        expect(result, equals('Hello from Ali to Arshad'));
      });
      
      test('should prevent Abubakar from receiving Ali → Arshad message', () async {
        // Ali creates message for Arshad
        final messageForArshad = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          payload: {
            'messageId': 'isolation_test_1',
            'content': 'Private message for Arshad only',
            'intendedRecipient': arshadNodeId,
          },
          timestamp: DateTime.now(),
        );
        
        // Abubakar tries to process it (should be blocked)
        messageHandler.setCurrentNodeId(abubakarNodeId);
        
        final result = await messageHandler.processReceivedData(
          messageForArshad.toBytes(),
          senderPublicKey: aliNodeId,
          contactRepository: contactRepository,
        );
        
        // Should be null (blocked) - Abubakar cannot read Ali's message to Arshad
        expect(result, isNull);
      });
    });
  });
}