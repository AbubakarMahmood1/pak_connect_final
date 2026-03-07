import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:pak_connect/data/services/inbound_text_processor.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/signing_manager.dart';

void main() {
  group('InboundTextProcessor', () {
    late _FakeSecurityService securityService;
    late _FakeContactRepository contactRepository;
    late InboundTextProcessor processor;

    setUp(() {
      InboundTextProcessor.clearPeerProtocolVersionFloorForTest();
      securityService = _FakeSecurityService();
      contactRepository = _FakeContactRepository();
      processor = InboundTextProcessor(
        contactRepository: contactRepository,
        isMessageForMe: (_) async => true,
        currentNodeIdProvider: () => 'local-node',
        securityService: securityService,
      );
    });

    test(
      'uses declared sender identity for v2 decrypt when transport sender is relay',
      () async {
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-relay-decrypt',
            'content': 'ciphertext',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );

        final result = await processor.process(
          protocolMessage: message,
          senderPublicKey: 'relay-node',
        );

        expect(result.content, equals('typed:ciphertext'));
        expect(result.shouldAck, isTrue);
        expect(securityService.decryptMessageByTypeCalls, equals(1));
        expect(securityService.lastDecryptPublicKey, equals('crypto-sender'));
      },
    );

    test(
      'uses sealed sender and recipient bindings from envelope over transport sender',
      () async {
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-sealed-relay',
            'content': 'ciphertext-base64',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'recipientId': 'recipient-key',
            'crypto': {
              'mode': 'sealed_v1',
              'modeVersion': 1,
              'kid': 'kid-1',
              'epk': 'ZWJjZGVmZw==',
              'nonce': 'bm9uY2UxMjM=',
            },
          },
          timestamp: DateTime.now(),
        );

        final result = await processor.process(
          protocolMessage: message,
          senderPublicKey: 'relay-node',
        );

        expect(result.content, equals('sealed:ciphertext-base64'));
        expect(result.shouldAck, isTrue);
        expect(securityService.decryptSealedCalls, equals(1));
        expect(securityService.lastSealedSenderId, equals('crypto-sender'));
        expect(securityService.lastSealedRecipientId, equals('recipient-key'));
      },
    );

    test('rejects sealed v2 payload missing sender binding', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed-missing-sender',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'recipientId': 'recipient-key',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'kid': 'kid-1',
            'epk': 'ZWJjZGVmZw==',
            'nonce': 'bm9uY2UxMjM=',
          },
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptSealedCalls, equals(0));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test('rejects sealed v2 payload missing recipient binding', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed-missing-recipient',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'senderId': 'crypto-sender',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'kid': 'kid-1',
            'epk': 'ZWJjZGVmZw==',
            'nonce': 'bm9uY2UxMjM=',
          },
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptSealedCalls, equals(0));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });


    test('rejects unsigned sealed v2 message', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed-unsigned',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'senderId': 'crypto-sender',
          'recipientId': 'recipient-key',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'kid': 'kid-1',
            'epk': 'ZWJjZGVmZw==',
            'nonce': 'bm9uY2UxMjM=',
          },
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptSealedCalls, equals(0));
    });

    test('rejects sealed v2 message with empty-string signature', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed-empty-sig',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'senderId': 'crypto-sender',
          'recipientId': 'recipient-key',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'kid': 'kid-1',
            'epk': 'ZWJjZGVmZw==',
            'nonce': 'bm9uY2UxMjM=',
          },
        },
        timestamp: DateTime.now(),
        signature: '',
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptSealedCalls, equals(0));
    });

    test(
      'rejects sealed v2 message with whitespace-only signature',
      () async {
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-sealed-whitespace-sig',
            'content': 'ciphertext-base64',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'recipientId': 'recipient-key',
            'crypto': {
              'mode': 'sealed_v1',
              'modeVersion': 1,
              'kid': 'kid-1',
              'epk': 'ZWJjZGVmZw==',
              'nonce': 'bm9uY2UxMjM=',
            },
          },
          timestamp: DateTime.now(),
          signature: '   ',
        );

        final result = await processor.process(
          protocolMessage: message,
          senderPublicKey: 'relay-node',
        );

        expect(result.content, isNull);
        expect(result.shouldAck, isFalse);
        expect(securityService.decryptSealedCalls, equals(0));
      },
    );

    test(
      'requires signature for v2 encrypted message when policy enabled',
      () async {
        final strictProcessor = InboundTextProcessor(
          contactRepository: contactRepository,
          isMessageForMe: (_) async => true,
          currentNodeIdProvider: () => 'local-node',
          securityService: securityService,
          requireV2Signature: true,
        );
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-signature-required',
            'content': 'ciphertext',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );

        final result = await strictProcessor.process(
          protocolMessage: message,
          senderPublicKey: 'relay-node',
        );

        expect(result.content, isNull);
        expect(result.shouldAck, isFalse);
        expect(securityService.decryptMessageByTypeCalls, equals(0));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test(
      'requires signature for encrypted v2 message once peer floor is upgraded',
      () async {
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-floor-signature',
            'content': 'ciphertext-floor-signature',
            'encrypted': true,
            'senderId': 'peer-upgraded',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final baselinePayload = SigningManager.signaturePayloadForMessage(
          baselineV2,
          fallbackContent: 'typed:ciphertext-floor-signature',
        );
        final baselineSignature = _signWithEphemeralPrivateKey(
          content: baselinePayload,
          privateKeyHex: signingKeyPair.privateHex,
        );
        final signedV2 = ProtocolMessage(
          type: baselineV2.type,
          version: baselineV2.version,
          payload: baselineV2.payload,
          signature: baselineSignature,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final unsignedV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-unsigned-after-upgrade',
            'content': 'ciphertext-unsigned',
            'encrypted': true,
            'senderId': 'peer-upgraded',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: now.add(const Duration(seconds: 1)),
        );

        final firstResult = await processor.process(
          protocolMessage: signedV2,
          senderPublicKey: 'relay-node',
        );
        final secondResult = await processor.process(
          protocolMessage: unsignedV2,
          senderPublicKey: 'relay-node',
        );

        expect(firstResult.content, equals('typed:ciphertext-floor-signature'));
        expect(firstResult.shouldAck, isTrue);
        expect(secondResult.content, isNull);
        expect(secondResult.shouldAck, isFalse);
        expect(securityService.decryptMessageByTypeCalls, equals(1));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test('rejects unsigned v2 direct plaintext text message', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-direct-plaintext',
          'content': 'spoof-attempt',
          'encrypted': false,
          'senderId': 'crypto-sender',
          'intendedRecipient': 'local-node',
          'recipientId': 'local-node',
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test('rejects unsigned v2 broadcast plaintext text message', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-broadcast-plaintext',
          'content': 'spoof-broadcast',
          'encrypted': false,
          'senderId': 'crypto-sender',
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test('blocks legacy v2 decrypt modes when policy disables them', () async {
      final strictProcessor = InboundTextProcessor(
        contactRepository: contactRepository,
        isMessageForMe: (_) async => true,
        currentNodeIdProvider: () => 'local-node',
        securityService: securityService,
        allowLegacyV2Decrypt: false,
      );
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-legacy-block',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'crypto-sender',
          'crypto': {'mode': 'legacy_ecdh_v1', 'modeVersion': 1},
        },
        timestamp: DateTime.now(),
      );

      final result = await strictProcessor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test(
      'blocks v2 legacy_global_v1 decrypt mode even when compatibility is enabled',
      () async {
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-legacy-global-blocked',
            'content': 'PLAINTEXT:spoofed-message',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'crypto': {'mode': 'legacy_global_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );

        final result = await processor.process(
          protocolMessage: message,
          senderPublicKey: 'relay-node',
        );

        expect(result.content, isNull);
        expect(result.shouldAck, isFalse);
        expect(securityService.decryptMessageByTypeCalls, equals(0));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test(
      'blocks legacy v2 decrypt mode for peers already observed at v2 floor',
      () async {
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-floor-legacy-mode',
            'content': 'ciphertext-floor',
            'encrypted': true,
            'senderId': 'peer-upgraded',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final baselinePayload = SigningManager.signaturePayloadForMessage(
          baselineV2,
          fallbackContent: 'typed:ciphertext-floor',
        );
        final baselineSignature = _signWithEphemeralPrivateKey(
          content: baselinePayload,
          privateKeyHex: signingKeyPair.privateHex,
        );
        final signedV2 = ProtocolMessage(
          type: baselineV2.type,
          version: baselineV2.version,
          payload: baselineV2.payload,
          signature: baselineSignature,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final legacyModePayload = <String, dynamic>{
          'messageId': 'msg-v2-legacy-after-upgrade',
          'content': 'ciphertext-legacy',
          'encrypted': true,
          'senderId': 'peer-upgraded',
          'crypto': {'mode': 'legacy_ecdh_v1', 'modeVersion': 1},
        };
        final legacyModeUnsigned = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: legacyModePayload,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now.add(const Duration(seconds: 1)),
        );
        final legacyModeSignature = _signWithEphemeralPrivateKey(
          content: SigningManager.signaturePayloadForMessage(
            legacyModeUnsigned,
            fallbackContent: 'typed:ciphertext-legacy',
          ),
          privateKeyHex: signingKeyPair.privateHex,
        );
        final legacyModeV2 = ProtocolMessage(
          type: legacyModeUnsigned.type,
          version: legacyModeUnsigned.version,
          payload: legacyModeUnsigned.payload,
          signature: legacyModeSignature,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: legacyModeUnsigned.timestamp,
        );

        final firstResult = await processor.process(
          protocolMessage: signedV2,
          senderPublicKey: 'relay-node',
        );
        final secondResult = await processor.process(
          protocolMessage: legacyModeV2,
          senderPublicKey: 'relay-node',
        );

        expect(firstResult.content, equals('typed:ciphertext-floor'));
        expect(firstResult.shouldAck, isTrue);
        expect(secondResult.content, isNull);
        expect(secondResult.shouldAck, isFalse);
        expect(securityService.decryptMessageByTypeCalls, equals(1));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test(
      'rejects v1 message after observing authenticated v2 from same peer',
      () async {
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-floor',
            'content': 'ciphertext-floor',
            'encrypted': true,
            'senderId': 'peer-upgraded',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final baselinePayload = SigningManager.signaturePayloadForMessage(
          baselineV2,
          fallbackContent: 'typed:ciphertext-floor',
        );
        final baselineSignature = _signWithEphemeralPrivateKey(
          content: baselinePayload,
          privateKeyHex: signingKeyPair.privateHex,
        );
        final signedV2 = ProtocolMessage(
          type: baselineV2.type,
          version: baselineV2.version,
          payload: baselineV2.payload,
          signature: baselineSignature,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final v1Message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 1,
          payload: {
            'messageId': 'msg-v1-downgrade',
            'content': 'hello-v1',
            'encrypted': false,
            'senderId': 'peer-upgraded',
          },
          timestamp: DateTime.now(),
        );

        final firstResult = await processor.process(
          protocolMessage: signedV2,
          senderPublicKey: 'relay-node',
        );
        final secondResult = await processor.process(
          protocolMessage: v1Message,
          senderPublicKey: 'relay-node',
        );

        expect(firstResult.content, equals('typed:ciphertext-floor'));
        expect(firstResult.shouldAck, isTrue);
        expect(secondResult.content, isNull);
        expect(secondResult.shouldAck, isFalse);
        expect(securityService.decryptMessageCalls, equals(0));
        expect(securityService.decryptMessageByTypeCalls, equals(1));
      },
    );

    test(
      'does not raise protocol floor for unauthenticated v2 message',
      () async {
        final unsignedV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-unsigned-floor',
            'content': 'ciphertext-unsigned',
            'encrypted': true,
            'senderId': 'peer-unsigned',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );
        final v1Message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 1,
          payload: {
            'messageId': 'msg-v1-after-unsigned',
            'content': 'hello-v1',
            'encrypted': false,
            'senderId': 'peer-unsigned',
          },
          timestamp: DateTime.now(),
        );

        final firstResult = await processor.process(
          protocolMessage: unsignedV2,
          senderPublicKey: 'relay-node',
        );
        final secondResult = await processor.process(
          protocolMessage: v1Message,
          senderPublicKey: 'relay-node',
        );

        expect(firstResult.content, equals('typed:ciphertext-unsigned'));
        expect(firstResult.shouldAck, isTrue);
        expect(secondResult.content, equals('hello-v1'));
        expect(secondResult.shouldAck, isTrue);
        expect(securityService.decryptMessageCalls, equals(0));
        expect(securityService.decryptMessageByTypeCalls, equals(1));
      },
    );

    test(
      'shares downgrade floor with ProtocolMessageHandler across inbound paths',
      () async {
        final protocolHandler = ProtocolMessageHandler(
          securityService: securityService,
        );
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-cross-handler',
            'content': 'ciphertext-cross',
            'encrypted': true,
            'senderId': 'peer-shared',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final baselinePayload = SigningManager.signaturePayloadForMessage(
          baselineV2,
          fallbackContent: 'typed:ciphertext-cross',
        );
        final baselineSignature = _signWithEphemeralPrivateKey(
          content: baselinePayload,
          privateKeyHex: signingKeyPair.privateHex,
        );
        final v2Message = ProtocolMessage(
          type: baselineV2.type,
          version: baselineV2.version,
          payload: baselineV2.payload,
          signature: baselineSignature,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final v1Message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 1,
          payload: {
            'messageId': 'msg-v1-cross-handler',
            'content': 'hello-v1',
            'encrypted': false,
            'senderId': 'peer-shared',
          },
          timestamp: DateTime.now(),
        );

        final protocolResult = await protocolHandler.processProtocolMessage(
          message: v2Message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );
        final inboundResult = await processor.process(
          protocolMessage: v1Message,
          senderPublicKey: 'relay-node',
        );

        expect(protocolResult, equals('typed:ciphertext-cross'));
        expect(inboundResult.content, isNull);
        expect(inboundResult.shouldAck, isFalse);
      },
    );

    test(
      'rejects v2 envelope tampering across bound fields when signature is present',
      () async {
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final basePayload = <String, dynamic>{
          'messageId': 'msg-v2-signed-inbound',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'crypto-sender',
          'recipientId': 'recipient-key',
          'intendedRecipient': 'local-node',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'sessionId': 'session-1',
            'kid': 'kid-1',
            'epk': 'ZWJjZGVmZw==',
            'nonce': 'bm9uY2UxMjM=',
          },
        };

        final baselineMessage = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: _clonePayload(basePayload),
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        );
        final baselineSignature = _signWithEphemeralPrivateKey(
          content: SigningManager.signaturePayloadForMessage(
            baselineMessage,
            fallbackContent: 'sealed:ciphertext',
          ),
          privateKeyHex: signingKeyPair.privateHex,
        );

        final validResult = await processor.process(
          protocolMessage: ProtocolMessage(
            type: ProtocolMessageType.textMessage,
            version: 2,
            payload: _clonePayload(basePayload),
            signature: baselineSignature,
            useEphemeralSigning: true,
            ephemeralSigningKey: signingKeyPair.publicHex,
            timestamp: now,
          ),
          senderPublicKey: 'relay-node',
        );
        expect(validResult.content, equals('sealed:ciphertext'));
        expect(validResult.shouldAck, isTrue);

        final tamperCases = <_EnvelopeTamperCase>[
          _EnvelopeTamperCase(
            label: 'senderId',
            apply: (payload) => payload['senderId'] = 'sender-tampered',
          ),
          _EnvelopeTamperCase(
            label: 'recipientId',
            apply: (payload) => payload['recipientId'] = 'recipient-tampered',
          ),
          _EnvelopeTamperCase(
            label: 'messageId',
            apply: (payload) =>
                payload['messageId'] = 'msg-v2-signed-inbound-tampered',
          ),
          _EnvelopeTamperCase(
            label: 'content',
            apply: (payload) => payload['content'] = 'ciphertext-tampered',
          ),
          _EnvelopeTamperCase(
            label: 'crypto.mode',
            apply: (payload) {
              final crypto = Map<String, dynamic>.from(
                payload['crypto'] as Map,
              );
              crypto['mode'] = 'noise_v1';
              payload['crypto'] = crypto;
            },
          ),
          _EnvelopeTamperCase(
            label: 'crypto.sessionId',
            apply: (payload) {
              final crypto = Map<String, dynamic>.from(
                payload['crypto'] as Map,
              );
              crypto['sessionId'] = 'session-2';
              payload['crypto'] = crypto;
            },
          ),
          _EnvelopeTamperCase(
            label: 'crypto.kid',
            apply: (payload) {
              final crypto = Map<String, dynamic>.from(
                payload['crypto'] as Map,
              );
              crypto['kid'] = 'kid-2';
              payload['crypto'] = crypto;
            },
          ),
          _EnvelopeTamperCase(
            label: 'crypto.epk',
            apply: (payload) {
              final crypto = Map<String, dynamic>.from(
                payload['crypto'] as Map,
              );
              crypto['epk'] = 'YWJjZGVmZw==';
              payload['crypto'] = crypto;
            },
          ),
          _EnvelopeTamperCase(
            label: 'crypto.nonce',
            apply: (payload) {
              final crypto = Map<String, dynamic>.from(
                payload['crypto'] as Map,
              );
              crypto['nonce'] = 'bm9uY2UyMzQ=';
              payload['crypto'] = crypto;
            },
          ),
        ];

        for (final tamperCase in tamperCases) {
          final tamperedPayload = _clonePayload(basePayload);
          tamperCase.apply(tamperedPayload);

          final tamperedResult = await processor.process(
            protocolMessage: ProtocolMessage(
              type: ProtocolMessageType.textMessage,
              version: 2,
              payload: tamperedPayload,
              signature: baselineSignature,
              useEphemeralSigning: true,
              ephemeralSigningKey: signingKeyPair.publicHex,
              timestamp: now,
            ),
            senderPublicKey: 'relay-node',
          );
          expect(
            tamperedResult.content,
            equals('[❌ UNTRUSTED MESSAGE - Signature Invalid]'),
            reason: 'Tamper case failed: ${tamperCase.label}',
          );
          expect(tamperedResult.shouldAck, isFalse);
        }
      },
    );
  });
}

Map<String, dynamic> _clonePayload(Map<String, dynamic> payload) {
  return Map<String, dynamic>.from(
    jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
  );
}

_EphemeralSigningKeyPair _generateEphemeralSigningKeyPair() {
  final keyGen = ECKeyGenerator();
  final secureRandom = FortunaRandom();
  final random = Random.secure();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));
  keyGen.init(
    ParametersWithRandom(
      ECKeyGeneratorParameters(ECCurve_secp256r1()),
      secureRandom,
    ),
  );

  final keyPair = keyGen.generateKeyPair();
  final publicKey = keyPair.publicKey as ECPublicKey;
  final privateKey = keyPair.privateKey as ECPrivateKey;

  return _EphemeralSigningKeyPair(
    privateHex: privateKey.d!.toRadixString(16),
    publicHex: publicKey.Q!
        .getEncoded(false)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
  );
}

String _signWithEphemeralPrivateKey({
  required String content,
  required String privateKeyHex,
}) {
  final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
  final privateKey = ECPrivateKey(privateKeyInt, ECCurve_secp256r1());
  final signer = ECDSASigner(SHA256Digest());
  final secureRandom = FortunaRandom();
  final random = Random.secure();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));
  signer.init(
    true,
    ParametersWithRandom(PrivateKeyParameter(privateKey), secureRandom),
  );

  final signature =
      signer.generateSignature(utf8.encode(content)) as ECSignature;
  return '${signature.r.toRadixString(16)}:${signature.s.toRadixString(16)}';
}

