/// Phase 11.2 — Additional coverage for SecurityManager focusing on
/// encryption/decryption branches, sealed messages, binary payloads,
/// identity mapping, and Noise peer resolution.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/core/security/noise/models/noise_models.dart';
import 'package:pak_connect/core/exceptions/encryption_exception.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _MockSecureStorage extends Fake implements FlutterSecureStorage {
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
    if (value == null) {
      _storage.remove(key);
    } else {
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
  }) async => Map.unmodifiable(_storage);

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

  @override
  Future<bool> isCupertinoProtectedDataAvailable() async => true;

  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged =>
      const Stream.empty();
}

class _FakeContactRepo extends Fake implements IContactRepository {
  final Map<String, Contact?> byAnyId = {};
  final Map<String, String?> secrets = {};
  final List<MapEntry<String, SecurityLevel>> lvlUpdates = [];
  bool clearCalled = false;

  @override
  Future<Contact?> getContactByAnyId(String id) async => byAnyId[id];

  @override
  Future<String?> getCachedSharedSecret(String pk) async => secrets[pk];

  @override
  Future<void> updateContactSecurityLevel(String pk, SecurityLevel lv) async {
    lvlUpdates.add(MapEntry(pk, lv));
    final c = byAnyId[pk];
    if (c != null) {
      byAnyId[pk] = _contact(
        key: c.publicKey,
        trustStatus: c.trustStatus,
        securityLevel: lv,
        persistentPublicKey: c.persistentPublicKey,
        currentEphemeralId: c.currentEphemeralId,
        noisePublicKey: c.noisePublicKey,
      );
    }
  }

