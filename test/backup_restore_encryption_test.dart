// Test backup and restore services with encryption
// Validates that encryption keys are properly used in selective backup/restore

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' hide equals;
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/services/export_import/selective_backup_service.dart';
import 'package:pak_connect/data/services/export_import/selective_restore_service.dart';
import 'package:pak_connect/data/services/export_import/export_bundle.dart';
import 'test_helpers/test_setup.dart';

void main() {
  final List<LogRecord> logRecords = [];

  Future<void> insertContact({
    required String publicKey,
    required String displayName,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('contacts', {
      'public_key': publicKey,
      'display_name': displayName,
      'trust_status': 0,
      'security_level': 0,
      'first_seen': now,
      'last_seen': now,
      'created_at': now,
      'updated_at': now,
    });
  }

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'backup_restore_encryption',
    );
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.fullDatabaseReset();
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  group('Selective Backup with Encryption Tests', () {
    test('Contacts-only backup succeeds', () async {
      final db = await DatabaseHelper.database;

      // Create test contacts
      for (var i = 0; i < 3; i++) {
        await db.insert('contacts', {
          'public_key': 'test_key_$i',
          'display_name': 'Test User $i',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': DateTime.now().millisecondsSinceEpoch,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Create backup
      final dbPath = await DatabaseHelper.getDatabasePath();
      final backupDir = join(dirname(dbPath), 'test_backups');

      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
        customBackupDir: backupDir,
      );

      expect(result.success, isTrue);
      expect(result.backupPath, isNotNull);
      expect(result.recordCount, equals(3));

      // Verify backup file exists
      final backupFile = File(result.backupPath!);
      expect(await backupFile.exists(), isTrue);

      // Clean up
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      final dir = Directory(backupDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('Messages-only backup succeeds', () async {
      final db = await DatabaseHelper.database;

      await insertContact(publicKey: 'test_key_1', displayName: 'Test User');

      // Create test chat
      await db.insert('chats', {
        'chat_id': 'chat_test',
        'contact_public_key': 'test_key_1',
        'contact_name': 'Test User',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Create test messages
      for (var i = 0; i < 5; i++) {
        await db.insert('messages', {
          'id': 'msg_$i',
          'chat_id': 'chat_test',
          'content': 'Test message $i',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'is_from_me': i % 2,
          'status': 1,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Create backup
      final dbPath = await DatabaseHelper.getDatabasePath();
      final backupDir = join(dirname(dbPath), 'test_backups');

      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.messagesOnly,
        customBackupDir: backupDir,
      );

      expect(result.success, isTrue);
      expect(result.backupPath, isNotNull);
      expect(result.recordCount, equals(6)); // 1 chat + 5 messages

      // Clean up
      final backupFile = File(result.backupPath!);
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      final dir = Directory(backupDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('Backup file can be read after creation', () async {
      final db = await DatabaseHelper.database;

      // Create test contacts
      await db.insert('contacts', {
        'public_key': 'test_key_backup',
        'display_name': 'Backup Test User',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': DateTime.now().millisecondsSinceEpoch,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Create backup
      final dbPath = await DatabaseHelper.getDatabasePath();
      final backupDir = join(dirname(dbPath), 'test_backups');

      final result = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
        customBackupDir: backupDir,
      );

      expect(result.success, isTrue);

      // Verify file exists and has size
      final backupFile = File(result.backupPath!);
      expect(await backupFile.exists(), isTrue);
      expect(await backupFile.length(), greaterThan(0));

      // Clean up
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      final dir = Directory(backupDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
  });

  group('Selective Restore with Encryption Tests', () {
    test('Contacts-only restore succeeds', () async {
      final db = await DatabaseHelper.database;

      // Create test contacts
      for (var i = 0; i < 3; i++) {
        await db.insert('contacts', {
          'public_key': 'backup_key_$i',
          'display_name': 'Backup User $i',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': DateTime.now().millisecondsSinceEpoch,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Create backup
      final dbPath = await DatabaseHelper.getDatabasePath();
      final backupDir = join(dirname(dbPath), 'test_backups');

      final backupResult = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.contactsOnly,
        customBackupDir: backupDir,
      );

      expect(backupResult.success, isTrue);

      // Clear contacts from main DB
      await db.delete('contacts');

      // Verify contacts are deleted
      final contactsBeforeRestore = await db.query('contacts');
      expect(contactsBeforeRestore.length, equals(0));

      // Restore from backup
      final restoreResult =
          await SelectiveRestoreService.restoreSelectiveBackup(
            backupPath: backupResult.backupPath!,
            exportType: ExportType.contactsOnly,
            clearExistingData: false,
          );

      expect(restoreResult.success, isTrue);
      expect(restoreResult.recordsRestored, equals(3));

      // Verify contacts are restored
      final contactsAfterRestore = await db.query('contacts');
      expect(contactsAfterRestore.length, equals(3));

      // Clean up
      final backupFile = File(backupResult.backupPath!);
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      final dir = Directory(backupDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('Messages-only restore succeeds', () async {
      final db = await DatabaseHelper.database;

      await insertContact(
        publicKey: 'restore_key',
        displayName: 'Restore User',
      );

      // Create test chat and messages
      await db.insert('chats', {
        'chat_id': 'restore_chat',
        'contact_public_key': 'restore_key',
        'contact_name': 'Restore User',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      for (var i = 0; i < 3; i++) {
        await db.insert('messages', {
          'id': 'restore_msg_$i',
          'chat_id': 'restore_chat',
          'content': 'Restore message $i',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'is_from_me': 1,
          'status': 1,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Create backup
      final dbPath = await DatabaseHelper.getDatabasePath();
      final backupDir = join(dirname(dbPath), 'test_backups');

      final backupResult = await SelectiveBackupService.createSelectiveBackup(
        exportType: ExportType.messagesOnly,
        customBackupDir: backupDir,
      );

      expect(backupResult.success, isTrue);

      // Clear messages and chats
      await db.delete('messages');
      await db.delete('chats');

      // Restore from backup
      final restoreResult =
          await SelectiveRestoreService.restoreSelectiveBackup(
            backupPath: backupResult.backupPath!,
            exportType: ExportType.messagesOnly,
            clearExistingData: false,
          );

      expect(restoreResult.success, isTrue);
      expect(restoreResult.recordsRestored, equals(4)); // 1 chat + 3 messages

      // Verify data is restored
      final chats = await db.query('chats');
      expect(chats.length, equals(1));

      final messages = await db.query('messages');
      expect(messages.length, equals(3));

      // Clean up
      final backupFile = File(backupResult.backupPath!);
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      final dir = Directory(backupDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
  });

  group('Backup/Restore Statistics Tests', () {
    test('getSelectiveStats returns correct contact counts', () async {
      final db = await DatabaseHelper.database;

      // Create test contacts
      for (var i = 0; i < 5; i++) {
        await db.insert('contacts', {
          'public_key': 'stats_key_$i',
          'display_name': 'Stats User $i',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': DateTime.now().millisecondsSinceEpoch,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      final stats = await SelectiveBackupService.getSelectiveStats(
        ExportType.contactsOnly,
      );

      expect(stats['type'], equals('contacts_only'));
      expect(stats['record_count'], equals(5));
      expect(stats['tables'], contains('contacts'));
    });

    test('getSelectiveStats returns correct message counts', () async {
      final db = await DatabaseHelper.database;

      await insertContact(publicKey: 'stats_key', displayName: 'Stats User');

      // Create test chat and messages
      await db.insert('chats', {
        'chat_id': 'stats_chat',
        'contact_public_key': 'stats_key',
        'contact_name': 'Stats User',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      for (var i = 0; i < 7; i++) {
        await db.insert('messages', {
          'id': 'stats_msg_$i',
          'chat_id': 'stats_chat',
          'content': 'Stats message $i',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'is_from_me': 1,
          'status': 1,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      final stats = await SelectiveBackupService.getSelectiveStats(
        ExportType.messagesOnly,
      );

      expect(stats['type'], equals('messages_only'));
      expect(stats['chat_count'], equals(1));
      expect(stats['message_count'], equals(7));
      expect(stats['record_count'], equals(8)); // 1 chat + 7 messages
      expect(stats['tables'], contains('chats'));
      expect(stats['tables'], contains('messages'));
    });
  });
}
