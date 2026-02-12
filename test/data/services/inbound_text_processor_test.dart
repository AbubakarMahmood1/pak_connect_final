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

    test('rejects v1 message after observing v2 from same peer', () async {
      final v2Message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-floor',
          'content': 'hello-v2',
          'encrypted': false,
          'senderId': 'peer-upgraded',
          'crypto': {'mode': 'none', 'modeVersion': 1},
        },
        timestamp: DateTime.now(),
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
        protocolMessage: v2Message,
        senderPublicKey: 'relay-node',
      );
      final secondResult = await processor.process(
        protocolMessage: v1Message,
        senderPublicKey: 'relay-node',
      );

      expect(firstResult.content, equals('hello-v2'));
      expect(firstResult.shouldAck, isTrue);
      expect(secondResult.content, isNull);
      expect(secondResult.shouldAck, isFalse);
      expect(securityService.decryptMessageCalls, equals(0));
      expect(securityService.decryptMessageByTypeCalls, equals(0));
    });

    test(
      'shares downgrade floor with ProtocolMessageHandler across inbound paths',
      () async {
        final protocolHandler = ProtocolMessageHandler(
          securityService: securityService,
        );
        final v2Message = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-cross-handler',
            'content': 'hello-v2',
            'encrypted': false,
            'senderId': 'peer-shared',
            'crypto': {'mode': 'none', 'modeVersion': 1},
          },
          timestamp: DateTime.now(),
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

        expect(protocolResult, equals('hello-v2'));
        expect(inboundResult.content, isNull);
        expect(inboundResult.shouldAck, isFalse);
      },
    );

    test('rejects v2 envelope tampering when signature is present', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
      final signingKeyPair = _generateEphemeralSigningKeyPair();

      final baselineMessage = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-signed-inbound',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'crypto-sender',
          'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
        },
        useEphemeralSigning: true,
        ephemeralSigningKey: signingKeyPair.publicHex,
        timestamp: now,
      );
      final baselinePayload = SigningManager.signaturePayloadForMessage(
        baselineMessage,
        fallbackContent: 'typed:ciphertext',
      );
      final baselineSignature = _signWithEphemeralPrivateKey(
        content: baselinePayload,
        privateKeyHex: signingKeyPair.privateHex,
      );

      final validResult = await processor.process(
        protocolMessage: ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-signed-inbound',
            'content': 'ciphertext',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
          },
          signature: baselineSignature,
          useEphemeralSigning: true,
          ephemeralSigningKey: signingKeyPair.publicHex,
          timestamp: now,
        ),
        senderPublicKey: 'relay-node',
      );
      expect(validResult.content, equals('typed:ciphertext'));
      expect(validResult.shouldAck, isTrue);

      final tamperedResult = await processor.process(
        protocolMessage: ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'msg-v2-signed-inbound',
            'content': 'ciphertext',
            'encrypted': true,
            'senderId': 'crypto-sender',
            'crypto': {'mode': 'legacy_ecdh_v1', 'modeVersion': 1},
          },
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
      );
      expect(tamperedResult.shouldAck, isFalse);
    });
  });
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
