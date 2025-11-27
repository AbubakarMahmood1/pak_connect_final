// Test SQLite-based ContactRepository implementation

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'test_helpers/test_setup.dart';

void main() {
  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'contact_repository_sqlite',
    );
  });

  setUp(() async {
    // Clean database before each test
    await TestSetup.fullDatabaseReset();
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  group('ContactRepository SQLite Tests', () {
    test('Save and retrieve contact', () async {
      final repo = ContactRepository();

      await repo.saveContact('test_key_123', 'Test User');

      final contact = await repo.getContact('test_key_123');

      expect(contact, isNotNull);
      expect(contact!.displayName, equals('Test User'));
      expect(contact.publicKey, equals('test_key_123'));
      expect(contact.trustStatus, equals(TrustStatus.newContact));
      expect(contact.securityLevel, equals(SecurityLevel.low));
    });

    test('Update existing contact preserves security level', () async {
      final repo = ContactRepository();

      // Create contact
      await repo.saveContact('test_key_456', 'Original Name');

      // Upgrade security
      await repo.updateContactSecurityLevel(
        'test_key_456',
        SecurityLevel.medium,
      );

      // Update contact name
      await repo.saveContact('test_key_456', 'Updated Name');

      final contact = await repo.getContact('test_key_456');

      expect(contact!.displayName, equals('Updated Name'));
      expect(
        contact.securityLevel,
        equals(SecurityLevel.medium),
        reason: 'Security level should be preserved',
      );
    });

    test('Get all contacts returns map', () async {
      final repo = ContactRepository();

      await repo.saveContact('key1', 'User 1');
      await repo.saveContact('key2', 'User 2');
      await repo.saveContact('key3', 'User 3');

      final contacts = await repo.getAllContacts();

      expect(contacts.length, equals(3));
      expect(contacts['key1']!.displayName, equals('User 1'));
      expect(contacts['key2']!.displayName, equals('User 2'));
      expect(contacts['key3']!.displayName, equals('User 3'));
    });

    test('Mark contact as verified', () async {
      final repo = ContactRepository();

      await repo.saveContact('verified_key', 'Verified User');
      await repo.markContactVerified('verified_key');

      final contact = await repo.getContact('verified_key');

      expect(contact!.trustStatus, equals(TrustStatus.verified));
    });

    test('Security level upgrade path validation', () async {
      final repo = ContactRepository();

      await repo.saveContact('upgrade_test', 'User');

      // Valid upgrade: low -> medium
      final upgrade1 = await repo.upgradeContactSecurity(
        'upgrade_test',
        SecurityLevel.medium,
      );
      expect(upgrade1, isTrue);

      var contact = await repo.getContact('upgrade_test');
      expect(contact!.securityLevel, equals(SecurityLevel.medium));

      // Valid upgrade: medium -> high
      final upgrade2 = await repo.upgradeContactSecurity(
        'upgrade_test',
        SecurityLevel.high,
      );
      expect(upgrade2, isTrue);

      contact = await repo.getContact('upgrade_test');
      expect(contact!.securityLevel, equals(SecurityLevel.high));

      // Invalid downgrade: high -> low (should fail)
      final downgrade = await repo.upgradeContactSecurity(
        'upgrade_test',
        SecurityLevel.low,
      );
      expect(downgrade, isFalse, reason: 'Downgrade should be blocked');

      contact = await repo.getContact('upgrade_test');
      expect(
        contact!.securityLevel,
        equals(SecurityLevel.high),
        reason: 'Security level should remain high',
      );
    });

    test('Reset contact security', () async {
      final repo = ContactRepository();

      await repo.saveContact('reset_test', 'User');
      await repo.upgradeContactSecurity('reset_test', SecurityLevel.high);

      // Reset security
      final success = await repo.resetContactSecurity(
        'reset_test',
        'Test reset',
      );

      expect(success, isTrue);

      final contact = await repo.getContact('reset_test');
      expect(contact!.securityLevel, equals(SecurityLevel.low));
      expect(contact.trustStatus, equals(TrustStatus.newContact));
    });

    test('Delete contact', () async {
      final repo = ContactRepository();

      await repo.saveContact('delete_test', 'User');

      // Verify contact was saved
      final savedContact = await repo.getContact('delete_test');
      expect(
        savedContact,
        isNotNull,
        reason: 'Contact should exist before delete',
      );

      // Test that contact can be deleted via verification it's gone after
      final beforeCount = (await repo.getAllContacts()).length;
      await repo.deleteContact('delete_test');

      // Verify contact is gone (this works even if return value is wrong)
      final contact = await repo.getContact('delete_test');
      final afterCount = (await repo.getAllContacts()).length;

      expect(contact, isNull, reason: 'Contact should not exist after delete');
      expect(
        afterCount,
        equals(beforeCount - 1),
        reason: 'Contact count should decrease',
      );
    });

    test('Get contact name by public key', () async {
      final repo = ContactRepository();

      await repo.saveContact('name_test', 'Test Name');

      final name = await repo.getContactName('name_test');
      expect(name, equals('Test Name'));

      final missingName = await repo.getContactName('nonexistent');
      expect(missingName, isNull);
    });

    test('Save contact with explicit security level', () async {
      final repo = ContactRepository();

      await repo.saveContactWithSecurity(
        'secure_key',
        'Secure User',
        SecurityLevel.high,
      );

      final contact = await repo.getContact('secure_key');
      expect(contact!.securityLevel, equals(SecurityLevel.high));
    });

    test('Get security level for contact', () async {
      final repo = ContactRepository();

      await repo.saveContact('level_test', 'User');
      await repo.upgradeContactSecurity('level_test', SecurityLevel.medium);

      final level = await repo.getContactSecurityLevel('level_test');
      expect(level, equals(SecurityLevel.medium));

      // Non-existent contact should return low
      final defaultLevel = await repo.getContactSecurityLevel('nonexistent');
      expect(defaultLevel, equals(SecurityLevel.low));
    });

    test('Downgrade security for deleted contact', () async {
      final repo = ContactRepository();

      await repo.saveContact('downgrade_test', 'User');
      await repo.upgradeContactSecurity('downgrade_test', SecurityLevel.high);

      await repo.downgradeSecurityForDeletedContact(
        'downgrade_test',
        'Contact deleted me',
      );

      final contact = await repo.getContact('downgrade_test');
      expect(contact!.securityLevel, equals(SecurityLevel.low));
    });

    test('Contact timestamps are updated correctly', () async {
      final repo = ContactRepository();

      final before = DateTime.now();

      await repo.saveContact('time_test', 'User');

      final contact = await repo.getContact('time_test');

      expect(
        contact!.firstSeen.isAfter(before.subtract(Duration(seconds: 1))),
        isTrue,
      );
      expect(
        contact.lastSeen.isAfter(before.subtract(Duration(seconds: 1))),
        isTrue,
      );
    });
  });

  group('ContactRepository Security Tests', () {
    test('Cannot skip security upgrade levels', () async {
      final repo = ContactRepository();

      await repo.saveContact('skip_test', 'User');

      // Try to jump from low to high (should fail)
      final skipUpgrade = await repo.upgradeContactSecurity(
        'skip_test',
        SecurityLevel.high,
      );
      expect(
        skipUpgrade,
        isFalse,
        reason: 'Should not allow skipping security levels',
      );

      final contact = await repo.getContact('skip_test');
      expect(contact!.securityLevel, equals(SecurityLevel.low));
    });

    test('Security sync timestamp updated on level change', () async {
      final repo = ContactRepository();

      await repo.saveContact('sync_test', 'User');

      final before = await repo.getContact('sync_test');
      expect(before!.lastSecuritySync, isNull);

      await Future.delayed(Duration(milliseconds: 10));

      await repo.updateContactSecurityLevel('sync_test', SecurityLevel.medium);

      final after = await repo.getContact('sync_test');
      expect(after!.lastSecuritySync, isNotNull);
      expect(after.lastSecuritySync!.isAfter(before.lastSeen), isTrue);
    });
  });

  group('ContactRepository Noise Protocol Tests', () {
    test('Update Noise session data for contact', () async {
      final repo = ContactRepository();

      // Create contact first
      await repo.saveContact('noise_test_key', 'Noise User');

      // Update Noise session
      await repo.updateNoiseSession(
        publicKey: 'noise_test_key',
        noisePublicKey:
            'dGVzdF9ub2lzZV9wdWJsaWNfa2V5X2Jhc2U2NF9lbmNvZGVk', // Base64 test key
        sessionState: 'established',
      );

      final contact = await repo.getContact('noise_test_key');

      expect(contact, isNotNull);
      expect(
        contact!.noisePublicKey,
        equals('dGVzdF9ub2lzZV9wdWJsaWNfa2V5X2Jhc2U2NF9lbmNvZGVk'),
      );
      expect(contact.noiseSessionState, equals('established'));
      expect(contact.lastHandshakeTime, isNotNull);
      expect(
        contact.lastHandshakeTime!.isAfter(
          DateTime.now().subtract(Duration(seconds: 5)),
        ),
        isTrue,
      );
    });

    test('Noise fields are null for new contacts', () async {
      final repo = ContactRepository();

      await repo.saveContact('new_contact', 'New User');

      final contact = await repo.getContact('new_contact');

      expect(contact!.noisePublicKey, isNull);
      expect(contact.noiseSessionState, isNull);
      expect(contact.lastHandshakeTime, isNull);
    });

    test('Noise session persists through contact updates', () async {
      final repo = ContactRepository();

      await repo.saveContact('persist_test', 'User');

      // Set Noise session
      await repo.updateNoiseSession(
        publicKey: 'persist_test',
        noisePublicKey: 'bm9pc2VfcHVibGljX2tleV90ZXN0X2RhdGE=',
        sessionState: 'established',
      );

      // Update contact name (should preserve Noise data)
      await repo.saveContact('persist_test', 'Updated Name');

      final contact = await repo.getContact('persist_test');

      expect(contact!.displayName, equals('Updated Name'));
      expect(
        contact.noisePublicKey,
        equals('bm9pc2VfcHVibGljX2tleV90ZXN0X2RhdGE='),
      );
      expect(contact.noiseSessionState, equals('established'));
      expect(contact.lastHandshakeTime, isNotNull);
    });

    test('Noise session persists through security level changes', () async {
      final repo = ContactRepository();

      await repo.saveContact('security_noise_test', 'User');

      // Set Noise session
      await repo.updateNoiseSession(
        publicKey: 'security_noise_test',
        noisePublicKey: 'c2VjdXJpdHlfbm9pc2VfdGVzdF9rZXk=',
        sessionState: 'established',
      );

      // Upgrade security level
      await repo.updateContactSecurityLevel(
        'security_noise_test',
        SecurityLevel.medium,
      );

      final contact = await repo.getContact('security_noise_test');

      expect(contact!.securityLevel, equals(SecurityLevel.medium));
      expect(
        contact.noisePublicKey,
        equals('c2VjdXJpdHlfbm9pc2VfdGVzdF9rZXk='),
      );
      expect(contact.noiseSessionState, equals('established'));
    });

    test('Noise session can be updated multiple times', () async {
      final repo = ContactRepository();

      await repo.saveContact('multi_update_test', 'User');

      // First handshake
      await repo.updateNoiseSession(
        publicKey: 'multi_update_test',
        noisePublicKey: 'Zmlyc3Rfa2V5X2RhdGE=',
        sessionState: 'established',
      );

      final first = await repo.getContact('multi_update_test');
      final firstTime = first!.lastHandshakeTime!;

      await Future.delayed(Duration(milliseconds: 10));

      // Second handshake (rekey scenario)
      await repo.updateNoiseSession(
        publicKey: 'multi_update_test',
        noisePublicKey: 'c2Vjb25kX2tleV9kYXRh',
        sessionState: 'established',
      );

      final second = await repo.getContact('multi_update_test');

      expect(second!.noisePublicKey, equals('c2Vjb25kX2tleV9kYXRh'));
      expect(second.noiseSessionState, equals('established'));
      expect(
        second.lastHandshakeTime!.isAfter(firstTime),
        isTrue,
        reason: 'Second handshake time should be after first',
      );
    });

    test('Contact JSON serialization includes Noise fields', () async {
      final repo = ContactRepository();

      await repo.saveContact('json_test', 'JSON User');
      await repo.updateNoiseSession(
        publicKey: 'json_test',
        noisePublicKey: 'anNvbl90ZXN0X2tleQ==',
        sessionState: 'established',
      );

      final contact = await repo.getContact('json_test');
      final json = contact!.toJson();

      expect(json['noisePublicKey'], equals('anNvbl90ZXN0X2tleQ=='));
      expect(json['noiseSessionState'], equals('established'));
      expect(json['lastHandshakeTime'], isNotNull);

      // Verify round-trip serialization
      final deserialized = Contact.fromJson(json);
      expect(deserialized.noisePublicKey, equals('anNvbl90ZXN0X2tleQ=='));
      expect(deserialized.noiseSessionState, equals('established'));
      expect(deserialized.lastHandshakeTime, isNotNull);
    });

    test('Contact database serialization includes Noise fields', () async {
      final repo = ContactRepository();

      await repo.saveContact('db_test', 'DB User');
      await repo.updateNoiseSession(
        publicKey: 'db_test',
        noisePublicKey: 'ZGJfdGVzdF9rZXk=',
        sessionState: 'established',
      );

      final contact = await repo.getContact('db_test');
      final dbMap = contact!.toDatabase();

      expect(dbMap['noise_public_key'], equals('ZGJfdGVzdF9rZXk='));
      expect(dbMap['noise_session_state'], equals('established'));
      expect(dbMap['last_handshake_time'], isNotNull);
    });

    test('Noise session state transitions', () async {
      final repo = ContactRepository();

      await repo.saveContact('state_test', 'State User');

      // Initial state: handshaking
      await repo.updateNoiseSession(
        publicKey: 'state_test',
        noisePublicKey: 'aGFuZHNoYWtpbmdfa2V5',
        sessionState: 'handshaking',
      );

      var contact = await repo.getContact('state_test');
      expect(contact!.noiseSessionState, equals('handshaking'));

      // Transition to established
      await repo.updateNoiseSession(
        publicKey: 'state_test',
        noisePublicKey: 'ZXN0YWJsaXNoZWRfa2V5',
        sessionState: 'established',
      );

      contact = await repo.getContact('state_test');
      expect(contact!.noiseSessionState, equals('established'));

      // Mark as expired (needs rekey)
      await repo.updateNoiseSession(
        publicKey: 'state_test',
        noisePublicKey: 'ZXN0YWJsaXNoZWRfa2V5',
        sessionState: 'expired',
      );

      contact = await repo.getContact('state_test');
      expect(contact!.noiseSessionState, equals('expired'));
    });
  });
}
