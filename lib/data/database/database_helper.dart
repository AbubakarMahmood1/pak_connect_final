// SQLite database helper with comprehensive schema
// Supports messages, contacts, chats, offline queue, archives with FTS5
// Features: SQLCipher encryption, WAL mode, FTS5 search, foreign key constraints

import 'dart:io';

import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:path/path.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_encryption.dart';
import 'archive_db_utilities.dart';

class DatabaseHelper {
  static final _logger = Logger('DatabaseHelper');
  static sqlcipher.Database? _database;
  static Future<sqlcipher.Database>? _initializingDatabase;
  static const String _databaseName = 'pak_connect.db';
  static const int _databaseVersion =
      10; // v10: Added seen_messages table for mesh deduplication (FIX-005)
  static int get currentVersion => _databaseVersion;

  /// Override database name for testing (allows using fresh database files)
  static String? _testDatabaseName;

  /// Set custom database name for testing
  static void setTestDatabaseName(String? name) {
    _testDatabaseName = name;
  }

  /// Get database instance (singleton pattern)
  static Future<sqlcipher.Database> get database async {
    if (_database != null) {
      return _database!;
    }

    if (_initializingDatabase != null) {
      return _initializingDatabase!;
    }

    _initializingDatabase = _initDatabase();
    try {
      _database = await _initializingDatabase!;
      return _database!;
    } finally {
      _initializingDatabase = null;
    }
  }

  /// Initialize the database with SQLCipher encryption
  static Future<sqlcipher.Database> _initDatabase() async {
    // Platform-specific database factory:
    // - Android/iOS: Use sqlcipher.databaseFactory (already initialized)
    // - Desktop/Tests: Use sqflite_common.databaseFactory (initialized by test setup)
    final factory = Platform.isAndroid || Platform.isIOS
        ? sqlcipher.databaseFactory
        : sqflite_common.databaseFactory;

    final databasesPath = await factory.getDatabasesPath();
    final dbName = _testDatabaseName ?? _databaseName;
    final path = join(databasesPath, dbName);

    // Get encryption key from secure storage (skip in test environment)
    try {
      await DatabaseEncryption.getOrCreateEncryptionKey();
    } catch (e) {
      _logger.fine('Encryption key retrieval skipped (test environment): $e');
      // In test environment without secure storage, proceed without encryption
    }

    _logger.info(
      'Initializing database at: $path (factory: ${factory.runtimeType})',
    );

    return await factory.openDatabase(
      path,
      options: sqlcipher.OpenDatabaseOptions(
        version: _databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onConfigure: _onConfigure,
      ),
    );
  }

  /// Configure database before opening
  static Future<void> _onConfigure(sqlcipher.Database db) async {
    // Enable foreign key constraints
    await db.execute('PRAGMA foreign_keys = ON');

    // Enable WAL mode for better concurrency
    // Note: PRAGMA journal_mode returns a result, so we must use rawQuery
    try {
      final walResult = await db.rawQuery('PRAGMA journal_mode = WAL');
      final mode = walResult.isNotEmpty
          ? walResult.first.values.first
          : 'unknown';
      _logger.info('WAL mode set, journal_mode: $mode');
    } catch (e) {
      _logger.warning('Failed to enable WAL mode (will use default): $e');
      // Continue anyway - WAL is an optimization, not required
    }

    // Set cache size (10MB)
    // PRAGMA cache_size also returns a result
    try {
      await db.rawQuery('PRAGMA cache_size = -10000');
    } catch (e) {
      _logger.warning('Failed to set cache size (using default): $e');
      // Continue anyway - cache_size is an optimization
    }

    _logger.info('Database configured with foreign keys and optimizations');
  }

