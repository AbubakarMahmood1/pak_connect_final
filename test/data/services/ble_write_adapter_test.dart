import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
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

  void clearAllNoiseSessions() => _noiseSessions.clear();

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {
    _noiseSessions.add(ephemeralID);
  }

  @override
  void unregisterIdentityMapping(String persistentPublicKey) {
    _noiseSessions.remove(persistentPublicKey);
  }

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async {
    if (_noiseSessions.contains(publicKey)) {
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
    if (_noiseSessions.contains(publicKey)) {
      return EncryptionMethod.noise(publicKey);
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
    if (_noiseSessions.contains(publicKey)) {
      return 'noise:$message';
    }
    if (SimpleCrypto.hasConversationKey(publicKey)) {
      return SimpleCrypto.encryptForConversation(message, publicKey);
    }
    throw _FakeEncryptionException('no encryption context for $publicKey');
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
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async {
    if (!_noiseSessions.contains(publicKey) &&
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
    if (!_noiseSessions.contains(publicKey) &&
        !SimpleCrypto.hasConversationKey(publicKey)) {
      throw _FakeEncryptionException('no binary decryption context');
    }
    return data;
  }

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) =>
      _noiseSessions.contains(peerSessionId);
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
    SecurityServiceLocator.registerFallback(securityService);
  });

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);

    // Keep each test independent from previous key/session state.
    SimpleCrypto.clearAllConversationKeys();
    securityService.clearAllNoiseSessions();

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
  });

  test('central send returns false when write client throws', () async {
    await contactRepository.saveContact('recipient', 'Recipient');
    SimpleCrypto.initializeConversation('recipient', 'ble-write-test-secret');

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
