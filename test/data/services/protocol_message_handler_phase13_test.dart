// Phase 13: Supplementary tests for ProtocolMessageHandler
// Targets uncovered lines: protocol message type dispatch branches
// (contactRequest, contactAccept, contactReject, cryptoVerification,
// cryptoVerificationResponse, queueSync, friendReveal, ping, relayAck,
// default/unknown), processCompleteProtocolMessage, handleDirectProtocolMessage,
// _sendAck, callback invocation, isMessageForMe identity resolution,
// error propagation paths.
//
// NOTE: Data-layer test — imports data/ and domain/ only, NOT core/.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';

void main() {
  late _FakeSecurityService securityService;
  late ProtocolMessageHandler handler;
  final logRecords = <LogRecord>[];
  StreamSubscription<LogRecord>? logSub;
  final allowedSevere = <String>[];

  setUp(() {
    logRecords.clear();
    allowedSevere.clear();
    Logger.root.level = Level.ALL;
    logSub = Logger.root.onRecord.listen(logRecords.add);
    ProtocolMessageHandler.clearPeerProtocolVersionFloorForTest();
    ProtocolMessageHandler.clearIdentityManagerResolver();
    securityService = _FakeSecurityService();
    handler = ProtocolMessageHandler(securityService: securityService, allowLegacyV2Decrypt: true, requireV2Signature: false);
  });

  tearDown(() {
    logSub?.cancel();
    logSub = null;
    ProtocolMessageHandler.clearIdentityManagerResolver();
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) =>
              !allowedSevere.any((pattern) => log.message.contains(pattern)),
        )
        .toList();
    expect(severeErrors, isEmpty, reason: 'Unexpected SEVERE errors: $severeErrors');
  });

  // ── Contact request handling ────────────────────────────────────────

  group('contactRequest dispatch', () {
    test('fires callback with publicKey and displayName', () async {
      String? receivedKey;
      String? receivedName;
      handler.onContactRequestReceived((key, name) {
        receivedKey = key;
        receivedName = name;
      });

      final msg = ProtocolMessage.contactRequest(
        publicKey: 'pk_alice',
        displayName: 'Alice',
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(result, isNull);
      expect(receivedKey, 'pk_alice');
      expect(receivedName, 'Alice');
    });

    test('does not fire callback when no callback registered', () async {
      final msg = ProtocolMessage.contactRequest(
        publicKey: 'pk_bob',
        displayName: 'Bob',
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });
  });

  // ── Contact accept handling ────────────────────────────────────────

  group('contactAccept dispatch', () {
    test('fires callback with publicKey and displayName', () async {
      String? receivedKey;
      String? receivedName;
      handler.onContactAcceptReceived((key, name) {
        receivedKey = key;
        receivedName = name;
      });

      final msg = ProtocolMessage.contactAccept(
        publicKey: 'pk_carol',
        displayName: 'Carol',
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(result, isNull);
      expect(receivedKey, 'pk_carol');
      expect(receivedName, 'Carol');
    });

    test('null publicKey or displayName does not fire callback', () async {
      var callbackFired = false;
      handler.onContactAcceptReceived((_, _) {
        callbackFired = true;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.contactAccept,
        payload: {},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(callbackFired, isFalse);
    });
  });

  // ── Contact reject handling ────────────────────────────────────────

  group('contactReject dispatch', () {
    test('fires reject callback', () async {
      var callbackFired = false;
      handler.onContactRejectReceived(() {
        callbackFired = true;
      });

      final msg = ProtocolMessage.contactReject();

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(result, isNull);
      expect(callbackFired, isTrue);
    });

    test('no callback registered — no error', () async {
      final msg = ProtocolMessage.contactReject();
      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });
  });

  // ── Crypto verification request ────────────────────────────────────

  group('cryptoVerification dispatch', () {
    test('fires callback with verificationId and contactKey', () async {
      String? receivedVId;
      String? receivedKey;
      handler.onCryptoVerificationReceived((vId, key) {
        receivedVId = vId;
        receivedKey = key;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerification,
        payload: {
          'verificationId': 'v-123',
          'contactKey': 'ck-abc',
        },
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(result, isNull);
      expect(receivedVId, 'v-123');
      expect(receivedKey, 'ck-abc');
    });

    test('missing verificationId does not fire callback', () async {
      var callbackFired = false;
      handler.onCryptoVerificationReceived((_, _) {
        callbackFired = true;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerification,
        payload: {'contactKey': 'ck-only'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(callbackFired, isFalse);
    });
  });

  // ── Crypto verification response ────────────────────────────────────

  group('cryptoVerificationResponse dispatch', () {
    test('fires callback with verified=true', () async {
      String? receivedVId;
      bool? receivedVerified;
      handler.onCryptoVerificationResponseReceived((vId, key, verified, data) {
        receivedVId = vId;
        receivedVerified = verified;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerificationResponse,
        payload: {
          'verificationId': 'v-456',
          'contactKey': 'ck-def',
          'isVerified': true,
        },
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(receivedVId, 'v-456');
      expect(receivedVerified, isTrue);
    });

    test('fires callback with verified=false (default)', () async {
      bool? receivedVerified;
      handler.onCryptoVerificationResponseReceived((vId, key, verified, data) {
        receivedVerified = verified;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerificationResponse,
        payload: {
          'verificationId': 'v-789',
          'contactKey': 'ck-ghi',
          // no 'isVerified' — defaults to false
        },
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(receivedVerified, isFalse);
    });

    test('missing contactKey does not fire callback', () async {
      var callbackFired = false;
      handler.onCryptoVerificationResponseReceived((_, _, _, _) {
        callbackFired = true;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.cryptoVerificationResponse,
        payload: {'verificationId': 'v-000'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(callbackFired, isFalse);
    });
  });

  // ── Friend reveal handling ─────────────────────────────────────────

  group('friendReveal dispatch', () {
    test('fires identity callback with contactName', () async {
      String? revealedName;
      handler.onIdentityRevealed((name) {
        revealedName = name;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.friendReveal,
        payload: {'contactName': 'Eve'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(revealedName, 'Eve');
    });

    test('falls back to myPersistentKey when contactName absent', () async {
      String? revealedName;
      handler.onIdentityRevealed((name) {
        revealedName = name;
      });

      final msg = ProtocolMessage(
        type: ProtocolMessageType.friendReveal,
        payload: {'myPersistentKey': 'persistent-key-123'},
        timestamp: DateTime.now(),
      );

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(revealedName, 'persistent-key-123');
    });

    test('no callback and no fields — returns null silently', () async {
      final msg = ProtocolMessage(
        type: ProtocolMessageType.friendReveal,
        payload: {},
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });
  });

  // ── Ping / relayAck — no-op types ─────────────────────────────────

  group('ping and relayAck handling', () {
    test('ping returns null', () async {
      final msg = ProtocolMessage(
        type: ProtocolMessageType.ping,
        payload: {},
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });

    test('relayAck returns null', () async {
      final msg = ProtocolMessage(
        type: ProtocolMessageType.relayAck,
        payload: {},
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });
  });

  // ── ACK message type ──────────────────────────────────────────────

  group('ack message type', () {
    test('ack returns null (handled by fragmentation handler)', () async {
      final msg = ProtocolMessage.ack(originalMessageId: 'orig-123');

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });
  });

  // ── processCompleteProtocolMessage ─────────────────────────────────

  group('processCompleteProtocolMessage', () {
    test('parses binary content and dispatches', () async {
      var rejectFired = false;
      handler.onContactRejectReceived(() {
        rejectFired = true;
      });

      final msg = ProtocolMessage.contactReject();
      final bytes = msg.toBytes();
      final content = String.fromCharCodes(bytes);

      final result = await handler.processCompleteProtocolMessage(
        content: content,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
        messageData: null,
      );

      expect(result, isNull);
      expect(rejectFired, isTrue);
    });

    test('returns null on parse error', () async {
      allowedSevere.add('Failed to process complete protocol message');

      final result = await handler.processCompleteProtocolMessage(
        content: 'not valid protocol data',
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
        messageData: null,
      );

      expect(result, isNull);
    });
  });

  // ── handleDirectProtocolMessage ────────────────────────────────────

  group('handleDirectProtocolMessage', () {
    test('dispatches contact request directly', () async {
      String? receivedKey;
      handler.onContactRequestReceived((key, name) {
        receivedKey = key;
      });

      final msg = ProtocolMessage.contactRequest(
        publicKey: 'pk_direct',
        displayName: 'Direct',
      );

      final result = await handler.handleDirectProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
      );

      expect(result, isNull);
      expect(receivedKey, 'pk_direct');
    });

    test('returns null on processing error', () async {
      allowedSevere.add('Failed to handle direct protocol message');
      allowedSevere.add('Failed to handle text message');

      // Create a message that will cause internal error
      final badMsg = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {}, // Missing required fields
        timestamp: DateTime.now(),
      );

      final result = await handler.handleDirectProtocolMessage(
        message: badMsg,
        fromDeviceId: 'device1',
      );

      expect(result, isNull);
    });
  });

  // ── _sendAck behavior ─────────────────────────────────────────────

  group('sendAck behavior', () {
    test('sends ack when callback and messageId present', () async {
      ProtocolMessage? sentAck;
      handler.onSendAckMessage((msg) {
        sentAck = msg;
      });

      final queueMsg = QueueSyncMessage(
        queueHash: 'hash-123',
        messageIds: const ['m1'],
        syncTimestamp: DateTime.now(),
        nodeId: 'node-1',
        syncType: QueueSyncType.request,
      );
      final msg = ProtocolMessage.queueSync(queueMessage: queueMsg);

      await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
        transportMessageId: 'transport-id-1',
      );

      expect(sentAck, isNotNull);
      expect(sentAck!.type, ProtocolMessageType.ack);
    });

    test('no ack sent when callback not registered', () async {
      final queueMsg = QueueSyncMessage(
        queueHash: 'hash-456',
        messageIds: const ['m2'],
        syncTimestamp: DateTime.now(),
        nodeId: 'node-2',
        syncType: QueueSyncType.request,
      );
      final msg = ProtocolMessage.queueSync(queueMessage: queueMsg);

      // No callback registered — should not throw
      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
        transportMessageId: 'tid-2',
      );
      expect(result, isNull);
    });
  });

  // ── Queue sync handling ────────────────────────────────────────────

  group('queueSync dispatch', () {
    test('queue sync without valid payload logs warning', () async {
      allowedSevere.add('Failed to handle queue sync');

      final msg = ProtocolMessage(
        type: ProtocolMessageType.queueSync,
        payload: {'incomplete': true},
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      expect(result, isNull);
    });
  });

  // ── isMessageForMe — identity resolution ──────────────────────────

  group('isMessageForMe — identity resolution', () {
    test('null recipient means broadcast → true', () async {
      final result = await handler.isMessageForMe(null);
      expect(result, isTrue);
    });

    test('empty string recipient means broadcast → true', () async {
      final result = await handler.isMessageForMe('');
      expect(result, isTrue);
    });

    test('matches current node ID', () async {
      handler.setCurrentNodeId('my-node-id-123');
      final result = await handler.isMessageForMe('my-node-id-123');
      expect(result, isTrue);
    });

    test('does not match different node ID', () async {
      handler.setCurrentNodeId('my-node-id-123');
      final result = await handler.isMessageForMe('other-node-id-456');
      expect(result, isFalse);
    });

    test('matches persistent ID from identity manager', () async {
      ProtocolMessageHandler.configureIdentityManagerResolver(
        () => _FakeIdentityManager(persistentId: 'my-persistent-key'),
      );
      handler = ProtocolMessageHandler(securityService: securityService, allowLegacyV2Decrypt: true, requireV2Signature: false);

      final result = await handler.isMessageForMe('my-persistent-key');
      expect(result, isTrue);
    });

    test('identity manager resolver returns null gracefully', () async {
      ProtocolMessageHandler.configureIdentityManagerResolver(() => null);
      handler = ProtocolMessageHandler(securityService: securityService, allowLegacyV2Decrypt: true, requireV2Signature: false);
      handler.setCurrentNodeId('my-node');

      final result = await handler.isMessageForMe('unknown-id');
      expect(result, isFalse);
    });

    test('identity manager resolver throws gracefully', () async {
      ProtocolMessageHandler.configureIdentityManagerResolver(() {
        throw Exception('not initialized');
      });
      handler = ProtocolMessageHandler(securityService: securityService, allowLegacyV2Decrypt: true, requireV2Signature: false);
      handler.setCurrentNodeId('my-node');

      final result = await handler.isMessageForMe('unknown-id');
      expect(result, isFalse);
    });
  });

  // ── resolveMessageIdentities ───────────────────────────────────────

  group('resolveMessageIdentities', () {
    test('returns originalSender from encryption key', () async {
      final result = await handler.resolveMessageIdentities(
        encryptionSenderKey: 'enc-key',
        meshSenderKey: 'mesh-key',
        intendedRecipient: 'recipient-1',
      );
      expect(result['originalSender'], 'enc-key');
      expect(result['intendedRecipient'], 'recipient-1');
      expect(result['isSpyMode'], isTrue);
    });

    test('falls back to meshSenderKey when encryptionKey null', () async {
      final result = await handler.resolveMessageIdentities(
        encryptionSenderKey: null,
        meshSenderKey: 'mesh-key',
        intendedRecipient: null,
      );
      expect(result['originalSender'], 'mesh-key');
      expect(result['isSpyMode'], isTrue);
    });

    test('not spy mode when both keys match', () async {
      final result = await handler.resolveMessageIdentities(
        encryptionSenderKey: 'same-key',
        meshSenderKey: 'same-key',
        intendedRecipient: null,
      );
      expect(result['isSpyMode'], isFalse);
    });
  });

  // ── setEncryptionMethod / getEncryptionMethod ──────────────────────

  group('encryption method get/set', () {
    test('default is none', () {
      expect(handler.getEncryptionMethod(), 'none');
    });

    test('set and get custom method', () {
      handler.setEncryptionMethod('noise');
      expect(handler.getEncryptionMethod(), 'noise');
    });
  });

  // ── getMessageEncryptionMethod ────────────────────────────────────

  group('getMessageEncryptionMethod', () {
    test('returns none as placeholder', () async {
      final result = await handler.getMessageEncryptionMethod(
        senderKey: 'sender',
        recipientKey: 'recipient',
      );
      expect(result, 'none');
    });
  });

  // ── QR introduction ────────────────────────────────────────────────

  group('QR introduction', () {
    test('match returns true for identical hashes', () async {
      final result = await handler.checkQRIntroductionMatch(
        receivedHash: 'abc123',
        expectedHash: 'abc123',
      );
      expect(result, isTrue);
    });

    test('match returns false for different hashes', () async {
      final result = await handler.checkQRIntroductionMatch(
        receivedHash: 'abc123',
        expectedHash: 'xyz789',
      );
      expect(result, isFalse);
    });

    test('handleQRIntroductionClaim does not throw', () async {
      await handler.handleQRIntroductionClaim(
        claimJson: '{"test": true}',
        fromDeviceId: 'device1',
      );
      // No error expected
    });
  });

  // ── setCurrentNodeId ───────────────────────────────────────────────

  group('setCurrentNodeId', () {
    test('short node ID does not throw', () {
      handler.setCurrentNodeId('abc');
      // No error
    });

    test('long node ID truncates in log', () {
      handler.setCurrentNodeId('abcdefghijklmnopqrstuvwxyz');
      expect(
        logRecords.any((r) => r.message.contains('Current node ID set')),
        isTrue,
      );
    });
  });

  // ── Error propagation in processProtocolMessage ────────────────────

  group('error propagation', () {
    test('processProtocolMessage catches and returns null on error', () async {
      allowedSevere.add('Failed to process protocol message');
      allowedSevere.add('Failed to handle text message');

      // A textMessage with null textMessageId will throw
      final msg = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        payload: {},
        timestamp: DateTime.now(),
      );

      final result = await handler.processProtocolMessage(
        message: msg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });
  });

  // ── clearPeerProtocolVersionFloorForTest ────────────────────────────

  group('clearPeerProtocolVersionFloorForTest', () {
    test('clears without error', () {
      ProtocolMessageHandler.clearPeerProtocolVersionFloorForTest();
      // No error expected
    });
  });
}

// ── Fake security service ─────────────────────────────────────────────

class _FakeSecurityService implements ISecurityService {
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
  ) async => 'legacy:$encryptedMessage';

  @override
  Future<String> decryptMessageByType(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async => 'typed:$encryptedMessage';

  @override
  Future<String> decryptSealedMessage({
    required String encryptedMessage,
    required CryptoHeader cryptoHeader,
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async => 'sealed:$encryptedMessage';

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

// ── Fake identity manager ─────────────────────────────────────────────

class _FakeIdentityManager implements IIdentityManager {
  final String? persistentId;
  final String? ephemeralId;

  // ignore: unused_element_parameter
  _FakeIdentityManager({this.persistentId, this.ephemeralId});

  @override
  String? get myPersistentId => persistentId;

  @override
  String? getMyPersistentId() => persistentId;

  @override
  String? get myEphemeralId => ephemeralId;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> loadUserName() async {}

  @override
  Future<void> setMyUserName(String name) async {}

  @override
  Future<void> setMyUserNameWithCallbacks(String name) async {}

  @override
  void setOtherUserName(String? name) {}

  @override
  void setOtherDeviceIdentity(String deviceId, String displayName) {}

  @override
  void setTheirEphemeralId(String ephemeralId, String displayName) {}

  @override
  void setTheirPersistentKey(String persistentKey, {String? ephemeralId}) {}

  @override
  void setCurrentSessionId(String? sessionId) {}

  @override
  String? getPersistentKeyFromEphemeral(String ephemeralId) => null;

  @override
  String? get myUserName => null;

  @override
  String? get otherUserName => null;

  @override
  String? get theirEphemeralId => null;

  @override
  String? get theirPersistentKey => null;

  @override
  String? get currentSessionId => null;

  @override
  void Function(String newName)? onNameChanged;

  @override
  void Function(String newName)? onMyUsernameChanged;
}
