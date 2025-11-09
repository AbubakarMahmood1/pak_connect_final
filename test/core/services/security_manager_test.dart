import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Mock secure storage for testing
class MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _storage[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  // Unused FlutterSecureStorage methods
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Initialize sqflite_ffi for testing
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late MockSecureStorage mockStorage;

  setUpAll(() async {
    // Initialize SecurityManager with mock storage
    mockStorage = MockSecureStorage();
    await SecurityManager.initialize(secureStorage: mockStorage);
  });

  tearDownAll(() {
    // Shutdown SecurityManager
    SecurityManager.shutdown();
  });

  group('SecurityManager with Noise Integration', () {
    test('initializes with Noise service', () {
      expect(SecurityManager.noiseService, isNotNull);
      expect(
        SecurityManager.noiseService!.getStaticPublicKeyData().length,
        equals(32),
      );
    });

    test('getIdentityFingerprint returns valid fingerprint', () {
      final fingerprint = SecurityManager.noiseService!
          .getIdentityFingerprint();
      expect(fingerprint.length, equals(64)); // SHA-256 hex
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('can initialize twice (idempotent)', () async {
      final fingerprint1 = SecurityManager.noiseService!
          .getIdentityFingerprint();

      await SecurityManager.initialize(
        secureStorage: mockStorage,
      ); // Second init

      final fingerprint2 = SecurityManager.noiseService!
          .getIdentityFingerprint();
      expect(fingerprint1, equals(fingerprint2));
    });

    test('Noise service is available for encryption', () async {
      // Verify Noise service is ready
      expect(SecurityManager.noiseService, isNotNull);

      // Verify it can initiate handshakes
      final msg1 = await SecurityManager.noiseService!.initiateHandshake(
        'test_peer',
      );
      expect(msg1, isNotNull);
      expect(msg1!.length, equals(32)); // First message in XX handshake
    });

    test('shutdown clears Noise service', () {
      SecurityManager.shutdown();
      expect(SecurityManager.noiseService, isNull);

      // Re-initialize for other tests
      SecurityManager.initialize(secureStorage: mockStorage);
    });

    test('EncryptionMethod factories create correct types', () {
      final ecdh = EncryptionMethod.ecdh('key1');
      expect(ecdh.type, equals(EncryptionType.ecdh));
      expect(ecdh.publicKey, equals('key1'));

      final noise = EncryptionMethod.noise('key2');
      expect(noise.type, equals(EncryptionType.noise));
      expect(noise.publicKey, equals('key2'));

      final pairing = EncryptionMethod.pairing('key3');
      expect(pairing.type, equals(EncryptionType.pairing));
      expect(pairing.publicKey, equals('key3'));

      final global = EncryptionMethod.global();
      expect(global.type, equals(EncryptionType.global));
      expect(global.publicKey, isNull);
    });

    test('SecurityLevel enum values', () {
      expect(SecurityLevel.values.length, equals(3));
      expect(SecurityLevel.low.name, equals('low'));
      expect(SecurityLevel.medium.name, equals('medium'));
      expect(SecurityLevel.high.name, equals('high'));
    });

    test('EncryptionType enum includes noise', () {
      expect(EncryptionType.values.contains(EncryptionType.noise), isTrue);
      expect(EncryptionType.noise.name, equals('noise'));
    });
  });
}
