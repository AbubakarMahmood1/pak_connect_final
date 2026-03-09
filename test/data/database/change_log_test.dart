import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  final logRecords = <LogRecord>[];
  late Set<String> allowedSevere;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'change_log');
  });

  setUp(() async {
    logRecords.clear();
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    SharedPreferences.setMockInitialValues({});
    await TestSetup.fullDatabaseReset();
  });

  tearDown(() {
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) =>
              !allowedSevere.any((pattern) => log.message.contains(pattern)),
        )
        .toList();
    expect(severeErrors, isEmpty,
        reason: 'Unexpected SEVERE logs: ${severeErrors.map((l) => l.message)}');
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  // ── Schema verification ──────────────────────────────────────────

  group('change_log table schema', () {
    test('change_log table exists', () async {
      final db = await DatabaseHelper.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='change_log'",
      );
      expect(tables, isNotEmpty);
    });

    test('change_log has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(change_log)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'id',
        'table_name',
        'operation',
        'row_key',
        'changed_at',
      ]));
    });

    test('change_log has time indexes', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='change_log'",
      );
      final indexNames = indexes.map((i) => i['name'] as String).toSet();
      expect(indexNames, contains('idx_change_log_table_time'));
      expect(indexNames, contains('idx_change_log_time'));
    });
  });

  // ── Trigger verification ─────────────────────────────────────────

  group('change_log triggers', () {
    test('9 triggers exist', () async {
      final db = await DatabaseHelper.database;
      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_%'",
      );
      final names = triggers.map((t) => t['name'] as String).toSet();
      expect(names, containsAll([
        'trg_contacts_insert',
        'trg_contacts_update',
        'trg_contacts_delete',
        'trg_chats_insert',
        'trg_chats_update',
        'trg_chats_delete',
        'trg_messages_insert',
        'trg_messages_update',
        'trg_messages_delete',
      ]));
    });
  });

  // ── Contacts triggers ────────────────────────────────────────────

  group('contacts triggers', () {
    Future<Map<String, Object?>> insertContact(
      dynamic db,
      String pk, {
      String name = 'Test',
    }) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = {
        'public_key': pk,
        'display_name': name,
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      };
      await db.insert('contacts', row);
      return row;
    }

    test('INSERT fires trigger', () async {
      final db = await DatabaseHelper.database;
      await insertContact(db, 'pk_insert_test');

      final logs = await db.query('change_log',
          where: "table_name = 'contacts' AND operation = 'INSERT' AND row_key = ?",
          whereArgs: ['pk_insert_test']);
      expect(logs, hasLength(1));
      expect(logs.first['changed_at'], isA<int>());
    });

    test('UPDATE fires trigger', () async {
      final db = await DatabaseHelper.database;
      await insertContact(db, 'pk_update_test');

      await db.update('contacts', {'display_name': 'Updated'},
          where: 'public_key = ?', whereArgs: ['pk_update_test']);

      final logs = await db.query('change_log',
          where: "table_name = 'contacts' AND operation = 'UPDATE' AND row_key = ?",
          whereArgs: ['pk_update_test']);
      expect(logs, hasLength(1));
    });

    test('DELETE fires trigger', () async {
      final db = await DatabaseHelper.database;
      await insertContact(db, 'pk_delete_test');

      await db.delete('contacts',
          where: 'public_key = ?', whereArgs: ['pk_delete_test']);

      final logs = await db.query('change_log',
          where: "table_name = 'contacts' AND operation = 'DELETE' AND row_key = ?",
          whereArgs: ['pk_delete_test']);
      expect(logs, hasLength(1));
    });
  });

  // ── Chats triggers ───────────────────────────────────────────────

  group('chats triggers', () {
    Future<void> seedContactAndChat(dynamic db, String pk, String chatId) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('contacts', {
        'public_key': pk,
        'display_name': 'C',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('chats', {
        'chat_id': chatId,
        'contact_public_key': pk,
        'contact_name': 'C',
        'last_message': '',
        'last_message_time': now,
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });
    }

    test('INSERT fires trigger', () async {
      final db = await DatabaseHelper.database;
      await seedContactAndChat(db, 'chat_pk_i', 'chat_insert_test');

      final logs = await db.query('change_log',
          where: "table_name = 'chats' AND operation = 'INSERT' AND row_key = ?",
          whereArgs: ['chat_insert_test']);
      expect(logs, hasLength(1));
    });

    test('UPDATE fires trigger', () async {
      final db = await DatabaseHelper.database;
      await seedContactAndChat(db, 'chat_pk_u', 'chat_update_test');

      await db.update('chats', {'unread_count': 5},
          where: 'chat_id = ?', whereArgs: ['chat_update_test']);

      final logs = await db.query('change_log',
          where: "table_name = 'chats' AND operation = 'UPDATE' AND row_key = ?",
          whereArgs: ['chat_update_test']);
      expect(logs, hasLength(1));
    });

    test('DELETE fires trigger', () async {
      final db = await DatabaseHelper.database;
      await seedContactAndChat(db, 'chat_pk_d', 'chat_delete_test');

      // Direct delete (cascade deletes don't fire triggers in all SQLite versions)
      await db.delete('chats',
          where: 'chat_id = ?', whereArgs: ['chat_delete_test']);

      final logs = await db.query('change_log',
          where: "table_name = 'chats' AND operation = 'DELETE' AND row_key = ?",
          whereArgs: ['chat_delete_test']);
      expect(logs, hasLength(1));
    });
  });

  // ── Messages triggers ────────────────────────────────────────────

  group('messages triggers', () {
    Future<void> seedContactChatAndMessage(
      dynamic db,
      String pk,
      String chatId,
      String messageId,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('contacts', {
        'public_key': pk,
        'display_name': 'M',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('chats', {
        'chat_id': chatId,
        'contact_public_key': pk,
        'contact_name': 'M',
        'last_message': '',
        'last_message_time': now,
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('messages', {
        'id': messageId,
        'chat_id': chatId,
        'content': 'hello',
        'is_from_me': 1,
        'timestamp': now,
        'status': 0,
        'created_at': now,
        'updated_at': now,
      });
    }

    test('INSERT fires trigger', () async {
      final db = await DatabaseHelper.database;
      await seedContactChatAndMessage(db, 'msg_pk_i', 'msg_chat_i', 'msg_insert_test');

      final logs = await db.query('change_log',
          where: "table_name = 'messages' AND operation = 'INSERT' AND row_key = ?",
          whereArgs: ['msg_insert_test']);
      expect(logs, hasLength(1));
    });

    test('UPDATE fires trigger', () async {
      final db = await DatabaseHelper.database;
      await seedContactChatAndMessage(db, 'msg_pk_u', 'msg_chat_u', 'msg_update_test');

      await db.update('messages', {'content': 'updated'},
          where: 'id = ?', whereArgs: ['msg_update_test']);

      final logs = await db.query('change_log',
          where: "table_name = 'messages' AND operation = 'UPDATE' AND row_key = ?",
          whereArgs: ['msg_update_test']);
      expect(logs, hasLength(1));
    });

    test('DELETE fires trigger', () async {
      final db = await DatabaseHelper.database;
      await seedContactChatAndMessage(db, 'msg_pk_d', 'msg_chat_d', 'msg_delete_test');

      // Direct delete (cascade deletes may not fire triggers)
      await db.delete('messages',
          where: 'id = ?', whereArgs: ['msg_delete_test']);

      final logs = await db.query('change_log',
          where: "table_name = 'messages' AND operation = 'DELETE' AND row_key = ?",
          whereArgs: ['msg_delete_test']);
      expect(logs, hasLength(1));
    });
  });

  // ── Pruning ──────────────────────────────────────────────────────

  group('change_log pruning', () {
    test('prune removes old entries and keeps recent', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final thirtyOneDaysAgo = now - const Duration(days: 31).inMilliseconds;

      // Insert an old entry directly
      await db.insert('change_log', {
        'table_name': 'contacts',
        'operation': 'DELETE',
        'row_key': 'old_pk',
        'changed_at': thirtyOneDaysAgo,
      });

      // Insert a recent entry via trigger
      await db.insert('contacts', {
        'public_key': 'recent_pk',
        'display_name': 'Recent',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      // Prune with default 30-day window
      final deleted = await db.delete(
        'change_log',
        where: 'changed_at < ?',
        whereArgs: [now - const Duration(days: 30).inMilliseconds],
      );

      expect(deleted, greaterThanOrEqualTo(1));

      // Recent entry should survive
      final remaining = await db.query('change_log',
          where: "row_key = 'recent_pk'");
      expect(remaining, isNotEmpty);
    });
  });

  // ── Ordering / incremental query ─────────────────────────────────

  group('incremental query', () {
    test('change_log entries since a timestamp', () async {
      final db = await DatabaseHelper.database;
      final baseTime = DateTime.now().millisecondsSinceEpoch;

      // Insert an old synthetic entry BEFORE baseTime
      await db.insert('change_log', {
        'table_name': 'contacts',
        'operation': 'INSERT',
        'row_key': 'before_base',
        'changed_at': baseTime - 10000,
      });

      // Insert a contact (trigger fires with NOW > baseTime)
      await db.insert('contacts', {
        'public_key': 'after_base',
        'display_name': 'After',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': baseTime + 1000,
        'last_seen': baseTime + 1000,
        'created_at': baseTime + 1000,
        'updated_at': baseTime + 1000,
      });

      // Query with since = baseTime should get only the trigger-generated entry
      final entries = await db.query(
        'change_log',
        where: 'changed_at > ?',
        whereArgs: [baseTime - 5000],
        orderBy: 'id ASC',
      );

      // Should include the trigger entry (changed_at ~ now) but also the
      // synthetic entry at baseTime-10000 if since is baseTime-5000 only
      // the trigger entry is new.  The synthetic entry at baseTime-10000
      // is < baseTime-5000, so excluded.
      final keys = entries.map((e) => e['row_key'] as String).toList();
      expect(keys, contains('after_base'));
      expect(keys, isNot(contains('before_base')));
    });
  });
}
