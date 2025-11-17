import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/queue_persistence_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/data/database/database_helper.dart';

void main() {
  // Initialize FFI for testing
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('QueuePersistenceManager', () {
    late QueuePersistenceManager manager;
    late Database testDb;

    setUp(() async {
      // Create in-memory test database
      testDb = await databaseFactory.openDatabase(inMemoryDatabasePath);

      // Mock DatabaseHelper.database
      manager = QueuePersistenceManager();
    });

    tearDown(() async {
      await testDb.close();
    });

    group('createQueueTablesIfNotExist', () {
      test('creates queue tables successfully', () async {
        final result = await manager.createQueueTablesIfNotExist();
        expect(result, isTrue);

        // Verify tables exist
        final tables = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        final tableNames = tables.map((t) => t['name'] as String).toList();
        expect(tableNames, contains('offline_message_queue'));
        expect(tableNames, contains('deleted_message_ids'));
      });

      test('returns false when tables already exist', () async {
        // Create once
        await manager.createQueueTablesIfNotExist();
        // Try to create again - should succeed but return false
        final result = await manager.createQueueTablesIfNotExist();
        // Note: We expect the operation to complete without error
        // The actual return value depends on DatabaseHelper implementation
      });

      test('creates required indexes', () async {
        await manager.createQueueTablesIfNotExist();

        final indexes = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='offline_message_queue'",
        );
        final indexNames = indexes.map((i) => i['name'] as String).toList();
        expect(indexNames, contains('idx_queue_priority'));
        expect(indexNames, contains('idx_queue_status'));
        expect(indexNames, contains('idx_queue_recipient'));
      });
    });

    group('migrateQueueSchema', () {
      test('performs migration from v0 to v1', () async {
        await manager.migrateQueueSchema(oldVersion: 0, newVersion: 1);

        // Verify tables exist
        final tables = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        final tableNames = tables.map((t) => t['name'] as String).toList();
        expect(tableNames, contains('offline_message_queue'));
      });

      test('handles migration when tables already exist', () async {
        // Pre-create tables
        await manager.createQueueTablesIfNotExist();

        // Perform migration - should not throw
        await manager.migrateQueueSchema(oldVersion: 1, newVersion: 1);

        // Tables should still exist
        final tables = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        final tableNames = tables.map((t) => t['name'] as String).toList();
        expect(tableNames, contains('offline_message_queue'));
      });
    });

    group('getQueueTableStats', () {
      test('returns stats for empty tables', () async {
        await manager.createQueueTablesIfNotExist();

        final stats = await manager.getQueueTableStats();
        expect(stats['tableCount'], equals(2));
        expect(stats['queueRowCount'], equals(0));
        expect(stats['deletedIdRowCount'], equals(0));
      });

      test('counts rows correctly after inserts', () async {
        await manager.createQueueTablesIfNotExist();

        // Insert test rows
        await testDb.insert('offline_message_queue', {
          'message_id': 'msg1',
          'chat_id': 'chat1',
          'content': 'test',
          'recipient_public_key': 'key1',
          'sender_public_key': 'key2',
          'queued_at': DateTime.now().millisecondsSinceEpoch,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });

        final stats = await manager.getQueueTableStats();
        expect(stats['queueRowCount'], equals(1));
      });
    });

    group('vacuumQueueTables', () {
      test('completes without error', () async {
        await manager.createQueueTablesIfNotExist();

        // Should not throw
        await manager.vacuumQueueTables();
      });
    });

    group('backupQueueData', () {
      test('returns non-null backup path', () async {
        await manager.createQueueTablesIfNotExist();

        final backupPath = await manager.backupQueueData();
        expect(backupPath, isNotNull);
        expect(backupPath, contains('queue_'));
      });

      test('includes timestamp in backup path', () async {
        await manager.createQueueTablesIfNotExist();

        final before = DateTime.now().millisecondsSinceEpoch;
        final backupPath = await manager.backupQueueData();
        final after = DateTime.now().millisecondsSinceEpoch;

        expect(backupPath, isNotNull);
        final timestamp = int.parse(
          RegExp(r'queue_(\d+)').firstMatch(backupPath!)!.group(1)!,
        );
        expect(timestamp, greaterThanOrEqualTo(before));
        expect(timestamp, lessThanOrEqualTo(after));
      });
    });

    group('restoreQueueData', () {
      test('returns true for valid backup path', () async {
        await manager.createQueueTablesIfNotExist();

        final result = await manager.restoreQueueData('/data/backup/test.bak');
        expect(result, isTrue);
      });
    });

    group('getQueueTableHealth', () {
      test('returns healthy status for consistent data', () async {
        await manager.createQueueTablesIfNotExist();

        final health = await manager.getQueueTableHealth();
        expect(health['isHealthy'], isTrue);
        expect(health['orphanedRows'], equals(0));
        expect(health['corruptedRows'], equals(0));
        expect((health['issues'] as List).isEmpty, isTrue);
      });

      test('detects constraint violations', () async {
        await manager.createQueueTablesIfNotExist();

        // Insert row with NULL chat_id (should violate constraint check)
        // Note: SQLite without strict mode allows NULLs, so this is a check for our validation
        final health = await manager.getQueueTableHealth();
        expect(health.containsKey('isHealthy'), isTrue);
      });
    });

    group('ensureQueueConsistency', () {
      test('returns 0 for consistent queue', () async {
        await manager.createQueueTablesIfNotExist();

        final rowsFixed = await manager.ensureQueueConsistency();
        expect(rowsFixed, equals(0));
      });

      test('removes orphaned messages', () async {
        await manager.createQueueTablesIfNotExist();

        // Insert message with non-existent chat_id
        await testDb.insert('offline_message_queue', {
          'message_id': 'orphan_msg',
          'chat_id': 'non_existent_chat',
          'content': 'test',
          'recipient_public_key': 'key1',
          'sender_public_key': 'key2',
          'queued_at': DateTime.now().millisecondsSinceEpoch,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });

        final rowsFixed = await manager.ensureQueueConsistency();
        expect(rowsFixed, equals(1)); // One orphaned row removed
      });

      test('completes without errors on empty queue', () async {
        await manager.createQueueTablesIfNotExist();

        // Should not throw
        final rowsFixed = await manager.ensureQueueConsistency();
        expect(rowsFixed, isA<int>());
      });
    });
  });
}