class _EphemeralSigningKeyPair {
  const _EphemeralSigningKeyPair({
    required this.privateHex,
    required this.publicHex,
  });

  final String privateHex;
  final String publicHex;
}

class _EnvelopeTamperCase {
  const _EnvelopeTamperCase({required this.label, required this.apply});

  final String label;
  final void Function(Map<String, dynamic>) apply;
}

class _FakeContactRepository implements IContactRepository {
  @override
  Future<Contact?> getContactByAnyId(String identifier) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSecurityService implements ISecurityService {
  int decryptMessageCalls = 0;
  int decryptMessageByTypeCalls = 0;
  int decryptSealedCalls = 0;
  EncryptionType? lastDecryptType;
  String? lastDecryptPublicKey;
  String? lastSealedSenderId;
  String? lastSealedRecipientId;

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}

  @override
  void unregisterIdentityMapping(String persistentPublicKey) {}

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async => SecurityLevel.low;

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async => EncryptionMethod.global();

  @override
  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  ) async => message;

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async => message;

  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async {
    decryptMessageCalls++;
    lastDecryptPublicKey = publicKey;
    return 'legacy:$encryptedMessage';
  }

  @override
  Future<String> decryptMessageByType(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async {
    decryptMessageByTypeCalls++;
    lastDecryptType = type;
    lastDecryptPublicKey = publicKey;
    return 'typed:$encryptedMessage';
  }

  @override
  Future<String> decryptSealedMessage({
    required String encryptedMessage,
    required CryptoHeader cryptoHeader,
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    decryptSealedCalls++;
    lastSealedSenderId = senderId;
    lastSealedRecipientId = recipientId;
    return 'sealed:$encryptedMessage';
  }

  @override
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => false;
}
