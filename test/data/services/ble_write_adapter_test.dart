import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/core/security/ephemeral_key_manager.dart';
import 'package:pak_connect/core/services/simple_crypto.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_write_adapter.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import '../../helpers/ble/ble_fakes.dart';
import '../../helpers/ble/mock_ble_write_client.dart';

// Mock secure storage for testing
class _MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _storage[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _storage[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(_storage);

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _storage.containsKey(key);

  // Handle unused FlutterSecureStorage methods/properties
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  @override
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

void main() {
  late _FakeStateManager stateManager;
  late ContactRepository contactRepository;
  late FakeBleWriteClient writeClient;
  late BleWriteAdapter adapter;
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    // Initialize SimpleCrypto (needed for global AES encryption)
    SimpleCrypto.initialize();

    // Initialize SecurityManager with mock storage
    final mockStorage = _MockSecureStorage();
    await SecurityManager.instance.initialize(secureStorage: mockStorage);

    // Initialize EphemeralKeyManager
    await EphemeralKeyManager.initialize(
      'test-private-key-1234567890123456789012345678901234567890',
    );
  });

  tearDownAll(() {
    SecurityManager.instance.shutdown();
  });

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);

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
