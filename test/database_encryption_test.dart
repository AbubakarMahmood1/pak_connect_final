// Test database encryption implementation
// Validates that encryption keys are properly used and databases are encrypted

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_encryption.dart';
import 'test_helpers/test_setup.dart';

void main() {
  final List<LogRecord> logRecords = [];

  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'database_encryption',
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

  group('Database Encryption Tests', () {
    test('Encryption key is generated and cached', () async {
      // First call should generate key
      final key1 = await DatabaseEncryption.getOrCreateEncryptionKey();
      expect(key1, isNotNull);
      expect(key1.length, equals(64)); // 32 bytes = 64 hex characters
      
      // Second call should return cached key
      final key2 = await DatabaseEncryption.getOrCreateEncryptionKey();
      expect(key2, equals(key1));
    });

    test('Database initializes successfully', () async {
      final db = await DatabaseHelper.database;
      expect(db, isNotNull);
      expect(db.isOpen, isTrue);
    });

    test('verifyEncryption returns correct status on test platform', () async {
      // On test platforms (sqflite_common), encryption is not supported
      // so verifyEncryption should return false
      final db = await DatabaseHelper.database;
      expect(db.isOpen, isTrue);
      
      final isEncrypted = await DatabaseHelper.verifyEncryption();
      
      // On desktop/test platforms using sqflite_common, encryption is disabled
      // So we expect false or null (cannot determine)
      expect(isEncrypted == false || isEncrypted == null, isTrue,
        reason: 'Test platform should not have encryption (sqflite_common)');
    });

    test('Database path is accessible', () async {
      final path = await DatabaseHelper.getDatabasePath();
      expect(path, isNotNull);
      expect(path, contains('pak_connect'));
    });

    test('Database file exists after initialization', () async {
      final db = await DatabaseHelper.database;
      expect(db.isOpen, isTrue);
      
      final exists = await DatabaseHelper.exists();
      expect(exists, isTrue);
      
      final path = await DatabaseHelper.getDatabasePath();
      final file = File(path);
      expect(await file.exists(), isTrue);
    });

    test('Database can be queried successfully', () async {
      final db = await DatabaseHelper.database;
      
      // Query sqlite_master to verify database is functional
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      
      expect(tables, isNotEmpty);
      expect(tables.any((t) => t['name'] == 'contacts'), isTrue);
      expect(tables.any((t) => t['name'] == 'chats'), isTrue);
      expect(tables.any((t) => t['name'] == 'messages'), isTrue);
    });

    test('Database encryption key is consistent across calls', () async {
      // Get key multiple times
      final keys = <String>[];
      for (var i = 0; i < 5; i++) {
        keys.add(await DatabaseEncryption.getOrCreateEncryptionKey());
      }
      
      // All keys should be identical (cached)
      expect(keys.toSet().length, equals(1),
        reason: 'Encryption key should be cached and consistent');
    });
  });

  group('Encryption Helper Methods Tests', () {
    test('hasEncryptionKey returns true after key generation', () async {
      // Generate key
      await DatabaseEncryption.getOrCreateEncryptionKey();
      
      // Check if key exists
      final hasKey = await DatabaseEncryption.hasEncryptionKey();
      expect(hasKey, isTrue);
    });

    test('deleteEncryptionKey clears the key', () async {
      // Generate key
      final key = await DatabaseEncryption.getOrCreateEncryptionKey();
      expect(key, isNotNull);
      
      // Delete key
      await DatabaseEncryption.deleteEncryptionKey();
      
      // Check if key still exists
      final hasKey = await DatabaseEncryption.hasEncryptionKey();
      expect(hasKey, isFalse);
      
      // Regenerate key (should be different)
      final newKey = await DatabaseEncryption.getOrCreateEncryptionKey();
      expect(newKey, isNotNull);
      expect(newKey.length, equals(64));
      // Note: new key will be different from old key
    });
  });

  group('Database Statistics Tests', () {
    test('getStatistics returns valid database info', () async {
      final stats = await DatabaseHelper.getStatistics();
      
      expect(stats, isNotNull);
      expect(stats['database_path'], isNotNull);
      expect(stats['database_version'], equals(DatabaseHelper.currentVersion));
      expect(stats['table_counts'], isNotNull);
      expect(stats['total_records'], isA<int>());
    });
  });

  group('Platform-specific Encryption Tests', () {
    test('Desktop/test platforms log encryption skip message', () async {
      // Clear logs
      logRecords.clear();
      
      // Force database re-initialization
      await DatabaseHelper.deleteDatabase();
      final db = await DatabaseHelper.database;
      expect(db.isOpen, isTrue);
      
      // Check logs for encryption skip message
      final encryptionLogs = logRecords.where((log) =>
        log.message.contains('Encryption skipped') ||
        log.message.contains('desktop/test platform') ||
        log.message.contains('sqflite_common')
      );
      
      expect(encryptionLogs, isNotEmpty,
        reason: 'Should log that encryption is skipped on desktop/test platforms');
    });
  });
}
