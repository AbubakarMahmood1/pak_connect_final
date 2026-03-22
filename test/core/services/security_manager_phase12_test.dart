// Phase 12.9: SecurityManager supplementary coverage
// Targets: getEncryptionMethod fallback paths, decryptMessage, decryptBinaryPayload,
//          encryptBinaryPayload, encryptMessageByType, singleton, resolver config

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';

// ─── Fake Contact Repository ─────────────────────────────────────────

Contact _makeContact(String pk) => Contact(
  publicKey: pk,
  displayName: 'Test',
  trustStatus: TrustStatus.newContact,
  securityLevel: SecurityLevel.low,
  firstSeen: DateTime.now(),
  lastSeen: DateTime.now(),
);

class _FakeContactRepository extends Fake implements IContactRepository {
  Contact? _contact;
  SecurityLevel _securityLevel = SecurityLevel.low;
  String? _cachedSecret;
  bool clearSecretsCalled = false;
  bool updateLevelCalled = false;
  SecurityLevel? lastUpdatedLevel;

  void setContact(Contact? c) => _contact = c;
  void setSecurityLevel(SecurityLevel level) => _securityLevel = level;
  void setCachedSecret(String? secret) => _cachedSecret = secret;

  @override
  Future<Contact?> getContactByAnyId(String id) async => _contact;

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async =>
      _securityLevel;

  @override
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel level,
  ) async {
    updateLevelCalled = true;
    lastUpdatedLevel = level;
    _securityLevel = level;
  }

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async =>
      _cachedSecret;

  @override
  Future<void> clearCachedSecrets(String publicKey) async {
    clearSecretsCalled = true;
    _cachedSecret = null;
  }
}

