import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../../test_helpers/test_setup.dart';

/// Supplementary tests for ContactRepository
/// Targets: statistics, favorites, ephemeral/persistent lookups,
/// shared secret caching, seed bytes round-trip, edge cases
void main() {
 late List<LogRecord> logRecords;
 late Set<String> allowedSevere;

 setUpAll(() async {
 await TestSetup.initializeTestEnvironment(dbLabel: 'contact_repository_phase12',
);
 });

 setUp(() async {
 logRecords = [];
 allowedSevere = {};
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logRecords.add);
 await TestSetup.fullDatabaseReset();
 });

 tearDown(() {
 final severeErrors = logRecords
 .where((log) => log.level >= Level.SEVERE)
 .where((log) =>
 !allowedSevere.any((pattern) => log.message.contains(pattern)),
)
 .toList();
 expect(severeErrors,
 isEmpty,
 reason:
 'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
);
 });

 tearDownAll(() async {
 await DatabaseHelper.deleteDatabase();
 });

 group('ContactRepository — Statistics Methods', () {
 test('getContactCount returns 0 for empty DB', () async {
 final repo = ContactRepository();
 expect(await repo.getContactCount(), 0);
 });

 test('getContactCount returns correct count', () async {
 final repo = ContactRepository();
 await repo.saveContact('stats_k1', 'User 1');
 await repo.saveContact('stats_k2', 'User 2');
 await repo.saveContact('stats_k3', 'User 3');

 expect(await repo.getContactCount(), 3);
 });

 test('getVerifiedContactCount returns 0 when none verified', () async {
 final repo = ContactRepository();
 await repo.saveContact('v_k1', 'User 1');
 await repo.saveContact('v_k2', 'User 2');

 expect(await repo.getVerifiedContactCount(), 0);
 });

 test('getVerifiedContactCount counts only verified', () async {
 final repo = ContactRepository();
 await repo.saveContact('v_k3', 'User 3');
 await repo.saveContact('v_k4', 'User 4');
 await repo.markContactVerified('v_k3');

 expect(await repo.getVerifiedContactCount(), 1);
 });

 test('getContactsBySecurityLevel returns level distribution', () async {
 final repo = ContactRepository();
 await repo.saveContact('sl_1', 'Low User');
 await repo.saveContactWithSecurity('sl_2', 'Med User', SecurityLevel.medium);
 await repo.saveContactWithSecurity('sl_3', 'High User', SecurityLevel.high);
 await repo.saveContact('sl_4', 'Low User 2');

 final levels = await repo.getContactsBySecurityLevel();
 expect(levels[SecurityLevel.low], 2);
 expect(levels[SecurityLevel.medium], 1);
 expect(levels[SecurityLevel.high], 1);
 });

 test('getRecentlyActiveContactCount returns recent contacts', () async {
 final repo = ContactRepository();
 // Contacts saved "now" are active within the last 7 days
 await repo.saveContact('ra_1', 'Active 1');
 await repo.saveContact('ra_2', 'Active 2');

 final count = await repo.getRecentlyActiveContactCount();
 expect(count, 2);
 });
 });

 group('ContactRepository — Ephemeral & Persistent Lookups', () {
 test('getContactByCurrentEphemeralId returns null when not found', () async {
 final repo = ContactRepository();
 final contact = await repo.getContactByCurrentEphemeralId('no_such_id');
 expect(contact, isNull);
 });

 test('getContactByCurrentEphemeralId finds contact', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('eph_pk',
 'Ephemeral User',
 SecurityLevel.low,
 currentEphemeralId: 'eph_session_123',
);

 final contact = await repo.getContactByCurrentEphemeralId('eph_session_123');
 expect(contact, isNotNull);
 expect(contact!.displayName, 'Ephemeral User');
 });

 test('getContactByPersistentKey returns null when not found', () async {
 final repo = ContactRepository();
 final contact = await repo.getContactByPersistentKey('no_such_persistent');
 expect(contact, isNull);
 });

 test('getContactByPersistentKey finds contact', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('pers_pk',
 'Persistent User',
 SecurityLevel.medium,
 persistentPublicKey: 'persistent_key_abc',
);

 final contact = await repo.getContactByPersistentKey('persistent_key_abc');
 expect(contact, isNotNull);
 expect(contact!.displayName, 'Persistent User');
 });

 test('getContactByAnyId finds by publicKey', () async {
 final repo = ContactRepository();
 await repo.saveContact('any_pk', 'AnyId User');

 final contact = await repo.getContactByAnyId('any_pk');
 expect(contact, isNotNull);
 expect(contact!.displayName, 'AnyId User');
 });

 test('getContactByAnyId finds by persistentPublicKey', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('any_pk_2',
 'Persistent Lookup',
 SecurityLevel.medium,
 persistentPublicKey: 'persistent_any_key',
);

 final contact = await repo.getContactByAnyId('persistent_any_key');
 expect(contact, isNotNull);
 expect(contact!.displayName, 'Persistent Lookup');
 });

 test('getContactByAnyId finds by currentEphemeralId', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('any_pk_3',
 'Ephemeral Lookup',
 SecurityLevel.low,
 currentEphemeralId: 'eph_any_session',
);

 final contact = await repo.getContactByAnyId('eph_any_session');
 expect(contact, isNotNull);
 expect(contact!.displayName, 'Ephemeral Lookup');
 });

 test('getContactByAnyId returns null when not found anywhere', () async {
 final repo = ContactRepository();
 await repo.saveContact('some_key', 'Some User');

 final contact = await repo.getContactByAnyId('totally_unknown');
 expect(contact, isNull);
 });
 });

 group('ContactRepository — updateContactEphemeralId', () {
 test('updates ephemeral ID for existing contact', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('upd_eph_pk',
 'Eph Update User',
 SecurityLevel.low,
 currentEphemeralId: 'old_eph',
);

 await repo.updateContactEphemeralId('upd_eph_pk', 'new_eph_456');

 final contact = await repo.getContactByCurrentEphemeralId('new_eph_456');
 expect(contact, isNotNull);
 expect(contact!.publicKey, 'upd_eph_pk');

 // Old ephemeral should no longer match
 final old = await repo.getContactByCurrentEphemeralId('old_eph');
 expect(old, isNull);
 });
 });

 group('ContactRepository — Favorites Extended', () {
 test('markContactFavorite on non-existent contact is no-op', () async {
 final repo = ContactRepository();
 // Should not throw
 await repo.markContactFavorite('nonexistent');
 });

 test('markContactFavorite when already favorite is no-op', () async {
 final repo = ContactRepository();
 await repo.saveContact('fav_dup', 'Fav User');
 await repo.markContactFavorite('fav_dup');
 // Call again — should not error
 await repo.markContactFavorite('fav_dup');

 expect(await repo.isContactFavorite('fav_dup'), true);
 });

 test('unmarkContactFavorite on non-existent is no-op', () async {
 final repo = ContactRepository();
 await repo.unmarkContactFavorite('nonexistent');
 });

 test('unmarkContactFavorite when not favorite is no-op', () async {
 final repo = ContactRepository();
 await repo.saveContact('unfav', 'User');
 await repo.unmarkContactFavorite('unfav');

 expect(await repo.isContactFavorite('unfav'), false);
 });

 test('toggleContactFavorite toggles on then off', () async {
 final repo = ContactRepository();
 await repo.saveContact('toggle_k', 'Toggle User');

 // Toggle on
 final result1 = await repo.toggleContactFavorite('toggle_k');
 expect(result1, true);
 expect(await repo.isContactFavorite('toggle_k'), true);

 // Toggle off
 final result2 = await repo.toggleContactFavorite('toggle_k');
 expect(result2, false);
 expect(await repo.isContactFavorite('toggle_k'), false);
 });

 test('toggleContactFavorite on non-existent returns false', () async {
 final repo = ContactRepository();
 final result = await repo.toggleContactFavorite('nonexistent');
 expect(result, false);
 });

 test('getFavoriteContactCount returns correct count', () async {
 final repo = ContactRepository();
 await repo.saveContact('fc_1', 'User 1');
 await repo.saveContact('fc_2', 'User 2');
 await repo.saveContact('fc_3', 'User 3');
 await repo.markContactFavorite('fc_1');
 await repo.markContactFavorite('fc_3');

 expect(await repo.getFavoriteContactCount(), 2);
 });

 test('isContactFavorite returns false for non-existent', () async {
 final repo = ContactRepository();
 expect(await repo.isContactFavorite('nonexistent'), false);
 });

 test('getFavoriteContacts returns list of favorites', () async {
 final repo = ContactRepository();
 await repo.saveContact('fl_1', 'Fav User 1');
 await repo.saveContact('fl_2', 'Non Fav');
 await repo.saveContact('fl_3', 'Fav User 2');
 await repo.markContactFavorite('fl_1');
 await repo.markContactFavorite('fl_3');

 final favorites = await repo.getFavoriteContacts();
 expect(favorites.length, 2);
 final names = favorites.map((c) => c.displayName).toSet();
 expect(names.contains('Fav User 1'), true);
 expect(names.contains('Fav User 2'), true);
 });
 });

 group('ContactRepository — saveContactWithSecurity extended', () {
 test('creates contact with persistent and ephemeral keys', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('full_pk',
 'Full User',
 SecurityLevel.medium,
 persistentPublicKey: 'persistent_full',
 currentEphemeralId: 'eph_full',
);

 final contact = await repo.getContact('full_pk');
 expect(contact, isNotNull);
 expect(contact!.persistentPublicKey, 'persistent_full');
 expect(contact.currentEphemeralId, 'eph_full');
 expect(contact.securityLevel, SecurityLevel.medium);
 });

 test('updates existing contact preserving persistent key', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('upd_pk',
 'Original',
 SecurityLevel.medium,
 persistentPublicKey: 'pers_orig',
);

 // Update without providing persistent key — should preserve
 await repo.saveContactWithSecurity('upd_pk',
 'Updated',
 SecurityLevel.medium,
);

 final contact = await repo.getContact('upd_pk');
 expect(contact!.displayName, 'Updated');
 expect(contact.persistentPublicKey, 'pers_orig');
 });
 });

 group('ContactRepository — deleteContact edge cases', () {
 test('deleteContact returns false for non-existent', () async {
 final repo = ContactRepository();
 final result = await repo.deleteContact('nonexistent_delete');
 expect(result, false);
 });
 });

 group('ContactRepository — updateNoiseSession edge cases', () {
 test('updateNoiseSession on non-existent contact logs warning', () async {
 final repo = ContactRepository();
 await repo.updateNoiseSession(publicKey: 'no_such_contact',
 noisePublicKey: 'some_key',
 sessionState: 'established',
);

 // Verify warning was logged
 final warningLogs = logRecords
 .where((r) => r.level == Level.WARNING)
 .where((r) => r.message.contains('Cannot update Noise session'))
 .toList();
 expect(warningLogs, isNotEmpty);
 });

 test('updateNoiseSession with non-established state preserves handshake time', () async {
 final repo = ContactRepository();
 await repo.saveContact('noise_ne', 'Noise User');

 // Set with non-established state
 await repo.updateNoiseSession(publicKey: 'noise_ne',
 noisePublicKey: 'key_1',
 sessionState: 'handshaking',
);

 final contact = await repo.getContact('noise_ne');
 expect(contact!.noiseSessionState, 'handshaking');
 // lastHandshakeTime should be null because state != 'established'
 expect(contact.lastHandshakeTime, isNull);
 });
 });

 group('ContactRepository — downgradeSecurityForDeletedContact edge cases', () {
 test('no-op when contact is already at low security', () async {
 final repo = ContactRepository();
 await repo.saveContact('dg_low', 'Low User');

 await repo.downgradeSecurityForDeletedContact('dg_low', 'Test reason');

 // Should still be low
 final contact = await repo.getContact('dg_low');
 expect(contact!.securityLevel, SecurityLevel.low);
 });

 test('downgrades from medium to low', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('dg_med', 'Med User', SecurityLevel.medium);

 await repo.downgradeSecurityForDeletedContact('dg_med', 'Peer deleted');

 final contact = await repo.getContact('dg_med');
 expect(contact!.securityLevel, SecurityLevel.low);
 });
 });

 group('ContactRepository — upgradeContactSecurity edge cases', () {
 test('upgrade non-existent contact returns false', () async {
 final repo = ContactRepository();
 final result = await repo.upgradeContactSecurity('no_contact',
 SecurityLevel.medium,
);
 expect(result, false);
 });

 test('same level re-initialization returns true', () async {
 final repo = ContactRepository();
 await repo.saveContact('same_lvl', 'User');

 final result = await repo.upgradeContactSecurity('same_lvl',
 SecurityLevel.low,
);
 expect(result, true);
 });
 });

 group('ContactRepository — Shared Secret Cache', () {
 test('cacheSharedSecret and getCachedSharedSecret round-trip', () async {
 final repo = ContactRepository();
 await repo.cacheSharedSecret('cache_pk', 'my_shared_secret_123');

 final cached = await repo.getCachedSharedSecret('cache_pk');
 expect(cached, 'my_shared_secret_123');
 });

 test('getCachedSharedSecret returns null when not cached', () async {
 final repo = ContactRepository();
 final cached = await repo.getCachedSharedSecret('uncached_pk');
 expect(cached, isNull);
 });

 test('cacheSharedSeedBytes and getCachedSharedSeedBytes round-trip', () async {
 final repo = ContactRepository();
 final seedBytes = Uint8List.fromList([1, 2, 3, 4, 5, 42, 255, 0]);
 await repo.cacheSharedSeedBytes('seed_pk', seedBytes);

 final cached = await repo.getCachedSharedSeedBytes('seed_pk');
 expect(cached, isNotNull);
 expect(cached, seedBytes);
 });

 test('getCachedSharedSeedBytes returns null when not cached', () async {
 final repo = ContactRepository();
 final cached = await repo.getCachedSharedSeedBytes('uncached_seed');
 expect(cached, isNull);
 });

 test('clearCachedSecrets removes cached data', () async {
 final repo = ContactRepository();
 await repo.cacheSharedSecret('clear_pk', 'secret');

 await repo.clearCachedSecrets('clear_pk');

 final cached = await repo.getCachedSharedSecret('clear_pk');
 expect(cached, isNull);
 });
 });

 group('ContactRepository — getContactByUserId and getContactByPersistentUserId', () {
 test('getContactByUserId resolves through getContact', () async {
 final repo = ContactRepository();
 await repo.saveContact('uid_test', 'UserId User');

 final contact = await repo.getContactByUserId(UserId('uid_test'),
);
 expect(contact, isNotNull);
 expect(contact!.displayName, 'UserId User');
 });

 test('getContactByPersistentUserId resolves through getContactByPersistentKey', () async {
 final repo = ContactRepository();
 await repo.saveContactWithSecurity('puid_pk',
 'PersUserId User',
 SecurityLevel.medium,
 persistentPublicKey: 'persistent_user_id_val',
);

 final contact = await repo.getContactByPersistentUserId(UserId('persistent_user_id_val'),
);
 expect(contact, isNotNull);
 expect(contact!.displayName, 'PersUserId User');
 });
 });
}
