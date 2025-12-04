// Comprehensive database migration tests (v1 → v2 → v3)
// Tests schema upgrades, data preservation, and FTS5 integrity

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' hide equals;
import 'test_helpers/test_setup.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'database_migration');
  });

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
  });

  void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

  tearDown(() {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
  });

  /// Helper: Create v1 schema (original)
  Future<Database> createV1Database(String path) async {
    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          // V1 schema: archived_messages WITHOUT chat_id column
          await db.execute('''
            CREATE TABLE archived_chats (
              archive_id TEXT PRIMARY KEY,
              original_chat_id TEXT NOT NULL,
              contact_name TEXT NOT NULL,
              archive_reason TEXT,
              created_at INTEGER NOT NULL,
              archived_at INTEGER NOT NULL
            )
          ''');

          await db.execute('''
            CREATE TABLE archived_messages (
              id TEXT PRIMARY KEY,
              archive_id TEXT NOT NULL,
              original_message_id TEXT NOT NULL,
              content TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              is_from_me INTEGER NOT NULL,
              status INTEGER NOT NULL,
              reply_to_message_id TEXT,
              thread_id TEXT,
              is_starred INTEGER DEFAULT 0,
              is_forwarded INTEGER DEFAULT 0,
              priority INTEGER DEFAULT 1,
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
            CREATE VIRTUAL TABLE archived_messages_fts USING fts5(
              searchable_text,
              content=archived_messages,
              content_rowid=rowid,
              tokenize="porter"
            )
          ''');

          // V1 included user_preferences table
          await db.execute('''
            CREATE TABLE user_preferences (
              key TEXT PRIMARY KEY,
              value TEXT,
              updated_at INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
  }

  /// Helper: Apply v1→v2 migration
  Future<void> migrateV1toV2(Database db) async {
    // Drop and recreate archived_messages_fts triggers
    await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_insert');
    await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_update');
    await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_delete');

    // Drop FTS5 table
    await db.execute('DROP TABLE IF EXISTS archived_messages_fts');

    // Create temp table with new schema (adds chat_id)
    await db.execute('''
      CREATE TABLE archived_messages_new (
        id TEXT PRIMARY KEY,
        archive_id TEXT NOT NULL,
        original_message_id TEXT NOT NULL,
        chat_id TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_from_me INTEGER NOT NULL,
        status INTEGER NOT NULL,
        reply_to_message_id TEXT,
        thread_id TEXT,
        is_starred INTEGER DEFAULT 0,
        is_forwarded INTEGER DEFAULT 0,
        priority INTEGER DEFAULT 1,
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

    // Copy data from old table
    await db.execute('''
      INSERT INTO archived_messages_new
      SELECT id, archive_id, original_message_id, '', content, timestamp, is_from_me, status,
             reply_to_message_id, thread_id, is_starred, is_forwarded, priority,
             edited_at, original_content, has_media, media_type, archived_at, original_timestamp,
             metadata_json, delivery_receipt_json, read_receipt_json, reactions_json,
             attachments_json, encryption_info_json, archive_metadata_json, preserved_state_json,
             searchable_text, created_at
      FROM archived_messages
    ''');

    // Drop old table
    await db.execute('DROP TABLE archived_messages');

    // Rename new table
    await db.execute(
      'ALTER TABLE archived_messages_new RENAME TO archived_messages',
    );

    // Recreate indexes
    await db.execute(
      'CREATE INDEX idx_archived_msg_archive ON archived_messages(archive_id, timestamp)',
    );
    await db.execute(
      'CREATE INDEX idx_archived_msg_starred ON archived_messages(is_starred) WHERE is_starred = 1',
    );

    // Recreate FTS5 table
    await db.execute('''
      CREATE VIRTUAL TABLE archived_messages_fts USING fts5(
        searchable_text,
        content=archived_messages,
        content_rowid=rowid,
        tokenize="porter"
      )
    ''');

    // Recreate triggers
    await db.execute('''
      CREATE TRIGGER archived_msg_fts_insert AFTER INSERT ON archived_messages
      BEGIN
        INSERT INTO archived_messages_fts(rowid, searchable_text)
        VALUES (new.rowid, new.searchable_text);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_update AFTER UPDATE ON archived_messages
      BEGIN
        UPDATE archived_messages_fts SET searchable_text = new.searchable_text
        WHERE rowid = new.rowid;
      END
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_delete AFTER DELETE ON archived_messages
      BEGIN
        DELETE FROM archived_messages_fts WHERE rowid = old.rowid;
      END
    ''');
  }

  /// Helper: Apply v2→v3 migration
  Future<void> migrateV2toV3(Database db) async {
    await db.execute('DROP TABLE IF EXISTS user_preferences');
  }

  group('Database Migration Tests', () {
    test('v1 schema creates correctly', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'test_v1.db',
      );
      await databaseFactory.deleteDatabase(dbPath);

      final db = await createV1Database(dbPath);

      // Verify v1 schema
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );
      final tableNames = tables.map((t) => t['name'] as String).toList();

      expect(tableNames, contains('archived_chats'));
      expect(tableNames, contains('archived_messages'));
      expect(tableNames, contains('archived_messages_fts'));
      expect(tableNames, contains('user_preferences'));

      // Verify archived_messages does NOT have chat_id column
      final columns = await db.rawQuery('PRAGMA table_info(archived_messages)');
      final columnNames = columns.map((c) => c['name'] as String).toList();
      expect(
        columnNames,
        isNot(contains('chat_id')),
        reason: 'v1 should NOT have chat_id',
      );

      await db.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v1 → v2 migration adds chat_id column', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'test_v1_to_v2.db',
      );
      await databaseFactory.deleteDatabase(dbPath);

      // Create v1 database
      final db = await createV1Database(dbPath);

      // Insert test data in v1
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('archived_chats', {
        'archive_id': 'archive_1',
        'original_chat_id': 'chat_1',
        'contact_name': 'Test Contact',
        'created_at': now,
        'archived_at': now,
      });

      await db.insert('archived_messages', {
        'id': 'msg_1',
        'archive_id': 'archive_1',
        'original_message_id': 'orig_msg_1',
        'content': 'Test message',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'archived_at': now,
        'original_timestamp': now,
        'created_at': now,
      });

      // Verify data exists
      final beforeMigration = await db.query('archived_messages');
      expect(beforeMigration.length, equals(1));

      // Apply v1→v2 migration
      await migrateV1toV2(db);

      // Verify chat_id column now exists
      final columns = await db.rawQuery('PRAGMA table_info(archived_messages)');
      final columnNames = columns.map((c) => c['name'] as String).toList();
      expect(
        columnNames,
        contains('chat_id'),
        reason: 'v2 should have chat_id column',
      );

      // Verify data preserved
      final afterMigration = await db.query('archived_messages');
      expect(afterMigration.length, equals(1));
      expect(afterMigration.first['content'], equals('Test message'));
      expect(
        afterMigration.first['chat_id'],
        equals(''),
        reason: 'Default empty string for chat_id',
      );

      // Verify FTS5 table recreated
      final ftsExists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='archived_messages_fts'",
      );
      expect(ftsExists, isNotEmpty, reason: 'FTS5 table should be recreated');

      // Verify triggers recreated
      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='archived_messages'",
      );
      expect(
        triggers.length,
        equals(3),
        reason: 'Should have insert, update, delete triggers',
      );

      await db.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v2 → v3 migration removes user_preferences table', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'test_v2_to_v3.db',
      );
      await databaseFactory.deleteDatabase(dbPath);

      // Create v1 then migrate to v2
      final db = await createV1Database(dbPath);
      await migrateV1toV2(db);

      // Verify user_preferences exists in v2
      final beforeV3 = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='user_preferences'",
      );
      expect(
        beforeV3,
        isNotEmpty,
        reason: 'user_preferences should exist in v2',
      );

      // Apply v2→v3 migration
      await migrateV2toV3(db);

      // Verify user_preferences is gone in v3
      final afterV3 = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='user_preferences'",
      );
      expect(
        afterV3,
        isEmpty,
        reason: 'user_preferences should be removed in v3',
      );

      await db.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v1 → v3 direct migration applies all changes', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'test_v1_to_v3.db',
      );
      await databaseFactory.deleteDatabase(dbPath);

      // Create v1 database
      final db = await createV1Database(dbPath);

      // Insert test data
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('archived_chats', {
        'archive_id': 'archive_1',
        'original_chat_id': 'chat_1',
        'contact_name': 'Test Contact',
        'created_at': now,
        'archived_at': now,
      });

      await db.insert('archived_messages', {
        'id': 'msg_1',
        'archive_id': 'archive_1',
        'original_message_id': 'orig_msg_1',
        'content': 'Test message for v1→v3',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'archived_at': now,
        'original_timestamp': now,
        'created_at': now,
      });

      // Apply both migrations (v1→v2→v3)
      await migrateV1toV2(db);
      await migrateV2toV3(db);

      // Verify v3 state
      // 1. chat_id column exists
      final columns = await db.rawQuery('PRAGMA table_info(archived_messages)');
      final columnNames = columns.map((c) => c['name'] as String).toList();
      expect(columnNames, contains('chat_id'));

      // 2. user_preferences table is gone
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='user_preferences'",
      );
      expect(tables, isEmpty);

      // 3. Data preserved
      final messages = await db.query('archived_messages');
      expect(messages.length, equals(1));
      expect(messages.first['content'], equals('Test message for v1→v3'));

      // 4. FTS5 functional
      final ftsExists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='archived_messages_fts'",
      );
      expect(ftsExists, isNotEmpty);

      await db.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('FTS5 triggers work after v1→v2 migration', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'test_fts5_triggers.db',
      );
      await databaseFactory.deleteDatabase(dbPath);

      // Create v1 and migrate to v2
      final db = await createV1Database(dbPath);
      await migrateV1toV2(db);

      final now = DateTime.now().millisecondsSinceEpoch;

      // Create archive
      await db.insert('archived_chats', {
        'archive_id': 'archive_1',
        'original_chat_id': 'chat_1',
        'contact_name': 'Test Contact',
        'created_at': now,
        'archived_at': now,
      });

      // Insert message with searchable text
      await db.insert('archived_messages', {
        'id': 'msg_fts_test',
        'archive_id': 'archive_1',
        'original_message_id': 'orig_msg_1',
        'chat_id': 'chat_1',
        'content': 'Hello world',
        'timestamp': now,
        'is_from_me': 1,
        'status': 0,
        'archived_at': now,
        'original_timestamp': now,
        'searchable_text': 'Hello world',
        'created_at': now,
      });

      // Verify FTS5 trigger inserted data
      final ftsResult = await db.rawQuery(
        "SELECT * FROM archived_messages_fts WHERE searchable_text MATCH 'hello'",
      );
      expect(ftsResult, isNotEmpty, reason: 'FTS5 insert trigger should work');

      // Update message
      await db.update(
        'archived_messages',
        {'searchable_text': 'Updated content'},
        where: 'id = ?',
        whereArgs: ['msg_fts_test'],
      );

      // Verify FTS5 update trigger worked
      final ftsAfterUpdate = await db.rawQuery(
        "SELECT * FROM archived_messages_fts WHERE searchable_text MATCH 'Updated'",
      );
      expect(
        ftsAfterUpdate,
        isNotEmpty,
        reason: 'FTS5 update trigger should work',
      );

      // Delete message and cascade to FTS
      await db.delete(
        'archived_messages',
        where: 'id = ?',
        whereArgs: ['msg_fts_test'],
      );

      // Verify message is deleted from main table
      final messagesAfterDelete = await db.query(
        'archived_messages',
        where: 'id = ?',
        whereArgs: ['msg_fts_test'],
      );
      expect(messagesAfterDelete, isEmpty, reason: 'Message should be deleted');

      await db.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('Data integrity preserved across complex migration chain', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'test_data_integrity.db',
      );
      await databaseFactory.deleteDatabase(dbPath);

      // Create v1 with multiple records
      final db = await createV1Database(dbPath);
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('archived_chats', {
        'archive_id': 'archive_1',
        'original_chat_id': 'chat_1',
        'contact_name': 'Alice',
        'created_at': now,
        'archived_at': now,
      });

      final testMessages = [
        {'id': 'msg_1', 'content': 'First message', 'is_starred': 1},
        {'id': 'msg_2', 'content': 'Second message', 'is_starred': 0},
        {'id': 'msg_3', 'content': 'Third message', 'is_starred': 1},
      ];

      for (final msg in testMessages) {
        await db.insert('archived_messages', {
          'id': msg['id'],
          'archive_id': 'archive_1',
          'original_message_id': 'orig_${msg['id']}',
          'content': msg['content'],
          'timestamp': now,
          'is_from_me': 1,
          'status': 0,
          'is_starred': msg['is_starred'],
          'archived_at': now,
          'original_timestamp': now,
          'created_at': now,
        });
      }

      // Apply full migration chain v1→v2→v3
      await migrateV1toV2(db);
      await migrateV2toV3(db);

      // Verify all data intact
      final allMessages = await db.query(
        'archived_messages',
        orderBy: 'id ASC',
      );
      expect(allMessages.length, equals(3));

      expect(allMessages[0]['content'], equals('First message'));
      expect(allMessages[0]['is_starred'], equals(1));
      expect(
        allMessages[0]['chat_id'],
        equals(''),
        reason: 'Default chat_id after migration',
      );

      expect(allMessages[1]['content'], equals('Second message'));
      expect(allMessages[1]['is_starred'], equals(0));

      expect(allMessages[2]['content'], equals('Third message'));
      expect(allMessages[2]['is_starred'], equals(1));

      // Verify starred index works
      final starredMessages = await db.query(
        'archived_messages',
        where: 'is_starred = 1',
      );
      expect(starredMessages.length, equals(2));

      await db.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });

  group('Database Migration v4 → v5 Tests', () {
    test('v4→v5 migration adds Noise Protocol fields to contacts', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'migration_v4_v5_test.db',
      );

      // Create v4 database (without Noise fields)
      final db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, version) async {
            // Create contacts table as it existed in v4
            await db.execute('''
              CREATE TABLE contacts (
                public_key TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                trust_status INTEGER NOT NULL,
                security_level INTEGER NOT NULL,
                first_seen INTEGER NOT NULL,
                last_seen INTEGER NOT NULL,
                last_security_sync INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );

      // Insert test contact data
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('contacts', {
        'public_key': 'test_key_123',
        'display_name': 'Test User',
        'trust_status': 0,
        'security_level': 1,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('contacts', {
        'public_key': 'test_key_456',
        'display_name': 'Another User',
        'trust_status': 1,
        'security_level': 2,
        'first_seen': now,
        'last_seen': now,
        'last_security_sync': now,
        'created_at': now,
        'updated_at': now,
      });

      await db.close();

      // Reopen with v5 migration
      final dbV5 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 5,
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 5) {
              // Apply v4→v5 migration (add Noise fields)
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN noise_public_key TEXT',
              );
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN noise_session_state TEXT',
              );
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN last_handshake_time INTEGER',
              );
            }
          },
        ),
      );

      // Verify schema has new columns
      final tableInfo = await dbV5.rawQuery('PRAGMA table_info(contacts)');
      final columnNames = tableInfo
          .map((row) => row['name'] as String)
          .toList();

      expect(columnNames, contains('noise_public_key'));
      expect(columnNames, contains('noise_session_state'));
      expect(columnNames, contains('last_handshake_time'));

      // Verify existing data is intact with NULL Noise fields
      final contacts = await dbV5.query('contacts', orderBy: 'public_key');
      expect(contacts.length, equals(2));

      // First contact
      expect(contacts[0]['public_key'], equals('test_key_123'));
      expect(contacts[0]['display_name'], equals('Test User'));
      expect(
        contacts[0]['noise_public_key'],
        isNull,
        reason: 'New columns should be NULL after migration',
      );
      expect(contacts[0]['noise_session_state'], isNull);
      expect(contacts[0]['last_handshake_time'], isNull);

      // Second contact
      expect(contacts[1]['public_key'], equals('test_key_456'));
      expect(contacts[1]['display_name'], equals('Another User'));
      expect(contacts[1]['last_security_sync'], equals(now));
      expect(contacts[1]['noise_public_key'], isNull);
      expect(contacts[1]['noise_session_state'], isNull);
      expect(contacts[1]['last_handshake_time'], isNull);

      // Test inserting new contact with Noise fields
      await dbV5.insert('contacts', {
        'public_key': 'noise_test_key',
        'display_name': 'Noise User',
        'trust_status': 0,
        'security_level': 1,
        'first_seen': now,
        'last_seen': now,
        'noise_public_key': 'dGVzdF9ub2lzZV9wdWJsaWNfa2V5',
        'noise_session_state': 'established',
        'last_handshake_time': now,
        'created_at': now,
        'updated_at': now,
      });

      final noiseContact = await dbV5.query(
        'contacts',
        where: 'public_key = ?',
        whereArgs: ['noise_test_key'],
      );

      expect(
        noiseContact.first['noise_public_key'],
        equals('dGVzdF9ub2lzZV9wdWJsaWNfa2V5'),
      );
      expect(noiseContact.first['noise_session_state'], equals('established'));
      expect(noiseContact.first['last_handshake_time'], equals(now));

      // Test updating existing contact with Noise data
      await dbV5.update(
        'contacts',
        {
          'noise_public_key': 'dXBkYXRlZF9rZXk=',
          'noise_session_state': 'handshaking',
          'last_handshake_time': now + 1000,
          'updated_at': now + 1000,
        },
        where: 'public_key = ?',
        whereArgs: ['test_key_123'],
      );

      final updatedContact = await dbV5.query(
        'contacts',
        where: 'public_key = ?',
        whereArgs: ['test_key_123'],
      );

      expect(
        updatedContact.first['noise_public_key'],
        equals('dXBkYXRlZF9rZXk='),
      );
      expect(
        updatedContact.first['noise_session_state'],
        equals('handshaking'),
      );
      expect(updatedContact.first['last_handshake_time'], equals(now + 1000));

      await dbV5.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    test('v4→v5 migration preserves all existing contact data', () async {
      final dbPath = join(
        await databaseFactory.getDatabasesPath(),
        'migration_v4_v5_preserve_test.db',
      );

      // Create v4 database with comprehensive test data
      final db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE contacts (
                public_key TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                trust_status INTEGER NOT NULL,
                security_level INTEGER NOT NULL,
                first_seen INTEGER NOT NULL,
                last_seen INTEGER NOT NULL,
                last_security_sync INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final testContacts = [
        {
          'public_key': 'verified_contact',
          'display_name': 'Verified User',
          'trust_status': 1,
          'security_level': 2,
          'last_security_sync': now - 3600000,
        },
        {
          'public_key': 'new_contact',
          'display_name': 'New User',
          'trust_status': 0,
          'security_level': 0,
          'last_security_sync': null,
        },
        {
          'public_key': 'high_security_contact',
          'display_name': 'High Security User',
          'trust_status': 1,
          'security_level': 3,
          'last_security_sync': now - 1800000,
        },
      ];

      for (final contact in testContacts) {
        await db.insert('contacts', {
          ...contact,
          'first_seen': now - 86400000,
          'last_seen': now - 3600,
          'created_at': now - 86400000,
          'updated_at': now - 3600,
        });
      }

      await db.close();

      // Reopen with v5 migration
      final dbV5 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 5,
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 5) {
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN noise_public_key TEXT',
              );
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN noise_session_state TEXT',
              );
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN last_handshake_time INTEGER',
              );
            }
          },
        ),
      );

      final migratedContacts = await dbV5.query(
        'contacts',
        orderBy: 'public_key',
      );
      expect(migratedContacts.length, equals(3));

      // Verify each contact preserved all original data
      for (var i = 0; i < testContacts.length; i++) {
        final expected = testContacts[i];
        final actual = migratedContacts.firstWhere(
          (c) => c['public_key'] == expected['public_key'],
        );

        expect(actual['display_name'], equals(expected['display_name']));
        expect(actual['trust_status'], equals(expected['trust_status']));
        expect(actual['security_level'], equals(expected['security_level']));
        expect(
          actual['last_security_sync'],
          equals(expected['last_security_sync']),
        );
        expect(actual['first_seen'], equals(now - 86400000));
        expect(actual['last_seen'], equals(now - 3600));

        // New columns should be NULL
        expect(actual['noise_public_key'], isNull);
        expect(actual['noise_session_state'], isNull);
        expect(actual['last_handshake_time'], isNull);
      }

      await dbV5.close();
      await databaseFactory.deleteDatabase(dbPath);
    });
  });
}
