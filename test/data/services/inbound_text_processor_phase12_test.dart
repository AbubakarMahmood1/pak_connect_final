// Phase 12.13 — InboundTextProcessor supplementary coverage
// Targets: self-originated drop, routing discard, v2 plaintext rejection,
//          fallback decryption paths, resync paths, missing sender identity,
//          v2 missing crypto header, unsupported crypto mode

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/inbound_text_processor.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';

void main() {
  late _FakeSecurityService securityService;
  late _FakeContactRepository contactRepo;
  late InboundTextProcessor processor;
  late List<LogRecord> logs;

  setUp(() {
    InboundTextProcessor.clearPeerProtocolVersionFloorForTest();
    logs = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logs.add);

    securityService = _FakeSecurityService();
    contactRepo = _FakeContactRepository();
    processor = InboundTextProcessor(
      contactRepository: contactRepo,
      isMessageForMe: (_) async => true,
      currentNodeIdProvider: () => 'local-node',
      securityService: securityService,
      requireV2Signature: false,
    );
  });

  // ─── Self-originated message drop ──────────────────────────────────

  group('Self-originated message drop', () {
    test('drops message when senderPublicKey equals currentNodeId', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-self',
          'content': 'hello self',
          'encrypted': false,
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'local-node', // same as currentNodeIdProvider
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── Routing discard ───────────────────────────────────────────────

  group('Routing discard', () {
    test('discards message not addressed to us', () async {
      final notForMe = InboundTextProcessor(
        contactRepository: contactRepo,
        isMessageForMe: (_) async => false, // <-- not for me
        currentNodeIdProvider: () => 'local-node',
        securityService: securityService,
        requireV2Signature: false,
      );

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-not-mine',
          'content': 'hello',
          'encrypted': false,
          'intendedRecipient': 'someone-else',
        },
        timestamp: DateTime.now(),
      );

      final result = await notForMe.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── v2 plaintext rejection ────────────────────────────────────────

  group('v2 plaintext rejection', () {
    test('rejects v2 direct plaintext (non-broadcast) without signature', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-plain-v2',
          'content': 'plain text',
          'encrypted': false,
          'senderId': 'sender',
          'recipientId': 'specific-peer',
          'intendedRecipient': 'local-node',
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── Encrypted message missing sender key ─────────────────────────

  group('Missing sender key', () {
    test('returns error when encrypted but no sender key available', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-no-key',
          'content': 'ciphertext',
          'encrypted': true,
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: null, // no sender key
      );

      expect(result.content, contains('no sender identity'));
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── v2 encrypted missing crypto header ───────────────────────────

  group('v2 encrypted missing crypto header', () {
    test('rejects v2 encrypted message without crypto header', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-no-header',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-1',
          // no 'crypto' field
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── Decryption failure paths ─────────────────────────────────────

  group('Decryption failure paths', () {
    test('v1 decryption failure with "No session found" returns null content', () async {
      securityService.decryptMessageError = Exception('No session found for peer');

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-no-session',
          'content': 'ciphertext',
          'encrypted': true,
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
    });

    test('v1 decryption failure with security resync returns resync message', () async {
      securityService.decryptMessageError =
          Exception('security resync requested');

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-resync',
          'content': 'ciphertext',
          'encrypted': true,
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, contains('Security resync'));
      expect(result.shouldAck, isFalse);
    });

    test('v2 decryption failure returns v2-specific error', () async {
      securityService.decryptMessageByTypeError =
          Exception('decrypt failed');

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-v2-fail',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-1',
          'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, contains('Could not decrypt v2'));
      expect(result.shouldAck, isFalse);
    });

    test('v1 fallback to originalSender on primary decrypt failure', () async {
      securityService.decryptMessageError =
          Exception('generic decrypt error');
      securityService.fallbackDecryptResult = 'fallback-content';

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-fallback',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-key-1',
          'originalSender': 'original-sender-key',
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, equals('fallback-content'));
      expect(result.shouldAck, isTrue);
    });

    test('v1 fallback decrypt with resync returns resync message', () async {
      securityService.decryptMessageError =
          Exception('generic error');
      securityService.fallbackDecryptError =
          Exception('security resync requested');

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-fb-resync',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-key-1',
          'originalSender': 'original-sender-key',
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, contains('Security resync'));
      expect(result.shouldAck, isFalse);
    });

    test('v1 fallback decrypt failure returns error message', () async {
      securityService.decryptMessageError =
          Exception('generic error');
      securityService.fallbackDecryptError =
          Exception('also failed');

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-fb-fail',
          'content': 'ciphertext',
          'encrypted': true,
          'originalSender': 'original-sender-key',
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'relay-node',
      );

      expect(result.content, contains('Could not decrypt'));
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── v2 legacy global mode blocked ────────────────────────────────

  group('v2 legacy global mode', () {
    test('rejects v2 encrypted with legacy_global_v1 mode', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-legacy-global',
          'content': 'ciphertext',
          'encrypted': true,
          'senderId': 'sender-1',
          'crypto': {'mode': 'legacy_global_v1', 'modeVersion': 1},
        },
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, isNull);
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── Signature verification — missing sender identity ─────────────

  group('Signature verification edge cases', () {
    test('v2 ephemeral signature missing signing key rejects', () async {
      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'msg-no-ephem-key',
          'content': 'plaintext',
          'encrypted': false,
          'senderId': null,
          'recipientId': null,
        },
        signature: 'some-sig',
        useEphemeralSigning: true,
        ephemeralSigningKey: null,
        timestamp: DateTime.now(),
      );

      final result = await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender-1',
      );

      expect(result.content, contains('Missing ephemeral signing key'));
      expect(result.shouldAck, isFalse);
    });
  });

  // ─── onMessageIdFound callback ─────────────────────────────────────

  group('onMessageIdFound callback', () {
    test('invokes callback with messageId', () async {
      String? capturedId;

      final message = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        payload: {
          'messageId': 'msg-callback',
          'content': 'hello',
          'encrypted': false,
        },
        timestamp: DateTime.now(),
      );

      await processor.process(
        protocolMessage: message,
        senderPublicKey: 'sender',
        onMessageIdFound: (id) {
          capturedId = id;
          return null;
        },
      );

      expect(capturedId, equals('msg-callback'));
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
// Fakes
// ═══════════════════════════════════════════════════════════════════════

class _FakeContactRepository implements IContactRepository {
  @override
  Future<Contact?> getContactByAnyId(String identifier) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSecurityService implements ISecurityService {
  Exception? decryptMessageError;
  Exception? decryptMessageByTypeError;
  Exception? fallbackDecryptError;
  String? fallbackDecryptResult;
  int _decryptCallCount = 0;

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
  Future<String> decryptMessage(
    String message,
    String senderKey,
    IContactRepository repo,
  ) async {
    _decryptCallCount++;
    // First call uses primary error; subsequent calls check fallback
    if (_decryptCallCount == 1 && decryptMessageError != null) {
      throw decryptMessageError!;
    }
    if (_decryptCallCount > 1 && fallbackDecryptError != null) {
      throw fallbackDecryptError!;
    }
    if (_decryptCallCount > 1 && fallbackDecryptResult != null) {
      return fallbackDecryptResult!;
    }
    return 'decrypted:$message';
  }

  @override
  Future<String> decryptMessageByType(
    String message,
    String senderKey,
    IContactRepository repo,
    EncryptionType type,
  ) async {
    if (decryptMessageByTypeError != null) throw decryptMessageByTypeError!;
    return 'typed:$message';
  }

  @override
  Future<String> decryptSealedMessage({
    required String encryptedMessage,
    required CryptoHeader cryptoHeader,
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    return 'sealed:$encryptedMessage';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
