import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';

import 'test_helpers/test_setup.dart';

/// Tests for v9 → v10 migration: Add seen_messages table
///
/// **FIX-005**: Verifies that seen_messages table is properly created
/// via migration and in fresh installs, matching SeenMessageStore schema.
void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'seen_messages_v10');
  });

  group('Database v10: seen_messages table (FIX-005)', () {
    setUp(() async {
      await TestSetup.configureTestDatabase(label: 'seen_messages_v10');
    });

    tearDown(() async {
      await TestSetup.nukeDatabase();
    });

    test('fresh install creates seen_messages table (v10 schema)', () async {
      await _runDbTest(() async {
        final db = await DatabaseHelper.database;

        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
        );
        expect(tables.length, equals(1));

        final columns = await db.rawQuery('PRAGMA table_info(seen_messages)');
        final columnNames = columns
            .map((col) => col['name'] as String)
            .toList();

        expect(
          columnNames,
          containsAll(['message_id', 'seen_type', 'seen_at']),
        );
        expect(columnNames.length, equals(3));

        final pk = columns.where((col) => (col['pk'] as int) > 0).toList();
        expect(pk.length, equals(2));

        final indexes = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='seen_messages'",
        );
        final indexNames = indexes.map((idx) => idx['name'] as String).toList();

        expect(indexNames, contains('idx_seen_messages_type'));
        expect(indexNames, contains('idx_seen_messages_time'));
      });
    });

    test('v9 → v10 migration creates seen_messages table', () async {
      await _runDbTest(() async {
        final db = await DatabaseHelper.database;
        await db.execute('DROP TABLE IF EXISTS seen_messages');

        var tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
        );
        expect(tables.length, equals(0));

        await TestSetup.configureTestDatabase(label: 'seen_messages_v10');
        final db2 = await DatabaseHelper.database;
        tables = await db2.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
        );
        expect(tables.length, equals(1));
      });
    });

    test(
      'seen_messages table structure matches SeenMessageStore expectations',
      () async {
        await _runDbTest(() async {
          final db = await DatabaseHelper.database;
          final now = DateTime.now().millisecondsSinceEpoch;

          await db.insert('seen_messages', {
            'message_id': 'msg_123',
            'seen_type': 'delivered',
            'seen_at': now,
          });

          await db.insert('seen_messages', {
            'message_id': 'msg_123',
            'seen_type': 'read',
            'seen_at': now + 1000,
          });

          final delivered = await db.query(
            'seen_messages',
            where: 'seen_type = ?',
            whereArgs: ['delivered'],
          );
          expect(delivered.length, equals(1));

          final recent = await db.query(
            'seen_messages',
            where: 'seen_at > ?',
            whereArgs: [now - 1000],
            orderBy: 'seen_at DESC',
          );
          expect(recent.length, equals(2));

          expect(
            () => db.insert('seen_messages', {
              'message_id': 'msg_123',
              'seen_type': 'delivered',
              'seen_at': now + 2000,
            }),
            throwsA(isA<Exception>()),
          );
        });
      },
    );

    test('seen_messages supports 5-minute TTL cleanup', () async {
      await _runDbTest(() async {
        final db = await DatabaseHelper.database;

        final now = DateTime.now().millisecondsSinceEpoch;
        final fiveMinutesAgo = now - (5 * 60 * 1000);

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

        await db.insert('seen_messages', {
          'message_id': 'new_msg_1',
          'seen_type': 'delivered',
          'seen_at': now,
        });

        await db.insert('seen_messages', {
          'message_id': 'new_msg_2',
          'seen_type': 'delivered',
          'seen_at': now - 1000,
        });

        final deleted = await db.delete(
          'seen_messages',
          where: 'seen_at < ?',
          whereArgs: [fiveMinutesAgo],
        );

        expect(deleted, equals(2));

        final remaining = await db.query('seen_messages');
        expect(remaining.length, equals(2));
      });
    });
  });
}

Future<void> _runDbTest(Future<void> Function() body) async {
  try {
    await body();
  } catch (e) {
    final message = e.toString();
    final skip =
        message.contains('Failed to load dynamic library') ||
        message.contains('databaseFactory not initialized');
    if (skip) {
      // ignore: avoid_print
      print(
        '⚠️  Skipping seen_messages DB test - SQLite FFI unavailable:\n$message',
      );
      return;
    }
    rethrow;
  }
}
