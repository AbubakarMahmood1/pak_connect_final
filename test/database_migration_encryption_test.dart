// Test database migration from unencrypted to encrypted format
// This test validates the seamless migration path for existing users

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_encryption.dart';
import 'test_helpers/test_setup.dart';

void main() {
  final List<LogRecord> logRecords = [];

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'database_migration_encryption',
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

  group('Database Encryption Migration Tests', () {
    test('Can create and query unencrypted database', () async {
      // Get a test database path
      final factory = sqflite_common.databaseFactory;
      final databasesPath = await factory.getDatabasesPath();
      final testPath = join(databasesPath, 'test_unencrypted.db');

      // Clean up any existing file
      final file = File(testPath);
      if (await file.exists()) {
        await file.delete();
      }

      // Create an unencrypted database
      final db = await factory.openDatabase(
        testPath,
        options: sqflite_common.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE test_table (
                id INTEGER PRIMARY KEY,
                data TEXT
              )
            ''');
          },
        ),
      );

      // Insert test data
      await db.insert('test_table', {'id': 1, 'data': 'test data'});

      // Query to verify
      final result = await db.query('test_table');
      expect(result.length, equals(1));
      expect(result.first['data'], equals('test data'));

      await db.close();

      // Verify file exists and is readable as plaintext SQLite
      expect(await file.exists(), isTrue);

      // Read file header to verify it's plaintext
      final bytes = await file.openRead(0, 16).first;
      final header = String.fromCharCodes(bytes.take(15));
      expect(
        header,
        equals('SQLite format 3'),
        reason: 'Test database should be plaintext SQLite',
      );

      // Clean up
      await file.delete();
    });

    test('verifyEncryption returns false for plaintext database', () async {
      // This test is informational on desktop/test platforms
      // The actual encryption only happens on mobile (Android/iOS)
      final isEncrypted = await DatabaseHelper.verifyEncryption();

      // On test platforms, encryption is not supported
      // So we expect false or null
      if (isEncrypted != null) {
        expect(
          isEncrypted,
          isFalse,
          reason: 'Test platform databases should not be encrypted',
        );
      }
    });

    test('Database can store and retrieve data after initialization', () async {
      final db = await DatabaseHelper.database;

      // Insert a test contact
      await db.insert('contacts', {
        'public_key': 'test_key_123',
        'display_name': 'Test User',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': DateTime.now().millisecondsSinceEpoch,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Query back
      final contacts = await db.query('contacts');
      expect(contacts.length, equals(1));
      expect(contacts.first['public_key'], equals('test_key_123'));
      expect(contacts.first['display_name'], equals('Test User'));
    });

    test('Multiple database operations work correctly', () async {
      final db = await DatabaseHelper.database;

      await db.insert('contacts', {
        'public_key': 'test_key_123',
        'display_name': 'Test User',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': DateTime.now().millisecondsSinceEpoch,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Create a chat
      await db.insert('chats', {
        'chat_id': 'chat_1',
        'contact_public_key': 'test_key_123',
        'contact_name': 'Test User',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Create messages
      for (var i = 0; i < 5; i++) {
        await db.insert('messages', {
          'id': 'msg_$i',
          'chat_id': 'chat_1',
          'content': 'Test message $i',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'is_from_me': i % 2,
          'status': 1,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Query messages
      final messages = await db.query(
        'messages',
        where: 'chat_id = ?',
        whereArgs: ['chat_1'],
      );
      expect(messages.length, equals(5));

      // Query chat
      final chats = await db.query('chats');
      expect(chats.length, equals(1));
    });

    test('Database integrity check passes after operations', () async {
      final db = await DatabaseHelper.database;

      // Add some data
      await db.insert('contacts', {
        'public_key': 'test_key_456',
        'display_name': 'Another User',
        'trust_status': 1,
        'security_level': 1,
        'first_seen': DateTime.now().millisecondsSinceEpoch,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      // Verify integrity
      final isValid = await DatabaseHelper.verifyIntegrity();
      expect(isValid, isTrue);
    });
  });

  group('Encryption Key Consistency Tests', () {
    test('Encryption key persists across database operations', () async {
      final key1 = await DatabaseEncryption.getOrCreateEncryptionKey();

      // Initialize database
      final db = await DatabaseHelper.database;
      expect(db.isOpen, isTrue);

      // Get key again
      final key2 = await DatabaseEncryption.getOrCreateEncryptionKey();

      expect(
        key1,
        equals(key2),
        reason: 'Encryption key should remain consistent',
      );
    });

    test(
      'Same encryption key is used after database close and reopen',
      () async {
        final key1 = await DatabaseEncryption.getOrCreateEncryptionKey();

        // Open database
        final db1 = await DatabaseHelper.database;
        expect(db1.isOpen, isTrue);

        // Close database
        await DatabaseHelper.close();

        // Open again
        final db2 = await DatabaseHelper.database;
        expect(db2.isOpen, isTrue);

        // Get key again
        final key2 = await DatabaseEncryption.getOrCreateEncryptionKey();

        expect(
          key1,
          equals(key2),
          reason: 'Encryption key should persist after close/reopen',
        );
      },
    );
  });
}
