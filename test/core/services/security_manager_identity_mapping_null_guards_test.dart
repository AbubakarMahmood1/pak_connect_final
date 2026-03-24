// SecurityManager supplementary coverage
// Targets: pairing encrypt/decrypt paths, identity mapping null guards,
// MEDIUM+pairing getEncryptionMethod, non-EncryptionException wrapping

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/core/security/noise/models/noise_models.dart';

// ─── Fake Contact Repository ─────────────────────────────────────────

Contact _contact(String pk, {
 SecurityLevel level = SecurityLevel.low,
 TrustStatus trust = TrustStatus.newContact,
 String? persistentPublicKey,
 String? currentEphemeralId,
}) => Contact(publicKey: pk,
 persistentPublicKey: persistentPublicKey,
 currentEphemeralId: currentEphemeralId,
 displayName: 'Test',
 trustStatus: trust,
 securityLevel: level,
 firstSeen: DateTime.now(),
 lastSeen: DateTime.now(),
);

class _Repo extends Fake implements IContactRepository {
 Contact? contact;
 SecurityLevel storedLevel = SecurityLevel.low;
 String? cachedSecret;

 @override
 Future<Contact?> getContactByAnyId(String id) async => contact;

 @override
 Future<SecurityLevel> getContactSecurityLevel(String pk) async => storedLevel;

 @override
 Future<void> updateContactSecurityLevel(String pk,
 SecurityLevel level,
) async {
 storedLevel = level;
 }

 @override
 Future<String?> getCachedSharedSecret(String pk) async => cachedSecret;

 Future<void> clearSharedSecrets(String pk) async {}
}

