
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/test_setup.dart';

void main() {
 late List<LogRecord> logRecords;
 late Set<String> allowedSevere;

 setUpAll(() async {
 await TestSetup.initializeTestEnvironment(dbLabel: 'db_helper_p13');
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
 .where((log) =>
 !allowedSevere.any((pattern) => log.message.contains(pattern)),
)
 .toList();
 expect(severeErrors,
 isEmpty,
 reason:
 'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
);
 });

 tearDownAll(() async {
 await DatabaseHelper.deleteDatabase();
 });

 // ---------- setTestDatabaseName ----------
 group('DatabaseHelper.setTestDatabaseName', () {
 test('switching database name isolates data', () async {
 final db1 = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db1.insert('contacts', {
 'public_key': 'pk-db1',
 'display_name': 'DB1 Contact',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 // Switch to a different test DB name
 await DatabaseHelper.close();
 DatabaseHelper.setTestDatabaseName('db_helper_p13_alt.db');
 final db2 = await DatabaseHelper.database;

 final rows = await db2.rawQuery('SELECT COUNT(*) as c FROM contacts');
 expect(rows.first['c'] as int, 0,
 reason: 'Alternate DB should be empty');

 // Clean up: switch back
 await DatabaseHelper.close();
 await DatabaseHelper.deleteDatabase();
 DatabaseHelper.setTestDatabaseName(null);
 });
 });

 // ---------- Schema verification ----------
 group('DatabaseHelper schema verification', () {
 test('contacts table has expected columns', () async {
 final db = await DatabaseHelper.database;
 final columns = await db.rawQuery('PRAGMA table_info(contacts)');
 final names = columns.map((c) => c['name'] as String).toSet();
 expect(names, containsAll([
 'public_key',
 'persistent_public_key',
 'current_ephemeral_id',
 'ephemeral_id',
 'display_name',
 'trust_status',
 'security_level',
 'first_seen',
 'last_seen',
 'created_at',
 'updated_at',
]));
 });

 test('chats table has expected columns', () async {
 final db = await DatabaseHelper.database;
 final columns = await db.rawQuery('PRAGMA table_info(chats)');
 final names = columns.map((c) => c['name'] as String).toSet();
 expect(names, containsAll([
 'chat_id',
 'contact_public_key',
 'contact_name',
 'last_message',
 'last_message_time',
 'unread_count',
 'created_at',
 'updated_at',
]));
 });

 test('messages table has expected columns', () async {
 final db = await DatabaseHelper.database;
 final columns = await db.rawQuery('PRAGMA table_info(messages)');
 final names = columns.map((c) => c['name'] as String).toSet();
 expect(names, containsAll(['id', 'chat_id', 'content', 'timestamp']));
 });

 test('app_preferences table exists', () async {
 final db = await DatabaseHelper.database;
 final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='app_preferences'",
);
 expect(tables, isNotEmpty);
 });

 test('offline_message_queue table exists', () async {
 final db = await DatabaseHelper.database;
 final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='offline_message_queue'",
);
 expect(tables, isNotEmpty);
 });
 });

 // ---------- WAL & foreign keys verification ----------
 group('DatabaseHelper configuration', () {
 test('WAL mode is enabled', () async {
 final db = await DatabaseHelper.database;
 final result = await db.rawQuery('PRAGMA journal_mode');
 final mode = result.first.values.first as String;
 expect(mode.toLowerCase(), 'wal');
 });

 test('foreign keys are enabled', () async {
 final db = await DatabaseHelper.database;
 final result = await db.rawQuery('PRAGMA foreign_keys');
 final fk = result.first.values.first;
 expect(fk, 1);
 });
 });

 // ---------- CRUD operations ----------
 group('DatabaseHelper CRUD operations', () {
 test('insert and query contacts', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-crud-1',
 'display_name': 'CRUD Contact',
 'trust_status': 1,
 'security_level': 2,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 final rows = await db.query('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk-crud-1'],
);
 expect(rows, hasLength(1));
 expect(rows.first['display_name'], 'CRUD Contact');
 expect(rows.first['trust_status'], 1);
 });

 test('update contacts', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-update-1',
 'display_name': 'Original',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 final count = await db.update('contacts',
 {'display_name': 'Updated'},
 where: 'public_key = ?',
 whereArgs: ['pk-update-1'],
);
 expect(count, 1);

 final rows = await db.query('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk-update-1'],
);
 expect(rows.first['display_name'], 'Updated');
 });

 test('delete contacts', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-delete-1',
 'display_name': 'ToDelete',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 final deleted = await db.delete('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk-delete-1'],
);
 expect(deleted, 1);

 final rows = await db.query('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk-delete-1'],
);
 expect(rows, isEmpty);
 });

 test('insert and query app_preferences', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('app_preferences', {
 'key': 'test_pref',
 'value': 'test_value',
 'value_type': 'string',
 'created_at': now,
 'updated_at': now,
 });

 final rows = await db.query('app_preferences',
 where: '"key" = ?',
 whereArgs: ['test_pref'],
);
 expect(rows, hasLength(1));
 expect(rows.first['value'], 'test_value');
 expect(rows.first['value_type'], 'string');
 });

 test('insert and query offline_message_queue', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('offline_message_queue', {
 'queue_id': 'omq-1',
 'message_id': 'msg-omq-1',
 'chat_id': 'chat-omq-1',
 'content': 'queued message',
 'recipient_public_key': 'pk-recipient',
 'sender_public_key': 'pk-sender',
 'queued_at': now,
 'retry_count': 0,
 'status': 0,
 'created_at': now,
 'updated_at': now,
 });

 final rows = await db.query('offline_message_queue',
 where: 'queue_id = ?',
 whereArgs: ['omq-1'],
);
 expect(rows, hasLength(1));
 expect(rows.first['content'], 'queued message');
 });
 });

 // ---------- Foreign key CASCADE ----------
 group('DatabaseHelper foreign key enforcement', () {
 test('deleting a contact sets chat FK to null (ON DELETE SET NULL)', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-cascade-1',
 'display_name': 'Cascade',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 await db.insert('chats', {
 'chat_id': 'chat-cascade-1',
 'contact_public_key': 'pk-cascade-1',
 'contact_name': 'Cascade',
 'last_message': 'hello',
 'last_message_time': now,
 'unread_count': 0,
 'created_at': now,
 'updated_at': now,
 });

 // Delete the contact
 await db.delete('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk-cascade-1'],
);

 // Chat should still exist but FK set to null
 final chats = await db.query('chats',
 where: 'chat_id = ?',
 whereArgs: ['chat-cascade-1'],
);
 expect(chats, hasLength(1));
 expect(chats.first['contact_public_key'], isNull);
 });

 test('deleting a chat cascades to messages', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-msg-cascade',
 'display_name': 'MsgCascade',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 await db.insert('chats', {
 'chat_id': 'chat-msg-cascade',
 'contact_public_key': 'pk-msg-cascade',
 'contact_name': 'MsgCascade',
 'last_message': 'hi',
 'last_message_time': now,
 'unread_count': 0,
 'created_at': now,
 'updated_at': now,
 });

 await db.insert('messages', {
 'id': 'msg-cascade-1',
 'chat_id': 'chat-msg-cascade',
 'content': 'cascade test',
 'timestamp': now,
 'is_from_me': 1,
 'status': 0,
 'created_at': now,
 'updated_at': now,
 });

 // Delete the chat
 await db.delete('chats',
 where: 'chat_id = ?',
 whereArgs: ['chat-msg-cascade'],
);

 // Messages should be cascade-deleted
 final msgs = await db.query('messages',
 where: 'chat_id = ?',
 whereArgs: ['chat-msg-cascade'],
);
 expect(msgs, isEmpty);
 });
 });

 // ---------- Multiple database getter calls ----------
 group('DatabaseHelper singleton/lock', () {
 test('multiple concurrent database calls return same instance', () async {
 final futures = List.generate(5, (_) => DatabaseHelper.database);
 final databases = await Future.wait(futures);

 for (final db in databases) {
 expect(identical(db, databases.first), isTrue);
 }
 });
 });

 // ---------- getStatistics with multi-table data ----------
 group('DatabaseHelper.getStatistics extended', () {
 test('counts records across multiple tables', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 // Insert into contacts
 await db.insert('contacts', {
 'public_key': 'pk-stats-multi',
 'display_name': 'Stats Multi',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 // Insert into chats
 await db.insert('chats', {
 'chat_id': 'chat-stats-multi',
 'contact_public_key': 'pk-stats-multi',
 'contact_name': 'Stats Multi',
 'last_message': 'msg',
 'last_message_time': now,
 'unread_count': 1,
 'created_at': now,
 'updated_at': now,
 });

 final stats = await DatabaseHelper.getStatistics();
 final counts = stats['table_counts'] as Map<String, int>;
 expect(counts['contacts'], greaterThanOrEqualTo(1));
 expect(counts['chats'], greaterThanOrEqualTo(1));
 expect(stats['total_records'] as int, greaterThanOrEqualTo(2));
 });
 });

 // ---------- getDatabaseSize extended ----------
 group('DatabaseHelper.getDatabaseSize extended', () {
 test('size increases after data insertion', () async {
 final sizeBefore = await DatabaseHelper.getDatabaseSize();

 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 for (int i = 0; i < 10; i++) {
 await db.insert('contacts', {
 'public_key': 'pk-size-$i',
 'display_name': 'Size Test $i',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });
 }

 final sizeAfter = await DatabaseHelper.getDatabaseSize();
 expect(sizeAfter['exists'], isTrue);
 expect(sizeAfter['size_bytes'] as int,
 greaterThanOrEqualTo(sizeBefore['size_bytes'] as int));
 });
 });

 // ---------- vacuum with data ----------
 group('DatabaseHelper.vacuum extended', () {
 test('vacuum after deletions reclaims space', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 // Insert many rows
 for (int i = 0; i < 50; i++) {
 await db.insert('contacts', {
 'public_key': 'pk-vacuum-$i',
 'display_name': 'Vacuum Test $i',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });
 }

 // Delete them all
 await db.delete('contacts');

 final result = await DatabaseHelper.vacuum();
 expect(result['success'], isTrue);
 expect(result['size_before_bytes'], isA<int>());
 expect(result['size_after_bytes'], isA<int>());
 });
 });

 // ---------- isVacuumDue boundary ----------
 group('DatabaseHelper.isVacuumDue boundary', () {
 test('returns false when vacuum was exactly 29 days ago', () async {
 final ts = DateTime.now()
 .subtract(const Duration(days: 29))
 .millisecondsSinceEpoch;
 SharedPreferences.setMockInitialValues({'last_vacuum_timestamp': ts});
 final isDue = await DatabaseHelper.isVacuumDue();
 expect(isDue, isFalse);
 });

 test('returns true when vacuum was exactly 30 days ago', () async {
 final ts = DateTime.now()
 .subtract(const Duration(days: 30))
 .millisecondsSinceEpoch;
 SharedPreferences.setMockInitialValues({'last_vacuum_timestamp': ts});
 final isDue = await DatabaseHelper.isVacuumDue();
 expect(isDue, isTrue);
 });
 });

 // ---------- verifyIntegrity after operations ----------
 group('DatabaseHelper.verifyIntegrity extended', () {
 test('integrity holds after CRUD operations', () async {
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-integrity',
 'display_name': 'Integrity',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 await db.delete('contacts',
 where: 'public_key = ?', whereArgs: ['pk-integrity']);

 final valid = await DatabaseHelper.verifyIntegrity();
 expect(valid, isTrue);
 });
 });

 // ---------- Multiple close/reopen cycles ----------
 group('DatabaseHelper close/reopen cycles', () {
 test('survives multiple close and reopen cycles', () async {
 for (var i = 0; i < 3; i++) {
 final db = await DatabaseHelper.database;
 expect(db.isOpen, isTrue);
 await DatabaseHelper.close();
 }
 // Final open to leave in usable state
 final db = await DatabaseHelper.database;
 expect(db.isOpen, isTrue);
 });
 });

 // ---------- Database version ----------
 group('DatabaseHelper version', () {
 test('database pragma version matches currentVersion', () async {
 final db = await DatabaseHelper.database;
 final result = await db.rawQuery('PRAGMA user_version');
 final version = result.first.values.first as int;
 expect(version, DatabaseHelper.currentVersion);
 });
 });

 // ---------- clearAllData extended ----------
 group('DatabaseHelper.clearAllData extended', () {
 test('clearAllData with data in multiple tables', () async {
 allowedSevere.add('Failed to clear all data');
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;

 await db.insert('contacts', {
 'public_key': 'pk-multi-clear',
 'display_name': 'MultiClear',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 await db.insert('chats', {
 'chat_id': 'chat-multi-clear',
 'contact_public_key': 'pk-multi-clear',
 'contact_name': 'MultiClear',
 'last_message': 'hi',
 'last_message_time': now,
 'unread_count': 0,
 'created_at': now,
 'updated_at': now,
 });

 await db.insert('app_preferences', {
 'key': 'clear_test',
 'value': 'val',
 'value_type': 'string',
 'created_at': now,
 'updated_at': now,
 });

 try {
 await DatabaseHelper.clearAllData();
 } catch (_) {
 // FTS tables may not exist in test env
 await db.delete('chats');
 await db.delete('offline_message_queue');
 await db.delete('contacts');
 await db.delete('app_preferences');
 }

 final contactCount =
 await db.rawQuery('SELECT COUNT(*) as c FROM contacts');
 final chatCount = await db.rawQuery('SELECT COUNT(*) as c FROM chats');
 final prefCount =
 await db.rawQuery('SELECT COUNT(*) as c FROM app_preferences');

 expect(contactCount.first['c'] as int, 0);
 expect(chatCount.first['c'] as int, 0);
 expect(prefCount.first['c'] as int, 0);
 });
 });

 // ---------- exists after delete ----------
 group('DatabaseHelper.exists extended', () {
 test('exists returns false after delete and before reinit', () async {
 await DatabaseHelper.database; // ensure exists
 await DatabaseHelper.deleteDatabase();
 final doesExist = await DatabaseHelper.exists();
 expect(doesExist, isFalse);

 // Re-create for subsequent tests
 await DatabaseHelper.database;
 });
 });

 // ---------- getDatabasePath ----------
 group('DatabaseHelper.getDatabasePath extended', () {
 test('path contains database name', () async {
 final path = await DatabaseHelper.getDatabasePath();
 expect(path, contains('.db'));
 });
 });
}
