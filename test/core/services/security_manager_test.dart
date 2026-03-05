import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/core/security/noise/models/noise_models.dart';
import 'package:pak_connect/core/exceptions/encryption_exception.dart';

// Mock secure storage for testing
class MockSecureStorage implements FlutterSecureStorage {
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
  }) async {
    return _storage[key];
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
    _storage.remove(key);
  }

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
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
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
  }) async {
    return _storage.containsKey(key);
  }

  // Unused FlutterSecureStorage methods
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeContactRepository extends Fake implements IContactRepository {
  final Map<String, Contact?> contactsByAnyId = <String, Contact?>{};
  final Map<String, String?> cachedSecrets = <String, String?>{};
  final List<MapEntry<String, SecurityLevel>> securityUpdates =
      <MapEntry<String, SecurityLevel>>[];

  @override
  Future<Contact?> getContactByAnyId(String identifier) async {
    return contactsByAnyId[identifier];
  }

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async {
    return cachedSecrets[publicKey];
  }

  @override
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    securityUpdates.add(MapEntry(publicKey, newLevel));
    final existing = contactsByAnyId[publicKey];
    if (existing != null) {
      contactsByAnyId[publicKey] = Contact(
        publicKey: existing.publicKey,
        persistentPublicKey: existing.persistentPublicKey,
        currentEphemeralId: existing.currentEphemeralId,
        displayName: existing.displayName,
        trustStatus: existing.trustStatus,
        securityLevel: newLevel,
        firstSeen: existing.firstSeen,
        lastSeen: existing.lastSeen,
        isFavorite: existing.isFavorite,
        noisePublicKey: existing.noisePublicKey,
      );
    }
  }

  @override
  Future<void> clearCachedSecrets(String publicKey) async {
    cachedSecrets.remove(publicKey);
  }
}

