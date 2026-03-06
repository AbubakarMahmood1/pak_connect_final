import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/protocol_message_type.dart';
import 'package:pak_connect/domain/models/security_level.dart';

/// Phase 12.4: Supplementary tests for ProtocolMessageHandler
/// Covers message type dispatch: contactRequest, contactAccept, contactReject,
///   cryptoVerification, cryptoVerificationResponse, queueSync, friendReveal, ping
void main() {
  late List<LogRecord> logRecords;
  late ProtocolMessageHandler handler;
  late _FakeSecurityService securityService;

  setUp(() {
    logRecords = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    ProtocolMessageHandler.clearPeerProtocolVersionFloorForTest();
    securityService = _FakeSecurityService();
    handler = ProtocolMessageHandler(securityService: securityService);
  });

  group('contactRequest dispatch', () {
    test('invokes callback with publicKey and displayName', () async {
      String? capturedKey;
      String? capturedName;
      handler.onContactRequestReceived((key, name) {
        capturedKey = key;
        capturedName = name;
      });

      final msg = ProtocolMessage.contactRequest(
        publicKey: 'pk_alice',
        displayName: 'Alice',
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-1',
        fromNodeId: 'node-1',
      );

      expect(capturedKey, 'pk_alice');
      expect(capturedName, 'Alice');
    });

    test('ignores request with missing publicKey', () async {
      String? capturedKey;
      handler.onContactRequestReceived((key, name) {
        capturedKey = key;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.contactRequest,
        payload: {'displayName': 'Bob'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-1',
        fromNodeId: 'node-1',
      );

      expect(capturedKey, isNull);
    });
  });

  group('contactAccept dispatch', () {
    test('invokes callback with publicKey and displayName', () async {
      String? capturedKey;
      String? capturedName;
      handler.onContactAcceptReceived((key, name) {
        capturedKey = key;
        capturedName = name;
      });

      final msg = ProtocolMessage.contactAccept(
        publicKey: 'pk_bob',
        displayName: 'Bob',
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-2',
        fromNodeId: 'node-2',
      );

      expect(capturedKey, 'pk_bob');
      expect(capturedName, 'Bob');
    });
  });

  group('contactReject dispatch', () {
    test('invokes callback', () async {
      bool called = false;
      handler.onContactRejectReceived(() => called = true);

      final msg = ProtocolMessage.contactReject();

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-3',
        fromNodeId: 'node-3',
      );

      expect(called, true);
    });
  });

  group('cryptoVerification dispatch', () {
    test('invokes callback with verificationId and contactKey', () async {
      String? capturedVerifId;
      String? capturedContactKey;
      handler.onCryptoVerificationReceived((verifId, contactKey) {
        capturedVerifId = verifId;
        capturedContactKey = contactKey;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerification,
        payload: {
          'verificationId': 'verif-123',
          'contactKey': 'contact-key-abc',
        },
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-4',
        fromNodeId: 'node-4',
      );

      expect(capturedVerifId, 'verif-123');
      expect(capturedContactKey, 'contact-key-abc');
    });

    test('skips callback when verificationId missing', () async {
      String? capturedVerifId;
      handler.onCryptoVerificationReceived((verifId, _) {
        capturedVerifId = verifId;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerification,
        payload: {'contactKey': 'contact-key-abc'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-4',
        fromNodeId: 'node-4',
      );

      expect(capturedVerifId, isNull);
    });
  });

  group('cryptoVerificationResponse dispatch', () {
    test('invokes callback with isVerified=true', () async {
      String? capturedVerifId;
      bool? capturedIsVerified;
      handler.onCryptoVerificationResponseReceived((
        verifId,
        contactKey,
        isVerified,
        payload,
      ) {
        capturedVerifId = verifId;
        capturedIsVerified = isVerified;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerificationResponse,
        payload: {
          'verificationId': 'verif-456',
          'contactKey': 'contact-key-xyz',
          'isVerified': true,
        },
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-5',
        fromNodeId: 'node-5',
      );

      expect(capturedVerifId, 'verif-456');
      expect(capturedIsVerified, true);
    });

    test('defaults isVerified to false when missing', () async {
      bool? capturedIsVerified;
      handler.onCryptoVerificationResponseReceived((_, __, isVerified, ___) {
        capturedIsVerified = isVerified;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerificationResponse,
        payload: {
          'verificationId': 'verif-789',
          'contactKey': 'contact-key-def',
          // Note: no 'isVerified' key
        },
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-5',
        fromNodeId: 'node-5',
      );

      expect(capturedIsVerified, false);
    });
  });

  group('friendReveal dispatch', () {
    test('invokes callback with contactName', () async {
      String? capturedName;
      handler.onIdentityRevealed((name) => capturedName = name);

      final msg = ProtocolMessage(
        type: ProtocolMessageType.friendReveal,
        payload: {'contactName': 'RealAlice'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-6',
        fromNodeId: 'node-6',
      );

      expect(capturedName, 'RealAlice');
    });

    test('falls back to myPersistentKey when contactName missing', () async {
      String? capturedName;
      handler.onIdentityRevealed((name) => capturedName = name);

      final msg = ProtocolMessage(
        type: ProtocolMessageType.friendReveal,
        payload: {'myPersistentKey': 'pk_persistent_xyz'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-6',
        fromNodeId: 'node-6',
      );

      expect(capturedName, 'pk_persistent_xyz');
    });
  });

  group('ping dispatch', () {
    test('ping returns null and is handled gracefully', () async {
      final result = await handler.processProtocolMessage(
        message: ProtocolMessage.ping(),
        fromDeviceId: 'device-7',
        fromNodeId: 'node-7',
      );

      expect(result, isNull);
    });
  });

  group('ack dispatch', () {
    test('ack returns null', () async {
      final msg = ProtocolMessage.ack(originalMessageId: 'msg-original');
      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-8',
        fromNodeId: 'node-8',
      );

      expect(result, isNull);
    });
  });

  group('queueSync dispatch', () {
    test('processes valid queueSync and triggers ACK', () async {
      ProtocolMessage? capturedAck;
      handler.onSendAckMessage((msg) => capturedAck = msg);

      final msg = ProtocolMessage(
        type: ProtocolMessageType.queueSync,
        payload: {
          'queueHash': 'hash-abc-123',
          'messageIds': ['msg-1', 'msg-2'],
          'syncTimestamp': DateTime.now().millisecondsSinceEpoch,
          'nodeId': 'sync-node-1',
          'syncType': 0, // QueueSyncType.request
        },
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-sync',
        fromNodeId: 'node-sync',
        transportMessageId: 'transport-msg-id',
      );

      expect(result, isNull);
      expect(capturedAck, isNotNull);
      expect(capturedAck!.type, ProtocolMessageType.ack);
    });

    test('uses queueHash when transportMessageId is null', () async {
      ProtocolMessage? capturedAck;
      handler.onSendAckMessage((msg) => capturedAck = msg);

      final msg = ProtocolMessage(
        type: ProtocolMessageType.queueSync,
        payload: {
          'queueHash': 'hash-fallback',
          'messageIds': <String>[],
          'syncTimestamp': DateTime.now().millisecondsSinceEpoch,
          'nodeId': 'sync-node-2',
          'syncType': 1, // QueueSyncType.response
        },
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-sync',
        fromNodeId: 'node-sync',
      );

      expect(capturedAck, isNotNull);
    });

    test('handles invalid queueSync payload gracefully', () async {
      final msg = ProtocolMessage(
        type: ProtocolMessageType.queueSync,
        payload: {'invalid': 'data'},
        timestamp: DateTime.now(),
      );

      // Should not throw — caught internally
      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-sync',
        fromNodeId: 'node-sync',
      );

      expect(result, isNull);
    });
  });

  group('relayAck dispatch', () {
    test('returns null', () async {
      final msg = ProtocolMessage(
        type: ProtocolMessageType.relayAck,
        payload: {},
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device-9',
        fromNodeId: 'node-9',
      );

      expect(result, isNull);
    });
  });

  group('handleDirectProtocolMessage', () {
    test('dispatches contact request through direct handler', () async {
      String? capturedKey;
      handler.onContactRequestReceived((key, name) {
        capturedKey = key;
      });

      final msg = ProtocolMessage.contactRequest(
        publicKey: 'pk_direct',
        displayName: 'DirectUser',
      );

      final result = await handler.handleDirectProtocolMessage(
        message: msg,
        fromDeviceId: 'device-direct',
      );

      expect(result, isNull);
      expect(capturedKey, 'pk_direct');
    });
  });

  group('processCompleteProtocolMessage', () {
    test('processes serialized ping message', () async {
      final pingMsg = ProtocolMessage.ping();
      final bytes = pingMsg.toBytes(enableCompression: false);
      final content = String.fromCharCodes(bytes);

      final result = await handler.processCompleteProtocolMessage(
        content: content,
        fromDeviceId: 'device-complete',
        fromNodeId: 'node-complete',
        messageData: null,
      );

      expect(result, isNull);
    });
  });

  group('encryption method', () {
    test('getEncryptionMethod returns current method', () {
      expect(handler.getEncryptionMethod(), 'none');
    });

    test('setEncryptionMethod updates method', () {
      handler.setEncryptionMethod('noise');
      expect(handler.getEncryptionMethod(), 'noise');
    });
  });
}

/// Minimal fake security service for dispatch tests
class _FakeSecurityService extends Fake implements ISecurityService {
  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async {
    return 'decrypted:$encryptedMessage';
  }

  @override
  Future<String> decryptMessageByType(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async {
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
    return 'sealed:$encryptedMessage';
  }

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async =>
      SecurityLevel.low;
}
