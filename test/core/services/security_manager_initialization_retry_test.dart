import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/noise_encryption_service.dart';
import 'package:pak_connect/core/services/security_manager.dart';

class _MemorySecureStorage extends Fake implements FlutterSecureStorage {
  _MemorySecureStorage({this.failReads = false, this.failOnWriteNumber});

  final bool failReads;
  final int? failOnWriteNumber;
  final Map<String, String> _values = <String, String>{};
  int _writeCount = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReads) {
      throw StateError('secure storage unavailable');
    }
    return _values[key];
  }

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
    _writeCount++;
    if (_writeCount == failOnWriteNumber) {
      throw StateError('secure storage write unavailable');
    }
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

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
    _values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SecurityManager.instance.shutdown);
  tearDown(SecurityManager.instance.shutdown);

  test('failed Noise initialization remains retryable', () async {
    final manager = SecurityManager.instance;

    await expectLater(
      manager.initialize(secureStorage: _MemorySecureStorage(failReads: true)),
      throwsA(isA<StateError>()),
    );
    expect(manager.noiseService, isNull);

    await manager.initialize(secureStorage: _MemorySecureStorage());

    expect(manager.noiseService, isNotNull);
    expect(
      () => manager.noiseService!.getIdentityFingerprint(),
      returnsNormally,
    );
  });

  test(
    'partial Noise identity is zeroized when key persistence fails',
    () async {
      final service = NoiseEncryptionService(
        secureStorage: _MemorySecureStorage(failOnWriteNumber: 2),
      );

      await expectLater(service.initialize(), throwsA(isA<StateError>()));

      expect(service.debugIsStaticPrivateKeyZeroized, isTrue);
    },
  );
}