void main() {
  Logger.root.level = Level.OFF;

  group('SecurityManager - getEncryptionMethod', () {
    late SecurityManager sm;
    late _FakeContactRepository repo;

    setUp(() {
      sm = SecurityManager();
      repo = _FakeContactRepository();
    });

    test('LOW level without Noise session throws', () async {
      repo.setSecurityLevel(SecurityLevel.low);
      repo.setContact(_makeContact('pk_low'));

      expect(
        () => sm.getEncryptionMethod('pk_low', repo),
        throwsA(isA<Exception>()),
      );
    });

    test('HIGH level without ECDH key downgrades', () async {
      // getCurrentLevel recalculates: verified + no ECDH → low
      repo.setSecurityLevel(SecurityLevel.high);
      repo.setCachedSecret(null);
      repo.setContact(
        Contact(
          publicKey: 'pk_high',
          displayName: 'Test',
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.high,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
      );

      expect(
        () => sm.getEncryptionMethod('pk_high', repo),
        throwsA(isA<Exception>()),
      );
    });

    test('MEDIUM level without pairing or Noise throws', () async {
      repo.setSecurityLevel(SecurityLevel.medium);
      repo.setContact(_makeContact('pk_med'));

      expect(
        () => sm.getEncryptionMethod('pk_med', repo),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'HIGH level with valid ECDH key and verified trust returns ecdh',
      () async {
        repo.setSecurityLevel(SecurityLevel.high);
        repo.setCachedSecret('some_shared_secret');
        repo.setContact(
          Contact(
            publicKey: 'pk_ecdh',
            displayName: 'Test',
            trustStatus: TrustStatus.verified,
            securityLevel: SecurityLevel.high,
            firstSeen: DateTime.now(),
            lastSeen: DateTime.now(),
          ),
        );

        final method = await sm.getEncryptionMethod('pk_ecdh', repo);
        expect(method.type, EncryptionType.ecdh);
      },
    );

    test('MEDIUM level with no pairing or noise throws', () async {
      repo.setSecurityLevel(SecurityLevel.medium);
      repo.setContact(_makeContact('pk_pair'));

      expect(
        () => sm.getEncryptionMethod('pk_pair', repo),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('SecurityManager - encryptMessageByType', () {
    late SecurityManager sm;
    late _FakeContactRepository repo;

    setUp(() {
      sm = SecurityManager();
      repo = _FakeContactRepository();
    });

    test('global encryption throws EncryptionException', () async {
      expect(
        () => sm.encryptMessageByType(
          'test message',
          'pk_global',
          repo,
          EncryptionType.global,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('noise encryption without service throws', () async {
      // If noise service is null, should throw
      // We don't initialize noise service here
      expect(
        () => sm.encryptMessageByType(
          'test',
          'pk_noise',
          repo,
          EncryptionType.noise,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('SecurityManager - decryptMessageByType', () {
    late SecurityManager sm;
    late _FakeContactRepository repo;

    setUp(() {
      sm = SecurityManager();
      repo = _FakeContactRepository();
    });

    test('global decryption uses legacy compatible path', () async {
      // SimpleCrypto.decryptLegacyCompatible should handle legacy plaintext markers.
      final encrypted = SimpleCrypto.encodeLegacyPlaintext('hello world');
      final decrypted = await sm.decryptMessageByType(
        encrypted,
        'pk_test',
        repo,
        EncryptionType.global,
      );
      expect(decrypted, 'hello world');
    });

    test('noise decryption without service throws', () async {
      // noise service is null in fresh SM (may have been initialized before)
      // This tests the null check - but SM is singleton, so noise may be set
      // We test that it at least attempts decryption
      expect(
        () => sm.decryptMessageByType(
          base64.encode([1, 2, 3]),
          'pk_test',
          repo,
          EncryptionType.noise,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('ecdh decryption returns null throws', () async {
      repo.setCachedSecret(null);
      expect(
        () => sm.decryptMessageByType(
          'encrypted_ecdh',
          'pk_test',
          repo,
          EncryptionType.ecdh,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('pairing decryption without key throws', () async {
      expect(
        () => sm.decryptMessageByType(
          'encrypted_pairing',
          'pk_test',
          repo,
          EncryptionType.pairing,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('SecurityManager - decryptMessage', () {
    late SecurityManager sm;
    late _FakeContactRepository repo;

    setUp(() {
      sm = SecurityManager();
      repo = _FakeContactRepository();
    });

    test('decryptMessage at LOW level tries methods in order', () async {
      repo.setSecurityLevel(SecurityLevel.low);
      repo.setContact(_makeContact('pk_dec'));

      final encrypted = SimpleCrypto.encodeLegacyPlaintext('secret message');
      final decrypted = await sm.decryptMessage(encrypted, 'pk_dec', repo);
      expect(decrypted, 'secret message');
    });
  });

  group('SecurityManager - decryptSealedMessage validation', () {
    late SecurityManager sm;

    setUp(() {
      sm = SecurityManager();
    });

    test('non-sealed mode throws ArgumentError', () async {
      // This is already tested in phase 11 but we verify the path
      expect(
        () => sm.decryptSealedMessage(
          encryptedMessage: 'data',
          cryptoHeader: const CryptoHeader(mode: CryptoMode.legacyGlobalV1),
          messageId: 'msg1',
          senderId: 'sender1',
          recipientId: 'recipient1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SecurityManager - hasEstablishedNoiseSession', () {
    test('returns false when noise service not initialized', () {
      final sm = SecurityManager();
      // If noise service hasn't been initialized for this peer
      expect(sm.hasEstablishedNoiseSession('unknown_peer'), isFalse);
    });
  });

  group('SecurityManager - singleton pattern', () {
    test('factory returns same instance', () {
      final sm1 = SecurityManager();
      final sm2 = SecurityManager();
      expect(identical(sm1, sm2), isTrue);
    });

    test('instance getter returns same as factory', () {
      final sm = SecurityManager();
      expect(identical(sm, SecurityManager.instance), isTrue);
    });
  });

  group('SecurityManager - configureContactRepositoryResolver', () {
    test('configure and clear resolver', () {
      SecurityManager.configureContactRepositoryResolver(
        () => _FakeContactRepository(),
      );
      SecurityManager.clearContactRepositoryResolver();
      // Should not throw
    });
  });

  group('SecurityManager - encryptBinaryPayload', () {
    late SecurityManager sm;
    late _FakeContactRepository repo;

    setUp(() {
      sm = SecurityManager();
      repo = _FakeContactRepository();
    });

    test('binary payload at LOW level without noise throws', () async {
      repo.setSecurityLevel(SecurityLevel.low);
      repo.setContact(_makeContact('pk_bin'));

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      // Binary payloads require non-global encryption
      expect(
        () => sm.encryptBinaryPayload(data, 'pk_bin', repo),
        throwsA(isA<Exception>()),
      );
    });

    test('binary payload with ECDH encrypts successfully', () async {
      repo.setSecurityLevel(SecurityLevel.high);
      repo.setCachedSecret('shared_secret_for_ecdh');
      repo.setContact(
        Contact(
          publicKey: 'pk_bin_ecdh',
          displayName: 'Test',
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.high,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
      );

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted = await sm.encryptBinaryPayload(
        data,
        'pk_bin_ecdh',
        repo,
      );
      expect(encrypted, isNotEmpty);
      expect(encrypted.length > data.length, isTrue);
    });
  });

  group('SecurityManager - decryptBinaryPayload', () {
    late SecurityManager sm;
    late _FakeContactRepository repo;

    setUp(() {
      sm = SecurityManager();
      repo = _FakeContactRepository();
    });

    test('binary payload ECDH decryption round-trips', () async {
      repo.setSecurityLevel(SecurityLevel.high);
      repo.setCachedSecret('shared_secret_for_bin');
      repo.setContact(
        Contact(
          publicKey: 'pk_bin_dec',
          displayName: 'Test',
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.high,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
      );

      final data = Uint8List.fromList([10, 20, 30, 40, 50]);
      final encrypted = await sm.encryptBinaryPayload(data, 'pk_bin_dec', repo);
      final decrypted = await sm.decryptBinaryPayload(
        encrypted,
        'pk_bin_dec',
        repo,
      );
      expect(decrypted, equals(data));
    });

    test('binary payload noise decryption without service throws', () async {
      repo.setSecurityLevel(SecurityLevel.high);
      repo.setCachedSecret(null);
      repo.setContact(_makeContact('pk_test'));
      final data = Uint8List.fromList([1, 2, 3]);
      // decryptBinaryPayload determines type internally via getEncryptionMethod
      // At LOW with no noise, uses global — but with garbage data it may throw
      expect(
        () => sm.decryptBinaryPayload(data, 'pk_test', repo),
        throwsA(isA<Exception>()),
      );
    });
  });
}
