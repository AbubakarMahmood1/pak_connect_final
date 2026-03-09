/// Phase 13b — SecurityManager additional coverage.
///
/// Targets uncovered branches:
///   - registerIdentityMapping when noise service is null
///   - unregisterIdentityMapping when noise service is null
///   - registerIdentityMappingForUser / unregisterIdentityMappingForUser
///   - getCurrentLevelForUser wrapper
///   - selectNoisePattern: null contact, LOW, MEDIUM with invalid key,
///     MEDIUM with valid 32-byte key
///   - selectNoisePatternForUser wrapper
///   - getEncryptionMethodForUser wrapper
///   - encryptMessageForUser wrapper
///   - decryptMessageForUser wrapper
///   - encryptMessageByType global throws EncryptionException
///   - encryptMessageByType non-EncryptionException wrapping
///   - decryptSealedMessage: wrong mode throws ArgumentError,
///     missing ephemeral key, missing nonce
///   - _resolveContactRepository without resolver throws StateError
///   - _getLevelDescription all branches
///   - _getMethodsForLevel all branches
///   - hasEstablishedNoiseSession when noise null
///   - configureContactRepositoryResolver and clearContactRepositoryResolver
///   - getCurrentLevel empty publicKey
///   - getCurrentLevel contact not found
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/exceptions/encryption_exception.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
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
  }) async =>
      _storage[key];

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
  }) async =>
      Map.unmodifiable(_storage);

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
  }) async =>
      _storage.containsKey(key);

  @override
  Future<bool> isCupertinoProtectedDataAvailable() async => true;

  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged =>
      const Stream.empty();
}

class _FakeRepo extends Fake implements IContactRepository {
  final Map<String, Contact?> byAnyId = {};
  final Map<String, String?> secrets = {};
  final List<MapEntry<String, SecurityLevel>> lvlUpdates = [];
  bool clearCalled = false;

  @override
  Future<Contact?> getContactByAnyId(String id) async => byAnyId[id];

  @override
  Future<String?> getCachedSharedSecret(String pk) async => secrets[pk];

