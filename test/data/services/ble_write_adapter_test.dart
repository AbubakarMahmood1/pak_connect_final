import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/domain/utils/message_fragmenter.dart';
import 'package:pak_connect/core/security/noise/primitives/dh_state.dart';
import 'package:pak_connect/core/security/peer_protocol_version_guard.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_write_adapter.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import '../../helpers/ble/ble_fakes.dart';
import '../../helpers/ble/mock_ble_write_client.dart';

class _FakeStateManager extends BLEStateManager {
  bool peripheralMode = false;
  bool paired = true;
  _FakeStateManager() : super(identityManager: null);
  @override
  bool get isPeripheralMode => peripheralMode;
  @override
  bool get isPaired => paired;
  @override
  String getIdType() => paired ? 'persistent' : 'ephemeral';
}

class _FakeCentralManager implements CentralManager {
  @override
  Future<void> writeCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required Uint8List value,
    required GATTCharacteristicWriteType type,
  }) async {
    // Stub: do nothing
  }

  @override
  Future<void> disconnect(Peripheral peripheral) async {
    // Stub: do nothing
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePeripheralManager implements PeripheralManager {
  Future<void> writeCharacteristic(
    GATTCharacteristic characteristic, {
    required Uint8List value,
    required List<Central> centrals,
  }) async {
    // Stub: do nothing
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEncryptionException implements Exception {
  _FakeEncryptionException(this.message);

  final String message;

  @override
  String toString() => 'EncryptionException: $message';
}

class _FakeSecurityService implements ISecurityService {
  final Set<String> _noiseSessions = <String>{};
  final Map<String, String> _identityMappings = <String, String>{};
  int encryptByTypeCalls = 0;
  EncryptionType? lastEncryptType;

  void clearAllNoiseSessions() {
    _noiseSessions.clear();
    _identityMappings.clear();
  }

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {
    _identityMappings[persistentPublicKey] = ephemeralID;
    _noiseSessions.add(ephemeralID);
  }

  @override
  void unregisterIdentityMapping(String persistentPublicKey) {
    _identityMappings.remove(persistentPublicKey);
    _noiseSessions.remove(persistentPublicKey);
  }

  String _resolveSessionKey(String publicKey) =>
      _identityMappings[publicKey] ?? publicKey;

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async {
    if (_noiseSessions.contains(_resolveSessionKey(publicKey))) {
      return SecurityLevel.high;
    }
    if (SimpleCrypto.hasConversationKey(publicKey)) {
      return SecurityLevel.medium;
    }
    return SecurityLevel.low;
  }

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async {
    final sessionKey = _resolveSessionKey(publicKey);
    if (_noiseSessions.contains(sessionKey)) {
      return EncryptionMethod.noise(sessionKey);
    }
    if (SimpleCrypto.hasConversationKey(publicKey)) {
      return EncryptionMethod.ecdh(publicKey);
    }
    return EncryptionMethod.global();
  }

  @override
  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  ) async {
    if (_noiseSessions.contains(_resolveSessionKey(publicKey))) {
      return 'noise:$message';
    }
    if (SimpleCrypto.hasConversationKey(publicKey)) {
      return SimpleCrypto.encryptForConversation(message, publicKey);
    }
    throw _FakeEncryptionException('no encryption context for $publicKey');
  }

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async {
    encryptByTypeCalls++;
    lastEncryptType = type;
    return encryptMessage(message, publicKey, repo);
  }

  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async {
    if (encryptedMessage.startsWith('noise:')) {
      return encryptedMessage.substring('noise:'.length);
    }
    if (SimpleCrypto.hasConversationKey(publicKey)) {
      return SimpleCrypto.decryptFromConversation(encryptedMessage, publicKey);
    }
    throw _FakeEncryptionException('no decryption context for $publicKey');
  }

  @override
  Future<String> decryptMessageByType(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async {
    return decryptMessage(encryptedMessage, publicKey, repo);
  }

  @override
  Future<String> decryptSealedMessage({
    required String encryptedMessage,
    required CryptoHeader cryptoHeader,
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async {
    throw _FakeEncryptionException('sealed decrypt not implemented in fake');
  }

  @override
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async {
    if (!_noiseSessions.contains(_resolveSessionKey(publicKey)) &&
        !SimpleCrypto.hasConversationKey(publicKey)) {
      throw _FakeEncryptionException('no binary encryption context');
    }
    return data;
  }

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async {
    if (!_noiseSessions.contains(_resolveSessionKey(publicKey)) &&
        !SimpleCrypto.hasConversationKey(publicKey)) {
      throw _FakeEncryptionException('no binary decryption context');
    }
    return data;
  }

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) =>
      _noiseSessions.contains(peerSessionId);
}

class _CaptureThenThrowCentralWriteClient extends FakeBleWriteClient {
  @override
  Future<void> writeCentral({
    required CentralManager centralManager,
    required Peripheral device,
    required GATTCharacteristic characteristic,
    required List<int> value,
  }) async {
    lastCentralManager = centralManager;
    lastPeripheral = device;
    lastCentralCharacteristic = characteristic;
    lastCentralValue = Uint8List.fromList(value);
    throw Exception('central boom after capture');
  }
}

void main() {
  late _FakeStateManager stateManager;
  late ContactRepository contactRepository;
  late FakeBleWriteClient writeClient;
  late BleWriteAdapter adapter;
  late _FakeSecurityService securityService;
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    // Initialize SimpleCrypto (used by our test security service).
    SimpleCrypto.initialize();

    // Initialize EphemeralKeyManager
    await EphemeralKeyManager.initialize(
      'test-private-key-1234567890123456789012345678901234567890',
    );

    securityService = _FakeSecurityService();
    SecurityServiceLocator.configureServiceResolver(() => securityService);
  });

  tearDownAll(() {
    SecurityServiceLocator.clearServiceResolver();
  });

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);

    // Keep each test independent from previous key/session state.
    SimpleCrypto.clearAllConversationKeys();
    securityService.clearAllNoiseSessions();
    PeerProtocolVersionGuard.clearForTest();

    stateManager = _FakeStateManager();
    contactRepository = ContactRepository();
    writeClient = FakeBleWriteClient();
    adapter = BleWriteAdapter(
      contactRepository: contactRepository,
      stateManagerProvider: () => stateManager,
      writeClient: writeClient,
    );
  });

  void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

  tearDown(() {
    // Find all SEVERE logs
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);

    // Filter out allowed SEVEREs
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );

    // Assert no unexpected SEVEREs
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );

    // Assert expected SEVEREs are present
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }

    PeerProtocolVersionGuard.clearForTest();
  });

  test('central send returns false when write client throws', () async {
    await contactRepository.saveContact('recipient', 'Recipient');
    securityService.registerIdentityMapping(
      persistentPublicKey: 'recipient',
      ephemeralID: 'noise-session-recipient',
    );

    // This test intentionally throws an error to test error handling
    allowSevere('Failed to send message: Exception: central boom');
    allowSevere('Stack trace'); // Allow the stack trace log

    writeClient.throwCentral = true;

    final result = await adapter.sendCentralMessage(
      centralManager: _FakeCentralManager(),
      connectedDevice: FakePeripheral(uuid: makeUuid(1)),
      messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(2)),
      recipientKey: 'recipient',
      content: 'hi',
      mtuSize: 185, // Realistic BLE MTU size
    );

    expect(result, isFalse);
  });

  test(
    'central send does not transmit plaintext when encryption fails',
    () async {
      await contactRepository.saveContact(
        'recipient_fail_closed',
        'Recipient Fail Closed',
      );

      // No conversation key and no Noise session -> security must fail
      // closed before any transport write is attempted.
      allowSevere(RegExp(r'Failed to send message: EncryptionException'));
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(11)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(12)),
        recipientKey: 'recipient_fail_closed',
        content: 'plaintext must never be transmitted',
        mtuSize: 185,
      );

      expect(result, isFalse);
      expect(
        writeClient.lastCentralValue,
        isNull,
        reason:
            'No BLE bytes should be written when encryption fails (fail-closed)',
      );
    },
  );

  test(
    'central send rejects removed legacy transport when no sealed_v1 fallback exists',
    () async {
      await contactRepository.saveContact(
        'recipient_removed_transport',
        'Recipient Removed Transport',
      );
      SimpleCrypto.initializeConversation(
        'recipient_removed_transport',
        'ble-write-test-removed-transport-secret',
      );

      adapter = BleWriteAdapter(
        contactRepository: contactRepository,
        stateManagerProvider: () => stateManager,
        writeClient: writeClient,
      );
      allowSevere('Legacy v2 transport modes have been removed');
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(21)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(22)),
        recipientKey: 'recipient_removed_transport',
        content: 'removed transport should fail closed',
        mtuSize: 185,
      );

      expect(result, isFalse);
      expect(
        writeClient.lastCentralValue,
        isNull,
        reason: 'Transport must not write when only removed legacy modes are available',
      );
    },
  );

  test(
    'v2 header mode/sessionId follows selected Noise method from security service',
    () async {
      await contactRepository.saveContact('recipient_noise', 'Recipient Noise');
      securityService.registerIdentityMapping(
        persistentPublicKey: 'recipient_noise',
        ephemeralID: 'noise-session-abc',
      );

      final captureWriteClient = _CaptureThenThrowCentralWriteClient();
      adapter = BleWriteAdapter(
        contactRepository: contactRepository,
        stateManagerProvider: () => stateManager,
        writeClient: captureWriteClient,
      );

      allowSevere(
        'Failed to send message: Exception: central boom after capture',
      );
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(31)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(32)),
        recipientKey: 'recipient_noise',
        content: 'noise header check',
        mtuSize: 1024,
      );

      expect(result, isFalse);
      expect(captureWriteClient.lastCentralValue, isNotNull);

      final chunk = MessageChunk.fromBytes(
        captureWriteClient.lastCentralValue!,
      );
      final protocolBytes = base64.decode(chunk.content);
      final protocolMessage = ProtocolMessage.fromBytes(
        Uint8List.fromList(protocolBytes),
      );

      expect(protocolMessage.version, equals(2));
      expect(protocolMessage.cryptoHeader?.mode, equals(CryptoMode.noiseV1));
      expect(
        protocolMessage.cryptoHeader?.sessionId,
        equals('noise-session-abc'),
      );
      expect(securityService.encryptByTypeCalls, greaterThan(0));
      expect(securityService.lastEncryptType, equals(EncryptionType.noise));
    },
  );

  test(
    'send upgrades to sealed_v1 when recipient Noise static key is known',
    () async {
      await contactRepository.saveContact(
        'recipient_sealed',
        'Recipient Sealed',
      );
      await contactRepository.updateNoiseSession(
        publicKey: 'recipient_sealed',
        noisePublicKey: _generateNoiseStaticPublicKeyBase64(),
        sessionState: 'established',
      );

      SimpleCrypto.initializeConversation(
        'recipient_sealed',
        'ble-write-test-sealed-secret',
      );

      final captureWriteClient = _CaptureThenThrowCentralWriteClient();
      adapter = BleWriteAdapter(
        contactRepository: contactRepository,
        stateManagerProvider: () => stateManager,
        writeClient: captureWriteClient,
      );

      allowSevere(
        'Failed to send message: Exception: central boom after capture',
      );
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(41)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(42)),
        recipientKey: 'recipient_sealed',
        content: 'sealed strict fallback',
        mtuSize: 1024,
      );

      expect(result, isFalse);
      expect(captureWriteClient.lastCentralValue, isNotNull);

      final chunk = MessageChunk.fromBytes(
        captureWriteClient.lastCentralValue!,
      );
      final protocolBytes = base64.decode(chunk.content);
      final protocolMessage = ProtocolMessage.fromBytes(
        Uint8List.fromList(protocolBytes),
      );

      expect(protocolMessage.version, equals(2));
      expect(protocolMessage.payload['encryptionMethod'], equals('sealed'));
      final header = protocolMessage.cryptoHeader;
      expect(header, isNotNull);
      expect(header!.mode, equals(CryptoMode.sealedV1));
      expect(header.sessionId, isNull);
      expect(header.keyId, isNotEmpty);
      expect(header.ephemeralPublicKey, isNotEmpty);
      expect(header.nonce, isNotEmpty);
      expect(
        protocolMessage.textContent,
        isNot(equals('sealed strict fallback')),
      );
    },
  );

  test(
    'send auto-falls back to sealed_v1 when legacy transport is unavailable',
    () async {
      await contactRepository.saveContact(
        'recipient_strict_auto_sealed',
        'Recipient Strict Auto Sealed',
      );
      await contactRepository.updateNoiseSession(
        publicKey: 'recipient_strict_auto_sealed',
        noisePublicKey: _generateNoiseStaticPublicKeyBase64(),
        sessionState: 'established',
      );
      SimpleCrypto.initializeConversation(
        'recipient_strict_auto_sealed',
        'ble-write-test-strict-auto-sealed-secret',
      );

      final captureWriteClient = _CaptureThenThrowCentralWriteClient();
      adapter = BleWriteAdapter(
        contactRepository: contactRepository,
        stateManagerProvider: () => stateManager,
        writeClient: captureWriteClient,
      );

      allowSevere(
        'Failed to send message: Exception: central boom after capture',
      );
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(43)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(44)),
        recipientKey: 'recipient_strict_auto_sealed',
        content: 'auto sealed fallback',
        mtuSize: 1024,
      );

      expect(result, isFalse);
      expect(captureWriteClient.lastCentralValue, isNotNull);

      final chunk = MessageChunk.fromBytes(
        captureWriteClient.lastCentralValue!,
      );
      final protocolBytes = base64.decode(chunk.content);
      final protocolMessage = ProtocolMessage.fromBytes(
        Uint8List.fromList(protocolBytes),
      );

      expect(protocolMessage.version, equals(2));
      expect(protocolMessage.payload['encryptionMethod'], equals('sealed'));
      expect(protocolMessage.cryptoHeader?.mode, equals(CryptoMode.sealedV1));
    },
  );

  test(
    'sealed_v1 is used when recipient static key is available',
    () async {
      await contactRepository.saveContact(
        'recipient_sealed_pref',
        'Recipient Sealed Pref',
      );
      await contactRepository.updateNoiseSession(
        publicKey: 'recipient_sealed_pref',
        noisePublicKey: _generateNoiseStaticPublicKeyBase64(),
        sessionState: 'established',
      );

      SimpleCrypto.initializeConversation(
        'recipient_sealed_pref',
        'ble-write-test-sealed-pref-secret',
      );

      final captureWriteClient = _CaptureThenThrowCentralWriteClient();
      adapter = BleWriteAdapter(
        contactRepository: contactRepository,
        stateManagerProvider: () => stateManager,
        writeClient: captureWriteClient,
      );

      allowSevere(
        'Failed to send message: Exception: central boom after capture',
      );
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(51)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(52)),
        recipientKey: 'recipient_sealed_pref',
        content: 'sealed preferred path',
        mtuSize: 1024,
      );

      expect(result, isFalse);
      expect(captureWriteClient.lastCentralValue, isNotNull);

      final chunk = MessageChunk.fromBytes(
        captureWriteClient.lastCentralValue!,
      );
      final protocolBytes = base64.decode(chunk.content);
      final protocolMessage = ProtocolMessage.fromBytes(
        Uint8List.fromList(protocolBytes),
      );

      expect(protocolMessage.version, equals(2));
      expect(protocolMessage.payload['encryptionMethod'], equals('sealed'));
      expect(protocolMessage.cryptoHeader?.mode, equals(CryptoMode.sealedV1));
    },
  );

  test(
    'upgraded peer also uses sealed_v1 after legacy transport removal',
    () async {
      await contactRepository.saveContact(
        'recipient_sealed_upgraded',
        'Recipient Sealed Upgraded',
      );
      await contactRepository.updateNoiseSession(
        publicKey: 'recipient_sealed_upgraded',
        noisePublicKey: _generateNoiseStaticPublicKeyBase64(),
        sessionState: 'established',
      );
      SimpleCrypto.initializeConversation(
        'recipient_sealed_upgraded',
        'ble-write-test-sealed-upgraded-secret',
      );
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 2,
        peerKey: 'recipient_sealed_upgraded',
      );

      final captureWriteClient = _CaptureThenThrowCentralWriteClient();
      adapter = BleWriteAdapter(
        contactRepository: contactRepository,
        stateManagerProvider: () => stateManager,
        writeClient: captureWriteClient,
      );

      allowSevere(
        'Failed to send message: Exception: central boom after capture',
      );
      allowSevere('Stack trace');

      final result = await adapter.sendCentralMessage(
        centralManager: _FakeCentralManager(),
        connectedDevice: FakePeripheral(uuid: makeUuid(53)),
        messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(54)),
        recipientKey: 'recipient_sealed_upgraded',
        content: 'sealed upgraded fallback',
        mtuSize: 1024,
      );

      expect(result, isFalse);
      expect(captureWriteClient.lastCentralValue, isNotNull);

      final chunk = MessageChunk.fromBytes(
        captureWriteClient.lastCentralValue!,
      );
      final protocolBytes = base64.decode(chunk.content);
      final protocolMessage = ProtocolMessage.fromBytes(
        Uint8List.fromList(protocolBytes),
      );

      expect(protocolMessage.version, equals(2));
      expect(protocolMessage.payload['encryptionMethod'], equals('sealed'));
      expect(protocolMessage.cryptoHeader?.mode, equals(CryptoMode.sealedV1));
    },
  );

  test('peripheral send short-circuits when not in peripheral mode', () async {
    stateManager.peripheralMode = false;

    final result = await adapter.sendPeripheralMessage(
      peripheralManager: _FakePeripheralManager(),
      connectedCentral: FakeCentral(uuid: makeUuid(3)),
      messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(4)),
      senderKey: 'sender',
      content: 'hello',
      mtuSize: 185, // Realistic BLE MTU size
    );

    expect(result, isFalse);
    expect(writeClient.lastPeripheralValue, isNull);
  });
}

String _generateNoiseStaticPublicKeyBase64() {
  final dh = DHState()..generateKeyPair();
  final publicKey = dh.getPublicKey();
  dh.destroy();
  if (publicKey == null) {
    throw StateError('Failed to generate Noise static test key');
  }
  return base64.encode(publicKey);
}