Contact _contact({
  required String key,
  required TrustStatus trustStatus,
  required SecurityLevel securityLevel,
  String? persistentPublicKey,
  String? currentEphemeralId,
  String? noisePublicKey,
}) {
  return Contact(
    publicKey: key,
    persistentPublicKey: persistentPublicKey,
    currentEphemeralId: currentEphemeralId,
    displayName: key,
    trustStatus: trustStatus,
    securityLevel: securityLevel,
    firstSeen: DateTime(2026, 1, 1),
    lastSeen: DateTime(2026, 1, 2),
    noisePublicKey: noisePublicKey,
  );
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
    await SecurityManager.instance.initialize(secureStorage: mockStorage);
  });

  tearDownAll(() {
    // Shutdown SecurityManager
    SecurityManager.instance.shutdown();
  });

  group('SecurityManager with Noise Integration', () {
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUp(() {
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      SimpleCrypto.resetDeprecatedWrapperUsageCounts();
    });

    tearDown(() {
      final severe = logRecords.where((l) => l.level >= Level.SEVERE);
      final unexpected = severe.where(
        (l) => !allowedSevere.any(
          (p) => p is String
              ? l.message.contains(p)
              : (p as RegExp).hasMatch(l.message),
        ),
      );
      expect(
        unexpected,
        isEmpty,
        reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
      );
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

      final wrapperUsage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
      expect(
        wrapperUsage['total'],
        equals(0),
        reason:
            'Deprecated SimpleCrypto wrappers were used unexpectedly: $wrapperUsage',
      );
    });

    test('initializes with Noise service', () {
      expect(SecurityManager.instance.noiseService, isNotNull);
      expect(
        SecurityManager.instance.noiseService!.getStaticPublicKeyData().length,
        equals(32),
      );
    });

    test('getIdentityFingerprint returns valid fingerprint', () {
      final fingerprint = SecurityManager.instance.noiseService!
          .getIdentityFingerprint();
      expect(fingerprint.length, equals(64)); // SHA-256 hex
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('can initialize twice (idempotent)', () async {
      final fingerprint1 = SecurityManager.instance.noiseService!
          .getIdentityFingerprint();

      await SecurityManager.instance.initialize(
        secureStorage: mockStorage,
      ); // Second init

      final fingerprint2 = SecurityManager.instance.noiseService!
          .getIdentityFingerprint();
      expect(fingerprint1, equals(fingerprint2));
    });

    test('Noise service is available for encryption', () async {
      // Verify Noise service is ready
      expect(SecurityManager.instance.noiseService, isNotNull);

      // Verify it can initiate handshakes
      final msg1 = await SecurityManager.instance.noiseService!
          .initiateHandshake('test_peer');
      expect(msg1, isNotNull);
      expect(msg1!.length, equals(32)); // First message in XX handshake
    });

    test('shutdown clears Noise service', () {
      SecurityManager.instance.shutdown();
      expect(SecurityManager.instance.noiseService, isNull);

      // Re-initialize for other tests
      SecurityManager.instance.initialize(secureStorage: mockStorage);
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

    test(
      'getCurrentLevel returns LOW for empty key and missing contact',
      () async {
        final repo = _FakeContactRepository();
        expect(
          await SecurityManager.instance.getCurrentLevel('', repo),
          SecurityLevel.low,
        );
        expect(
          await SecurityManager.instance.getCurrentLevel('missing-key', repo),
          SecurityLevel.low,
        );
      },
    );

    test(
      'getCurrentLevel promotes verified contact with cached secret to HIGH',
      () async {
        final repo = _FakeContactRepository()
          ..contactsByAnyId['peer-high'] = _contact(
            key: 'peer-high',
            trustStatus: TrustStatus.verified,
            securityLevel: SecurityLevel.low,
          )
          ..cachedSecrets['peer-high'] = 'shared-secret';

        final level = await SecurityManager.instance.getCurrentLevel(
          'peer-high',
          repo,
        );
        expect(level, SecurityLevel.high);
        expect(repo.securityUpdates.last.key, 'peer-high');
        expect(repo.securityUpdates.last.value, SecurityLevel.high);
      },
    );

    test('getCurrentLevel resolves MEDIUM when pairing key exists', () async {
      final repo = _FakeContactRepository()
        ..contactsByAnyId['peer-medium'] = _contact(
          key: 'peer-medium',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.low,
        );
      SimpleCrypto.initializeConversation('peer-medium', 'shared-medium');
      addTearDown(() => SimpleCrypto.clearConversationKey('peer-medium'));

      final level = await SecurityManager.instance.getCurrentLevel(
        'peer-medium',
        repo,
      );
      expect(level, SecurityLevel.medium);
    });

    test(
      'selectNoisePattern chooses KK with valid static key, XX otherwise',
      () async {
        final kkKey = base64.encode(List<int>.filled(32, 7));
        final repo = _FakeContactRepository()
          ..contactsByAnyId['peer-kk'] = _contact(
            key: 'peer-kk',
            trustStatus: TrustStatus.newContact,
            securityLevel: SecurityLevel.medium,
            noisePublicKey: kkKey,
          )
          ..contactsByAnyId['peer-bad'] = _contact(
            key: 'peer-bad',
            trustStatus: TrustStatus.newContact,
            securityLevel: SecurityLevel.medium,
            noisePublicKey: 'bad-key',
          );

        final kk = await SecurityManager.instance.selectNoisePattern(
          'peer-kk',
          repo,
        );
        expect(kk.$1, NoisePattern.kk);
        expect(kk.$2, isNotNull);
        expect(kk.$2!.length, 32);

        final xx = await SecurityManager.instance.selectNoisePattern(
          'peer-bad',
          repo,
        );
        expect(xx.$1, NoisePattern.xx);
        expect(xx.$2, isNull);
      },
    );

    test('getEncryptionMethod returns global for unknown contact', () async {
      final repo = _FakeContactRepository();
      final method = await SecurityManager.instance.getEncryptionMethod(
        'unknown-contact',
        repo,
      );
      expect(method.type, EncryptionType.global);
    });

    test(
      'getEncryptionMethod returns pairing when conversation key exists',
      () async {
        final repo = _FakeContactRepository()
          ..contactsByAnyId['peer-pairing'] = _contact(
            key: 'peer-pairing',
            trustStatus: TrustStatus.newContact,
            securityLevel: SecurityLevel.medium,
          );
        SimpleCrypto.initializeConversation('peer-pairing', 'shared-pairing');
        addTearDown(() => SimpleCrypto.clearConversationKey('peer-pairing'));

        final method = await SecurityManager.instance.getEncryptionMethod(
          'peer-pairing',
          repo,
        );
        expect(method.type, EncryptionType.pairing);
        expect(method.publicKey, 'peer-pairing');
      },
    );

    test('encryptMessageByType global throws EncryptionException', () async {
      final repo = _FakeContactRepository();
      allowedSevere.add('🔒 ENCRYPT FAILED: global');
      expect(
        () => SecurityManager.instance.encryptMessageByType(
          'hello',
          'peer-global',
          repo,
          EncryptionType.global,
        ),
        throwsA(isA<EncryptionException>()),
      );
    });

    test(
      'decryptSealedMessage validates header mode and required metadata',
      () async {
        await SecurityManager.instance.initialize(secureStorage: mockStorage);

        expect(
          () => SecurityManager.instance.decryptSealedMessage(
            encryptedMessage: 'AAAA',
            cryptoHeader: const CryptoHeader(mode: CryptoMode.noiseV1),
            messageId: 'm1',
            senderId: 'sender',
            recipientId: 'recipient',
          ),
          throwsA(isA<ArgumentError>()),
        );

        expect(
          () => SecurityManager.instance.decryptSealedMessage(
            encryptedMessage: 'AAAA',
            cryptoHeader: const CryptoHeader(mode: CryptoMode.sealedV1),
            messageId: 'm2',
            senderId: 'sender',
            recipientId: 'recipient',
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}
