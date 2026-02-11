import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

/// Owns sequential schema migrations for existing installs.
class DatabaseMigrationRunner {
  static Future<void> runMigrations(
    sqlcipher.Database db,
    int oldVersion,
    int newVersion, {
    required Logger logger,
  }) async {
    logger.info('Upgrading database from v$oldVersion to v$newVersion');

    // Migration from version 1 to 2: Add chat_id to archived_messages
    if (oldVersion < 2) {
      // Create temp table with new schema (matching ArchiveDbUtilities)
      await db.execute('''
        CREATE TABLE archived_messages_new (
          id TEXT PRIMARY KEY,
          archive_id TEXT NOT NULL,
          original_message_id TEXT,
          chat_id TEXT NOT NULL DEFAULT '',
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

      // Copy data from old table (if it exists)
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

      // Drop existing FTS objects if present
      await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_insert');
      await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_update');
      await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_delete');
      await db.execute('DROP TABLE IF EXISTS archived_messages_fts');

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

      logger.info(
        'Migration to v2 complete: Added chat_id to archived_messages',
      );
    }

    // Migration from version 2 to 3: Remove unused user_preferences table, add encryption
    if (oldVersion < 3) {
      // Drop unused user_preferences table (config now stays in SharedPreferences)
      await db.execute('DROP TABLE IF EXISTS user_preferences');

      logger.info(
        'Migration to v3 complete: Removed unused user_preferences table, SQLCipher encryption enabled',
      );
    }

    // Migration from version 3 to 4: Add app_preferences table for settings
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE app_preferences (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          value_type TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_preferences_type ON app_preferences(value_type)
      ''');

      logger.info('Migration to v4 complete: Added app_preferences table');
    }

    // Migration from version 4 to 5: Add Noise Protocol fields to contacts
    if (oldVersion < 5) {
      await db.execute('''
        ALTER TABLE contacts ADD COLUMN noise_public_key TEXT
      ''');

      await db.execute('''
        ALTER TABLE contacts ADD COLUMN noise_session_state TEXT
      ''');

      await db.execute('''
        ALTER TABLE contacts ADD COLUMN last_handshake_time INTEGER
      ''');

      logger.info(
        'Migration to v5 complete: Added Noise Protocol fields to contacts',
      );
    }

    // Migration from version 5 to 6: Add favorites support to contacts
    if (oldVersion < 6) {
      await db.execute('''
        ALTER TABLE contacts ADD COLUMN is_favorite INTEGER DEFAULT 0
      ''');

      await db.execute('''
        CREATE INDEX idx_contacts_favorite ON contacts(is_favorite) WHERE is_favorite = 1
      ''');

      logger.info(
        'Migration to v6 complete: Added is_favorite field to contacts',
      );
    }

    // Migration from version 6 to 7: Add ephemeral_id column for session tracking
    if (oldVersion < 7) {
      await db.execute('''
        ALTER TABLE contacts ADD COLUMN ephemeral_id TEXT
      ''');

      logger.info('Migration to v7 complete: Added ephemeral_id to contacts');
      logger.info(
        '🔧 Model: LOW security = public_key==ephemeral_id (both ephemeral)',
      );
      logger.info(
        '🔧 Model: MEDIUM+ security = public_key!=ephemeral_id (persistent + current ephemeral)',
      );
    }

    // Migration from version 7 to 8: Add persistent_public_key and current_ephemeral_id for proper key management
    if (oldVersion < 8) {
      logger.info(
        '🔧 SCHEMA FIX: Adding persistent_public_key and current_ephemeral_id columns',
      );

      // Add persistent_public_key column (NULL at LOW security, set at MEDIUM+)
      await db.execute('''
        ALTER TABLE contacts ADD COLUMN persistent_public_key TEXT
      ''');

      // Add current_ephemeral_id column (tracks active Noise session)
      await db.execute('''
        ALTER TABLE contacts ADD COLUMN current_ephemeral_id TEXT
      ''');

      // Create index on persistent_public_key for fast lookups
      await db.execute('''
        CREATE UNIQUE INDEX idx_contacts_persistent_key ON contacts(persistent_public_key) WHERE persistent_public_key IS NOT NULL
      ''');

      // Migrate existing data:
      // For all existing contacts, copy ephemeral_id to current_ephemeral_id
      // This preserves current session tracking
      await db.execute('''
        UPDATE contacts SET current_ephemeral_id = ephemeral_id WHERE ephemeral_id IS NOT NULL
      ''');

      logger.info(
        'Migration to v8 complete: Added persistent_public_key and current_ephemeral_id',
      );
      logger.info('🔧 NEW MODEL:');
      logger.info(
        '   - public_key: Immutable first contact ID (never changes)',
      );
      logger.info(
        '   - persistent_public_key: NULL at LOW, set at MEDIUM+ (real identity)',
      );
      logger.info(
        '   - current_ephemeral_id: Active Noise session ID (updates on reconnect)',
      );
      logger.info(
        '   - ephemeral_id: DEPRECATED - use current_ephemeral_id instead',
      );
    }

    // Migration from version 8 to 9: Add contact groups for secure multi-unicast messaging
    if (oldVersion < 9) {
      logger.info(
        '🔧 Adding contact groups tables for secure multi-unicast messaging...',
      );

      // Create contact_groups table
      await db.execute('''
        CREATE TABLE contact_groups (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT,
          created_at INTEGER NOT NULL,
          last_modified_at INTEGER NOT NULL
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_groups_modified ON contact_groups(last_modified_at DESC)
      ''');

      // Create group_members junction table
      await db.execute('''
        CREATE TABLE group_members (
          group_id TEXT NOT NULL,
          member_key TEXT NOT NULL,
          added_at INTEGER NOT NULL,
          PRIMARY KEY (group_id, member_key),
          FOREIGN KEY (group_id) REFERENCES contact_groups(id) ON DELETE CASCADE
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_group_members_key ON group_members(member_key)
      ''');

      // Create group_messages table
      await db.execute('''
        CREATE TABLE group_messages (
          id TEXT PRIMARY KEY,
          group_id TEXT NOT NULL,
          sender_key TEXT NOT NULL,
          content TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          FOREIGN KEY (group_id) REFERENCES contact_groups(id) ON DELETE CASCADE
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_group_messages_group ON group_messages(group_id, timestamp DESC)
      ''');

      await db.execute('''
        CREATE INDEX idx_group_messages_sender ON group_messages(sender_key)
      ''');

      // Create group_message_delivery table for per-member tracking
      await db.execute('''
        CREATE TABLE group_message_delivery (
          message_id TEXT NOT NULL,
          member_key TEXT NOT NULL,
          status INTEGER NOT NULL,
          timestamp INTEGER NOT NULL,
          PRIMARY KEY (message_id, member_key),
          FOREIGN KEY (message_id) REFERENCES group_messages(id) ON DELETE CASCADE
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_delivery_status ON group_message_delivery(message_id, status)
      ''');

      logger.info(
        'Migration to v9 complete: Added 4 tables for contact groups',
      );
      logger.info(
        '✅ contact_groups, group_members, group_messages, group_message_delivery',
      );
    }

    // Migration from version 9 to 10: Add seen_messages table for mesh deduplication (FIX-005)
    if (oldVersion < 10) {
      logger.info(
        '🔧 Adding seen_messages table for mesh message deduplication...',
      );

      // Create seen_messages table (matches SeenMessageStore schema)
      await db.execute('''
        CREATE TABLE seen_messages (
          message_id TEXT NOT NULL,
          seen_type TEXT NOT NULL,
          seen_at INTEGER NOT NULL,
          PRIMARY KEY (message_id, seen_type)
        )
      ''');

      // Index for type-based queries and cleanup
      await db.execute('''
        CREATE INDEX idx_seen_messages_type ON seen_messages(seen_type, seen_at DESC)
      ''');

      // Index for time-based cleanup (5-minute TTL)
      await db.execute('''
        CREATE INDEX idx_seen_messages_time ON seen_messages(seen_at DESC)
      ''');

      logger.info(
        'Migration to v10 complete: Added seen_messages table with 2 indexes',
      );
      logger.info('✅ seen_messages (message_id, seen_type, seen_at)');
    }
  }
}