  @override
  Future<void> updateContactSecurityLevel(
    String pk,
    SecurityLevel lv,
  ) async {
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
  late _FakeRepo repo;
  late SecurityManager sm;

  setUp(() async {
    Logger.root.level = Level.OFF;
    mockStorage = _MockSecureStorage();
    repo = _FakeRepo();
    sm = SecurityManager.instance;
    sm.shutdown();
    SimpleCrypto.clearAllConversationKeys();
    await sm.initialize(secureStorage: mockStorage);
  });

  tearDown(() {
    sm.shutdown();
    SimpleCrypto.clearAllConversationKeys();
    SecurityManager.clearContactRepositoryResolver();
    Logger.root.clearListeners();
  });

  // -------------------------------------------------------------------------
  // hasEstablishedNoiseSession — with and without noise
  // -------------------------------------------------------------------------
  group('hasEstablishedNoiseSession', () {
    test('returns false when noise service is initialized but no session', () {
      expect(sm.hasEstablishedNoiseSession('nonexistent-peer'), isFalse);
    });

    test('returns false when noise service is null (shutdown)', () {
      sm.shutdown();
      expect(sm.hasEstablishedNoiseSession('any-peer'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // registerIdentityMapping — when noise service is null
  // -------------------------------------------------------------------------
  group('registerIdentityMapping — noise null', () {
    test('does not throw when noise service is null', () {
      sm.shutdown();
      // Should log warning but not throw
      sm.registerIdentityMapping(
        persistentPublicKey: 'persistent-key',
        ephemeralID: 'eph-id',
      );
    });

    test('succeeds when noise service is initialized', () {
      sm.registerIdentityMapping(
        persistentPublicKey: 'persistent-key',
        ephemeralID: 'eph-id',
      );
      // No exception means success
    });
  });

  // -------------------------------------------------------------------------
  // unregisterIdentityMapping — when noise service is null
  // -------------------------------------------------------------------------
  group('unregisterIdentityMapping — noise null', () {
    test('does not throw when noise service is null', () {
      sm.shutdown();
      sm.unregisterIdentityMapping('some-key');
    });

    test('succeeds when noise service is initialized', () {
      sm.unregisterIdentityMapping('some-key');
    });
  });

  // -------------------------------------------------------------------------
  // Typed overloads (UserId adapters)
  // -------------------------------------------------------------------------
  group('UserId adapter methods', () {
    test('registerIdentityMappingForUser delegates to registerIdentityMapping', () {
      sm.registerIdentityMappingForUser(
        persistentUserId: UserId('user-persistent'),
        ephemeralID: 'eph-user',
      );
      // No exception = success
    });

    test('unregisterIdentityMappingForUser delegates', () {
      sm.unregisterIdentityMappingForUser(UserId('user-persistent'));
    });

    test('getCurrentLevelForUser delegates', () async {
      repo.byAnyId['user-pk'] = _contact(
        key: 'user-pk',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final level = await sm.getCurrentLevelForUser(UserId('user-pk'), repo);
      expect(level, SecurityLevel.low);
    });

    test('getEncryptionMethodForUser delegates', () async {
      repo.byAnyId['user-em'] = _contact(
        key: 'user-em',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final method = await sm.getEncryptionMethodForUser(UserId('user-em'), repo);
      // LOW without noise session → global
      expect(method.type, EncryptionType.global);
    });
  });

  // -------------------------------------------------------------------------
  // getCurrentLevel — empty publicKey
  // -------------------------------------------------------------------------
  group('getCurrentLevel — edge cases', () {
    test('empty publicKey returns LOW', () async {
      final level = await sm.getCurrentLevel('', repo);
      expect(level, SecurityLevel.low);
    });

    test('contact not found returns LOW', () async {
      final level = await sm.getCurrentLevel('nonexistent-key-123', repo);
      expect(level, SecurityLevel.low);
    });

    test('verified contact with ECDH secret returns HIGH', () async {
      repo.byAnyId['pk-high'] = _contact(
        key: 'pk-high',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.high,
      );
      repo.secrets['pk-high'] = 'ecdh-secret';
      final level = await sm.getCurrentLevel('pk-high', repo);
      expect(level, SecurityLevel.high);
    });

    test('contact with no secrets returns LOW', () async {
      repo.byAnyId['pk-none'] = _contact(
        key: 'pk-none',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final level = await sm.getCurrentLevel('pk-none', repo);
      expect(level, SecurityLevel.low);
    });
  });

  // -------------------------------------------------------------------------
  // selectNoisePattern
  // -------------------------------------------------------------------------
  group('selectNoisePattern', () {
    test('null contact returns XX pattern', () async {
      final (pattern, key) = await sm.selectNoisePattern('nonexistent', repo);
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });

    test('LOW security contact returns XX', () async {
      repo.byAnyId['pk-low-pat'] = _contact(
        key: 'pk-low-pat',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final (pattern, key) = await sm.selectNoisePattern('pk-low-pat', repo);
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });

    test('MEDIUM contact with valid 32-byte noisePublicKey returns KK', () async {
      final validKey = base64.encode(List.filled(32, 0xAA));
      repo.byAnyId['pk-kk'] = _contact(
        key: 'pk-kk',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.medium,
      );
      // Need pairing key to make getCurrentLevel calculate MEDIUM
      await SimpleCrypto.restoreConversationKey('pk-kk', 'pair-key');
      repo.byAnyId['pk-kk'] = _contact(
        key: 'pk-kk',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: validKey,
      );
      final (pattern, key) = await sm.selectNoisePattern('pk-kk', repo);
      expect(pattern.name, 'kk');
      expect(key, isNotNull);
      expect(key!.length, 32);
    });

    test('MEDIUM contact with invalid base64 noisePublicKey falls back to XX', () async {
      repo.byAnyId['pk-inv'] = _contact(
        key: 'pk-inv',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: 'not-valid-base64!!!',
      );
      await SimpleCrypto.restoreConversationKey('pk-inv', 'pair-key');
      final (pattern, key) = await sm.selectNoisePattern('pk-inv', repo);
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });

    test('MEDIUM contact with wrong-length key falls back to XX', () async {
      final shortKey = base64.encode(List.filled(16, 0xBB)); // 16 bytes, not 32
      repo.byAnyId['pk-short'] = _contact(
        key: 'pk-short',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: shortKey,
      );
      await SimpleCrypto.restoreConversationKey('pk-short', 'pair-key');
      final (pattern, key) = await sm.selectNoisePattern('pk-short', repo);
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });

    test('MEDIUM contact with null noisePublicKey returns XX', () async {
      repo.byAnyId['pk-null-nk'] = _contact(
        key: 'pk-null-nk',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: null,
      );
      await SimpleCrypto.restoreConversationKey('pk-null-nk', 'pair-key');
      final (pattern, key) = await sm.selectNoisePattern('pk-null-nk', repo);
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });

    test('MEDIUM contact with empty noisePublicKey returns XX', () async {
      repo.byAnyId['pk-empty-nk'] = _contact(
        key: 'pk-empty-nk',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.medium,
        noisePublicKey: '',
      );
      await SimpleCrypto.restoreConversationKey('pk-empty-nk', 'pair-key');
      final (pattern, key) = await sm.selectNoisePattern('pk-empty-nk', repo);
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });

    test('selectNoisePatternForUser delegates', () async {
      final (pattern, key) = await sm.selectNoisePatternForUser(
        UserId('nonexistent'),
        repo,
      );
      expect(pattern.name, 'xx');
      expect(key, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // encryptMessageByType — global path throws
  // -------------------------------------------------------------------------
  group('encryptMessageByType — global', () {
    test('global type throws EncryptionException', () async {
      expect(
        () => sm.encryptMessageByType('msg', 'pk', repo, EncryptionType.global),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // decryptMessageByType — pairing no key throws
  // -------------------------------------------------------------------------
  group('decryptMessageByType — pairing no key', () {
    test('pairing decrypt with no key throws', () async {
      expect(
        () => sm.decryptMessageByType(
          'encrypted-data',
          'pk-no-pair',
          repo,
          EncryptionType.pairing,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // decryptMessageByType — ecdh returns null
  // -------------------------------------------------------------------------
  group('decryptMessageByType — ecdh null result', () {
    test('ecdh decrypt returning null throws', () async {
      expect(
        () => sm.decryptMessageByType(
          'bad-data',
          'pk-ecdh-bad',
          repo,
          EncryptionType.ecdh,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // decryptSealedMessage — argument validation
  // -------------------------------------------------------------------------
  group('decryptSealedMessage — argument validation', () {
    test('wrong mode throws ArgumentError', () async {
      final header = CryptoHeader(mode: CryptoMode.noiseV1);
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: 'data',
          cryptoHeader: header,
          messageId: 'msg-1',
          senderId: 'sender-id-1234567890',
          recipientId: 'recipient-id-1234567890',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing ephemeral public key throws ArgumentError', () async {
      final header = CryptoHeader(
        mode: CryptoMode.sealedV1,
        ephemeralPublicKey: null,
        nonce: base64.encode(List.filled(24, 0xBB)),
      );
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: base64.encode([1, 2, 3]),
          cryptoHeader: header,
          messageId: 'msg-1',
          senderId: 'sender-id-1234567890',
          recipientId: 'recipient-id-1234567890',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty ephemeral public key throws ArgumentError', () async {
      final header = CryptoHeader(
        mode: CryptoMode.sealedV1,
        ephemeralPublicKey: '',
        nonce: base64.encode(List.filled(24, 0xBB)),
      );
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: base64.encode([1, 2, 3]),
          cryptoHeader: header,
          messageId: 'msg-1',
          senderId: 'sender-id-1234567890',
          recipientId: 'recipient-id-1234567890',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing nonce throws ArgumentError', () async {
      final header = CryptoHeader(
        mode: CryptoMode.sealedV1,
        ephemeralPublicKey: base64.encode(List.filled(32, 0xAA)),
        nonce: null,
      );
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: base64.encode([1, 2, 3]),
          cryptoHeader: header,
          messageId: 'msg-1',
          senderId: 'sender-id-1234567890',
          recipientId: 'recipient-id-1234567890',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty nonce throws ArgumentError', () async {
      final header = CryptoHeader(
        mode: CryptoMode.sealedV1,
        ephemeralPublicKey: base64.encode(List.filled(32, 0xAA)),
        nonce: '',
      );
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: base64.encode([1, 2, 3]),
          cryptoHeader: header,
          messageId: 'msg-1',
          senderId: 'sender-id-1234567890',
          recipientId: 'recipient-id-1234567890',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('noise service null throws StateError', () async {
      sm.shutdown();
      final header = CryptoHeader(
        mode: CryptoMode.sealedV1,
        ephemeralPublicKey: base64.encode(List.filled(32, 0xAA)),
        nonce: base64.encode(List.filled(24, 0xBB)),
      );
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: base64.encode([1, 2, 3]),
          cryptoHeader: header,
          messageId: 'msg-1',
          senderId: 'sender-id-1234567890',
          recipientId: 'recipient-id-1234567890',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // _resolveContactRepository — without resolver
  // -------------------------------------------------------------------------
  group('_resolveContactRepository — no resolver', () {
    test('throws StateError when no repo and no resolver', () async {
      SecurityManager.clearContactRepositoryResolver();
      expect(
        () => sm.getCurrentLevel('any-key'),
        throwsA(isA<StateError>()),
      );
    });

    test('uses resolver when configured', () async {
      SecurityManager.configureContactRepositoryResolver(() => repo);
      repo.byAnyId['resolved-pk'] = _contact(
        key: 'resolved-pk',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final level = await sm.getCurrentLevel('resolved-pk');
      expect(level, SecurityLevel.low);
    });
  });

  // -------------------------------------------------------------------------
  // initialize — already initialized
  // -------------------------------------------------------------------------
  group('initialize — idempotent', () {
    test('second initialize does nothing', () async {
      // sm is already initialized in setUp
      await sm.initialize(secureStorage: mockStorage);
      // No error, just early return
      expect(sm.noiseService, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // clearAllNoiseSessions
  // -------------------------------------------------------------------------
  group('clearAllNoiseSessions', () {
    test('does not throw when noise service is initialized', () {
      sm.clearAllNoiseSessions();
      // Verify no established sessions after clear
      expect(sm.hasEstablishedNoiseSession('any-peer'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // shutdown
  // -------------------------------------------------------------------------
  group('shutdown', () {
    test('nullifies noise service', () {
      sm.shutdown();
      expect(sm.noiseService, isNull);
    });

    test('shutdown is idempotent', () {
      sm.shutdown();
      sm.shutdown();
      expect(sm.noiseService, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // getEncryptionMethod — LOW without noise session → global
  // -------------------------------------------------------------------------
  group('getEncryptionMethod — LOW fallback to global', () {
    test('LOW with no noise session returns global', () async {
      repo.byAnyId['pk-low-g'] = _contact(
        key: 'pk-low-g',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final method = await sm.getEncryptionMethod('pk-low-g', repo);
      expect(method.type, EncryptionType.global);
    });
  });

  // -------------------------------------------------------------------------
  // encryptBinaryPayload — global throws
  // -------------------------------------------------------------------------
  group('encryptBinaryPayload — global path', () {
    test('global encryption for binary throws EncryptionException', () async {
      repo.byAnyId['pk-bin-g'] = _contact(
        key: 'pk-bin-g',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
      );
      final data = Uint8List.fromList([1, 2, 3]);
      expect(
        () => sm.encryptBinaryPayload(data, 'pk-bin-g', repo),
        throwsA(isA<EncryptionException>()),
      );
    });
  });
}
