// Test database initialization and schema creation

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/data/database/database_helper.dart';

void main() {
  // Initialize sqflite_ffi for testing
  setUpAll(() {
    // Initialize ffi implementation for testing
    sqfliteFfiInit();
    // Set the database factory for testing
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    // Clean up test database
    await DatabaseHelper.deleteDatabase();
  });

  group('DatabaseHelper Initialization Tests', () {
    test('Database initializes successfully', () async {
      final db = await DatabaseHelper.database;
      expect(db, isNotNull);
      expect(db.isOpen, isTrue);
    });

    test('Database integrity check passes', () async {
      final isValid = await DatabaseHelper.verifyIntegrity();
      expect(isValid, isTrue);
    });

    test('All core tables exist', () async {
      final db = await DatabaseHelper.database;

      final expectedTables = [
        'contacts',
        'chats',
        'messages',
        'offline_message_queue',
        'queue_sync_state',
        'deleted_message_ids',
        'archived_chats',
        'archived_messages',
        'archived_messages_fts', // FTS5 virtual table
        'user_preferences',
        'device_mappings',
        'contact_last_seen',
        'migration_metadata',
      ];

      for (final tableName in expectedTables) {
        final result = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        expect(result, isNotEmpty, reason: 'Table $tableName should exist');
      }
    });

    test('Contacts table has correct structure', () async {
      final db = await DatabaseHelper.database;

      final result = await db.rawQuery("PRAGMA table_info(contacts)");
      final columns = result.map((row) => row['name'] as String).toList();

      expect(columns, contains('public_key'));
      expect(columns, contains('display_name'));
      expect(columns, contains('trust_status'));
      expect(columns, contains('security_level'));
      expect(columns, contains('first_seen'));
      expect(columns, contains('last_seen'));
    });

    test('Messages table has enhanced fields', () async {
      final db = await DatabaseHelper.database;

      final result = await db.rawQuery("PRAGMA table_info(messages)");
      final columns = result.map((row) => row['name'] as String).toList();

      // Basic fields
      expect(columns, contains('id'));
      expect(columns, contains('chat_id'));
      expect(columns, contains('content'));

      // Enhanced fields
      expect(columns, contains('reply_to_message_id'));
      expect(columns, contains('thread_id'));
      expect(columns, contains('is_starred'));
      expect(columns, contains('priority'));
      expect(columns, contains('edited_at'));

      // JSON blob fields
      expect(columns, contains('metadata_json'));
      expect(columns, contains('reactions_json'));
      expect(columns, contains('attachments_json'));
      expect(columns, contains('encryption_info_json'));
    });

    test('Offline message queue table exists with relay fields', () async {
      final db = await DatabaseHelper.database;

      final result = await db.rawQuery("PRAGMA table_info(offline_message_queue)");
      final columns = result.map((row) => row['name'] as String).toList();

      expect(columns, contains('queue_id'));
      expect(columns, contains('message_id'));
      expect(columns, contains('status'));
      expect(columns, contains('retry_count'));

      // Relay-specific fields
      expect(columns, contains('is_relay_message'));
      expect(columns, contains('relay_node_id'));
      expect(columns, contains('message_hash'));
      expect(columns, contains('relay_metadata_json'));
    });

    test('FTS5 virtual table exists for archive search', () async {
      final db = await DatabaseHelper.database;

      // Check that FTS5 table exists
      final result = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='archived_messages_fts'",
      );
      expect(result, isNotEmpty);

      // Verify FTS5 triggers exist
      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='archived_messages'",
      );
      expect(triggers.length, equals(3), reason: 'Should have insert, update, delete triggers');
    });

    test('Foreign key constraints are enabled', () async {
      final db = await DatabaseHelper.database;

      final result = await db.rawQuery('PRAGMA foreign_keys');
      final enabled = Sqflite.firstIntValue(result);
      expect(enabled, equals(1), reason: 'Foreign keys should be enabled');
    });

    test('WAL mode is enabled for concurrency', () async {
      final db = await DatabaseHelper.database;

      final result = await db.rawQuery('PRAGMA journal_mode');
      final mode = result.first['journal_mode'] as String;
      expect(mode.toLowerCase(), equals('wal'), reason: 'WAL mode should be enabled');
    });

    test('Database statistics are retrievable', () async {
      final stats = await DatabaseHelper.getStatistics();

      expect(stats, isNotNull);
      expect(stats['database_version'], equals(1));
      expect(stats['table_counts'], isNotNull);
      expect(stats['total_records'], equals(0)); // Fresh database
    });

    test('Can insert and query contacts', () async {
      final db = await DatabaseHelper.database;

      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a test contact
      await db.insert('contacts', {
        'public_key': 'test_key_123',
        'display_name': 'Test User',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      // Query the contact
      final result = await db.query(
        'contacts',
        where: 'public_key = ?',
        whereArgs: ['test_key_123'],
      );

      expect(result, isNotEmpty);
      expect(result.first['display_name'], equals('Test User'));
      expect(result.first['trust_status'], equals(0));

      // Clean up
      await db.delete('contacts', where: 'public_key = ?', whereArgs: ['test_key_123']);
    });

    test('Can insert message with JSON blobs', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // First create a chat
      await db.insert('chats', {
        'chat_id': 'test_chat',
        'contact_name': 'Test Contact',
        'created_at': now,
        'updated_at': now,
      });

      // Insert a message with JSON blobs
      await db.insert('messages', {
        'id': 'msg_123',
        'chat_id': 'test_chat',
        'content': 'Test message',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'reactions_json': '[]',
        'attachments_json': '[]',
        'created_at': now,
        'updated_at': now,
      });

      // Query the message
      final result = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: ['msg_123'],
      );

      expect(result, isNotEmpty);
      expect(result.first['content'], equals('Test message'));
      expect(result.first['reactions_json'], equals('[]'));

      // Clean up
      await db.delete('chats', where: 'chat_id = ?', whereArgs: ['test_chat']);
    });

    test('Foreign key cascade works for messages', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Create chat and message
      await db.insert('chats', {
        'chat_id': 'cascade_test_chat',
        'contact_name': 'Test',
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('messages', {
        'id': 'cascade_msg',
        'chat_id': 'cascade_test_chat',
        'content': 'Test',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'created_at': now,
        'updated_at': now,
      });

      // Delete chat
      await db.delete('chats', where: 'chat_id = ?', whereArgs: ['cascade_test_chat']);

      // Verify message was deleted via cascade
      final result = await db.query('messages', where: 'id = ?', whereArgs: ['cascade_msg']);
      expect(result, isEmpty, reason: 'Message should be deleted via CASCADE');
    });
  });
}
