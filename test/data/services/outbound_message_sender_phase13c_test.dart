/// Phase 13c — OutboundMessageSender integration tests covering
/// sendCentralMessage and sendPeripheralMessage full flows:
/// error branches, ACK tracking, spy mode, sealed V1, encryption paths.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/outbound_message_sender.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import 'package:pak_connect/domain/messaging/message_chunk_sender.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/values/id_types.dart';

import '../../helpers/ble/ble_fakes.dart';
import '../../test_helpers/ble/fake_ble_platform.dart';
import '../../test_helpers/mocks/in_memory_secure_storage.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSecurityService extends Fake implements ISecurityService {
  EncryptionMethod nextMethod = EncryptionMethod.ecdh(
    'default-ecdh-recipient-key',
  );
  SecurityLevel nextLevel = SecurityLevel.low;
  bool nextHasNoise = false;
  bool getCurrentLevelThrows = false;
  bool encryptThrows = false;

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async =>
      nextMethod;

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async {
    if (getCurrentLevelThrows) throw Exception('level unavailable');
    return nextLevel;
  }

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => nextHasNoise;

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async {
    if (encryptThrows) throw Exception('encryption failed');
    return 'encrypted:$message';
  }
}

/// Extends the concrete [ContactRepository] so it can be passed where the
/// production code expects the concrete type, while avoiding real DB access.
class _TestContactRepository extends ContactRepository {
  Contact? contactToReturn;
  Contact? contactByAnyIdToReturn;

  @override
  Future<Contact?> getContact(String publicKey) async => contactToReturn;

  @override
  Future<Contact?> getContactByAnyId(String identifier) async =>
      contactByAnyIdToReturn ?? contactToReturn;
}

