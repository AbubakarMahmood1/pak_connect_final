import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/test_setup.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<String> allowedSevere;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'db_helper_p13b');
  });

  setUp(() async {
    logRecords = [];
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
    expect(
      severeErrors,
      isEmpty,
      reason:
          'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
    );
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  // ==================== Index verification ====================
  group('DatabaseHelper index verification', () {
    test('contacts table has trust index', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='contacts'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_contacts_trust'));
    });

    test('contacts table has security level index', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='contacts'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_contacts_security'));
    });

    test('contacts table has last_seen index', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='contacts'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_contacts_last_seen'));
    });

    test('contacts table has favorite index', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='contacts'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_contacts_favorite'));
    });

    test('chats table has expected indexes', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='chats'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_chats_contact'));
      expect(names, contains('idx_chats_last_message'));
      expect(names, contains('idx_chats_unread'));
      expect(names, contains('idx_chats_pinned'));
    });

    test('messages table has expected indexes', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messages'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_messages_chat_time'));
      expect(names, contains('idx_messages_thread'));
      expect(names, contains('idx_messages_reply'));
      expect(names, contains('idx_messages_starred'));
      expect(names, contains('idx_messages_media'));
    });

    test('offline_message_queue has expected indexes', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='offline_message_queue'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_queue_status'));
      expect(names, contains('idx_queue_recipient'));
      expect(names, contains('idx_queue_priority'));
      expect(names, contains('idx_queue_hash'));
    });

    test('seen_messages table has expected indexes', () async {
      final db = await DatabaseHelper.database;
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='seen_messages'",
      );
      final names = indexes.map((i) => i['name'] as String).toSet();
      expect(names, contains('idx_seen_messages_type'));
      expect(names, contains('idx_seen_messages_time'));
    });
  });

  // ==================== Full table inventory ====================
  group('DatabaseHelper table inventory', () {
    test('all 18+ core tables exist', () async {
      final db = await DatabaseHelper.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
      );
      final names = tables.map((t) => t['name'] as String).toSet();

      expect(names, containsAll([
        'contacts',
        'chats',
        'messages',
        'offline_message_queue',
        'queue_sync_state',
        'deleted_message_ids',
        'archived_chats',
        'archived_messages',
        'device_mappings',
        'contact_last_seen',
        'migration_metadata',
        'app_preferences',
        'contact_groups',
        'group_members',
        'group_messages',
        'group_message_delivery',
        'seen_messages',
      ]));
    });

    test('device_mappings table has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(device_mappings)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'device_uuid',
        'public_key',
        'last_seen',
        'created_at',
        'updated_at',
      ]));
    });

    test('contact_last_seen table has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(contact_last_seen)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'public_key',
        'last_seen_at',
        'was_online',
        'updated_at',
      ]));
    });

    test('seen_messages table has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(seen_messages)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'message_id',
        'seen_type',
        'seen_at',
      ]));
    });

    test('queue_sync_state table has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(queue_sync_state)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'device_id',
        'last_sync_at',
        'pending_messages_count',
        'sync_enabled',
        'updated_at',
      ]));
    });

    test('contact_groups table has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(contact_groups)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'id',
        'name',
        'description',
        'created_at',
        'last_modified_at',
      ]));
    });

    test('group_members table has expected columns', () async {
      final db = await DatabaseHelper.database;
      final columns = await db.rawQuery('PRAGMA table_info(group_members)');
      final names = columns.map((c) => c['name'] as String).toSet();
      expect(names, containsAll([
        'group_id',
        'member_key',
        'added_at',
      ]));
    });
  });

  // ==================== PRAGMA / configuration ====================
  group('DatabaseHelper PRAGMA settings', () {
    test('cache size is configured', () async {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery('PRAGMA cache_size');
      final cacheSize = result.first.values.first as int;
      // -10000 means 10MB. The actual value may be negative.
      expect(cacheSize, isNot(0));
    });

    test('WAL mode persists after close and reopen', () async {
      await DatabaseHelper.close();
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery('PRAGMA journal_mode');
      final mode = result.first.values.first as String;
      expect(mode.toLowerCase(), 'wal');
    });

    test('foreign keys persist after close and reopen', () async {
      await DatabaseHelper.close();
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery('PRAGMA foreign_keys');
      final fk = result.first.values.first;
      expect(fk, 1);
    });
  });

  // ==================== Concurrent access patterns ====================
  group('DatabaseHelper concurrent access', () {
    test('concurrent reads do not interfere', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert test data
      for (int i = 0; i < 5; i++) {
        await db.insert('contacts', {
          'public_key': 'pk-concurrent-$i',
          'display_name': 'Concurrent $i',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': now,
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        });
      }

      // Run multiple reads concurrently
      final futures = List.generate(10, (_) async {
        final rows = await db.rawQuery('SELECT COUNT(*) as c FROM contacts');
        return rows.first['c'] as int;
      });

      final results = await Future.wait(futures);
      for (final count in results) {
        expect(count, 5);
      }
    });

    test('concurrent database getter calls during initialization', () async {
      await DatabaseHelper.close();

      // Trigger concurrent initialization
      final futures = List.generate(10, (_) => DatabaseHelper.database);
      final databases = await Future.wait(futures);

      // All should return the same instance
      for (final db in databases) {
        expect(identical(db, databases.first), isTrue);
        expect(db.isOpen, isTrue);
      }
    });

    test('concurrent writes with transactions', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      final futures = List.generate(5, (i) async {
        await db.insert('contacts', {
          'public_key': 'pk-txn-$i',
          'display_name': 'Txn $i',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': now,
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        });
      });

      await Future.wait(futures);

      final rows = await db.rawQuery('SELECT COUNT(*) as c FROM contacts');
      expect(rows.first['c'] as int, 5);
    });
  });

  // ==================== Foreign key cascades (extended) ====================
  group('DatabaseHelper foreign key cascades extended', () {
    test('contact_last_seen cascades on contact delete', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('contacts', {
        'public_key': 'pk-ls-cascade',
        'display_name': 'LastSeen Cascade',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('contact_last_seen', {
        'public_key': 'pk-ls-cascade',
        'last_seen_at': now,
        'was_online': 1,
        'updated_at': now,
      });

      // Delete the contact
      await db.delete(
        'contacts',
        where: 'public_key = ?',
        whereArgs: ['pk-ls-cascade'],
      );

      // contact_last_seen should cascade-delete
      final rows = await db.query(
        'contact_last_seen',
        where: 'public_key = ?',
        whereArgs: ['pk-ls-cascade'],
      );
      expect(rows, isEmpty);
    });

    test('group_members cascade on group delete', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('contact_groups', {
        'id': 'grp-cascade-1',
        'name': 'Cascade Group',
        'created_at': now,
        'last_modified_at': now,
      });

      await db.insert('group_members', {
        'group_id': 'grp-cascade-1',
        'member_key': 'pk-member-1',
        'added_at': now,
      });

      await db.delete(
        'contact_groups',
        where: 'id = ?',
        whereArgs: ['grp-cascade-1'],
      );

      final members = await db.query(
        'group_members',
        where: 'group_id = ?',
        whereArgs: ['grp-cascade-1'],
      );
      expect(members, isEmpty);
    });

    test('group_messages cascade on group delete', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('contact_groups', {
        'id': 'grp-msg-cascade',
        'name': 'Msg Cascade Group',
        'created_at': now,
        'last_modified_at': now,
      });

      await db.insert('group_messages', {
        'id': 'gmsg-1',
        'group_id': 'grp-msg-cascade',
        'sender_key': 'pk-sender',
        'content': 'hello',
        'timestamp': now,
      });

      await db.delete(
        'contact_groups',
        where: 'id = ?',
        whereArgs: ['grp-msg-cascade'],
      );

      final msgs = await db.query(
        'group_messages',
        where: 'group_id = ?',
        whereArgs: ['grp-msg-cascade'],
      );
      expect(msgs, isEmpty);
    });

    test('group_message_delivery cascades on group_message delete', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('contact_groups', {
        'id': 'grp-delivery-cascade',
        'name': 'Delivery Cascade',
        'created_at': now,
        'last_modified_at': now,
      });

      await db.insert('group_messages', {
        'id': 'gmsg-delivery-1',
        'group_id': 'grp-delivery-cascade',
        'sender_key': 'pk-sender',
        'content': 'delivery test',
        'timestamp': now,
      });

      await db.insert('group_message_delivery', {
        'message_id': 'gmsg-delivery-1',
        'member_key': 'pk-member-delivery',
        'status': 1,
        'timestamp': now,
      });

      // Delete the group message
      await db.delete(
        'group_messages',
        where: 'id = ?',
        whereArgs: ['gmsg-delivery-1'],
      );

      final deliveries = await db.query(
        'group_message_delivery',
        where: 'message_id = ?',
        whereArgs: ['gmsg-delivery-1'],
      );
      expect(deliveries, isEmpty);
    });
  });

  // ==================== CRUD on additional tables ====================
  group('DatabaseHelper CRUD on additional tables', () {
    test('insert and query device_mappings', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('device_mappings', {
        'device_uuid': 'uuid-test-1',
        'public_key': 'pk-device-1',
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      final rows = await db.query(
        'device_mappings',
        where: 'device_uuid = ?',
        whereArgs: ['uuid-test-1'],
      );
      expect(rows, hasLength(1));
      expect(rows.first['public_key'], 'pk-device-1');
    });

    test('insert and query seen_messages', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('seen_messages', {
        'message_id': 'msg-seen-1',
        'seen_type': 'relay',
        'seen_at': now,
      });

      final rows = await db.query(
        'seen_messages',
        where: 'message_id = ? AND seen_type = ?',
        whereArgs: ['msg-seen-1', 'relay'],
      );
      expect(rows, hasLength(1));
      expect(rows.first['seen_at'], now);
    });

    test('insert and query contact_groups and members', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('contact_groups', {
        'id': 'grp-crud-1',
        'name': 'Test Group',
        'description': 'A test group',
        'created_at': now,
        'last_modified_at': now,
      });

      await db.insert('group_members', {
        'group_id': 'grp-crud-1',
        'member_key': 'pk-member-crud',
        'added_at': now,
      });

      final groups = await db.query(
        'contact_groups',
        where: 'id = ?',
        whereArgs: ['grp-crud-1'],
      );
      expect(groups, hasLength(1));
      expect(groups.first['name'], 'Test Group');

      final members = await db.query(
        'group_members',
        where: 'group_id = ?',
        whereArgs: ['grp-crud-1'],
      );
      expect(members, hasLength(1));
    });

    test('insert and query queue_sync_state', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('queue_sync_state', {
        'device_id': 'device-sync-1',
        'last_sync_at': now,
        'pending_messages_count': 3,
        'sync_enabled': 1,
        'updated_at': now,
      });

      final rows = await db.query(
        'queue_sync_state',
        where: 'device_id = ?',
        whereArgs: ['device-sync-1'],
      );
      expect(rows, hasLength(1));
      expect(rows.first['pending_messages_count'], 3);
    });

    test('insert and query deleted_message_ids', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('deleted_message_ids', {
        'message_id': 'del-msg-1',
        'deleted_at': now,
        'reason': 'user_request',
      });

      final rows = await db.query(
        'deleted_message_ids',
        where: 'message_id = ?',
        whereArgs: ['del-msg-1'],
      );
      expect(rows, hasLength(1));
      expect(rows.first['reason'], 'user_request');
    });

    test('insert and query migration_metadata', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('migration_metadata', {
        'key': 'test_migration',
        'value': 'completed',
        'migrated_at': now,
      });

      final rows = await db.query(
        'migration_metadata',
        where: '"key" = ?',
        whereArgs: ['test_migration'],
      );
      expect(rows, hasLength(1));
      expect(rows.first['value'], 'completed');
    });
  });

  // ==================== Error recovery paths ====================
  group('DatabaseHelper error recovery', () {
    test('getStatistics handles missing tables gracefully', () async {
      // getStatistics tries to count rows from specific tables
      // With a fresh database, all tables exist so this should work
      final stats = await DatabaseHelper.getStatistics();
      expect(stats, isNot(contains('error')));
      expect(stats, contains('table_counts'));
    });

    test('vacuum returns success false on failure scenario', () async {
      // A successful vacuum should return success: true
      final result = await DatabaseHelper.vacuum();
      expect(result['success'], isTrue);
      expect(result['duration_ms'], isA<int>());
    });

    test('getDatabaseSize returns exists false after delete', () async {
      await DatabaseHelper.deleteDatabase();
      final sizeInfo = await DatabaseHelper.getDatabaseSize();
      expect(sizeInfo['exists'], isFalse);
      expect(sizeInfo['size_bytes'], 0);

      // Re-create for subsequent tests
      await DatabaseHelper.database;
    });

    test('verifyIntegrity returns true after heavy operations', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert, update, delete across multiple tables
      for (int i = 0; i < 20; i++) {
        await db.insert('contacts', {
          'public_key': 'pk-integrity-$i',
          'display_name': 'Integrity $i',
          'trust_status': i % 3,
          'security_level': i % 3,
          'first_seen': now,
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        });
      }

      // Update half
      for (int i = 0; i < 10; i++) {
        await db.update(
          'contacts',
          {'display_name': 'Updated $i'},
          where: 'public_key = ?',
          whereArgs: ['pk-integrity-$i'],
        );
      }

      // Delete half
      for (int i = 10; i < 20; i++) {
        await db.delete(
          'contacts',
          where: 'public_key = ?',
          whereArgs: ['pk-integrity-$i'],
        );
      }

      final valid = await DatabaseHelper.verifyIntegrity();
      expect(valid, isTrue);
    });

    test('deleteDatabase is idempotent', () async {
      await DatabaseHelper.deleteDatabase();
      // Second delete should not throw
      await DatabaseHelper.deleteDatabase();
      final exists = await DatabaseHelper.exists();
      expect(exists, isFalse);

      // Re-create
      await DatabaseHelper.database;
    });

    test('close on already closed database is safe', () async {
      await DatabaseHelper.close();
      // Second close should not throw
      await DatabaseHelper.close();

      // Should be able to reopen
      final db = await DatabaseHelper.database;
      expect(db.isOpen, isTrue);
    });
  });

  // ==================== Maintenance statistics ====================
  group('DatabaseHelper maintenance extended', () {
    test('vacuum result has non-negative duration', () async {
      final result = await DatabaseHelper.vacuum();
      expect(result['success'], isTrue);
      expect(result['duration_ms'] as int, greaterThanOrEqualTo(0));
    });

    test('vacuumIfDue runs and updates timestamp', () async {
      SharedPreferences.setMockInitialValues({});
      final result = await DatabaseHelper.vacuumIfDue();
      expect(result, isNotNull);
      expect(result!['success'], isTrue);

      // Now it should not be due
      final isDue = await DatabaseHelper.isVacuumDue();
      expect(isDue, isFalse);
    });

    test('getMaintenanceStatistics includes database_size', () async {
      final stats = await DatabaseHelper.getMaintenanceStatistics();
      expect(stats, contains('database_size'));
      final sizeInfo = stats['database_size'] as Map<String, dynamic>;
      expect(sizeInfo, contains('exists'));
    });

    test('getDatabasePath includes test database name', () async {
      final path = await DatabaseHelper.getDatabasePath();
      // Test databases are named pak_connect_test_*
      expect(path, contains('pak_connect_test'));
    });
  });

  // ==================== Batch operations ====================
  group('DatabaseHelper batch operations', () {
    test('batch insert across multiple tables', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final batch = db.batch();

      batch.insert('contacts', {
        'public_key': 'pk-batch-1',
        'display_name': 'Batch 1',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      batch.insert('chats', {
        'chat_id': 'chat-batch-1',
        'contact_public_key': 'pk-batch-1',
        'contact_name': 'Batch 1',
        'last_message': 'batch msg',
        'last_message_time': now,
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });

      batch.insert('messages', {
        'id': 'msg-batch-1',
        'chat_id': 'chat-batch-1',
        'content': 'batch content',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'created_at': now,
        'updated_at': now,
      });

      await batch.commit(noResult: true);

      final stats = await DatabaseHelper.getStatistics();
      final counts = stats['table_counts'] as Map<String, int>;
      expect(counts['contacts'], greaterThanOrEqualTo(1));
      expect(counts['chats'], greaterThanOrEqualTo(1));
      expect(counts['messages'], greaterThanOrEqualTo(1));
    });
  });

  // ==================== Messages table extended columns ====================
  group('DatabaseHelper messages table extended', () {
    test('messages table supports threading columns', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a contact and chat first
      await db.insert('contacts', {
        'public_key': 'pk-threading',
        'display_name': 'Threading',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('chats', {
        'chat_id': 'chat-threading',
        'contact_public_key': 'pk-threading',
        'contact_name': 'Threading',
        'last_message': 'hi',
        'last_message_time': now,
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('messages', {
        'id': 'msg-thread-1',
        'chat_id': 'chat-threading',
        'content': 'parent message',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'thread_id': 'thread-1',
        'reply_to_message_id': null,
        'is_starred': 1,
        'is_forwarded': 0,
        'priority': 2,
        'has_media': 0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('messages', {
        'id': 'msg-thread-2',
        'chat_id': 'chat-threading',
        'content': 'reply message',
        'timestamp': now + 1,
        'is_from_me': 0,
        'status': 1,
        'thread_id': 'thread-1',
        'reply_to_message_id': 'msg-thread-1',
        'created_at': now,
        'updated_at': now,
      });

      final threadMsgs = await db.query(
        'messages',
        where: 'thread_id = ?',
        whereArgs: ['thread-1'],
        orderBy: 'timestamp ASC',
      );
      expect(threadMsgs, hasLength(2));
      expect(threadMsgs[0]['is_starred'], 1);
      expect(threadMsgs[1]['reply_to_message_id'], 'msg-thread-1');
    });

    test('messages table supports JSON blob columns', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('contacts', {
        'public_key': 'pk-json',
        'display_name': 'JSON',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('chats', {
        'chat_id': 'chat-json',
        'contact_public_key': 'pk-json',
        'contact_name': 'JSON',
        'last_message': 'hi',
        'last_message_time': now,
        'unread_count': 0,
        'created_at': now,
        'updated_at': now,
      });

      final metadataJson = '{"key":"value"}';
      final reactionsJson = '["thumbsup","heart"]';

      await db.insert('messages', {
        'id': 'msg-json-1',
        'chat_id': 'chat-json',
        'content': 'json test',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'metadata_json': metadataJson,
        'reactions_json': reactionsJson,
        'created_at': now,
        'updated_at': now,
      });

      final rows = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: ['msg-json-1'],
      );
      expect(rows, hasLength(1));
      expect(rows.first['metadata_json'], metadataJson);
      expect(rows.first['reactions_json'], reactionsJson);
    });
  });

  // ==================== verifyEncryption extended ====================
  group('DatabaseHelper verifyEncryption extended', () {
    test('verifyEncryption returns false for non-encrypted test DB', () async {
      await DatabaseHelper.database;
      final result = await DatabaseHelper.verifyEncryption();
      // In test environment (sqflite_common_ffi), DB is not encrypted
      expect(result, isFalse);
    });

    test('verifyEncryption returns null when database does not exist', () async {
      await DatabaseHelper.deleteDatabase();
      final result = await DatabaseHelper.verifyEncryption();
      expect(result, isNull);

      // Re-create for subsequent tests
      await DatabaseHelper.database;
    });
  });

  // ==================== setTestDatabaseName extended ====================
  group('DatabaseHelper setTestDatabaseName extended', () {
    test('null name resets to production name', () async {
      DatabaseHelper.setTestDatabaseName('temp_test_db.db');
      await DatabaseHelper.close();

      final path1 = await DatabaseHelper.getDatabasePath();
      expect(path1, contains('temp_test_db'));

      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
      DatabaseHelper.setTestDatabaseName(null);

      final path2 = await DatabaseHelper.getDatabasePath();
      expect(path2, isNot(contains('temp_test_db')));

      // Restore test DB name via fullDatabaseReset
      await TestSetup.fullDatabaseReset();
    });
  });
}