  /// Create database schema
  static Future<void> _onCreate(sqlcipher.Database db, int version) async {
    _logger.info('Creating database schema v$version...');

    // =========================
    // 1. CONTACTS TABLE
    // =========================
    await db.execute('''
      CREATE TABLE contacts (
        public_key TEXT PRIMARY KEY,
        persistent_public_key TEXT UNIQUE,
        current_ephemeral_id TEXT,
        ephemeral_id TEXT,
        display_name TEXT NOT NULL,
        trust_status INTEGER NOT NULL,
        security_level INTEGER NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        last_security_sync INTEGER,
        noise_public_key TEXT,
        noise_session_state TEXT,
        last_handshake_time INTEGER,
        is_favorite INTEGER DEFAULT 0,
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

    await db.execute('''
      CREATE INDEX idx_contacts_favorite ON contacts(is_favorite) WHERE is_favorite = 1
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
        expires_at INTEGER,

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
    // 7-9. ARCHIVES (delegated)
    // =========================
    await ArchiveDbUtilities.createArchiveTables(db);

    // =========================
    // 10. DEVICE MAPPINGS (for public key to device UUID tracking)
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
    // 11. CONTACT LAST SEEN (for online status tracking)
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
    // 12. MIGRATION METADATA (track migration progress)
    // =========================
    await db.execute('''
      CREATE TABLE migration_metadata (
        key TEXT PRIMARY KEY,
        value TEXT,
        migrated_at INTEGER NOT NULL
      )
    ''');

    // =========================
    // 13. APP PREFERENCES (user settings and preferences)
    // =========================
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

    // =========================
    // 14. CONTACT GROUPS (for secure multi-unicast messaging)
    // =========================
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

    // =========================
    // 15. GROUP MEMBERS (junction table)
    // =========================
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

    // =========================
    // 16. GROUP MESSAGES (with per-member delivery tracking)
    // =========================
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

    // =========================
    // 17. GROUP MESSAGE DELIVERY (per-member delivery status)
    // =========================
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

    // =========================
    // 18. SEEN MESSAGES (mesh deduplication)
    // =========================
    // FIX-005: Added in v10 for proper mesh relay deduplication
    await db.execute('''
      CREATE TABLE seen_messages (
        message_id TEXT NOT NULL,
        seen_type TEXT NOT NULL,
        seen_at INTEGER NOT NULL,
        PRIMARY KEY (message_id, seen_type)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_seen_messages_type ON seen_messages(seen_type, seen_at DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_seen_messages_time ON seen_messages(seen_at DESC)
    ''');

    _logger.info(
      '✅ Database schema created successfully with 18 core tables + FTS5',
    );
  }

  /// Handle database upgrades
  static Future<void> _onUpgrade(
    sqlcipher.Database db,
    int oldVersion,
    int newVersion,
  ) async {
    _logger.info('Upgrading database from v$oldVersion to v$newVersion');

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

      _logger.info(
        'Migration to v2 complete: Added chat_id to archived_messages',
      );
    }

    // Migration from version 2 to 3: Remove unused user_preferences table, add encryption
    if (oldVersion < 3) {
      // Drop unused user_preferences table (config now stays in SharedPreferences)
      await db.execute('DROP TABLE IF EXISTS user_preferences');

      _logger.info(
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

      _logger.info('Migration to v4 complete: Added app_preferences table');
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

      _logger.info(
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

      _logger.info(
        'Migration to v6 complete: Added is_favorite field to contacts',
      );
    }

    // Migration from version 6 to 7: Add ephemeral_id column for session tracking
    if (oldVersion < 7) {
      await db.execute('''
        ALTER TABLE contacts ADD COLUMN ephemeral_id TEXT
      ''');

      _logger.info('Migration to v7 complete: Added ephemeral_id to contacts');
      _logger.info(
        '🔧 Model: LOW security = public_key==ephemeral_id (both ephemeral)',
      );
      _logger.info(
        '🔧 Model: MEDIUM+ security = public_key!=ephemeral_id (persistent + current ephemeral)',
      );
    }

    // Migration from version 7 to 8: Add persistent_public_key and current_ephemeral_id for proper key management
    if (oldVersion < 8) {
      _logger.info(
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

      _logger.info(
        'Migration to v8 complete: Added persistent_public_key and current_ephemeral_id',
      );
      _logger.info('🔧 NEW MODEL:');
      _logger.info(
        '   - public_key: Immutable first contact ID (never changes)',
      );
      _logger.info(
        '   - persistent_public_key: NULL at LOW, set at MEDIUM+ (real identity)',
      );
      _logger.info(
        '   - current_ephemeral_id: Active Noise session ID (updates on reconnect)',
      );
      _logger.info(
        '   - ephemeral_id: DEPRECATED - use current_ephemeral_id instead',
      );
    }

    // Migration from version 8 to 9: Add contact groups for secure multi-unicast messaging
    if (oldVersion < 9) {
      _logger.info(
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

      _logger.info(
        'Migration to v9 complete: Added 4 tables for contact groups',
      );
      _logger.info(
        '✅ contact_groups, group_members, group_messages, group_message_delivery',
      );
    }

    // Migration from version 9 to 10: Add seen_messages table for mesh deduplication (FIX-005)
    if (oldVersion < 10) {
      _logger.info(
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

      _logger.info(
        'Migration to v10 complete: Added seen_messages table with 2 indexes',
      );
      _logger.info('✅ seen_messages (message_id, seen_type, seen_at)');
    }
  }

  /// Close the database
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _initializingDatabase = null;
      _logger.info('Database closed');
    }
  }

  /// Delete the database (for testing)
  static Future<void> deleteDatabase() async {
    try {
      final factory = Platform.isAndroid || Platform.isIOS
          ? sqlcipher.databaseFactory
          : sqflite_common.databaseFactory;
      final databasesPath = await factory.getDatabasesPath();
      final dbName = _testDatabaseName ?? _databaseName;
      final path = join(databasesPath, dbName);
      await factory.deleteDatabase(path);
      _database = null;
      _initializingDatabase = null;
      if (_testDatabaseName != null) {
        _logger.fine('Database deleted (test database: $dbName)');
      } else {
        _logger.warning('Database deleted');
      }
    } catch (e) {
      // In test environment, may fail - that's OK
      _logger.fine('Database delete attempted: $e');
      _database = null;
      _initializingDatabase = null;
    }
  }

  /// Check if database exists
  static Future<bool> exists() async {
    try {
      final factory = Platform.isAndroid || Platform.isIOS
          ? sqlcipher.databaseFactory
          : sqflite_common.databaseFactory;
      final databasesPath = await factory.getDatabasesPath();
      final dbName = _testDatabaseName ?? _databaseName;
      final path = join(databasesPath, dbName);
      return await factory.databaseExists(path);
    } catch (e) {
      _logger.fine('Database exists check failed: $e');
      return false;
    }
  }

  /// Clear all user data from the database (keeps schema intact)
  /// This deletes all messages, chats, contacts, archives, and preferences
  static Future<void> clearAllData() async {
    try {
      final db = await database;

      _logger.warning('🗑️ Clearing all user data from database...');

      // Delete in correct order to respect foreign key constraints
      // 1. Delete messages and related data first
      await db.delete('messages');
      await db.delete('messages_fts'); // Clear FTS index

      // 2. Delete archived data
      await db.delete('archived_messages');
      await db.delete('archived_messages_fts'); // Clear FTS index
      await db.delete('archived_chats');

      // 3. Delete chats
      await db.delete('chats');

      // 4. Delete offline queue
      await db.delete('offline_message_queue');

      // 5. Delete contacts
      await db.delete('contacts');

      // 6. Delete preferences
      await db.delete('app_preferences');

      _logger.warning('🗑️ All user data cleared from database');
    } catch (e) {
      _logger.severe('❌ Failed to clear all data: $e');
      rethrow;
    }
  }

  /// Get database path (for debugging)
  static Future<String> getDatabasePath() async {
    final factory = Platform.isAndroid || Platform.isIOS
        ? sqlcipher.databaseFactory
        : sqflite_common.databaseFactory;
    final databasesPath = await factory.getDatabasesPath();
    final dbName = _testDatabaseName ?? _databaseName;
    return join(databasesPath, dbName);
  }

  /// Verify database integrity
  static Future<bool> verifyIntegrity() async {
    try {
      final db = await database;
      final result = await db.rawQuery('PRAGMA integrity_check');
      final isValid =
          result.isNotEmpty && result.first['integrity_check'] == 'ok';

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
        'device_mappings',
        'contact_last_seen',
      ];

      for (final table in tables) {
        final result = await db.rawQuery(
          'SELECT COUNT(*) as count FROM $table',
        );
        counts[table] = sqlcipher.Sqflite.firstIntValue(result) ?? 0;
      }

      final dbPath = await getDatabasePath();

      return {
        'database_path': dbPath,
        'database_version': _databaseVersion,
        'table_counts': counts,
        'total_records': counts.values.fold<int>(
          0,
          (sum, count) => sum + count,
        ),
      };
    } catch (e) {
      _logger.severe('Failed to get database statistics: $e');
      return {'error': e.toString()};
    }
  }

  // ==================== Maintenance & VACUUM ====================

  static const String _lastVacuumKey = 'last_vacuum_timestamp';
  static const int _vacuumIntervalDays = 30; // Run VACUUM monthly

  /// Run VACUUM to reclaim space and defragment database
  static Future<Map<String, dynamic>> vacuum() async {
    try {
      _logger.info('Starting database VACUUM...');
      final startTime = DateTime.now();

      // Get database size before VACUUM
      final dbPath = await getDatabasePath();
      final file = File(dbPath);
      final sizeBefore = await file.exists() ? await file.length() : 0;

      final db = await database;

      // Run VACUUM
      await db.execute('VACUUM');

      // Get database size after VACUUM
      final sizeAfter = await file.exists() ? await file.length() : 0;
      final spaceReclaimed = sizeBefore - sizeAfter;
      final duration = DateTime.now().difference(startTime);

      // Update last vacuum timestamp using SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          _lastVacuumKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      } catch (e) {
        _logger.fine('Could not save vacuum timestamp (test environment): $e');
      }

      final result = {
        'success': true,
        'duration_ms': duration.inMilliseconds,
        'size_before_bytes': sizeBefore,
        'size_after_bytes': sizeAfter,
        'space_reclaimed_bytes': spaceReclaimed,
        'space_reclaimed_mb': (spaceReclaimed / 1024 / 1024).toStringAsFixed(2),
      };

      _logger.info(
        'VACUUM completed in ${duration.inMilliseconds}ms. Space reclaimed: ${result['space_reclaimed_mb']}MB',
      );

      return result;
    } catch (e, stackTrace) {
      _logger.severe('VACUUM failed', e, stackTrace);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Check if VACUUM is due based on interval
  static Future<bool> isVacuumDue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastVacuumTimestamp = prefs.getInt(_lastVacuumKey);

      if (lastVacuumTimestamp == null) return true; // Never vacuumed

      final lastVacuum = DateTime.fromMillisecondsSinceEpoch(
        lastVacuumTimestamp,
      );
      final daysSinceVacuum = DateTime.now().difference(lastVacuum).inDays;

      return daysSinceVacuum >= _vacuumIntervalDays;
    } catch (e) {
      _logger.fine('Error checking vacuum due status (test environment): $e');
      return false;
    }
  }

  /// Perform VACUUM if due (automatic maintenance)
  static Future<Map<String, dynamic>?> vacuumIfDue() async {
    if (await isVacuumDue()) {
      _logger.info('VACUUM is due, starting maintenance...');
      return await vacuum();
    }
    return null;
  }

  /// Get database size statistics
  static Future<Map<String, dynamic>> getDatabaseSize() async {
    try {
      final dbPath = await getDatabasePath();
      final file = File(dbPath);

      if (!await file.exists()) {
        return {'exists': false, 'size_bytes': 0, 'size_kb': 0, 'size_mb': 0};
      }

      final sizeBytes = await file.length();

      return {
        'exists': true,
        'path': dbPath,
        'size_bytes': sizeBytes,
        'size_kb': (sizeBytes / 1024).toStringAsFixed(2),
        'size_mb': (sizeBytes / 1024 / 1024).toStringAsFixed(2),
      };
    } catch (e) {
      _logger.warning('Failed to get database size: $e');
      return {'error': e.toString()};
    }
  }

  /// Get maintenance statistics
  static Future<Map<String, dynamic>> getMaintenanceStatistics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastVacuumTimestamp = prefs.getInt(_lastVacuumKey);
      final sizeInfo = await getDatabaseSize();

      return {
        'last_vacuum': lastVacuumTimestamp != null
            ? DateTime.fromMillisecondsSinceEpoch(
                lastVacuumTimestamp,
              ).toIso8601String()
            : null,
        'vacuum_interval_days': _vacuumIntervalDays,
        'vacuum_due': await isVacuumDue(),
        'database_size': sizeInfo,
      };
    } catch (e) {
      _logger.warning('Failed to get maintenance statistics: $e');
      return {'error': e.toString()};
    }
  }
}
