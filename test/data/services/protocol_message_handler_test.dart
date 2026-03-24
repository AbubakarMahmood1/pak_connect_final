import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/signing_manager.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};
  StreamSubscription<LogRecord>? logSub;
  Level? previousLevel;

  group('ProtocolMessageHandler', () {
    late ProtocolMessageHandler handler;
    late _FakeSecurityService securityService;

    setUp(() {
      logRecords.clear();
      allowedSevere.clear();
      previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      logSub = Logger.root.onRecord.listen(logRecords.add);
      ProtocolMessageHandler.clearPeerProtocolVersionFloorForTest();
      securityService = _FakeSecurityService();
      // Explicit permissive flags: production now defaults to strict (false/true).
      // Tests that exercise non-policy logic use permissive mode; tests for
      // strict behavior construct their own handler with explicit flags.
      handler = ProtocolMessageHandler(
        securityService: securityService,
        requireV2Signature: false,
      );
    });

    tearDown(() {
      logSub?.cancel();
      logSub = null;
      if (previousLevel != null) {
        Logger.root.level = previousLevel!;
      }
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
    });

    test('creates instance successfully', () {
      expect(handler, isNotNull);
    });

    test('sets current node ID', () {
      final nodeId = 'test-node-12345678-abcdefgh';
      expect(() => handler.setCurrentNodeId(nodeId), returnsNormally);
    });

    test(
      'message is for me when intended recipient is null (broadcast)',
      () async {
        final isForMe = await handler.isMessageForMe(null);
        expect(isForMe, isTrue);
      },
    );

    test(
      'message is for me when intended recipient matches current node',
      () async {
        final nodeId = 'test-node-123';
        handler.setCurrentNodeId(nodeId);

        final isForMe = await handler.isMessageForMe(nodeId);
        expect(isForMe, isTrue);
      },
    );

    test(
      'message is not for me when recipient differs from current node',
      () async {
        handler.setCurrentNodeId('node-A');

        final isForMe = await handler.isMessageForMe('node-B');
        expect(isForMe, isFalse);
      },
    );

    test('resolves message identities', () async {
      final identities = await handler.resolveMessageIdentities(
        encryptionSenderKey: 'sender-key',
        meshSenderKey: 'sender-key',
        intendedRecipient: 'recipient-key',
      );

      expect(identities, isA<Map<String, dynamic>>());
      expect(identities['originalSender'], equals('sender-key'));
      expect(identities['intendedRecipient'], equals('recipient-key'));
      expect(identities['isSpyMode'], isFalse);
    });

    test('detects spy mode when sender keys differ', () async {
      final identities = await handler.resolveMessageIdentities(
        encryptionSenderKey: 'sender-key',
        meshSenderKey: 'different-key',
        intendedRecipient: 'recipient-key',
      );

      expect(identities['isSpyMode'], isTrue);
    });

    test('gets and sets encryption method', () {
      expect(handler.getEncryptionMethod(), equals('none'));

      handler.setEncryptionMethod('ecdh');
      expect(handler.getEncryptionMethod(), equals('ecdh'));

      handler.setEncryptionMethod('conversation');
      expect(handler.getEncryptionMethod(), equals('conversation'));
    });

    test('registers contact request callback', () {
      handler.onContactRequestReceived((key, name) {});

      expect(handler, isNotNull);
    });

    test('registers contact accept callback', () {
      handler.onContactAcceptReceived((key, name) {});

      expect(handler, isNotNull);
    });

    test('registers contact reject callback', () {
      handler.onContactRejectReceived(() {});

      expect(handler, isNotNull);
    });

    test('registers crypto verification callback', () {
      handler.onCryptoVerificationReceived((verificationId, contactKey) {
        // Callback set
      });

      expect(handler, isNotNull);
    });

    test('registers crypto verification response callback', () {
      handler.onCryptoVerificationResponseReceived((
        verificationId,
        contactKey,
        isVerified,
        data,
      ) {
        // Callback set
      });

      expect(handler, isNotNull);
    });

    test('registers identity revealed callback', () {
      handler.onIdentityRevealed((contactName) {
        // Callback set
      });

      expect(handler, isNotNull);
    });

    test('QR introduction match succeeds with identical hashes', () async {
      const hash = 'abc123def456';
      final matches = await handler.checkQRIntroductionMatch(
        receivedHash: hash,
        expectedHash: hash,
      );
      expect(matches, isTrue);
    });

    test('QR introduction match fails with different hashes', () async {
      final matches = await handler.checkQRIntroductionMatch(
        receivedHash: 'hash1',
        expectedHash: 'hash2',
      );
      expect(matches, isFalse);
    });

    test('handles QR introduction claim', () async {
      expect(
        () => handler.handleQRIntroductionClaim(
          claimJson: '{"key":"value"}',
          fromDeviceId: 'device1',
        ),
        returnsNormally,
      );
    });

    test('gets message encryption method', () async {
      final method = await handler.getMessageEncryptionMethod(
        senderKey: 'sender',
        recipientKey: 'recipient',
      );
      expect(method, isA<String>());
    });

    test('rejects v2 encrypted message without crypto header', () async {
      allowedSevere.add('v2 encrypted message missing crypto header');
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-no-header',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-key',
        },
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test(
      'requires signature for v2 encrypted message when policy enabled',
      () async {
        allowedSevere.add(
          'v2 encrypted message missing signature under strict/upgraded-peer policy',
        );
        final strictHandler = ProtocolMessageHandler(
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
            'senderId': 'sender-key',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );

        final result = await strictHandler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );

        expect(result, isNull);
        expect(securityService.decryptMessageByTypeCalls, equals(0));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test(
      'requires signature for encrypted v2 message once peer floor is upgraded',
      () async {
        allowedSevere.add(
          'v2 encrypted message missing signature under strict/upgraded-peer policy',
        );
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final peerKey = signingKeyPair.publicHex;
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-floor-signature',
            'content': 'ciphertext-floor-signature',
            'encrypted': true,
            'senderId': peerKey,
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: false,
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
          useEphemeralSigning: false,
          timestamp: now,
        );
        final unsignedV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-unsigned-after-upgrade',
            'content': 'ciphertext-unsigned',
            'encrypted': true,
            'senderId': peerKey,
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: now.add(const Duration(seconds: 1)),
        );

        final firstResult = await handler.processProtocolMessage(
          message: signedV2,
          fromDeviceId: 'device-1',
          fromNodeId: peerKey,
        );
        final secondResult = await handler.processProtocolMessage(
          message: unsignedV2,
          fromDeviceId: 'device-1',
          fromNodeId: peerKey,
        );

        expect(firstResult, equals('typed:ciphertext-floor-signature'));
        expect(secondResult, isNull);
        expect(securityService.decryptMessageByTypeCalls, equals(1));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test('rejects unsigned v2 direct plaintext text message', () async {
      allowedSevere.add('v2 direct plaintext text message rejected');
      handler.setCurrentNodeId('local-node');
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-direct-plaintext',
          'content': 'spoof-attempt',
          'encrypted': false,
          'senderId': 'sender-key',
          'intendedRecipient': 'local-node',
          'recipientId': 'local-node',
        },
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test('rejects unsigned v2 broadcast plaintext text message', () async {
      allowedSevere.add('v2 plaintext broadcast missing signature');
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-broadcast-plaintext',
          'content': 'spoof-broadcast',
          'encrypted': false,
          'senderId': 'sender-key',
        },
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test(
      'legacy v1 plaintext callback keeps transport sender over declared sender',
      () async {
        String? callbackSender;
        handler.onTextMessageReceived((content, messageId, senderNodeId) async {
          callbackSender = senderNodeId;
        });

        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 1,
          payload: {
            'messageId': 'msg-v1-plaintext-transport',
            'content': 'hello-v1',
            'encrypted': false,
            'senderId': 'spoofed-sender',
            'originalSender': 'spoofed-sender',
          },
          timestamp: DateTime.now(),
        );

        final result = await handler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'transport-sender',
        );

        expect(result, equals('hello-v1'));
        expect(callbackSender, equals('transport-sender'));
      },
    );

    test(
      'legacy v1 encrypted messages decrypt with transport sender first',
      () async {
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 1,
          payload: {
            'messageId': 'msg-v1-encrypted-transport',
            'content': 'ciphertext-v1',
            'encrypted': true,
            'senderId': 'spoofed-sender',
            'originalSender': 'spoofed-sender',
          },
          timestamp: DateTime.now(),
        );

        final result = await handler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'transport-sender',
        );

        expect(result, equals('legacy:ciphertext-v1'));
        expect(securityService.lastDecryptPublicKey, equals('transport-sender'));
      },
    );

    test(
      'routes v2 decrypt by declared mode without fallback guessing',
      () async {
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-mode',
            'content': 'ciphertext',
            'encrypted': true,
            'senderId': 'sender-key',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );

        final result = await handler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );

        expect(result, equals('typed:ciphertext'));
        expect(securityService.decryptMessageByTypeCalls, equals(1));
        expect(securityService.decryptMessageCalls, equals(0));
        expect(securityService.lastDecryptType, equals(EncryptionType.noise));
        expect(securityService.lastDecryptPublicKey, equals('sender-key'));
      },
    );

    test('routes v2 sealed decrypt via dedicated sealed path', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
      final signingKeyPair = _generateEphemeralSigningKeyPair();
      final baseMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'senderId': 'sender-key',
          'recipientId': 'recipient-key',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'kid': 'kid-1',
            'epk': 'ZWJjZGVmZw==',
            'nonce': 'bm9uY2UxMjM=',
          },
        },
        useEphemeralSigning: true,
        ephemeralSigningKey: signingKeyPair.publicHex,
        timestamp: now,
      );
      final signaturePayload = SigningManager.signaturePayloadForMessage(
        baseMessage,
        fallbackContent: 'sealed:ciphertext-base64',
      );
      final signature = _signWithEphemeralPrivateKey(
        content: signaturePayload,
        privateKeyHex: signingKeyPair.privateHex,
      );
      final message = ProtocolMessage(
        type: baseMessage.type,
        version: baseMessage.version,
        payload: baseMessage.payload,
        signature: signature,
        useEphemeralSigning: true,
        ephemeralSigningKey: signingKeyPair.publicHex,
        timestamp: now,
      );

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, equals('sealed:ciphertext-base64'));
      expect(securityService.decryptSealedCalls, equals(1));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.lastSealedSenderId, equals('sender-key'));
      expect(securityService.lastSealedRecipientId, equals('recipient-key'));
    });

    test('rejects v2 sealed message missing sender binding', () async {
      allowedSevere.add('v2 sealed message missing sender binding');
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
        signature: 'placeholder-sig',
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptSealedCalls, equals(0));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test(
      'rejects v2 sealed message missing explicit recipient binding',
      () async {
        allowedSevere.add('v2 sealed message missing recipient binding');
        handler.setCurrentNodeId('recipient-key');
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-sealed-missing-recipient',
            'content': 'ciphertext-base64',
            'encrypted': true,
            'senderId': 'sender-key',
            'intendedRecipient': 'recipient-key',
            'crypto': {
              'mode': 'sealed_v1',
              'modeVersion': 1,
              'kid': 'kid-1',
              'epk': 'ZWJjZGVmZw==',
              'nonce': 'bm9uY2UxMjM=',
            },
          },
          signature: 'placeholder-sig',
          timestamp: DateTime.now(),
        );

        final result = await handler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );

        expect(result, isNull);
        expect(securityService.decryptSealedCalls, equals(0));
        expect(securityService.decryptMessageByTypeCalls, equals(0));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );


    test('rejects unsigned sealed v2 message', () async {
      allowedSevere.add('v2 sealed message missing signature');
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed-unsigned',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'senderId': 'sender-key',
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

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptSealedCalls, equals(0));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test('rejects sealed v2 message with empty-string signature', () async {
      allowedSevere.add('v2 sealed message missing signature');
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-sealed-empty-sig',
          'content': 'ciphertext-base64',
          'encrypted': true,
          'senderId': 'sender-key',
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

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptSealedCalls, equals(0));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test(
      'rejects sealed v2 message with whitespace-only signature',
      () async {
        allowedSevere.add('v2 sealed message missing signature');
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-sealed-whitespace-sig',
            'content': 'ciphertext-base64',
            'encrypted': true,
            'senderId': 'sender-key',
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

        final result = await handler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );

        expect(result, isNull);
        expect(securityService.decryptSealedCalls, equals(0));
        expect(securityService.decryptMessageByTypeCalls, equals(0));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test(
      'rejects removed legacy_global_v1 transport header',
      () async {
        allowedSevere.add('v2 encrypted message has unsupported crypto mode');
        final message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-legacy-global-blocked',
            'content': 'PLAINTEXT:spoofed-message',
            'encrypted': true,
            'senderId': 'sender-key',
            'crypto': {'mode': 'legacy_global_v1', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
        );

        final result = await handler.processProtocolMessage(
          message: message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );

        expect(result, isNull);
        expect(securityService.decryptMessageByTypeCalls, equals(0));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test('rejects removed legacy v2 transport mode header', () async {
      allowedSevere.add('v2 encrypted message has unsupported crypto mode');
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-legacy-block',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-key',
          'crypto': {'mode': 'legacy_ecdh_v1', 'modeVersion': 1},
        },
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: message,
        fromDeviceId: 'device-1',
        fromNodeId: 'relay-node',
      );

      expect(result, isNull);
      expect(securityService.decryptMessageByTypeCalls, equals(0));
      expect(securityService.decryptMessageCalls, equals(0));
    });

    test(
      'rejects removed legacy transport header after peer upgrade',
      () async {
        allowedSevere.add('v2 encrypted message has unsupported crypto mode');
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final peerKey = signingKeyPair.publicHex;
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-floor-legacy-mode',
            'content': 'ciphertext-floor',
            'encrypted': true,
            'senderId': peerKey,
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: false,
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
          useEphemeralSigning: false,
          timestamp: now,
        );
        final legacyModePayload = <String, dynamic>{
          'messageId': 'msg-v2-legacy-after-upgrade',
          'content': 'ciphertext-legacy',
          'encrypted': true,
          'senderId': peerKey,
          'crypto': {'mode': 'legacy_ecdh_v1', 'modeVersion': 1},
        };
        final legacyModeBase = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: legacyModePayload,
          useEphemeralSigning: false,
          timestamp: now.add(const Duration(seconds: 1)),
        );
        final legacyModeSignature = _signWithEphemeralPrivateKey(
          content: SigningManager.signaturePayloadForMessage(
            legacyModeBase,
            fallbackContent: 'typed:ciphertext-legacy',
          ),
          privateKeyHex: signingKeyPair.privateHex,
        );
        final legacyModeV2 = ProtocolMessage(
          type: legacyModeBase.type,
          version: legacyModeBase.version,
          payload: legacyModeBase.payload,
          signature: legacyModeSignature,
          useEphemeralSigning: false,
          timestamp: legacyModeBase.timestamp,
        );

        final firstResult = await handler.processProtocolMessage(
          message: signedV2,
          fromDeviceId: 'device-1',
          fromNodeId: peerKey,
        );
        final secondResult = await handler.processProtocolMessage(
          message: legacyModeV2,
          fromDeviceId: 'device-1',
          fromNodeId: peerKey,
        );

        expect(firstResult, equals('typed:ciphertext-floor'));
        expect(secondResult, isNull);
        expect(securityService.decryptMessageByTypeCalls, equals(1));
        expect(securityService.decryptMessageCalls, equals(0));
      },
    );

    test(
      'rejects v1 message after observing authenticated v2 from same peer',
      () async {
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final peerKey = signingKeyPair.publicHex;
        final baselineV2 = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-floor',
            'content': 'ciphertext-floor',
            'encrypted': true,
            'senderId': peerKey,
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          useEphemeralSigning: false,
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
          useEphemeralSigning: false,
          timestamp: now,
        );

        final v1Message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 1,
          payload: {
            'messageId': 'msg-v1-downgrade',
            'content': 'hello-v1',
            'encrypted': false,
            'senderId': peerKey,
          },
          timestamp: DateTime.now(),
        );

        final firstResult = await handler.processProtocolMessage(
          message: signedV2,
          fromDeviceId: 'device-1',
          fromNodeId: peerKey,
        );
        final secondResult = await handler.processProtocolMessage(
          message: v1Message,
          fromDeviceId: 'device-1',
          fromNodeId: peerKey,
        );

        expect(firstResult, equals('typed:ciphertext-floor'));
        expect(secondResult, isNull);
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

        final firstResult = await handler.processProtocolMessage(
          message: unsignedV2,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );
        final secondResult = await handler.processProtocolMessage(
          message: v1Message,
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );

        expect(firstResult, equals('typed:ciphertext-unsigned'));
        expect(secondResult, equals('hello-v1'));
        expect(securityService.decryptMessageCalls, equals(0));
        expect(securityService.decryptMessageByTypeCalls, equals(1));
      },
    );

    test(
      'rejects v2 envelope tampering across bound fields when signature is present',
      () async {
        allowedSevere.add('Signature verification failed');
        handler.setCurrentNodeId('local-node');

        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final signingKeyPair = _generateEphemeralSigningKeyPair();
        final basePayload = <String, dynamic>{
          'messageId': 'msg-v2-signed',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-key',
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

        final validResult = await handler.processProtocolMessage(
          message: ProtocolMessage(
            type: ProtocolMessageType.textMessage,
            version: 2,
            payload: _clonePayload(basePayload),
            signature: baselineSignature,
            useEphemeralSigning: true,
            ephemeralSigningKey: signingKeyPair.publicHex,
            timestamp: now,
          ),
          fromDeviceId: 'device-1',
          fromNodeId: 'relay-node',
        );
        expect(validResult, equals('sealed:ciphertext'));

        final tamperCases = <_EnvelopeTamperCase>[
          _EnvelopeTamperCase(
            label: 'senderId',
            apply: (payload) => payload['senderId'] = 'sender-key-tampered',
          ),
          _EnvelopeTamperCase(
            label: 'recipientId',
            apply: (payload) => payload['recipientId'] = 'recipient-tampered',
          ),
          _EnvelopeTamperCase(
            label: 'messageId',
            apply: (payload) => payload['messageId'] = 'msg-v2-signed-tampered',
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
          final tamperedMessage = ProtocolMessage(
            type: ProtocolMessageType.textMessage,
            version: 2,
            payload: tamperedPayload,
            signature: baselineSignature,
            useEphemeralSigning: true,
            ephemeralSigningKey: signingKeyPair.publicHex,
            timestamp: now,
          );

          final tamperedResult = await handler.processProtocolMessage(
            message: tamperedMessage,
            fromDeviceId: 'device-1',
            fromNodeId: 'relay-node',
          );

          expect(
            tamperedResult,
            equals('[❌ UNTRUSTED MESSAGE - Invalid signature]'),
            reason: 'Tamper case failed: ${tamperCase.label}',
          );
        }
      },
    );

    // -------------------------------------------------------------------------
    // Production defaults verification
    // -------------------------------------------------------------------------
    group('Production defaults', () {
      test(
        'rejects unsigned v2 encrypted message with production defaults',
        () async {
          allowedSevere.add(
            'v2 encrypted message missing signature under strict/upgraded-peer policy',
          );
          // Construct with NO overrides — exercises the hardened production defaults
          // (requireV2Signature=true).
          final strictHandler = ProtocolMessageHandler(
            securityService: securityService,
          );
          final message = ProtocolMessage(
            type: ProtocolMessageType.textMessage,
            version: 2,
            payload: {
              'messageId': 'msg-v2-prod-defaults',
              'content': 'ciphertext',
              'encrypted': true,
              'senderId': 'sender-key',
              'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
            },
            timestamp: DateTime.now(),
          );

          final result = await strictHandler.processProtocolMessage(
            message: message,
            fromDeviceId: 'device-1',
            fromNodeId: 'relay-node',
          );

          expect(result, isNull);
          expect(securityService.decryptMessageByTypeCalls, equals(0));
        },
      );

      test(
        'rejects removed legacy transport with production defaults',
        () async {
          allowedSevere.add('v2 encrypted message has unsupported crypto mode');
          final strictHandler = ProtocolMessageHandler(
            securityService: securityService,
          );
          final message = ProtocolMessage(
            type: ProtocolMessageType.textMessage,
            version: 2,
            payload: {
              'messageId': 'msg-v2-prod-legacy',
              'content': 'ciphertext',
              'encrypted': true,
              'senderId': 'sender-key',
              'crypto': {'mode': 'legacy_ecdh_v1', 'modeVersion': 1},
            },
            signature: 'sig',
            timestamp: DateTime.now(),
          );

          final result = await strictHandler.processProtocolMessage(
            message: message,
            fromDeviceId: 'device-1',
            fromNodeId: 'relay-node',
          );

          expect(result, isNull);
          expect(securityService.decryptMessageByTypeCalls, equals(0));
        },
      );
    });
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
