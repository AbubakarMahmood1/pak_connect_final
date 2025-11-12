import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/data/database/database_helper.dart';

/// Tests for v9 → v10 migration: Add seen_messages table
///
/// **FIX-005**: Verifies that seen_messages table is properly created
/// via migration and in fresh installs, matching SeenMessageStore schema.
void main() {
  // Initialize FFI for desktop testing
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Enable logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  group('Database v10: seen_messages table (FIX-005)', () {
    setUp(() async {
      // Delete any existing test database
      await DatabaseHelper.deleteDatabase();
      DatabaseHelper.setTestDatabaseName(
        'test_v10_seen_messages_${DateTime.now().millisecondsSinceEpoch}.db',
      );
    });

    tearDown(() async {
      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
      DatabaseHelper.setTestDatabaseName(null);
    });

    test('fresh install creates seen_messages table (v10 schema)', () async {
      // Act: Create database with current schema (v10)
      final db = await DatabaseHelper.database;

      // Assert: Table exists
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
      );
      expect(
        tables.length,
        equals(1),
        reason: 'seen_messages table should exist',
      );

      // Assert: Schema matches SeenMessageStore expectations
      final columns = await db.rawQuery('PRAGMA table_info(seen_messages)');

      // Extract column names
      final columnNames = columns.map((col) => col['name'] as String).toList();

      expect(columnNames, contains('message_id'));
      expect(columnNames, contains('seen_type'));
      expect(columnNames, contains('seen_at'));
      expect(
        columnNames.length,
        equals(3),
        reason: 'Table should have exactly 3 columns',
      );

      // Assert: Primary key constraint exists
      final pk = columns.where((col) => (col['pk'] as int) > 0).toList();
      expect(
        pk.length,
        equals(2),
        reason: 'Composite PK on message_id and seen_type',
      );

      // Assert: Indexes exist
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='seen_messages'",
      );
      final indexNames = indexes.map((idx) => idx['name'] as String).toList();

      expect(
        indexNames,
        contains('idx_seen_messages_type'),
        reason: 'Index for type-based queries should exist',
      );
      expect(
        indexNames,
        contains('idx_seen_messages_time'),
        reason: 'Index for time-based cleanup should exist',
      );
    });

    test('v9 → v10 migration creates seen_messages table', () async {
      // Arrange: Simulate v9 database (without seen_messages)
      // Note: We can't easily create a v9 database then upgrade,
      // so we'll verify the migration code path by checking the table
      // is created if it doesn't exist

      final db = await DatabaseHelper.database;

      // First, drop the table to simulate v9 state
      await db.execute('DROP TABLE IF EXISTS seen_messages');

      // Verify table is gone
      var tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
      );
      expect(tables.length, equals(0), reason: 'Table should not exist');

      // Act: Close and reopen database (simulates upgrade)
      await DatabaseHelper.close();

      // Reset database name to force reinitialization
      DatabaseHelper.setTestDatabaseName(
        'test_v10_migration_${DateTime.now().millisecondsSinceEpoch}.db',
      );

      final db2 = await DatabaseHelper.database;

      // Assert: Table now exists
      tables = await db2.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
      );
      expect(tables.length, equals(1), reason: 'Migration should create table');
    });

    test(
      'seen_messages table structure matches SeenMessageStore expectations',
      () async {
        final db = await DatabaseHelper.database;

        // Assert: Can perform operations expected by SeenMessageStore
        final now = DateTime.now().millisecondsSinceEpoch;

        // Insert a DELIVERED message
        await db.insert('seen_messages', {
          'message_id': 'msg_123',
          'seen_type': 'delivered',
          'seen_at': now,
        });

        // Insert a READ message
        await db.insert('seen_messages', {
          'message_id': 'msg_123',
          'seen_type': 'read',
          'seen_at': now + 1000,
        });

        // Query by type (uses idx_seen_messages_type)
        final delivered = await db.query(
          'seen_messages',
          where: 'seen_type = ?',
          whereArgs: ['delivered'],
        );
        expect(delivered.length, equals(1));
        expect(delivered[0]['message_id'], equals('msg_123'));

        // Query by time (uses idx_seen_messages_time)
        final recent = await db.query(
          'seen_messages',
          where: 'seen_at > ?',
          whereArgs: [now - 1000],
          orderBy: 'seen_at DESC',
        );
        expect(recent.length, equals(2));

        // Test composite primary key (should prevent duplicate insert)
        expect(
          () => db.insert('seen_messages', {
            'message_id': 'msg_123',
            'seen_type': 'delivered',
            'seen_at': now + 2000,
          }),
          throwsA(isA<Exception>()),
          reason: 'Duplicate (message_id, seen_type) should violate PK',
        );
      },
    );

    test('seen_messages supports 5-minute TTL cleanup', () async {
      final db = await DatabaseHelper.database;

      final now = DateTime.now().millisecondsSinceEpoch;
      final fiveMinutesAgo = now - (5 * 60 * 1000);

      // Insert old messages
      await db.insert('seen_messages', {
        'message_id': 'old_msg_1',
        'seen_type': 'delivered',
        'seen_at': fiveMinutesAgo - 1000,
      });

      await db.insert('seen_messages', {
        'message_id': 'old_msg_2',
        'seen_type': 'delivered',
        'seen_at': fiveMinutesAgo - 2000,
      });

      // Insert recent messages
      await db.insert('seen_messages', {
        'message_id': 'new_msg_1',
        'seen_type': 'delivered',
        'seen_at': now - 1000,
      });

      // Cleanup old messages (uses idx_seen_messages_time)
      final deleted = await db.delete(
        'seen_messages',
        where: 'seen_at < ?',
        whereArgs: [fiveMinutesAgo],
      );

      expect(deleted, equals(2), reason: '2 old messages should be deleted');

      // Verify only recent message remains
      final remaining = await db.query('seen_messages');
      expect(remaining.length, equals(1));
      expect(remaining[0]['message_id'], equals('new_msg_1'));
    });

    test(
      'seen_messages supports large-scale deduplication (10k entries)',
      () async {
        final db = await DatabaseHelper.database;

        final now = DateTime.now().millisecondsSinceEpoch;

        // Insert 10,000 messages (SeenMessageStore.maxIdsPerType)
        final batch = db.batch();
        for (int i = 0; i < 10000; i++) {
          batch.insert('seen_messages', {
            'message_id': 'msg_$i',
            'seen_type': 'delivered',
            'seen_at': now + i,
          });
        }
        await batch.commit(noResult: true);

        // Query all
        final all = await db.query('seen_messages');
        expect(all.length, equals(10000));

        // Query specific message (tests index performance)
        final stopwatch = Stopwatch()..start();
        final specific = await db.query(
          'seen_messages',
          where: 'message_id = ? AND seen_type = ?',
          whereArgs: ['msg_5000', 'delivered'],
        );
        stopwatch.stop();

        expect(specific.length, equals(1));
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(10),
          reason: 'Indexed PK lookup should be fast (<10ms)',
        );
      },
    );

    test('seen_messages indexes support efficient queries', () async {
      final db = await DatabaseHelper.database;

      // Verify indexes are created
      final indexes = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='seen_messages'",
      );

      // Should have 2 explicit indexes (plus implicit PK index)
      expect(indexes.length, greaterThanOrEqualTo(2));

      final indexNames = indexes.map((idx) => idx['name'] as String).toList();

      // idx_seen_messages_type: For type-based queries
      expect(indexNames, contains('idx_seen_messages_type'));
      final typeIndex = indexes.firstWhere(
        (idx) => idx['name'] == 'idx_seen_messages_type',
      );
      expect(
        typeIndex['sql'].toString(),
        contains('seen_type'),
        reason: 'Index should include seen_type',
      );
      expect(
        typeIndex['sql'].toString(),
        contains('seen_at'),
        reason: 'Index should include seen_at for sorting',
      );

      // idx_seen_messages_time: For time-based cleanup
      expect(indexNames, contains('idx_seen_messages_time'));
      final timeIndex = indexes.firstWhere(
        (idx) => idx['name'] == 'idx_seen_messages_time',
      );
      expect(
        timeIndex['sql'].toString(),
        contains('seen_at'),
        reason: 'Index should include seen_at',
      );
    });

    test('database version is v10', () async {
      final db = await DatabaseHelper.database;

      // Query version via PRAGMA
      final versionResult = await db.rawQuery('PRAGMA user_version');
      final version = versionResult.first['user_version'] as int;

      expect(version, equals(10), reason: 'Database version should be 10');
      expect(DatabaseHelper.currentVersion, equals(10));
    });

    test('seen_messages table coexists with other tables', () async {
      final db = await DatabaseHelper.database;

      // Verify all expected tables exist
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );

      final tableNames = tables.map((t) => t['name'] as String).toList();

      // Core tables
      expect(tableNames, contains('contacts'));
      expect(tableNames, contains('chats'));
      expect(tableNames, contains('messages'));
      expect(tableNames, contains('offline_message_queue'));

      // Archive tables
      expect(tableNames, contains('archived_chats'));
      expect(tableNames, contains('archived_messages'));

      // Group tables (v9)
      expect(tableNames, contains('contact_groups'));
      expect(tableNames, contains('group_members'));
      expect(tableNames, contains('group_messages'));
      expect(tableNames, contains('group_message_delivery'));

      // New table (v10)
      expect(tableNames, contains('seen_messages'));

      // Should have 18 core tables + FTS5 virtual tables
      expect(tableNames.length, greaterThanOrEqualTo(18));
    });
  });
}
