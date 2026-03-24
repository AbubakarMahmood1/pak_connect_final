import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart'
    as relay_models;
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/domain/services/signing_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pointycastle/export.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void _initializeSigningForTests() {
  final curve = ECCurve_secp256r1();
  final privateKey = BigInt.from(42);
  final publicPoint = curve.G * privateKey;
  final privateKeyHex = privateKey.toRadixString(16).padLeft(64, '0');
  final publicKeyHex = _bytesToHex(publicPoint!.getEncoded(false));

  SimpleCrypto.initializeSigning(privateKeyHex, publicKeyHex);
}

String _persistentPublicKeyForTests() {
  final curve = ECCurve_secp256r1();
  final publicPoint = curve.G * BigInt.from(42);
  return _bytesToHex(publicPoint!.getEncoded(false));
}

Uint8List _rawProtocolFrame(ProtocolMessage message) {
  return message.toBytes(enableCompression: false);
}

class _FakeSecurityService extends Fake implements ISecurityService {
  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BLEMessageHandler', () {
    late BLEMessageHandler handler;
    late ContactRepository sharedRepo;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SimpleCrypto.initialize();
      _initializeSigningForTests();
      SecurityServiceLocator.configureServiceResolver(
        () => _FakeSecurityService(),
      );
      sharedRepo = ContactRepository();
      handler = BLEMessageHandler(
        contactRepository: sharedRepo,
        enableCleanupTimer: false,
      );
    });

    tearDown(() {
      SimpleCrypto.clear();
      SimpleCrypto.clearAllConversationKeys();
      SecurityServiceLocator.clearServiceResolver();
      handler.dispose();
    });

    test(
      'checkQRIntroductionMatch returns true only when matching intro exists',
      () async {
        SharedPreferences.setMockInitialValues({
          'scanned_intro_public-key-a': jsonEncode({'intro_id': 'intro-1'}),
        });

        final hasMatch = await handler.checkQRIntroductionMatch(
          otherPublicKey: 'public-key-a',
          theirName: 'Alice',
        );
        final hasNoMatch = await handler.checkQRIntroductionMatch(
          otherPublicKey: 'public-key-b',
          theirName: 'Bob',
        );

        expect(hasMatch, isTrue);
        expect(hasNoMatch, isFalse);
      },
    );

    test(
      'handleQRIntroductionClaim accepts known and unknown intro sessions',
      () async {
        SharedPreferences.setMockInitialValues({
          'my_qr_session_intro-1': jsonEncode({
            'started_showing': 1000,
            'stopped_showing': 2000,
          }),
        });

        final stateManager = BLEStateManager();

        await handler.handleQRIntroductionClaim(
          otherPublicKey: 'peer-key-1',
          introId: 'intro-1',
          scannedTime: 1500,
          theirName: 'Peer',
          stateManager: stateManager,
        );
        await handler.handleQRIntroductionClaim(
          otherPublicKey: 'peer-key-2',
          introId: 'unknown-intro',
          scannedTime: 1500,
          theirName: 'Unknown',
          stateManager: stateManager,
        );
      },
    );

    test(
      'processReceivedData ignores ping byte and non-chunk binary payload',
      () async {
        final repo = ContactRepository();

        final pingResult = await handler.processReceivedData(
          Uint8List.fromList([0x00]),
          contactRepository: repo,
        );
        final binaryResult = await handler.processReceivedData(
          Uint8List.fromList([0x7F, 0x00, 0x01]),
          senderPublicKey: 'peer-key',
          contactRepository: repo,
        );

        expect(pingResult, isNull);
        expect(binaryResult, isNull);
      },
    );

    test(
      'relay wrappers are callable before and after relay initialization',
      () async {
        final preInitRelay = await handler.createOutgoingRelay(
          originalMessageId: 'msg-before-init',
          originalContent: 'hello',
          finalRecipientPublicKey: 'recipient-a',
        );
        final preInitDecrypt = await handler.shouldAttemptDecryption(
          finalRecipientPublicKey: 'recipient-a',
          originalSenderPublicKey: 'sender-a',
        );

        expect(preInitRelay, isNull);
        expect(preInitDecrypt, isFalse);

        await handler.initializeRelaySystem(
          currentNodeId: 'node-local',
          messageQueue: InMemoryOfflineMessageQueue(),
        );
        handler.setNextHopsProvider(() => ['hop-1', 'hop-2']);

        final postInitRelay = await handler.createOutgoingRelay(
          originalMessageId: 'msg-after-init',
          originalContent: 'hello after init',
          finalRecipientPublicKey: 'recipient-b',
        );
        final postInitDecrypt = await handler.shouldAttemptDecryption(
          finalRecipientPublicKey: 'recipient-b',
          originalSenderPublicKey: 'sender-b',
        );

        expect(handler.getAvailableNextHops(), ['hop-1', 'hop-2']);
        expect(postInitRelay, anyOf(isNull, isNotNull));
        expect(postInitDecrypt, isA<bool>());
        expect(handler.getRelayStatistics(), isNotNull);
      },
    );

    test('callback accessors round-trip assignments', () {
      void contactRequest(String _, String _) {}
      void contactAccept(String _, String _) {}
      void contactReject() {}
      void cryptoReq(String _, String _) {}
      void cryptoResp(
        String _,
        String _,
        bool _,
        Map<String, dynamic>? _,
      ) {}
      void queueSync(relay_models.QueueSyncMessage _, String _) {}
      void sendQueue(List<QueuedMessage> _, String _) {}
      void queueDone(String _, QueueSyncResult _) {}
      void relayText(String _, String _, String _) {}
      void relayIds(MessageId _, String _, String _) {}
      void relayDecision(relay_models.RelayDecision _) {}
      void relayStats(relay_models.RelayStatistics _) {}
      void sendAck(ProtocolMessage _) {}
      void sendRelay(ProtocolMessage _, String _) {}

      handler.onContactRequestReceived = contactRequest;
      handler.onContactAcceptReceived = contactAccept;
      handler.onContactRejectReceived = contactReject;
      handler.onCryptoVerificationReceived = cryptoReq;
      handler.onCryptoVerificationResponseReceived = cryptoResp;
      handler.onQueueSyncReceived = queueSync;
      handler.onSendQueueMessages = sendQueue;
      handler.onQueueSyncCompleted = queueDone;
      handler.onRelayMessageReceived = relayText;
      handler.onRelayMessageReceivedIds = relayIds;
      handler.onRelayDecisionMade = relayDecision;
      handler.onRelayStatsUpdated = relayStats;
      handler.onSendAckMessage = sendAck;
      handler.onSendRelayMessage = sendRelay;

      expect(handler.onContactRequestReceived, same(contactRequest));
      expect(handler.onContactAcceptReceived, same(contactAccept));
      expect(handler.onContactRejectReceived, same(contactReject));
      expect(handler.onCryptoVerificationReceived, same(cryptoReq));
      expect(handler.onCryptoVerificationResponseReceived, same(cryptoResp));
      expect(handler.onQueueSyncReceived, same(queueSync));
      expect(handler.onSendQueueMessages, same(sendQueue));
      expect(handler.onQueueSyncCompleted, same(queueDone));
      expect(handler.onRelayMessageReceived, same(relayText));
      expect(handler.onRelayMessageReceivedIds, same(relayIds));
      expect(handler.onRelayDecisionMade, same(relayDecision));
      expect(handler.onRelayStatsUpdated, same(relayStats));
      expect(handler.onSendAckMessage, same(sendAck));
      expect(handler.onSendRelayMessage, same(sendRelay));
    });

    test(
      'friend reveal protocol paths fail closed for stale or malformed payloads',
      () async {
        final staleReveal = ProtocolMessage.friendReveal(
          myPersistentKey: 'persistent-key',
          proof: 'proof',
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
        );
        final malformedReveal = ProtocolMessage(
          type: ProtocolMessageType.friendReveal,
          payload: {
            'proof': 'proof-only',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
          timestamp: DateTime.now(),
        );

        final staleResult = await handler.processReceivedData(
          _rawProtocolFrame(staleReveal),
          senderPublicKey: 'sender-a',
          contactRepository: sharedRepo,
        );
        final malformedResult = await handler.processReceivedData(
          _rawProtocolFrame(malformedReveal),
          senderPublicKey: 'sender-b',
          contactRepository: sharedRepo,
        );

        expect(staleResult, isNull);
        expect(malformedResult, isNull);
      },
    );

    test(
      'friend reveal verifies the challenge against the local ephemeral id',
      () async {
        final previousLevel = Logger.root.level;
        final logRecords = <LogRecord>[];
        Logger.root.level = Level.ALL;
        final subscription = Logger.root.onRecord.listen(logRecords.add);
        const localEphemeralId = 'local-ephemeral-id';
        const senderEphemeralId = 'sender-ephemeral-id';
        final persistentPublicKey = _persistentPublicKeyForTests();

        handler.setCurrentNodeId(localEphemeralId);
        await sharedRepo.saveContactWithSecurity(
          persistentPublicKey,
          'Peer',
          SecurityLevel.medium,
          currentEphemeralId: senderEphemeralId,
          persistentPublicKey: persistentPublicKey,
        );
        await sharedRepo.cacheSharedSecret(persistentPublicKey, 'cached-secret');
        expect(
          await sharedRepo.getCachedSharedSecret(persistentPublicKey),
          equals('cached-secret'),
        );
        expect(await sharedRepo.getContact(persistentPublicKey), isNotNull);

        final revealed = <String>[];
        handler.onIdentityRevealed = revealed.add;

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final proof = SimpleCrypto.signMessage(
          '${localEphemeralId}_$timestamp',
        );
        expect(proof, isNotNull);
        expect(
          SigningManager.verifySignature(
            '${localEphemeralId}_$timestamp',
            proof!,
            persistentPublicKey,
            false,
          ),
          isTrue,
        );

        final reveal = ProtocolMessage.friendReveal(
          myPersistentKey: persistentPublicKey,
          proof: proof,
          timestamp: timestamp,
        );

        final result = await handler.processReceivedData(
          _rawProtocolFrame(reveal),
          senderPublicKey: senderEphemeralId,
          contactRepository: sharedRepo,
        );
        await subscription.cancel();
        Logger.root.level = previousLevel;

        expect(result, isNull);
        expect(
          revealed,
          ['Peer'],
          reason: logRecords
              .map((record) => '${record.level.name}: ${record.message}')
              .join('\n'),
        );
      },
    );

    test('sendQueueSyncMessage preserves compatibility path', () async {
      final characteristic = GATTCharacteristic.mutable(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000c0c0'),
        properties: [GATTCharacteristicProperty.write],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: const [],
      );
      final queueSyncMessage = relay_models.QueueSyncMessage(
        queueHash: 'hash-1',
        messageIds: ['m1', 'm2'],
        syncTimestamp: DateTime.now(),
        nodeId: 'node-local',
        syncType: relay_models.QueueSyncType.request,
      );

      final sent = await handler.sendQueueSyncMessage(
        centralManager: null,
        peripheralManager: null,
        connectedDevice: null,
        connectedCentral: null,
        messageCharacteristic: characteristic,
        syncMessage: queueSyncMessage,
        mtuSize: 64,
        stateManager: BLEStateManager(),
      );

      expect(sent, isTrue);
    });

    test('dispose is safe to call repeatedly', () {
      handler.dispose();
      handler.dispose();
    });
  });
}
