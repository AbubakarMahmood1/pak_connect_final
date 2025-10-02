// SQLite database helper with comprehensive schema
// Supports messages, contacts, chats, offline queue, archives with FTS5

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:logging/logging.dart';

class DatabaseHelper {
  static final _logger = Logger('DatabaseHelper');
  static Database? _database;
  static const String _databaseName = 'pak_connect.db';
  static const int _databaseVersion = 1;

  /// Get database instance (singleton pattern)
  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Initialize the database
  static Future<Database> _initDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _databaseName);

    _logger.info('Initializing database at: $path');

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  /// Configure database before opening
  static Future<void> _onConfigure(Database db) async {
    // Enable foreign key constraints
    await db.execute('PRAGMA foreign_keys = ON');

    // Enable WAL mode for better concurrency
    await db.execute('PRAGMA journal_mode = WAL');

    // Set cache size (10MB)
    await db.execute('PRAGMA cache_size = -10000');

    _logger.info('Database configured with foreign keys and WAL mode');
  }

  /// Create database schema
  static Future<void> _onCreate(Database db, int version) async {
    _logger.info('Creating database schema v$version...');

    // =========================
    // 1. CONTACTS TABLE
    // =========================
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

    await db.execute('''
      CREATE INDEX idx_contacts_trust ON contacts(trust_status)
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_security ON contacts(security_level)
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_last_seen ON contacts(last_seen DESC)
    ''');

    // =========================
    // 2. CHATS TABLE
    // =========================
    await db.execute('''
      CREATE TABLE chats (
        chat_id TEXT PRIMARY KEY,
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

    await db.execute('''
      CREATE INDEX idx_chats_contact ON chats(contact_public_key)
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_last_message ON chats(last_message_time DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_unread ON chats(unread_count) WHERE unread_count > 0
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_pinned ON chats(is_pinned, last_message_time DESC) WHERE is_pinned = 1
    ''');

    // =========================
    // 3. MESSAGES TABLE (Enhanced with JSON blobs)
    // =========================
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_from_me INTEGER NOT NULL,
        status INTEGER NOT NULL,

        -- Threading
        reply_to_message_id TEXT,
        thread_id TEXT,

        -- Status flags
        is_starred INTEGER DEFAULT 0,
        is_forwarded INTEGER DEFAULT 0,
        priority INTEGER DEFAULT 1,

        -- Edit tracking
        edited_at INTEGER,
        original_content TEXT,

        -- Media support
        has_media INTEGER DEFAULT 0,
        media_type TEXT,

        -- Complex objects as JSON blobs
        metadata_json TEXT,
        delivery_receipt_json TEXT,
        read_receipt_json TEXT,
        reactions_json TEXT,
        attachments_json TEXT,
        encryption_info_json TEXT,

        -- Timestamps
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,

        FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_chat_time ON messages(chat_id, timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_thread ON messages(thread_id) WHERE thread_id IS NOT NULL
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_reply ON messages(reply_to_message_id) WHERE reply_to_message_id IS NOT NULL
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_starred ON messages(is_starred) WHERE is_starred = 1
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_media ON messages(chat_id, has_media) WHERE has_media = 1
    ''');

    // =========================
    // 4. OFFLINE MESSAGE QUEUE (CRITICAL for mesh networking)
    // =========================
    await db.execute('''
      CREATE TABLE offline_message_queue (
        queue_id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        content TEXT NOT NULL,
        recipient_public_key TEXT NOT NULL,
        sender_public_key TEXT NOT NULL,

        -- Queue metadata
        queued_at INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        max_retries INTEGER DEFAULT 5,
        next_retry_at INTEGER,
        priority INTEGER DEFAULT 1,

        -- Delivery tracking
        status INTEGER NOT NULL,
        attempts INTEGER DEFAULT 0,
        last_attempt_at INTEGER,
        delivered_at INTEGER,
        failed_at INTEGER,
        failure_reason TEXT,

        -- Relay metadata (for mesh networking)
        is_relay_message INTEGER DEFAULT 0,
        original_message_id TEXT,
        relay_node_id TEXT,
        message_hash TEXT,
        relay_metadata_json TEXT,

        -- Additional fields
        reply_to_message_id TEXT,
        attachments_json TEXT,
        sender_rate_count INTEGER DEFAULT 0,

        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_status ON offline_message_queue(status, next_retry_at)
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_recipient ON offline_message_queue(recipient_public_key, status)
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_priority ON offline_message_queue(priority DESC, queued_at ASC)
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_hash ON offline_message_queue(message_hash) WHERE message_hash IS NOT NULL
    ''');

    // =========================
    // 5. QUEUE SYNC STATE (for deleted messages tracking)
    // =========================
    await db.execute('''
      CREATE TABLE queue_sync_state (
        device_id TEXT PRIMARY KEY,
        last_sync_at INTEGER,
        pending_messages_count INTEGER DEFAULT 0,
        last_successful_delivery INTEGER,
        consecutive_failures INTEGER DEFAULT 0,
        sync_enabled INTEGER DEFAULT 1,
        metadata_json TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_sync_pending ON queue_sync_state(pending_messages_count)
        WHERE pending_messages_count > 0
    ''');

    // =========================
    // 6. DELETED MESSAGE IDS (for queue sync)
    // =========================
    await db.execute('''
      CREATE TABLE deleted_message_ids (
        message_id TEXT PRIMARY KEY,
        deleted_at INTEGER NOT NULL,
        reason TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_deleted_time ON deleted_message_ids(deleted_at)
    ''');

    // =========================
    // 7. ARCHIVED CHATS
    // =========================
    await db.execute('''
      CREATE TABLE archived_chats (
        archive_id TEXT PRIMARY KEY,
        original_chat_id TEXT NOT NULL,
        contact_name TEXT NOT NULL,
        contact_public_key TEXT,
        archived_at INTEGER NOT NULL,
        last_message_time INTEGER,
        message_count INTEGER NOT NULL,

        -- Archive metadata
        archive_reason TEXT,
        estimated_size INTEGER NOT NULL,
        is_compressed INTEGER DEFAULT 0,
        compression_ratio REAL,

        -- Metadata as JSON
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

    // =========================
    // 8. ARCHIVED MESSAGES
    // =========================
    await db.execute('''
      CREATE TABLE archived_messages (
        id TEXT PRIMARY KEY,
        archive_id TEXT NOT NULL,
        original_message_id TEXT NOT NULL,

        -- Basic message fields
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_from_me INTEGER NOT NULL,
        status INTEGER NOT NULL,

        -- Enhanced fields
        reply_to_message_id TEXT,
        thread_id TEXT,
        is_starred INTEGER DEFAULT 0,
        is_forwarded INTEGER DEFAULT 0,
        priority INTEGER DEFAULT 1,
        edited_at INTEGER,
        original_content TEXT,
        has_media INTEGER DEFAULT 0,
        media_type TEXT,

        -- Archive-specific metadata
        archived_at INTEGER NOT NULL,
        original_timestamp INTEGER NOT NULL,

        -- Complex objects as JSON
        metadata_json TEXT,
        delivery_receipt_json TEXT,
        read_receipt_json TEXT,
        reactions_json TEXT,
        attachments_json TEXT,
        encryption_info_json TEXT,
        archive_metadata_json TEXT,
        preserved_state_json TEXT,

        -- Search optimization
        searchable_text TEXT,

        created_at INTEGER NOT NULL,

        FOREIGN KEY (archive_id) REFERENCES archived_chats(archive_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_archived_msg_archive ON archived_messages(archive_id, timestamp)
    ''');

    await db.execute('''
      CREATE INDEX idx_archived_msg_starred ON archived_messages(is_starred) WHERE is_starred = 1
    ''');

    // =========================
    // 9. ARCHIVED MESSAGES FTS5 (Full-Text Search)
    // =========================
    await db.execute('''
      CREATE VIRTUAL TABLE archived_messages_fts USING fts5(
        searchable_text,
        content=archived_messages,
        content_rowid=rowid,
        tokenize='porter unicode61'
      )
    ''');

    // FTS triggers to keep search index in sync
    await db.execute('''
      CREATE TRIGGER archived_msg_fts_insert AFTER INSERT ON archived_messages BEGIN
        INSERT INTO archived_messages_fts(rowid, searchable_text)
        VALUES (new.rowid, new.searchable_text);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_delete AFTER DELETE ON archived_messages BEGIN
        DELETE FROM archived_messages_fts WHERE rowid = old.rowid;
      END
    ''');

    await db.execute('''
      CREATE TRIGGER archived_msg_fts_update AFTER UPDATE ON archived_messages BEGIN
        UPDATE archived_messages_fts
        SET searchable_text = new.searchable_text
        WHERE rowid = old.rowid;
      END
    ''');

    // =========================
    // 10. USER PREFERENCES
    // =========================
    await db.execute('''
      CREATE TABLE user_preferences (
        key TEXT PRIMARY KEY,
        value TEXT,
        value_type TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // =========================
    // 11. DEVICE MAPPINGS (for public key to device UUID tracking)
    // =========================
    await db.execute('''
      CREATE TABLE device_mappings (
        device_uuid TEXT PRIMARY KEY,
        public_key TEXT NOT NULL,
        last_seen INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_device_public_key ON device_mappings(public_key)
    ''');

    // =========================
    // 12. CONTACT LAST SEEN (for online status tracking)
    // =========================
    await db.execute('''
      CREATE TABLE contact_last_seen (
        public_key TEXT PRIMARY KEY,
        last_seen_at INTEGER NOT NULL,
        was_online INTEGER DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (public_key) REFERENCES contacts(public_key) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_last_seen_time ON contact_last_seen(last_seen_at DESC)
    ''');

    // =========================
    // 13. MIGRATION METADATA (track migration progress)
    // =========================
    await db.execute('''
      CREATE TABLE migration_metadata (
        key TEXT PRIMARY KEY,
        value TEXT,
        migrated_at INTEGER NOT NULL
      )
    ''');

    _logger.info('✅ Database schema created successfully with 13 core tables + FTS5');
  }

  /// Handle database upgrades
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _logger.info('Upgrading database from v$oldVersion to v$newVersion');

    // Future schema migrations will go here
    // Example:
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE messages ADD COLUMN new_field TEXT');
    // }
  }

  /// Close the database
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _logger.info('Database closed');
    }
  }

  /// Delete the database (for testing)
  static Future<void> deleteDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _databaseName);
    await databaseFactory.deleteDatabase(path);
    _database = null;
    _logger.warning('Database deleted');
  }

  /// Check if database exists
  static Future<bool> exists() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _databaseName);
    return await databaseFactory.databaseExists(path);
  }

  /// Get database path (for debugging)
  static Future<String> getDatabasePath() async {
    final databasesPath = await getDatabasesPath();
    return join(databasesPath, _databaseName);
  }

  /// Verify database integrity
  static Future<bool> verifyIntegrity() async {
    try {
      final db = await database;
      final result = await db.rawQuery('PRAGMA integrity_check');
      final isValid = result.isNotEmpty && result.first['integrity_check'] == 'ok';

      if (isValid) {
        _logger.info('✅ Database integrity check passed');
      } else {
        _logger.severe('❌ Database integrity check failed: $result');
      }

      return isValid;
    } catch (e) {
      _logger.severe('❌ Database integrity check error: $e');
      return false;
    }
  }

  /// Get database statistics
  static Future<Map<String, dynamic>> getStatistics() async {
    try {
      final db = await database;

      final counts = <String, int>{};
      final tables = [
        'contacts',
        'chats',
        'messages',
        'offline_message_queue',
        'queue_sync_state',
        'deleted_message_ids',
        'archived_chats',
        'archived_messages',
        'user_preferences',
        'device_mappings',
        'contact_last_seen',
      ];

      for (final table in tables) {
        final result = await db.rawQuery('SELECT COUNT(*) as count FROM $table');
        counts[table] = Sqflite.firstIntValue(result) ?? 0;
      }

      final dbPath = await getDatabasePath();

      return {
        'database_path': dbPath,
        'database_version': _databaseVersion,
        'table_counts': counts,
        'total_records': counts.values.fold<int>(0, (sum, count) => sum + count),
      };
    } catch (e) {
      _logger.severe('Failed to get database statistics: $e');
      return {'error': e.toString()};
    }
  }
}
