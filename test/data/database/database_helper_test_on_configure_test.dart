import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_schema_builder.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;

import '../../test_helpers/test_setup.dart';

/// Helper to open an isolated test database via the FFI factory.
Future<sqflite_common.Database> _openRawDb(String name, {
 Future<void> Function(sqflite_common.Database db, int version)? onCreate,
 int version = 1,
}) async {
 final factory = sqflite_common.databaseFactory;
 final basePath = await factory.getDatabasesPath();
 final ts = DateTime.now().microsecondsSinceEpoch;
 final path = p.join(basePath, 'p13c_${name}_$ts.db');
 return factory.openDatabase(path,
 options: sqflite_common.OpenDatabaseOptions(version: version,
 onCreate: onCreate,
 singleInstance: false,
),
);
}

/// Helper to delete a database by its path.
Future<void> _deleteRawDb(sqflite_common.Database db) async {
 final path = db.path;
 await db.close();
 try {
 await sqflite_common.databaseFactory.deleteDatabase(path);
 } catch (_) {}
}

void main() {
 late List<LogRecord> logRecords;
 late Set<String> allowedSevere;

 setUpAll(() async {
 await TestSetup.initializeTestEnvironment(dbLabel: 'db_helper_p13c');
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

 // ==================== _onConfigure ====================
 group('testOnConfigure', () {
 test('enables foreign keys, WAL mode and cache size', () async {
 final db = await _openRawDb('onConfigure');
 addTeardownDb(db) => addTearDown(() => _deleteRawDb(db));
 addTeardownDb(db);

 await DatabaseHelper.testOnConfigure(db);

 final fk = await db.rawQuery('PRAGMA foreign_keys');
 expect(fk.first.values.first, equals(1));

 final wal = await db.rawQuery('PRAGMA journal_mode');
 expect(wal.first.values.first, equals('wal'));

 expect(logRecords.any((l) => l.message.contains('WAL mode set')),
 isTrue,
);
 expect(logRecords.any((l) => l.message.contains('Database configured'),
),
 isTrue,
);
 });
 });

 // ==================== _onCreate ====================
 group('testOnCreate', () {
 test('creates full schema on a blank database', () async {
 final db = await _openRawDb('onCreate');
 addTearDown(() => _deleteRawDb(db));

 await DatabaseHelper.testOnCreate(db, DatabaseHelper.currentVersion);

 final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' "
 "AND name NOT LIKE 'sqlite_%'",
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

 // Verify indexes exist
 final indexes = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='index' "
 "AND name NOT LIKE 'sqlite_%'",
);
 final idxNames = indexes.map((i) => i['name'] as String).toSet();
 expect(idxNames, containsAll([
 'idx_contacts_trust',
 'idx_contacts_security',
 'idx_contacts_last_seen',
 'idx_contacts_favorite',
 'idx_chats_contact',
 'idx_messages_chat_time',
 'idx_queue_status',
 'idx_seen_messages_type',
 'idx_seen_messages_time',
]));
 });
 });

 // ==================== _onUpgrade ====================
 group('testOnUpgrade', () {
 test('v9 to v10 adds seen_messages table', () async {
 final db = await _openRawDb('onUpgrade_v9',
 version: 9,
 onCreate: (db, version) async {
 await DatabaseSchemaBuilder.createSchema(db,
 version,
 logger: Logger('test_schema'),
);
 // seen_messages is always created by schema builder;
 // drop it to simulate a real v9 DB that lacked this table.
 await db.execute('DROP TABLE IF EXISTS seen_messages');
 await db.execute('DROP INDEX IF EXISTS idx_seen_messages_type');
 await db.execute('DROP INDEX IF EXISTS idx_seen_messages_time');
 },
);
 addTearDown(() => _deleteRawDb(db));

 // Confirm seen_messages absent
 var tbl = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
);
 expect(tbl, isEmpty);

 await DatabaseHelper.testOnUpgrade(db, 9, 10);

 tbl = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
);
 expect(tbl, hasLength(1));

 // Verify indexes created
 final idx = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_seen_%'",
);
 expect(idx.length, greaterThanOrEqualTo(2));
 });

 test('full migration v1 to v10 runs all steps', () async {
 // Create a v1-era schema with only v1 tables
 final db = await _openRawDb('onUpgrade_full',
 version: 1,
 onCreate: (db, version) async {
 // Minimal v1 schema: contacts without newer columns
 await db.execute('''
 CREATE TABLE contacts (public_key TEXT PRIMARY KEY,
 display_name TEXT NOT NULL,
 trust_status INTEGER NOT NULL,
 security_level INTEGER NOT NULL,
 first_seen INTEGER NOT NULL,
 last_seen INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
)
 ''');
 await db.execute('''
 CREATE TABLE chats (chat_id TEXT PRIMARY KEY,
 contact_public_key TEXT,
 contact_name TEXT NOT NULL,
 last_message TEXT,
 last_message_time INTEGER,
 unread_count INTEGER DEFAULT 0,
 is_archived INTEGER DEFAULT 0,
 is_muted INTEGER DEFAULT 0,
 is_pinned INTEGER DEFAULT 0,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 FOREIGN KEY (contact_public_key) REFERENCES contacts(public_key) ON DELETE SET NULL
)
 ''');
 // archived tables for v1→v2 migration
 await db.execute('''
 CREATE TABLE archived_chats (archive_id TEXT PRIMARY KEY,
 original_chat_id TEXT NOT NULL,
 contact_name TEXT NOT NULL,
 contact_public_key TEXT,
 archived_at INTEGER NOT NULL,
 last_message_time INTEGER,
 message_count INTEGER NOT NULL,
 archive_reason TEXT,
 estimated_size INTEGER,
 is_compressed INTEGER DEFAULT 0,
 compression_ratio REAL,
 metadata_json TEXT,
 compression_info_json TEXT,
 custom_data_json TEXT,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
)
 ''');
 await db.execute('''
 CREATE TABLE archived_messages (id TEXT PRIMARY KEY,
 archive_id TEXT NOT NULL,
 original_message_id TEXT,
 content TEXT NOT NULL,
 timestamp INTEGER NOT NULL,
 is_from_me INTEGER NOT NULL,
 status INTEGER NOT NULL,
 reply_to_message_id TEXT,
 thread_id TEXT,
 is_starred INTEGER DEFAULT 0,
 is_forwarded INTEGER DEFAULT 0,
 priority INTEGER DEFAULT 0,
 edited_at INTEGER,
 original_content TEXT,
 has_media INTEGER DEFAULT 0,
 media_type TEXT,
 archived_at INTEGER NOT NULL,
 original_timestamp INTEGER NOT NULL,
 metadata_json TEXT,
 delivery_receipt_json TEXT,
 read_receipt_json TEXT,
 reactions_json TEXT,
 attachments_json TEXT,
 encryption_info_json TEXT,
 archive_metadata_json TEXT,
 preserved_state_json TEXT,
 searchable_text TEXT,
 created_at INTEGER NOT NULL,
 FOREIGN KEY (archive_id) REFERENCES archived_chats(archive_id) ON DELETE CASCADE
)
 ''');
 await db.execute('''
 CREATE VIRTUAL TABLE archived_messages_fts USING fts5(searchable_text,
 content=archived_messages,
 content_rowid=rowid,
 tokenize="porter"
)
 ''');
 },
);
 addTearDown(() => _deleteRawDb(db));

 // Run full migration v1 → v10
 await DatabaseHelper.testOnUpgrade(db, 1, 10);

 // Verify v2 migration: archived_messages has chat_id column
 final cols = await db.rawQuery('PRAGMA table_info(archived_messages)');
 final colNames = cols.map((c) => c['name'] as String).toSet();
 expect(colNames, contains('chat_id'));

 // Verify v5 migration: contacts has noise columns
 final contactCols = await db.rawQuery('PRAGMA table_info(contacts)');
 final cNames = contactCols.map((c) => c['name'] as String).toSet();
 expect(cNames, containsAll([
 'noise_public_key',
 'noise_session_state',
 'last_handshake_time',
]));

 // Verify v6: is_favorite
 expect(cNames, contains('is_favorite'));

 // Verify v7: ephemeral_id
 expect(cNames, contains('ephemeral_id'));

 // Verify v8: persistent_public_key, current_ephemeral_id
 expect(cNames, containsAll([
 'persistent_public_key',
 'current_ephemeral_id',
]));

 // Verify v9: contact_groups table
 final groups = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='contact_groups'",
);
 expect(groups, isNotEmpty);

 // Verify v10: seen_messages
 final seen = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
);
 expect(seen, isNotEmpty);
 });
 });

 // ==================== close ====================
 group('close', () {
 test('closes the database', () async {
 // Ensure DB is open
 final db = await DatabaseHelper.database;
 expect(db.isOpen, isTrue);

 await DatabaseHelper.close();

 expect(logRecords.any((l) => l.message.contains('Database closed')),
 isTrue,
);
 });

 test('close is idempotent', () async {
 await DatabaseHelper.close();
 // Second close should not throw
 await DatabaseHelper.close();
 });
 });

 // ==================== _isDatabaseEncrypted ====================
 group('testIsDatabaseEncrypted', () {
 test('returns false when file does not exist', () async {
 final result = await DatabaseHelper.testIsDatabaseEncrypted('/non/existent/path.db',
);
 expect(result, isFalse);
 });

 test('returns false for plaintext SQLite file', () async {
 final factory = sqflite_common.databaseFactory;
 final basePath = await factory.getDatabasesPath();
 final ts = DateTime.now().microsecondsSinceEpoch;
 final path = p.join(basePath, 'p13c_plaintext_$ts.db');

 // Create a real SQLite file (plaintext header)
 final db = await factory.openDatabase(path,
 options: sqflite_common.OpenDatabaseOptions(version: 1,
 singleInstance: false,
),
);
 await db.close();

 final result = await DatabaseHelper.testIsDatabaseEncrypted(path);
 expect(result, isFalse);

 expect(logRecords.any((l) => l.message.contains('plaintext SQLite (not encrypted)'),
),
 isTrue,
);

 await factory.deleteDatabase(path);
 });

 test('returns true for non-SQLite (encrypted-looking) file', () async {
 final factory = sqflite_common.databaseFactory;
 final basePath = await factory.getDatabasesPath();
 final ts = DateTime.now().microsecondsSinceEpoch;
 final filePath = p.join(basePath, 'p13c_encrypted_$ts.db');

 // Write random bytes that don't match the SQLite magic header
 final bytes = Uint8List.fromList(List.generate(64, (i) => (i * 37 + 13) % 256),
);
 await File(filePath).writeAsBytes(bytes);

 final result = await DatabaseHelper.testIsDatabaseEncrypted(filePath);
 expect(result, isTrue);

 expect(logRecords.any((l) => l.message.contains('appears to be encrypted'),
),
 isTrue,
);

 await File(filePath).delete();
 });
 });

 // ==================== _copyDatabaseContents ====================
 // Use simple hand-built schemas to avoid FTS5 shadow table conflicts.
 group('testCopyDatabaseContents', () {
 Future<sqflite_common.Database> createSimpleDb(String name, {
 List<String> extraSql = const [],
 }) async {
 return _openRawDb(name,
 onCreate: (db, version) async {
 await db.execute('''
 CREATE TABLE contacts (public_key TEXT PRIMARY KEY,
 display_name TEXT NOT NULL,
 trust_status INTEGER NOT NULL,
 security_level INTEGER NOT NULL,
 first_seen INTEGER NOT NULL,
 last_seen INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
)
 ''');
 await db.execute('''
 CREATE TABLE chats (chat_id TEXT PRIMARY KEY,
 contact_name TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
)
 ''');
 for (final sql in extraSql) {
 await db.execute(sql);
 }
 },
);
 }

 test('copies rows from source tables to destination', () async {
 final sourceDb = await createSimpleDb('copySrc');
 addTearDown(() => _deleteRawDb(sourceDb));

 final now = DateTime.now().millisecondsSinceEpoch;
 await sourceDb.insert('contacts', {
 'public_key': 'pk_test_1',
 'display_name': 'Alice',
 'trust_status': 1,
 'security_level': 1,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });
 await sourceDb.insert('chats', {
 'chat_id': 'chat_1',
 'contact_name': 'Alice',
 'created_at': now,
 'updated_at': now,
 });

 final destDb = await createSimpleDb('copyDst');
 addTearDown(() => _deleteRawDb(destDb));

 await DatabaseHelper.testCopyDatabaseContents(sourceDb, destDb);

 final contacts = await destDb.query('contacts');
 expect(contacts, hasLength(1));
 expect(contacts.first['public_key'], equals('pk_test_1'));

 final chats = await destDb.query('chats');
 expect(chats, hasLength(1));
 expect(chats.first['chat_id'], equals('chat_1'));

 expect(logRecords.any((l) => l.message.contains('Migration complete')),
 isTrue,
);
 });

 test('skips FTS tables', () async {
 // Source has a table whose name ends in _fts
 final sourceDb = await createSimpleDb('copyFtsSrc', extraSql: [
 'CREATE TABLE search_fts (id TEXT PRIMARY KEY, body TEXT)',
]);
 addTearDown(() => _deleteRawDb(sourceDb));
 await sourceDb.insert('search_fts', {'id': '1', 'body': 'hello'});

 final destDb = await createSimpleDb('copyFtsDst');
 addTearDown(() => _deleteRawDb(destDb));

 await DatabaseHelper.testCopyDatabaseContents(sourceDb, destDb);

 expect(logRecords.any((l) => l.message.contains('Skipping FTS table'),
),
 isTrue,
);
 });

 test('skips tables not present in destination', () async {
 final sourceDb = await createSimpleDb('copyMissingSrc', extraSql: [
 'CREATE TABLE legacy_data (id TEXT PRIMARY KEY, val TEXT)',
]);
 addTearDown(() => _deleteRawDb(sourceDb));
 await sourceDb.insert('legacy_data', {'id': '1', 'val': 'old'});

 final destDb = await createSimpleDb('copyMissingDst');
 addTearDown(() => _deleteRawDb(destDb));

 await DatabaseHelper.testCopyDatabaseContents(sourceDb, destDb);

 expect(logRecords.any((l) => l.message.contains('Skipping table legacy_data'),
),
 isTrue,
);
 });

 test('handles empty source tables', () async {
 final sourceDb = await createSimpleDb('copyEmptySrc');
 addTearDown(() => _deleteRawDb(sourceDb));
 // No rows inserted – tables are empty

 final destDb = await createSimpleDb('copyEmptyDst');
 addTearDown(() => _deleteRawDb(destDb));

 await DatabaseHelper.testCopyDatabaseContents(sourceDb, destDb);

 expect(logRecords.any((l) => l.message.contains('is empty')),
 isTrue,
);
 });
 });

 // ==================== _applyDataMigrationBackfills ====================
 group('testApplyDataMigrationBackfills', () {
 test('backfills current_ephemeral_id from ephemeral_id', () async {
 final db = await _openRawDb('backfill',
 onCreate: (db, version) async {
 await DatabaseSchemaBuilder.createSchema(db,
 version,
 logger: Logger('test'),
);
 },
);
 addTearDown(() => _deleteRawDb(db));

 final now = DateTime.now().millisecondsSinceEpoch;
 // Insert contact with ephemeral_id but null current_ephemeral_id
 await db.insert('contacts', {
 'public_key': 'pk_backfill_1',
 'display_name': 'Bob',
 'trust_status': 1,
 'security_level': 1,
 'first_seen': now,
 'last_seen': now,
 'ephemeral_id': 'eph_123',
 'current_ephemeral_id': null,
 'created_at': now,
 'updated_at': now,
 });
 // Also insert one that already has current_ephemeral_id set
 await db.insert('contacts', {
 'public_key': 'pk_backfill_2',
 'display_name': 'Carol',
 'trust_status': 1,
 'security_level': 1,
 'first_seen': now,
 'last_seen': now,
 'ephemeral_id': 'eph_456',
 'current_ephemeral_id': 'eph_456',
 'created_at': now,
 'updated_at': now,
 });

 await DatabaseHelper.testApplyDataMigrationBackfills(db);

 final rows = await db.query('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk_backfill_1'],
);
 expect(rows.first['current_ephemeral_id'], equals('eph_123'));

 // Carol's should remain unchanged
 final carol = await db.query('contacts',
 where: 'public_key = ?',
 whereArgs: ['pk_backfill_2'],
);
 expect(carol.first['current_ephemeral_id'], equals('eph_456'));

 expect(logRecords.any((l) => l.message.contains('v8 backfill complete'),
),
 isTrue,
);
 });

 test('logs warning when current_ephemeral_id column missing', () async {
 // Create DB with contacts table lacking current_ephemeral_id
 final db = await _openRawDb('backfillNoCol',
 onCreate: (db, version) async {
 await db.execute('''
 CREATE TABLE contacts (public_key TEXT PRIMARY KEY,
 display_name TEXT NOT NULL,
 trust_status INTEGER NOT NULL,
 security_level INTEGER NOT NULL,
 first_seen INTEGER NOT NULL,
 last_seen INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
)
 ''');
 },
);
 addTearDown(() => _deleteRawDb(db));

 await DatabaseHelper.testApplyDataMigrationBackfills(db);

 expect(logRecords.any((l) => l.message.contains('current_ephemeral_id column not found',
),
),
 isTrue,
);
 });

 test('catches and logs errors without rethrowing', () async {
 // Create contacts table with current_ephemeral_id but WITHOUT
 // ephemeral_id so the UPDATE referencing it will throw.
 final db = await _openRawDb('backfillErr',
 onCreate: (db, version) async {
 await db.execute('''
 CREATE TABLE contacts (public_key TEXT PRIMARY KEY,
 display_name TEXT NOT NULL,
 trust_status INTEGER NOT NULL,
 security_level INTEGER NOT NULL,
 first_seen INTEGER NOT NULL,
 last_seen INTEGER NOT NULL,
 current_ephemeral_id TEXT,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
)
 ''');
 },
);
 addTearDown(() => _deleteRawDb(db));

 allowedSevere.add('Failed to apply data migration backfills');

 // Should not throw even though the UPDATE will fail internally
 await DatabaseHelper.testApplyDataMigrationBackfills(db);

 expect(logRecords.any((l) =>
 l.level >= Level.SEVERE &&
 l.message.contains('Failed to apply data migration backfills'),
),
 isTrue,
);
 });
 });

 // ==================== _rebuildFtsIndexes ====================
 group('testRebuildFtsIndexes', () {
 test('rebuilds FTS when archived messages exist', () async {
 final db = await _openRawDb('ftsRebuild',
 onCreate: (db, version) async {
 await DatabaseSchemaBuilder.createSchema(db,
 version,
 logger: Logger('test'),
);
 },
);
 addTearDown(() => _deleteRawDb(db));

 final now = DateTime.now().millisecondsSinceEpoch;

 // Insert an archived chat
 await db.insert('archived_chats', {
 'archive_id': 'arc_1',
 'original_chat_id': 'chat_1',
 'contact_name': 'Alice',
 'archived_at': now,
 'message_count': 1,
 'created_at': now,
 'updated_at': now,
 });

 // Insert an archived message with searchable text
 // Use rawInsert to bypass FTS triggers (simulates a migration scenario)
 await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_insert');
 await db.insert('archived_messages', {
 'id': 'msg_1',
 'archive_id': 'arc_1',
 'chat_id': 'chat_1',
 'content': 'Hello world',
 'timestamp': now,
 'is_from_me': 1,
 'status': 1,
 'archived_at': now,
 'original_timestamp': now,
 'searchable_text': 'Hello world test message',
 'created_at': now,
 });

 // Rebuild FTS
 await DatabaseHelper.testRebuildFtsIndexes(db);

 expect(logRecords.any((l) => l.message.contains('FTS rebuild complete'),
),
 isTrue,
);
 });

 test('skips FTS rebuild when no archived messages', () async {
 final db = await _openRawDb('ftsEmpty',
 onCreate: (db, version) async {
 await DatabaseSchemaBuilder.createSchema(db,
 version,
 logger: Logger('test'),
);
 },
);
 addTearDown(() => _deleteRawDb(db));

 await DatabaseHelper.testRebuildFtsIndexes(db);

 expect(logRecords.any((l) => l.message.contains('No archived messages to index'),
),
 isTrue,
);
 });

 test('catches and logs errors without rethrowing', () async {
 // Create DB without archived_messages table
 final db = await _openRawDb('ftsErr');
 addTearDown(() => _deleteRawDb(db));

 allowedSevere.add('Failed to rebuild FTS indexes');

 await DatabaseHelper.testRebuildFtsIndexes(db);

 expect(logRecords.any((l) =>
 l.level >= Level.SEVERE &&
 l.message.contains('Failed to rebuild FTS indexes'),
),
 isTrue,
);
 });
 });

 // ==================== Full DB lifecycle via public API ====================
 group('DatabaseHelper public API', () {
 test('database getter returns open database', () async {
 final db = await DatabaseHelper.database;
 expect(db.isOpen, isTrue);
 });

 test('database getter returns same instance (singleton)', () async {
 final db1 = await DatabaseHelper.database;
 final db2 = await DatabaseHelper.database;
 expect(identical(db1, db2), isTrue);
 });

 test('close then reopen returns working database', () async {
 await DatabaseHelper.close();
 final db = await DatabaseHelper.database;
 expect(db.isOpen, isTrue);

 // Verify schema is intact after reopen
 final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='contacts'",
);
 expect(tables, isNotEmpty);
 });

 test('deleteDatabase removes DB', () async {
 // Ensure DB exists
 await DatabaseHelper.database;
 await DatabaseHelper.close();
 await DatabaseHelper.deleteDatabase();

 // Re-init with fresh name so subsequent tests work
 await TestSetup.configureTestDatabase(label: 'p13c_after_delete');
 });

 test('exists returns true for open database', () async {
 await DatabaseHelper.database;
 final exists = await DatabaseHelper.exists();
 expect(exists, isTrue);
 });

 test('verifyIntegrity passes on healthy database', () async {
 final result = await DatabaseHelper.verifyIntegrity();
 expect(result, isTrue);
 });

 test('getStatistics returns table counts', () async {
 final stats = await DatabaseHelper.getStatistics();
 expect(stats, contains('table_counts'));
 expect(stats, contains('database_version'));

 final counts = stats['table_counts'] as Map<String, int>;
 expect(counts, contains('contacts'));
 expect(counts, contains('messages'));
 });

 test('getDatabasePath returns non-empty path', () async {
 final path = await DatabaseHelper.getDatabasePath();
 expect(path, isNotEmpty);
 });

 test('getDatabaseSize returns size info', () async {
 await DatabaseHelper.database;
 final size = await DatabaseHelper.getDatabaseSize();
 expect(size, contains('exists'));
 });

 test('vacuum runs successfully', () async {
 await DatabaseHelper.database;
 final result = await DatabaseHelper.vacuum();
 expect(result['success'], isTrue);
 });

 test('isVacuumDue returns true when never vacuumed', () async {
 final due = await DatabaseHelper.isVacuumDue();
 expect(due, isTrue);
 });

 test('vacuumIfDue runs vacuum when due', () async {
 final result = await DatabaseHelper.vacuumIfDue();
 expect(result, isNotNull);
 expect(result!['success'], isTrue);
 });

 test('getMaintenanceStatistics returns stats', () async {
 await DatabaseHelper.database;
 final stats = await DatabaseHelper.getMaintenanceStatistics();
 expect(stats, contains('vacuum_interval_days'));
 });

 test('verifyEncryption returns false on desktop (no SQLCipher)', () async {
 await DatabaseHelper.database;
 final encrypted = await DatabaseHelper.verifyEncryption();
 // On desktop/test, databases are NOT encrypted
 expect(encrypted, isFalse);
 });

 test('clearAllData throws when messages_fts is missing', () async {
 final db = await DatabaseHelper.database;

 final now = DateTime.now().millisecondsSinceEpoch;
 await db.insert('contacts', {
 'public_key': 'pk_clear',
 'display_name': 'Test',
 'trust_status': 1,
 'security_level': 1,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 // messages_fts does not exist in current schema → clearAllData rethrows
 allowedSevere.add('Failed to clear all data');

 expect(() => DatabaseHelper.clearAllData(),
 throwsA(isA<Exception>()),
);
 });
 });
}
