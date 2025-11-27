// Tests for selective export/import functionality
// Ensures contacts-only and messages-only exports work correctly

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/export_import/export_bundle.dart';
import 'package:pak_connect/data/services/export_import/selective_backup_service.dart';
import 'package:pak_connect/data/services/export_import/selective_restore_service.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'dart:io';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'selective_export');
  });

  setUp(() async {
    await TestSetup.configureTestDatabase(label: 'selective_export');
    await TestSetup.fullDatabaseReset();
    TestSetup.resetSharedPreferences();

    // Initialize database
    final db = await DatabaseHelper.database;

    // Insert test contacts
    await db.insert('contacts', {
      'public_key': 'contact1_key',
      'display_name': 'Contact One',
      'trust_status': 1,
      'security_level': 2,
      'first_seen': DateTime.now().millisecondsSinceEpoch,
      'last_seen': DateTime.now().millisecondsSinceEpoch,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    await db.insert('contacts', {
      'public_key': 'contact2_key',
      'display_name': 'Contact Two',
      'trust_status': 0,
      'security_level': 1,
      'first_seen': DateTime.now().millisecondsSinceEpoch,
      'last_seen': DateTime.now().millisecondsSinceEpoch,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    // Insert test chat
    await db.insert('chats', {
      'chat_id': 'chat1',
      'contact_public_key': 'contact1_key',
      'contact_name': 'Contact One',
      'last_message': 'Hello',
      'last_message_time': DateTime.now().millisecondsSinceEpoch,
      'unread_count': 0,
      'is_archived': 0,
      'is_muted': 0,
      'is_pinned': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    // Insert test messages
    await db.insert('messages', {
      'id': 'msg1',
      'chat_id': 'chat1',
      'content': 'Test message 1',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'is_from_me': 1,
      'status': 2,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });

    await db.insert('messages', {
      'id': 'msg2',
      'chat_id': 'chat1',
      'content': 'Test message 2',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'is_from_me': 0,
      'status': 2,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  });

  tearDown(() async {
    await DatabaseHelper.close();
    await TestSetup.nukeDatabase();
  });

  group('ExportType', () {
    test('has correct enum values', () {
      expect(ExportType.values.length, equals(3));
      expect(ExportType.full.name, equals('full'));
      expect(ExportType.contactsOnly.name, equals('contactsOnly'));
      expect(ExportType.messagesOnly.name, equals('messagesOnly'));
    });
  });

  group('SelectiveBackupService', () {
    test('creates contacts-only backup successfully', () async {
      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
      );

      expect(result.success, isTrue);
      expect(result.backupPath, isNotNull);
      expect(result.recordCount, equals(2)); // 2 contacts
      expect(result.exportType, equals(ExportType.contactsOnly));
      expect(result.backupSize, greaterThan(0));

      // Verify backup file exists
      final backupFile = File(result.backupPath!);
      expect(await backupFile.exists(), isTrue);

      // Clean up
      await backupFile.delete();
    });

    test('creates messages-only backup successfully', () async {
      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.messagesOnly,
      );

      expect(result.success, isTrue);
      expect(result.backupPath, isNotNull);
      expect(result.recordCount, equals(3)); // 1 chat + 2 messages
      expect(result.exportType, equals(ExportType.messagesOnly));
      expect(result.backupSize, greaterThan(0));

      // Verify backup file exists
      final backupFile = File(result.backupPath!);
      expect(await backupFile.exists(), isTrue);

      // Clean up
      await backupFile.delete();
    });

    test('fails gracefully for full export type', () async {
      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.full,
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Unsupported operation'));
    });

    test('contacts-only backup contains only contacts table', () async {
      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
      );

      expect(result.success, isTrue);

      // Open backup and verify schema
      final backupDb = await sqflite_ffi.databaseFactoryFfi.openDatabase(
        result.backupPath!,
        options: sqflite_ffi.OpenDatabaseOptions(readOnly: true),
      );

      // Check that contacts table exists
      final contacts = await backupDb.query('contacts');
      expect(contacts.length, equals(2));

      // Verify contacts data
      expect(contacts[0]['public_key'], equals('contact1_key'));
      expect(contacts[0]['display_name'], equals('Contact One'));
      expect(contacts[1]['public_key'], equals('contact2_key'));

      await backupDb.close();
      await File(result.backupPath!).delete();
    });

    test('messages-only backup contains chats and messages tables', () async {
      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.messagesOnly,
      );

      expect(result.success, isTrue);

      // Open backup and verify schema
      final backupDb = await sqflite_ffi.databaseFactoryFfi.openDatabase(
        result.backupPath!,
        options: sqflite_ffi.OpenDatabaseOptions(readOnly: true),
      );

      // Check that chats table exists
      final chats = await backupDb.query('chats');
      expect(chats.length, equals(1));
      expect(chats[0]['chat_id'], equals('chat1'));

      // Check that messages table exists
      final messages = await backupDb.query('messages');
      expect(messages.length, equals(2));
      expect(messages[0]['content'], equals('Test message 1'));
      expect(messages[1]['content'], equals('Test message 2'));

      await backupDb.close();
      await File(result.backupPath!).delete();
    });
  });

  group('SelectiveRestoreService', () {
    test('restores contacts-only backup successfully', () async {
      // Create backup
      final backupResult = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
      );
      expect(backupResult.success, isTrue);

      // Clear contacts from database
      final db = await DatabaseHelper.database;
      await db.delete('contacts');

      // Verify contacts are cleared
      final contactsBefore = await db.query('contacts');
      expect(contactsBefore.length, equals(0));

      // Restore backup
      final restoreResult =
          await SelectiveRestoreService.restoreSelectiveBackup(
            backupPath: backupResult.backupPath!,
            exportType: ExportType.contactsOnly,
            clearExistingData: false,
          );

      expect(restoreResult.success, isTrue);
      expect(restoreResult.recordsRestored, equals(2));
      expect(restoreResult.exportType, equals(ExportType.contactsOnly));

      // Verify contacts are restored
      final contactsAfter = await db.query('contacts');
      expect(contactsAfter.length, equals(2));
      expect(contactsAfter[0]['display_name'], equals('Contact One'));
      expect(contactsAfter[1]['display_name'], equals('Contact Two'));

      // Clean up
      await File(backupResult.backupPath!).delete();
    });

    test('restores messages-only backup successfully', () async {
      // Create backup
      final backupResult = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.messagesOnly,
      );
      expect(backupResult.success, isTrue);

      // Clear messages and chats from database
      final db = await DatabaseHelper.database;
      await db.delete('messages');
      await db.delete('chats');

      // Verify cleared
      final chatsBefore = await db.query('chats');
      final messagesBefore = await db.query('messages');
      expect(chatsBefore.length, equals(0));
      expect(messagesBefore.length, equals(0));

      // Restore backup
      final restoreResult =
          await SelectiveRestoreService.restoreSelectiveBackup(
            backupPath: backupResult.backupPath!,
            exportType: ExportType.messagesOnly,
            clearExistingData: false,
          );

      expect(restoreResult.success, isTrue);
      expect(restoreResult.recordsRestored, equals(3)); // 1 chat + 2 messages

      // Verify restored
      final chatsAfter = await db.query('chats');
      final messagesAfter = await db.query('messages');
      expect(chatsAfter.length, equals(1));
      expect(messagesAfter.length, equals(2));
      expect(messagesAfter[0]['content'], equals('Test message 1'));

      // Clean up
      await File(backupResult.backupPath!).delete();
    });

    test('handles clearExistingData flag for contacts', () async {
      // Create backup
      final backupResult = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
      );

      // Add a different contact
      final db = await DatabaseHelper.database;
      await db.delete('contacts');
      await db.insert('contacts', {
        'public_key': 'contact3_key',
        'display_name': 'Contact Three',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': DateTime.now().millisecondsSinceEpoch,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Restore with clearExistingData = true
      final restoreResult =
          await SelectiveRestoreService.restoreSelectiveBackup(
            backupPath: backupResult.backupPath!,
            exportType: ExportType.contactsOnly,
            clearExistingData: true,
          );

      expect(restoreResult.success, isTrue);

      // Verify old contact is gone and backup contacts are restored
      final contacts = await db.query('contacts');
      expect(contacts.length, equals(2));
      expect(contacts.any((c) => c['public_key'] == 'contact3_key'), isFalse);
      expect(contacts.any((c) => c['public_key'] == 'contact1_key'), isTrue);

      // Clean up
      await File(backupResult.backupPath!).delete();
    });

    test('handles non-existent backup file gracefully', () async {
      final restoreResult =
          await SelectiveRestoreService.restoreSelectiveBackup(
            backupPath: '/non/existent/path.db',
            exportType: ExportType.contactsOnly,
            clearExistingData: false,
          );

      expect(restoreResult.success, isFalse);
      expect(restoreResult.errorMessage, contains('not found'));
    });
  });

  group('SelectiveBackupService.getSelectiveStats', () {
    test('returns correct stats for contacts-only', () async {
      final stats = await SelectiveBackupService.getSelectiveStats(
        ExportType.contactsOnly,
      );

      expect(stats['type'], equals('contacts_only'));
      expect(stats['record_count'], equals(2));
      expect(stats['tables'], equals(['contacts']));
    });

    test('returns correct stats for messages-only', () async {
      final stats = await SelectiveBackupService.getSelectiveStats(
        ExportType.messagesOnly,
      );

      expect(stats['type'], equals('messages_only'));
      expect(stats['record_count'], equals(3)); // 1 chat + 2 messages
      expect(stats['chat_count'], equals(1));
      expect(stats['message_count'], equals(2));
      expect(stats['tables'], equals(['chats', 'messages']));
    });
  });

  group('ExportBundle with exportType', () {
    test('serializes and deserializes exportType correctly', () {
      final bundle = ExportBundle(
        version: '1.0.0',
        timestamp: DateTime.now(),
        deviceId: 'device123',
        username: 'TestUser',
        exportType: ExportType.contactsOnly,
        encryptedMetadata: 'meta',
        encryptedKeys: 'keys',
        encryptedPreferences: 'prefs',
        databasePath: '/path/to/db',
        salt: Uint8List(32),
        checksum: 'checksum',
      );

      final json = bundle.toJson();
      expect(json['export_type'], equals('contactsOnly'));

      final restored = ExportBundle.fromJson(json);
      expect(restored.exportType, equals(ExportType.contactsOnly));
    });

    test('defaults to full export type if not specified', () {
      final json = {
        'version': '1.0.0',
        'timestamp': DateTime.now().toIso8601String(),
        'device_id': 'device123',
        'username': 'TestUser',
        // export_type not specified
        'encrypted_metadata': 'meta',
        'encrypted_keys': 'keys',
        'encrypted_preferences': 'prefs',
        'database_path': '/path/to/db',
        'salt': List.filled(32, 0),
        'checksum': 'checksum',
      };

      final bundle = ExportBundle.fromJson(json);
      expect(bundle.exportType, equals(ExportType.full));
    });
  });
}