  @override
  Future<void> clearCachedSecrets(String pk) async {
    clearCalled = true;
    secrets.remove(pk);
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

// ---------------------------------------------------------------------------
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late _MockSecureStorage mockStorage;
  late _FakeContactRepo repo;
  late SecurityManager sm;
  late List<LogRecord> logs;
  late Set<String> allowedSevere;

  setUp(() async {
    logs = [];
    allowedSevere = {
      'ENCRYPT FAILED',
      'DECRYPT',
      'All methods failed',
      'Failed to initialize',
      'Noise service not initialized',
      'RESYNC FAILED',
      'Cannot send message',
      'ECDH encryption failed',
      'Encryption failed',
      'Cannot send binary',
      'Binary payload',
      'ECDH decryption',
      'Noise decryption',
      'sealed_v1',
    };
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((r) {
      logs.add(r);
      if (r.level >= Level.SEVERE) {
        final isSuppressed = allowedSevere.any((s) => r.message.contains(s));
        if (!isSuppressed) {
          fail('Unexpected SEVERE log: ${r.message}');
        }
      }
    });

    mockStorage = _MockSecureStorage();
    repo = _FakeContactRepo();
    sm = SecurityManager.instance;
    sm.shutdown(); // reset from prior tests
    await sm.initialize(secureStorage: mockStorage);
  });

  tearDown(() {
    sm.shutdown();
    SecurityManager.clearContactRepositoryResolver();
    Logger.root.clearListeners();
  });

  // -------------------------------------------------------------------------
  // getCurrentLevel — branch coverage
  // -------------------------------------------------------------------------
  group('SecurityManager.getCurrentLevel', () {
    test('empty publicKey returns LOW', () async {
      expect(await sm.getCurrentLevel('', repo), SecurityLevel.low);
    });

    test('unknown contact returns LOW', () async {
      expect(await sm.getCurrentLevel('unknown-pk', repo), SecurityLevel.low);
    });

    test('verified contact WITH ecdh secret returns HIGH', () async {
      repo.byAnyId['pk-high'] = _contact(
        key: 'pk-high',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.high,
      );
      repo.secrets['pk-high'] = 'shared-secret-value';

      final level = await sm.getCurrentLevel('pk-high', repo);
      expect(level, SecurityLevel.high);
    });

    test('verified contact WITHOUT ecdh secret falls to medium/low', () async {
      repo.byAnyId['pk-noe'] = _contact(
        key: 'pk-noe',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.high,
      );
      // No cached secret → hasECDH = false
      // No pairing key → hasPairing = false
      // No noise session → hasNoiseSession = false
      final level = await sm.getCurrentLevel('pk-noe', repo);
      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevelForUser delegates', () async {
      // Unknown user → LOW
      final level = await sm.getCurrentLevelForUser(UserId('uid-1'), repo);
      expect(level, SecurityLevel.low);
    });

    test('updates stored level when actual differs', () async {
      repo.byAnyId['pk-sync'] = _contact(
        key: 'pk-sync',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.high,
      );
      final level = await sm.getCurrentLevel('pk-sync', repo);
      // actual should be LOW (no pairing/ecdh/noise), stored was HIGH
      expect(level, SecurityLevel.low);
      expect(repo.lvlUpdates.any((e) => e.key == 'pk-sync'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // selectNoisePattern
  // -------------------------------------------------------------------------
  group('SecurityManager.selectNoisePattern', () {
    test('no contact → XX', () async {
      final (pattern, key) = await sm.selectNoisePattern('no-contact', repo);
      expect(pattern, NoisePattern.xx);
      expect(key, isNull);
    });

    test('LOW security → XX', () async {
      repo.byAnyId['pk-low'] = _contact(
        key: 'pk-low',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final (pattern, _) = await sm.selectNoisePattern('pk-low', repo);
      expect(pattern, NoisePattern.xx);
    });

    test('MEDIUM with valid 32-byte noisePublicKey → KK', () async {
      final fakeKey = base64.encode(List.filled(32, 0xAB));
      repo.byAnyId['pk-med'] = _contact(
        key: 'pk-med',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: fakeKey,
      );
      final (pattern, keyBytes) = await sm.selectNoisePattern('pk-med', repo);
      expect(pattern, NoisePattern.kk);
      expect(keyBytes, isNotNull);
      expect(keyBytes!.length, 32);
    });

    test('MEDIUM with invalid base64 key falls back to XX', () async {
      repo.byAnyId['pk-bad'] = _contact(
        key: 'pk-bad',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: '!not-base64!',
      );
      final (pattern, key) = await sm.selectNoisePattern('pk-bad', repo);
      expect(pattern, NoisePattern.xx);
      expect(key, isNull);
    });

    test('MEDIUM with wrong-length key falls back to XX', () async {
      final shortKey = base64.encode(List.filled(16, 0xCD));
      repo.byAnyId['pk-short'] = _contact(
        key: 'pk-short',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: shortKey,
      );
      final (pattern, _) = await sm.selectNoisePattern('pk-short', repo);
      expect(pattern, NoisePattern.xx);
    });

    test('selectNoisePatternForUser delegates', () async {
      final (pattern, _) = await sm.selectNoisePatternForUser(
        UserId('uid-2'),
        repo,
      );
      expect(pattern, NoisePattern.xx);
    });
  });

  // -------------------------------------------------------------------------
  // encryptMessageByType
  // -------------------------------------------------------------------------
  group('SecurityManager.encryptMessageByType', () {
    test('global encryption throws EncryptionException', () async {
      expect(
        () =>
            sm.encryptMessageByType('hello', 'pk', repo, EncryptionType.global),
        throwsA(isA<EncryptionException>()),
      );
    });

    test(
      'noise encryption without service throws EncryptionException',
      () async {
        sm.shutdown(); // clears noise service
        expect(
          () =>
              sm.encryptMessageByType('msg', 'pk', repo, EncryptionType.noise),
          throwsA(isA<EncryptionException>()),
        );
      },
    );

    test('ecdh encryption with no secret throws EncryptionException', () async {
      expect(
        () => sm.encryptMessageByType('msg', 'pk', repo, EncryptionType.ecdh),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // decryptMessageByType
  // -------------------------------------------------------------------------
  group('SecurityManager.decryptMessageByType', () {
    test('noise decrypt without service throws', () async {
      sm.shutdown();
      expect(
        () => sm.decryptMessageByType('data', 'pk', repo, EncryptionType.noise),
        throwsA(isA<Exception>()),
      );
    });

    test('pairing decrypt without conversation key throws', () async {
      expect(
        () => sm.decryptMessageByType(
          'data',
          'no-pairing-key',
          repo,
          EncryptionType.pairing,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('ecdh decrypt returns null → throws', () async {
      expect(
        () => sm.decryptMessageByType(
          'data',
          'no-ecdh-key',
          repo,
          EncryptionType.ecdh,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // decryptSealedMessage
  // -------------------------------------------------------------------------
  group('SecurityManager.decryptSealedMessage', () {
    test('non-sealedV1 mode throws ArgumentError', () async {
      final header = CryptoHeader(mode: CryptoMode.noiseV1);
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: 'ct',
          cryptoHeader: header,
          messageId: 'm1',
          senderId: 's1',
          recipientId: 'r1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing ephemeralPublicKey throws ArgumentError', () async {
      final header = CryptoHeader(mode: CryptoMode.sealedV1, nonce: 'abc');
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: 'ct',
          cryptoHeader: header,
          messageId: 'm1',
          senderId: 's1',
          recipientId: 'r1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing nonce throws ArgumentError', () async {
      final header = CryptoHeader(
        mode: CryptoMode.sealedV1,
        ephemeralPublicKey: 'abc',
      );
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: 'ct',
          cryptoHeader: header,
          messageId: 'm1',
          senderId: 's1',
          recipientId: 'r1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // encryptBinaryPayload
  // -------------------------------------------------------------------------
  group('SecurityManager.encryptBinaryPayload', () {
    test('global encryption throws EncryptionException', () async {
      // Force getEncryptionMethod to return global by having no noise/pairing/ecdh
      repo.byAnyId['pk-bin'] = _contact(
        key: 'pk-bin',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      expect(
        () => sm.encryptBinaryPayload(
          Uint8List.fromList([1, 2, 3]),
          'pk-bin',
          repo,
        ),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Identity mapping
  // -------------------------------------------------------------------------
  group('SecurityManager identity mapping', () {
    test('registerIdentityMapping and unregister are no-ops without crash', () {
      expect(
        () => sm.registerIdentityMapping(
          persistentPublicKey: 'ppk-1',
          ephemeralID: 'eph-1',
        ),
        returnsNormally,
      );
      expect(() => sm.unregisterIdentityMapping('ppk-1'), returnsNormally);
    });

    test('registerIdentityMappingForUser delegates', () {
      expect(
        () => sm.registerIdentityMappingForUser(
          persistentUserId: UserId('u1'),
          ephemeralID: 'e1',
        ),
        returnsNormally,
      );
      sm.unregisterIdentityMappingForUser(UserId('u1'));
    });

    test('hasEstablishedNoiseSession returns false for unknown peer', () {
      expect(sm.hasEstablishedNoiseSession('random-peer'), isFalse);
    });

    test('clearAllNoiseSessions does not throw', () {
      expect(() => sm.clearAllNoiseSessions(), returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // _resolveContactRepository
  // -------------------------------------------------------------------------
  group('SecurityManager contact repo resolution', () {
    test('configureContactRepositoryResolver enables resolution', () async {
      SecurityManager.configureContactRepositoryResolver(() => repo);
      // getCurrentLevel without explicit repo should resolve via config
      expect(await sm.getCurrentLevel('any-pk'), SecurityLevel.low);
    });

    test(
      'clearContactRepositoryResolver causes StateError on resolve',
      () async {
        SecurityManager.clearContactRepositoryResolver();
        expect(() => sm.getCurrentLevel('pk'), throwsA(isA<StateError>()));
      },
    );
  });

  // -------------------------------------------------------------------------
  // getEncryptionMethod — various levels
  // -------------------------------------------------------------------------
  group('SecurityManager.getEncryptionMethod', () {
    test('LOW with no noise session throws', () async {
      repo.byAnyId['pk-glo'] = _contact(
        key: 'pk-glo',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      expect(
        () => sm.getEncryptionMethod('pk-glo', repo),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('getEncryptionMethodForUser propagates missing active lane', () async {
      repo.byAnyId['uid-3'] = _contact(
        key: 'uid-3',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      expect(
        () => sm.getEncryptionMethodForUser(UserId('uid-3'), repo),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // encryptMessage / decryptMessage wrapper delegation
  // -------------------------------------------------------------------------
  group('SecurityManager.encryptMessage', () {
    test(
      'encryptMessage for global contact throws EncryptionException',
      () async {
        repo.byAnyId['pk-gm'] = _contact(
          key: 'pk-gm',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.low,
        );
        expect(
          () => sm.encryptMessage('hello', 'pk-gm', repo),
          throwsA(isA<EncryptionException>()),
        );
      },
    );

    test('encryptMessageForUser delegates', () async {
      repo.byAnyId['uid-4'] = _contact(
        key: 'uid-4',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      expect(
        () => sm.encryptMessageForUser('msg', UserId('uid-4'), repo),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  group('SecurityManager.decryptMessage', () {
    test('decryptMessage with all methods failing triggers resync', () async {
      repo.byAnyId['pk-fail'] = _contact(
        key: 'pk-fail',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      expect(
        () => sm.decryptMessage('garbage', 'pk-fail', repo),
        throwsA(isA<Exception>()),
      );
    });

    test('decryptMessageForUser delegates', () async {
      expect(
        () => sm.decryptMessageForUser('ct', UserId('uid-5'), repo),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // initialize — idempotent / re-init
  // -------------------------------------------------------------------------
  group('SecurityManager lifecycle', () {
    test('double initialize is idempotent', () async {
      // Already initialized in setUp
      await sm.initialize(secureStorage: mockStorage);
      expect(sm.noiseService, isNotNull);
    });

    test('shutdown nullifies noiseService', () {
      sm.shutdown();
      expect(sm.noiseService, isNull);
    });

    test('shutdown then re-initialize works', () async {
      sm.shutdown();
      await sm.initialize(secureStorage: mockStorage);
      expect(sm.noiseService, isNotNull);
    });
  });
}
