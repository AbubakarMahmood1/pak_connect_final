import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'dart:convert';
import 'dart:typed_data';

void main() {
  group('P2P Message Routing Fix Tests', () {
    late BLEMessageHandler handler;
    late ContactRepository mockContactRepository;
    
    setUp(() {
      handler = BLEMessageHandler();
      mockContactRepository = ContactRepository();
      
      // Set up our node ID for testing
      handler.setCurrentNodeId('our_node_123');
    });
    
    tearDown(() {
      handler.dispose();
    });

    test('Direct P2P message without routing info should be accepted', () async {
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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
        senderPublicKey: 'sender_key_456',
        contactRepository: mockContactRepository,
      );
      
      // Should accept the message and return content
      expect(result, equals('Hello P2P!'));
    });

    test('Direct P2P message with recipient info should be accepted', () async {
      // Create a message with intendedRecipient (P2P with routing)
      final protocolMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {
          'messageId': 'test_msg_2',
          'content': 'Hello with routing!',
          'encrypted': false,
          'encryptionMethod': 'none',
          'intendedRecipient': 'recipient_key_789', // Different from our node ID
        },
        timestamp: DateTime.now(),
      );
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
        senderPublicKey: 'sender_key_456',
        contactRepository: mockContactRepository,
      );
      
      // Should accept the P2P message even though intendedRecipient != our node ID
      expect(result, equals('Hello with routing!'));
    });

    test('Mesh message explicitly addressed to our node ID should be accepted', () async {
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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
        senderPublicKey: 'sender_key_456',
        contactRepository: mockContactRepository,
      );
      
      // Should accept the mesh message
      expect(result, equals('Hello mesh message!'));
    });

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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
        senderPublicKey: 'our_node_123', // Same as our node ID
        contactRepository: mockContactRepository,
      );
      
      // Should block our own message even without routing info
      expect(result, isNull);
    });

    test('Encrypted P2P message should be processed normally', () async {
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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
        senderPublicKey: 'sender_key_456',
        contactRepository: mockContactRepository,
      );
      
      // Should attempt to process the encrypted message
      // (will fail decryption but shouldn't be blocked by routing)
      expect(result, isNotNull);
      expect(result, contains('Could not decrypt')); // Expected decryption failure
    });
  });
  
  group('Routing Logic Edge Cases', () {
    late BLEMessageHandler handler;
    late ContactRepository mockContactRepository;
    
    setUp(() {
      handler = BLEMessageHandler();
      mockContactRepository = ContactRepository();
    });
    
    tearDown(() {
      handler.dispose();
    });

    test('Message processing without node ID set should work', () async {
      // Don't set our node ID
      
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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
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
      
      final messageBytes = protocolMessage.toBytes();
      final result = await handler.processReceivedData(
        Uint8List.fromList(messageBytes),
        senderPublicKey: null, // Null sender
        contactRepository: mockContactRepository,
      );
      
      // Should process the message
      expect(result, equals('Message with null sender!'));
    });
  });
}