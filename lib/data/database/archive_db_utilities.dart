import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

/// Archive-specific schema helpers (FTS/indexes/migrations)
class ArchiveDbUtilities {
  static final _logger = Logger('ArchiveDbUtilities');

  static Future<void> createArchiveTables(sqlcipher.Database db) async {
    await db.execute('''
      CREATE TABLE archived_chats (
        archive_id TEXT PRIMARY KEY,
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
      CREATE INDEX idx_archived_chats_time ON archived_chats(archived_at DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_archived_chats_contact ON archived_chats(contact_public_key)
    ''');

    await db.execute('''
      CREATE TABLE archived_messages (
        id TEXT PRIMARY KEY,
        archive_id TEXT NOT NULL,
        original_message_id TEXT,
        chat_id TEXT NOT NULL,
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
        attachments_json TEXT,
        encryption_info_json TEXT,
        archive_metadata_json TEXT,
        preserved_state_json TEXT,
        searchable_text TEXT,
        delivery_receipt_json TEXT,
        read_receipt_json TEXT,
        reactions_json TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (archive_id) REFERENCES archived_chats(archive_id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_archived_msg_archive ON archived_messages(archive_id, timestamp)',
    );
    await db.execute(
      'CREATE INDEX idx_archived_msg_starred ON archived_messages(is_starred) WHERE is_starred = 1',
    );

    await _createFtsTables(db);
  }

  static Future<void> _createFtsTables(sqlcipher.Database db) async {
    await db.execute('''
      CREATE VIRTUAL TABLE archived_messages_fts USING fts5(
        content=archived_messages,
        searchable_text,
        tokenize = "porter unicode61"
      );
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_insert AFTER INSERT ON archived_messages BEGIN
        INSERT INTO archived_messages_fts(rowid, searchable_text)
        VALUES (new.rowid, new.searchable_text);
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_delete AFTER DELETE ON archived_messages BEGIN
        DELETE FROM archived_messages_fts WHERE rowid = old.rowid;
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_update AFTER UPDATE ON archived_messages BEGIN
        UPDATE archived_messages_fts
        SET searchable_text = new.searchable_text
        WHERE rowid = new.rowid;
      END;
    ''');
  }

  static Future<void> rebuildArchiveFts(sqlcipher.Database db) async {
    await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_insert');
    await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_update');
    await db.execute('DROP TRIGGER IF EXISTS archived_msg_fts_delete');
    await db.execute('DROP TABLE IF EXISTS archived_messages_fts');
    await _createFtsTables(db);
    _logger.info('Rebuilt archived_messages_fts and triggers');
  }
}