void main() {
 Logger.root.level = Level.OFF;

 late SecurityManager sm;
 late _Repo repo;
 const pk = 'test-public-key-12345678';

 setUp(() {
 sm = SecurityManager();
 repo = _Repo();
 // Ensure a clean state: shutdown so _noiseService is null
 sm.shutdown();
 SimpleCrypto.clearAllConversationKeys();
 });

 tearDown(() {
 SimpleCrypto.clearAllConversationKeys();
 });

 group('SecurityManager — identity mapping null guards', () {
 test('registerIdentityMapping does not throw when noise null', () {
 // _noiseService is null after shutdown
 expect(() => sm.registerIdentityMapping(persistentPublicKey: 'pk1',
 ephemeralID: 'eph1',
),
 returnsNormally,
);
 });

 test('unregisterIdentityMapping does not throw when noise null', () {
 expect(() => sm.unregisterIdentityMapping('pk1'), returnsNormally);
 });

 test('registerIdentityMappingForUser delegates without error', () {
 expect(() => sm.registerIdentityMappingForUser(persistentUserId: const UserId('user1'),
 ephemeralID: 'eph1',
),
 returnsNormally,
);
 });

 test('unregisterIdentityMappingForUser delegates without error', () {
 expect(() => sm.unregisterIdentityMappingForUser(const UserId('user1')),
 returnsNormally,
);
 });
 });

 group('SecurityManager — pairing encryption path', () {
 test('encryptMessageByType pairing succeeds with conversation key',
 () async {
 await SimpleCrypto.restoreConversationKey(pk, 'some-secret-key-value');
 expect(SimpleCrypto.hasConversationKey(pk), isTrue);

 final encrypted = await sm.encryptMessageByType('hello world',
 pk,
 repo,
 EncryptionType.pairing,
);

 expect(encrypted, isNotEmpty);
 expect(encrypted, isNot('hello world'));
 },
);

 test('decryptMessageByType pairing round-trips', () async {
 await SimpleCrypto.restoreConversationKey(pk, 'round-trip-key');

 final encrypted = await sm.encryptMessageByType('secret message',
 pk,
 repo,
 EncryptionType.pairing,
);

 final decrypted = await sm.decryptMessageByType(encrypted,
 pk,
 repo,
 EncryptionType.pairing,
);

 expect(decrypted, 'secret message');
 });

 test('pairing decrypt without key throws', () async {
 // No conversation key set for this pk
 expect(() => sm.decryptMessageByType('encrypted-data',
 'no-key-pk',
 repo,
 EncryptionType.pairing,
),
 throwsA(isA<Exception>()),
);
 });
 });

 group('SecurityManager — getEncryptionMethod with pairing', () {
 test('MEDIUM with pairing key returns pairing method', () async {
 repo.contact = _contact(pk, level: SecurityLevel.medium);
 repo.storedLevel = SecurityLevel.medium;
 await SimpleCrypto.restoreConversationKey(pk, 'pairing-key');

 final method = await sm.getEncryptionMethod(pk, repo);

 expect(method.type, EncryptionType.pairing);
 });

 test('MEDIUM without pairing or noise throws', () async {
 repo.contact = _contact(pk, level: SecurityLevel.medium);
 repo.storedLevel = SecurityLevel.medium;

 expect(() => sm.getEncryptionMethod(pk, repo), throwsA(isA<Exception>()));
 });
 });

 group('SecurityManager — global encryption throws', () {
 test('encryptMessageByType with global type throws EncryptionException',
 () async {
 expect(() => sm.encryptMessageByType('message',
 pk,
 repo,
 EncryptionType.global,
),
 throwsA(isA<Exception>()),
);
 },
);
 });

 group('SecurityManager — noise encryption without service', () {
 test('encryptMessageByType noise without service throws', () async {
 expect(() =>
 sm.encryptMessageByType('message', pk, repo, EncryptionType.noise),
 throwsA(isA<Exception>()),
);
 });

 test('decryptMessageByType noise without service throws', () async {
 expect(() => sm.decryptMessageByType('data', pk, repo, EncryptionType.noise),
 throwsA(isA<Exception>()),
);
 });
 });

 group('SecurityManager — getCurrentLevel scenarios', () {
 test('empty publicKey returns LOW', () async {
 final level = await sm.getCurrentLevel('', repo);
 expect(level, SecurityLevel.low);
 });

 test('no contact returns LOW', () async {
 repo.contact = null;
 final level = await sm.getCurrentLevel(pk, repo);
 expect(level, SecurityLevel.low);
 });

 test('contact with pairing key returns MEDIUM', () async {
 repo.contact = _contact(pk, level: SecurityLevel.low);
 await SimpleCrypto.restoreConversationKey(pk, 'pairing-key');

 final level = await sm.getCurrentLevel(pk, repo);
 expect(level, SecurityLevel.medium);
 });

 test('contact with ECDH secret and verified trust returns HIGH', () async {
 repo.contact = _contact(pk,
 level: SecurityLevel.low,
 trust: TrustStatus.verified,
);
 repo.cachedSecret = 'ecdh-shared-secret';

 final level = await sm.getCurrentLevel(pk, repo);
 expect(level, SecurityLevel.high);
 });
 });

 group('SecurityManager — selectNoisePattern', () {
 test('returns XX for null contact', () async {
 repo.contact = null;
 final (pattern, key) = await sm.selectNoisePattern(pk, repo);
 expect(pattern, NoisePattern.xx);
 expect(key, isNull);
 });

 test('returns XX for LOW security contact', () async {
 repo.contact = _contact(pk, level: SecurityLevel.low);
 final (pattern, key) = await sm.selectNoisePattern(pk, repo);
 expect(pattern, NoisePattern.xx);
 expect(key, isNull);
 });

 test('returns XX for MEDIUM contact without noise key', () async {
 repo.contact = _contact(pk, level: SecurityLevel.medium);
 final (pattern, key) = await sm.selectNoisePattern(pk, repo);
 expect(pattern, NoisePattern.xx);
 expect(key, isNull);
 });
 });

 group('SecurityManager — singleton and resolver', () {
 test('hasEstablishedNoiseSession returns false when noise null', () {
 expect(sm.hasEstablishedNoiseSession('any-peer'), isFalse);
 });

 test('shutdown sets noiseService to null', () {
 sm.shutdown();
 expect(sm.noiseService, isNull);
 });

 test('clearAllNoiseSessions does not throw when noise null', () {
 expect(() => sm.clearAllNoiseSessions(), returnsNormally);
 });
 });

 group('SecurityManager — decryptMessage fallback chain', () {
 test('decryptMessage with pairing key round-trips via fallback', () async {
 repo.contact = _contact(pk, level: SecurityLevel.low);
 await SimpleCrypto.restoreConversationKey(pk, 'decrypt-key');

 // Encrypt directly with pairing type
 final encrypted = await sm.encryptMessageByType('hello',
 pk,
 repo,
 EncryptionType.pairing,
);

 // decryptMessage recalculates level to MEDIUM (pairing key present),
 // then tries methods in order; pairing should succeed.
 final decrypted = await sm.decryptMessage(encrypted, pk, repo);
 expect(decrypted, 'hello');
 });

 test('decryptMessage throws when all methods fail', () async {
 repo.contact = null; // no contact → LOW, no keys

 expect(() => sm.decryptMessage('invalid-cipher', pk, repo),
 throwsA(isA<Exception>()),
);
 });
 });
}