Contact _makeContact({
  required String publicKey,
  String? persistentPublicKey,
  String? currentEphemeralId,
  String displayName = 'Test Contact',
  TrustStatus trustStatus = TrustStatus.newContact,
  SecurityLevel securityLevel = SecurityLevel.low,
  String? noisePublicKey,
}) {
  final now = DateTime.now();
  return Contact(
    publicKey: publicKey,
    persistentPublicKey: persistentPublicKey,
    currentEphemeralId: currentEphemeralId,
    displayName: displayName,
    trustStatus: trustStatus,
    securityLevel: securityLevel,
    firstSeen: now,
    lastSeen: now,
    noisePublicKey: noisePublicKey,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Logger logger;
  late List<LogRecord> logs;
  late _FakeSecurityService securityService;
  late _TestContactRepository contactRepo;
  
  late BLEStateManager stateManager;
  late FakePeripheral fakePeripheral;
  late FakeCentral fakeCentral;
  late FakeGATTCharacteristic fakeCharacteristic;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FakeBlePlatform.ensureRegistered();
    FlutterSecureStoragePlatform.instance = InMemorySecureStorage();
    SharedPreferences.setMockInitialValues({});
    await EphemeralKeyManager.initialize('test-private-key-phase13c');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    logs = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logs.add);

    logger = Logger('OutboundSenderPhase13c');
    securityService = _FakeSecurityService();
    contactRepo = _TestContactRepository();
    

    SecurityServiceLocator.configureServiceResolver(() => securityService);

    fakePeripheral = FakePeripheral(uuid: makeUuid(1));
    fakeCentral = FakeCentral(uuid: makeUuid(2));
    fakeCharacteristic = FakeGATTCharacteristic();

    stateManager = BLEStateManager();
  });

  tearDown(() {
    Logger.root.clearListeners();
    SecurityServiceLocator.clearServiceResolver();
  });

  // =========================================================================
  // sendCentralMessage
  // =========================================================================
  group('sendCentralMessage', () {
    test('happy path — ACK success returns true and fires callbacks',
        () async {
      final sentChunks = <Uint8List>[];
      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 5));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {
          sentChunks.add(value);
          ackTracker.complete('central-happy-001');
        },
      );
      sender.setCurrentNodeId('my-central-node-001');

      final opChangedValues = <bool>[];
      bool? sentResult;
      MessageId? sentMsgId;

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: 'Hello world',
        mtuSize: 512,
        messageId: 'central-happy-001',
        contactPublicKey: 'recipient-pk-abcdef12345678',
        contactRepository: contactRepo,
        stateManager: stateManager,
        onMessageOperationChanged: opChangedValues.add,
        onMessageSent: (id, success) => sentResult = success,
        onMessageSentIds: (id, success) => sentMsgId = id,
      );

      expect(result, isTrue);
      expect(sentResult, isTrue);
      expect(sentMsgId?.value, 'central-happy-001');
      expect(sentChunks, isNotEmpty);
      // onMessageOperationChanged(true) at line 123
      expect(opChangedValues, contains(true));
      // Delayed onMessageOperationChanged(false) at line 410
      await Future.delayed(Duration(milliseconds: 600));
      expect(opChangedValues, contains(false));
    });

    test('diagnostic logs omit plaintext payloads and full identifiers',
        () async {
      const message = 'TOP_SECRET_PAYLOAD_123';
      const recipientId = 'recipient-secret-abcdef1234567890';

      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 5));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {
          ackTracker.complete('central-log-safety-001');
        },
      );
      sender.setCurrentNodeId('node-secret-abcdef1234567890');

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: message,
        mtuSize: 512,
        messageId: 'central-log-safety-001',
        contactPublicKey: recipientId,
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(logs.where((log) => log.message.contains(message)), isEmpty);
      expect(logs.where((log) => log.message.contains(recipientId)), isEmpty);
      expect(
        logs.where(
          (log) => log.message.contains('node-secret-abcdef1234567890'),
        ),
        isEmpty,
      );
      expect(
        logs.where((log) => log.message.contains('SEND DEBUG: Message content')),
        isEmpty,
      );
    });

    test('empty recipient throws and fires error callbacks', () async {
      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 2));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
      );
      // Set node ID so recipient resolves to self → cleared to empty
      sender.setCurrentNodeId('my-self-node');

      bool? sentSuccess;
      MessageId? sentMsgId;

      try {
        await sender.sendCentralMessage(
          centralManager: CentralManager(),
          connectedDevice: fakePeripheral,
          messageCharacteristic: fakeCharacteristic,
          message: 'test msg',
          mtuSize: 512,
          messageId: 'empty-rcpt-central',
          contactRepository: contactRepo,
          stateManager: stateManager,
          onMessageSent: (id, success) => sentSuccess = success,
          onMessageSentIds: (id, success) => sentMsgId = id,
        );
        fail('Should have thrown');
      } on Exception catch (e) {
        expect(e.toString(), contains('Intended recipient not set'));
      }

      expect(sentSuccess, isFalse);
      expect(sentMsgId?.value, 'empty-rcpt-central');
    });

    test('spy mode logs anonymous send info', () async {
      // Enable spy mode: hint broadcast OFF + active noise session
      SharedPreferences.setMockInitialValues({
        'hint_broadcast_enabled': false,
      });

      securityService.nextHasNoise = true;

      contactRepo.contactToReturn = _makeContact(
        publicKey: 'spy-contact-pk-1234567890ab',
        currentEphemeralId: 'spy-eph-id-abcdef12345678',
      );

      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 5));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {
          ackTracker.complete('spy-msg-001');
        },
      );
      sender.setCurrentNodeId('my-spy-node-id-different');

      await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: 'secret message',
        mtuSize: 512,
        messageId: 'spy-msg-001',
        contactPublicKey: 'spy-contact-pk-1234567890ab',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      final spyLogs = logs.where(
        (l) => l.message.contains('SPY MODE'),
      );
      expect(spyLogs, isNotEmpty, reason: 'Should contain spy mode logs');
    });

    test('getCurrentLevel exception falls back to LOW', () async {
      securityService.getCurrentLevelThrows = true;

      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 5));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {
          ackTracker.complete('level-err-msg');
        },
      );
      sender.setCurrentNodeId('level-err-node');

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: 'test security fallback',
        mtuSize: 512,
        messageId: 'level-err-msg',
        contactPublicKey: 'level-err-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(
        logs.any((l) => l.message.contains('Failed to get security level')),
        isTrue,
      );
    });

    test('ACK timeout fires onTimeout callback and returns false', () async {
      final ackTracker =
          MessageAckTracker(timeout: Duration(milliseconds: 50));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {
          // Don't acknowledge — let it time out.
        },
      );
      sender.setCurrentNodeId('timeout-node');

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: 'timeout test',
        mtuSize: 512,
        messageId: 'timeout-msg-001',
        contactPublicKey: 'timeout-pk-1234567890ab',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isFalse);
      expect(
        logs.any((l) => l.message.contains('Message timeout')),
        isTrue,
      );
    });

    test('encryption error fires error callbacks and rethrows', () async {
      securityService.encryptThrows = true;

      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 2));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
      );
      sender.setCurrentNodeId('enc-err-node');

      bool? sentSuccess;

      try {
        await sender.sendCentralMessage(
          centralManager: CentralManager(),
          connectedDevice: fakePeripheral,
          messageCharacteristic: fakeCharacteristic,
          message: 'will fail',
          mtuSize: 512,
          messageId: 'enc-err-msg',
          contactPublicKey: 'enc-err-pk-abcdef1234',
          contactRepository: contactRepo,
          stateManager: stateManager,
          onMessageSent: (id, success) => sentSuccess = success,
        );
        fail('Should have thrown');
      } on Exception catch (e) {
        expect(e.toString(), contains('encryption failed'));
      }

      expect(sentSuccess, isFalse);
    });

    test('no centralWrite — single chunk uses CentralManager.writeCharacteristic',
        () async {
      // Small message + large MTU → single-chunk path through
      // CentralManager.writeCharacteristic (line 369 / onAfterSend 386-387)
      final ackTracker =
          MessageAckTracker(timeout: Duration(milliseconds: 100));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        // No centralWrite — falls back to CentralManager
      );
      sender.setCurrentNodeId('no-cw-node');

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: 'short msg',
        mtuSize: 2048,
        messageId: 'no-cw-msg-001',
        contactPublicKey: 'no-cw-pk-abcdef12345678',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      // ACK times out → false, but the single-chunk path was exercised
      expect(result, isFalse);
      expect(
        logs.any((l) => l.message.contains('SEND STEP 6.1')),
        isTrue,
        reason: 'onAfterSend callback should have fired',
      );
    });

    test('no centralWrite — binary envelope uses CentralManager.writeCharacteristic',
        () async {
      // Large message + moderate MTU → multi-chunk → binary envelope path
      // through CentralManager.writeCharacteristic (line 347)
      final ackTracker =
          MessageAckTracker(timeout: Duration(milliseconds: 200));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        // No centralWrite — falls back to CentralManager
      );
      sender.setCurrentNodeId('no-cw-bin-node');

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: List.filled(3000, 'X').join(),
        mtuSize: 80,
        messageId: 'no-cw-bin-msg',
        contactPublicKey: 'no-cw-bin-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isFalse); // ACK times out
      expect(
        logs.any((l) => l.message.contains('Using binary envelope')),
        isTrue,
      );
    });

    test('fragmentation failure falls back to binary envelope', () async {
      // Very small MTU causes MessageFragmenter.fragmentBytes to throw,
      // covering the catch at lines 316-317.  BinaryFragmenter also
      // rejects the tiny MTU, so the overall send throws.
      final ackTracker =
          MessageAckTracker(timeout: Duration(milliseconds: 200));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {},
      );
      sender.setCurrentNodeId('frag-err-node');

      try {
        await sender.sendCentralMessage(
          centralManager: CentralManager(),
          connectedDevice: fakePeripheral,
          messageCharacteristic: fakeCharacteristic,
          message: 'Fragmentation test payload',
          mtuSize: 10,
          messageId: 'frag-err-msg',
          contactPublicKey: 'frag-err-pk-abcdef1234',
          contactRepository: contactRepo,
          stateManager: stateManager,
        );
      } catch (_) {
        // Expected: BinaryFragmenter also rejects the tiny MTU.
      }

      expect(
        logs.any(
          (l) => l.message.contains('Chunk fragmentation failed'),
        ),
        isTrue,
        reason: 'Should log chunk fragmentation failure',
      );
    });
  });

  // =========================================================================
  // sendPeripheralMessage
  // =========================================================================
  group('sendPeripheralMessage', () {
    test('happy path returns true and fires callbacks', () async {
      final sentChunks = <Uint8List>[];
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {
          sentChunks.add(value);
        },
      );
      sender.setCurrentNodeId('periph-node-001');

      bool? sentResult;
      MessageId? sentMsgId;

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'Peripheral hello',
        mtuSize: 512,
        messageId: 'periph-happy-001',
        contactPublicKey: 'periph-rcpt-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
        onMessageSent: (id, success) => sentResult = success,
        onMessageSentIds: (id, success) => sentMsgId = id,
      );

      expect(result, isTrue);
      expect(sentResult, isTrue);
      expect(sentMsgId?.value, 'periph-happy-001');
      expect(sentChunks, isNotEmpty);
      // Verify sanitized outbound metadata log is still present.
      expect(
        logs.any((l) => l.message.contains('Outbound message prepared')),
        isTrue,
      );
    });

    test('empty recipient throws', () async {
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
      );
      sender.setCurrentNodeId('periph-self-node');

      bool? sentSuccess;

      try {
        await sender.sendPeripheralMessage(
          peripheralManager: PeripheralManager(),
          connectedCentral: fakeCentral,
          messageCharacteristic: fakeCharacteristic,
          message: 'will fail',
          mtuSize: 512,
          messageId: 'periph-empty-rcpt',
          contactRepository: contactRepo,
          stateManager: stateManager,
          onMessageSent: (id, success) => sentSuccess = success,
        );
        fail('Should have thrown');
      } on Exception catch (e) {
        expect(e.toString(), contains('Intended recipient not set'));
      }

      expect(sentSuccess, isFalse);
      expect(
        logs.any(
          (l) => l.message.contains('PERIPHERAL SEND ABORTED'),
        ),
        isTrue,
      );
    });

    test('sealed V1 fallback with valid noise key', () async {
      // Provide a contact with a valid 32-byte base64 noise key
      final noiseKey = base64.encode(List.filled(32, 0x42));
      contactRepo.contactToReturn = _makeContact(
        publicKey: 'sealed-contact-pk-abcdef1234',
        noisePublicKey: noiseKey,
      );
      contactRepo.contactByAnyIdToReturn = contactRepo.contactToReturn;

      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        enableSealedV1Send: true,
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {},
      );
      sender.setCurrentNodeId('sealed-test-node');

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'sealed v1 test',
        mtuSize: 512,
        messageId: 'sealed-msg-001',
        contactPublicKey: 'sealed-contact-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(
        logs.any((l) => l.message.contains('SEALED_V1 offline lane')),
        isTrue,
      );
    });

    test('getCurrentLevel exception falls back to LOW in peripheral',
        () async {
      securityService.getCurrentLevelThrows = true;

      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {},
      );
      sender.setCurrentNodeId('periph-level-node');

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'level fallback test',
        mtuSize: 512,
        messageId: 'periph-level-msg',
        contactPublicKey: 'periph-level-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(
        logs.any(
          (l) => l.message.contains('PERIPHERAL: Failed to get security level'),
        ),
        isTrue,
      );
    });

    test('encryption error fires error callbacks and rethrows', () async {
      securityService.encryptThrows = true;

      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
      );
      sender.setCurrentNodeId('periph-enc-err-node');

      bool? sentSuccess;
      MessageId? sentMsgId;

      try {
        await sender.sendPeripheralMessage(
          peripheralManager: PeripheralManager(),
          connectedCentral: fakeCentral,
          messageCharacteristic: fakeCharacteristic,
          message: 'will fail',
          mtuSize: 512,
          messageId: 'periph-enc-err-msg',
          contactPublicKey: 'periph-enc-err-pk-abcdef1234',
          contactRepository: contactRepo,
          stateManager: stateManager,
          onMessageSent: (id, success) => sentSuccess = success,
          onMessageSentIds: (id, success) => sentMsgId = id,
        );
        fail('Should have thrown');
      } on Exception catch (e) {
        expect(e.toString(), contains('encryption failed'));
      }

      expect(sentSuccess, isFalse);
      expect(sentMsgId?.value, 'periph-enc-err-msg');
    });

    test('no peripheralWrite — uses PeripheralManager.notifyCharacteristic',
        () async {
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        // No peripheralWrite → falls back to PeripheralManager
      );
      sender.setCurrentNodeId('periph-no-pw-node');

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'no peripheral write',
        mtuSize: 2048,
        messageId: 'periph-no-pw-msg',
        contactPublicKey: 'periph-no-pw-pk-abcdef12',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(
        logs.any((l) => l.message.contains('Peripheral message dispatched')),
        isTrue,
      );
    });

    test('binary envelope path for large peripheral messages', () async {
      final sentChunks = <Uint8List>[];
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {
          sentChunks.add(value);
        },
      );
      sender.setCurrentNodeId('periph-bin-node');

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: List.filled(3000, 'Y').join(),
        mtuSize: 80,
        messageId: 'periph-bin-msg',
        contactPublicKey: 'periph-bin-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(sentChunks.length, greaterThan(1));
      expect(
        logs.any((l) => l.message.contains('binary envelope')),
        isTrue,
      );
    });

    test('originalIntendedRecipient overrides default in peripheral',
        () async {
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {},
      );
      sender.setCurrentNodeId('periph-orig-node');

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'relay test',
        mtuSize: 512,
        messageId: 'periph-orig-msg',
        contactPublicKey: 'periph-orig-pk-abcdef1234',
        originalIntendedRecipient: 'original-dest-pk-xyz123',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
    });

    test('noise encryption method used in peripheral', () async {
      securityService.nextMethod = EncryptionMethod.noise(
        'noise-pk-1234567890abcdef',
      );

      contactRepo.contactToReturn = _makeContact(
        publicKey: 'noise-contact-pk-abcdef1234',
        currentEphemeralId: 'noise-eph-session-1234567890ab',
      );

      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {},
      );
      sender.setCurrentNodeId('periph-noise-node');

      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'noise encrypted msg',
        mtuSize: 512,
        messageId: 'periph-noise-msg',
        contactPublicKey: 'noise-contact-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(
        logs.any(
          (l) => l.message.contains('Encrypted with NOISE method'),
        ),
        isTrue,
      );
    });

    test('recipientId fallback when contactPublicKey is null', () async {
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: MessageAckTracker(),
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        peripheralWrite: ({
          required PeripheralManager peripheralManager,
          required Central central,
          required GATTCharacteristic characteristic,
          required Uint8List value,
          bool withoutResponse = false,
        }) async {},
      );
      sender.setCurrentNodeId('periph-fallback-node');

      // contactPublicKey is null, recipientId used as fallback
      final result = await sender.sendPeripheralMessage(
        peripheralManager: PeripheralManager(),
        connectedCentral: fakeCentral,
        messageCharacteristic: fakeCharacteristic,
        message: 'fallback test',
        mtuSize: 512,
        messageId: 'periph-fallback-msg',
        recipientId: 'fallback-recipient-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
    });
  });

  // =========================================================================
  // sendCentralMessage — sealed V1 fallback (central path)
  // =========================================================================
  group('sendCentralMessage sealed V1', () {
    test('sealed V1 applied when enableSealedV1Send is true', () async {
      final noiseKey = base64.encode(List.filled(32, 0x42));
      contactRepo.contactToReturn = _makeContact(
        publicKey: 'sealed-central-pk-abcdef1234',
        noisePublicKey: noiseKey,
      );
      contactRepo.contactByAnyIdToReturn = contactRepo.contactToReturn;

      final ackTracker = MessageAckTracker(timeout: Duration(seconds: 5));
      final sender = OutboundMessageSender(
        allowLegacyV2Send: true,
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: MessageChunkSender(logger: logger),
        securityService: securityService,
        
        enableSealedV1Send: true,
        centralWrite: ({
          required CentralManager centralManager,
          required Peripheral peripheral,
          required GATTCharacteristic characteristic,
          required Uint8List value,
        }) async {
          ackTracker.complete('sealed-central-msg');
        },
      );
      sender.setCurrentNodeId('sealed-central-node');

      final result = await sender.sendCentralMessage(
        centralManager: CentralManager(),
        connectedDevice: fakePeripheral,
        messageCharacteristic: fakeCharacteristic,
        message: 'sealed central test',
        mtuSize: 512,
        messageId: 'sealed-central-msg',
        contactPublicKey: 'sealed-central-pk-abcdef1234',
        contactRepository: contactRepo,
        stateManager: stateManager,
      );

      expect(result, isTrue);
      expect(
        logs.any((l) => l.message.contains('SEALED_V1 offline lane')),
        isTrue,
      );
    });
  });
}
