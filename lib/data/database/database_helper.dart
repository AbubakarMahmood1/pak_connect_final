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
    // - Android/iOS: Use sqlcipher.databaseFactory (supports encryption)
    // - Desktop/Tests: Use sqflite_common.databaseFactory (no encryption support)
    final factory = Platform.isAndroid || Platform.isIOS
        ? sqlcipher.databaseFactory
        : sqflite_common.databaseFactory;

    final databasesPath = await factory.getDatabasesPath();
    final dbName = _testDatabaseName ?? _databaseName;
    final path = join(databasesPath, dbName);

    // Get encryption key from secure storage on mobile platforms
    // Desktop/test builds use sqflite_common which doesn't support encryption
    String? encryptionKey;
    final isMobilePlatform = Platform.isAndroid || Platform.isIOS;

    if (isMobilePlatform) {
      try {
        encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
        _logger.info('🔐 Retrieved encryption key for SQLCipher');
      } catch (e) {
        _logger.severe(
          '❌ Failed to retrieve encryption key on mobile platform: $e',
        );
        // On mobile, encryption is required - fail closed
        rethrow;
      }

      // Check if we need to migrate an existing unencrypted database
      if (await File(path).exists()) {
        final isEncrypted = await _isDatabaseEncrypted(path);
        if (!isEncrypted) {
          _logger.warning(
            '⚠️ Existing database is unencrypted - migrating to encrypted storage',
          );
          await _migrateUnencryptedDatabase(
            path,
            encryptionKey,
            factory as sqlcipher.DatabaseFactory,
          );
        }
      }
    } else {
      _logger.fine(
        'Encryption skipped (desktop/test platform - sqflite_common does not support SQLCipher)',
      );
    }

    _logger.info(
      'Initializing database at: $path (factory: ${factory.runtimeType}, encrypted: ${encryptionKey != null})',
    );

    // Use platform-specific options to avoid runtime errors
    // - Mobile: sqlcipher.OpenDatabaseOptions supports password parameter
    // - Desktop/Test: sqflite_common.OpenDatabaseOptions does NOT support password
    return isMobilePlatform
        ? await factory.openDatabase(
            path,
            options: sqlcipher.SqlCipherOpenDatabaseOptions(
              version: _databaseVersion,
              onCreate: _onCreate,
              onUpgrade: _onUpgrade,
              onConfigure: _onConfigure,
              password: encryptionKey,
            ),
          )
        : await factory.openDatabase(
            path,
            options: sqflite_common.OpenDatabaseOptions(
              version: _databaseVersion,
              onCreate: _onCreate,
              onUpgrade: _onUpgrade,
              onConfigure: _onConfigure,
            ),
          );
  }

  /// Check if a database file is encrypted (SQLCipher format)
  /// Returns true if encrypted, false if plaintext SQLite
  static Future<bool> _isDatabaseEncrypted(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return false; // File doesn't exist, no encryption status
      }

      // Read first 16 bytes of the database file
      // SQLite plaintext databases start with "SQLite format 3\0"
      // SQLCipher encrypted databases have random-looking bytes
      final bytes = await file.openRead(0, 16).first;

      // Check for SQLite magic header (plaintext)
      const sqliteMagic = 'SQLite format 3';
      final header = String.fromCharCodes(bytes.take(15));

      if (header == sqliteMagic) {
        _logger.warning('Database file is plaintext SQLite (not encrypted)');
        return false;
      }

      // If header doesn't match SQLite magic, assume it's encrypted
      _logger.fine('Database file appears to be encrypted');
      return true;
    } catch (e) {
      _logger.warning('Could not determine database encryption status: $e');
      // On error, assume encrypted to prevent data loss
      return true;
    }
  }

  /// Migrate an existing unencrypted database to encrypted format
  /// This is a one-time migration for existing users
  /// Note: This method is only called on mobile platforms (Android/iOS)
  static Future<void> _migrateUnencryptedDatabase(
    String oldPath,
    String encryptionKey,
    sqlcipher.DatabaseFactory factory,
  ) async {
    try {
      _logger.info('🔄 Starting database encryption migration...');

      final tempPath = '$oldPath.encrypted_temp';
      final backupPath = '$oldPath.backup_unencrypted';

      // 1. Open the old unencrypted database (no password)
      _logger.fine('Opening unencrypted database for reading...');
      final oldDb = await factory.openDatabase(
        oldPath,
        options: sqlcipher.OpenDatabaseOptions(readOnly: true),
      );

      // 2. Create new encrypted database at temporary location
      _logger.fine('Creating new encrypted database...');
      final newDb = await factory.openDatabase(
        tempPath,
        options: sqlcipher.SqlCipherOpenDatabaseOptions(
          version: _databaseVersion,
          onCreate: _onCreate,
          password: encryptionKey, // Apply encryption
        ),
      );

      // 3. Copy all data from old to new database
      _logger.fine('Copying data to encrypted database...');
      await _copyDatabaseContents(oldDb, newDb);

      // 3.5. Apply critical data migration backfills
      // Since _copyDatabaseContents doesn't run _onUpgrade, we need to manually
      // apply any data transformations that would normally happen during upgrades
      _logger.fine('Applying data migration backfills...');
      await _applyDataMigrationBackfills(newDb);

      // 3.6. Rebuild FTS indexes
      // FTS virtual tables were skipped during copy and need to be repopulated
      // from the base tables for search to work
      _logger.fine('Rebuilding FTS indexes...');
      await _rebuildFtsIndexes(newDb);

      // 4. Close both databases
      await oldDb.close();
      await newDb.close();

      // 5. Backup the old unencrypted database
      _logger.fine('Backing up old unencrypted database...');
      await File(oldPath).copy(backupPath);

      // 6. Replace old database with new encrypted one
      _logger.fine('Replacing old database with encrypted version...');
      await File(oldPath).delete();
      await File(tempPath).rename(oldPath);

      // 7. Delete the plaintext backup for security
      // The backup was only kept for recovery in case of migration failure
      _logger.fine('Deleting plaintext backup for security...');
      try {
        await File(backupPath).delete();
        _logger.info('✅ Plaintext backup deleted');
      } catch (e) {
        _logger.warning('Could not delete plaintext backup: $e');
        // Non-fatal - migration succeeded
      }

      _logger.info(
        '✅ Database encryption migration complete. '
        'Data migrated and plaintext backup removed.',
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Database encryption migration failed', e, stackTrace);
      rethrow;
    }
  }

  /// Copy all tables and data from source to destination database
  static Future<void> _copyDatabaseContents(
    sqlcipher.Database sourceDb,
    sqlcipher.Database destDb,
  ) async {
    // Get list of all tables from source (excluding sqlite internal tables)
    final sourceTables = await sourceDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );

    // Get list of all tables from destination to validate against
    final destTables = await destDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );

    // Create a set of destination table names for fast lookup
    final destTableNames = destTables
        .map((table) => table['name'] as String)
        .toSet();

    _logger.fine(
      'Copying ${sourceTables.length} tables from source '
      '(${destTableNames.length} tables in destination)...',
    );

    int copiedCount = 0;
    int skippedCount = 0;

    for (final table in sourceTables) {
      final tableName = table['name'] as String;

      // Skip FTS tables - they will be rebuilt automatically
      if (tableName.endsWith('_fts')) {
        _logger.fine('Skipping FTS table: $tableName (will be rebuilt)');
        skippedCount++;
        continue;
      }

      // Check if table exists in destination database
      if (!destTableNames.contains(tableName)) {
        _logger.warning(
          '⚠️ Skipping table $tableName - not present in destination schema '
          '(table was removed in a later version)',
        );
        skippedCount++;
        continue;
      }

      _logger.fine('Copying table: $tableName');

      // Read all rows from source table
      final rows = await sourceDb.query(tableName);

      if (rows.isEmpty) {
        _logger.fine('Table $tableName is empty');
        copiedCount++;
        continue;
      }

      // Insert rows into destination table in batches
      final batch = destDb.batch();
      for (final row in rows) {
        batch.insert(tableName, row);
      }

      await batch.commit(noResult: true);
      _logger.fine('Copied ${rows.length} rows from $tableName');
      copiedCount++;
    }

    _logger.info(
      '✅ Migration complete: Copied $copiedCount tables, skipped $skippedCount tables',
    );
  }

  /// Apply critical data migration backfills after copying database contents
  ///
  /// When migrating from unencrypted to encrypted, _copyDatabaseContents only
  /// copies raw data without running _onUpgrade migrations. This method applies
  /// the critical data transformations that would normally happen during upgrades.
  static Future<void> _applyDataMigrationBackfills(
    sqlcipher.Database db,
  ) async {
    try {
      // v8 Migration Backfill: current_ephemeral_id
      // This backfill is critical for post-v8 identity/session tracking
      // Without it, upgraded users will have NULL current_ephemeral_id
      _logger.fine('Applying v8 backfill: current_ephemeral_id');

      // Check if current_ephemeral_id column exists (it should, from _onCreate)
      final columns = await db.rawQuery('PRAGMA table_info(contacts)');
      final hasCurrentEphemeralId = columns.any(
        (col) => col['name'] == 'current_ephemeral_id',
      );

      if (hasCurrentEphemeralId) {
        // Backfill current_ephemeral_id from ephemeral_id for existing contacts
        final result = await db.rawUpdate('''
          UPDATE contacts 
          SET current_ephemeral_id = ephemeral_id 
          WHERE ephemeral_id IS NOT NULL 
            AND current_ephemeral_id IS NULL
        ''');
        _logger.info(
          '✅ v8 backfill complete: Updated $result contacts with current_ephemeral_id',
        );
      } else {
        _logger.warning(
          'current_ephemeral_id column not found - skipping v8 backfill',
        );
      }

      // Add more backfills here as needed for future migrations
      // Example:
      // if (oldVersion < 9) {
      //   await _applyV9Backfill(db);
      // }
    } catch (e, stackTrace) {
      _logger.severe('Failed to apply data migration backfills', e, stackTrace);
      // Don't rethrow - migration can continue with copied data
      // But log the error so it can be investigated
    }
  }

  /// Rebuild FTS (Full-Text Search) indexes after copying database contents
  ///
  /// When migrating from unencrypted to encrypted, FTS virtual tables are
  /// skipped during _copyDatabaseContents. This method rebuilds the FTS tables
  /// and repopulates them from the base tables so search functionality works.
  static Future<void> _rebuildFtsIndexes(sqlcipher.Database db) async {
    try {
      _logger.fine('Rebuilding FTS indexes for archived messages...');

      // Check if archived_messages table exists and has data
      final archivedCount = await db.rawQuery(
        'SELECT COUNT(*) as count FROM archived_messages',
      );
      final hasArchivedMessages =
          ((archivedCount.first['count'] as int?) ?? 0) > 0;

      if (hasArchivedMessages) {
        // Use ArchiveDbUtilities to rebuild the FTS table and triggers
        await ArchiveDbUtilities.rebuildArchiveFts(db);

        // Repopulate the FTS index from existing archived_messages data
        // This is critical - without this, search results will be empty
        final result = await db.rawInsert('''
          INSERT INTO archived_messages_fts(rowid, searchable_text)
          SELECT rowid, searchable_text 
          FROM archived_messages
          WHERE searchable_text IS NOT NULL
        ''');

        _logger.info(
          '✅ FTS rebuild complete: Indexed $result archived messages',
        );
      } else {
        _logger.fine('No archived messages to index - skipping FTS rebuild');
      }

      // Note: messages_fts is not currently used in the schema
      // If it's added in the future, rebuild it here as well
    } catch (e, stackTrace) {
      _logger.severe('Failed to rebuild FTS indexes', e, stackTrace);
      // Don't rethrow - migration can continue without FTS
      // But log the error so search issues can be investigated
    }
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

  /// Verify that the database is properly encrypted (SQLCipher format)
  /// Returns true if encrypted, false if plaintext, null if cannot determine
  ///
  /// This method is useful for:
  /// - Runtime verification that encryption is working
  /// - Testing encryption implementation
  /// - Debugging encryption issues
  ///
  /// Note: On desktop/test platforms using sqflite_common, this will return
  /// false as those platforms don't support SQLCipher encryption.
  static Future<bool?> verifyEncryption() async {
    try {
      final path = await getDatabasePath();
      final file = File(path);

      if (!await file.exists()) {
        _logger.warning(
          'Cannot verify encryption - database file does not exist',
        );
        return null;
      }

      // Check if file is encrypted using header inspection
      final isEncrypted = await _isDatabaseEncrypted(path);

      // Additional verification: Try opening without password (should fail if encrypted)
      if (isEncrypted) {
        final factory = Platform.isAndroid || Platform.isIOS
            ? sqlcipher.databaseFactory
            : sqflite_common.databaseFactory;

        try {
          // Try to open without password
          final testDb = await factory.openDatabase(
            path,
            options: sqlcipher.OpenDatabaseOptions(
              readOnly: true,
              // Ensure this is a brand-new handle and not the existing
              // singleton instance that may already be unlocked.
              singleInstance: false,
              // No password parameter
            ),
          );

          // If we can query it without password, it's not encrypted
          try {
            await testDb.rawQuery('SELECT COUNT(*) FROM sqlite_master');
            await testDb.close();
            _logger.warning(
              '⚠️ Database opened successfully without password - NOT ENCRYPTED',
            );
            return false;
          } catch (e) {
            // Query failed even though open succeeded - might be corrupt or encrypted
            await testDb.close();
            _logger.fine(
              'Database query without password failed (expected for encryption): $e',
            );
            return true;
          }
        } catch (e) {
          // Failed to open without password - good sign for encryption
          _logger.fine(
            'Database cannot be opened without password (encrypted): $e',
          );
          return true;
        }
      }

      return false; // File header indicates plaintext
    } catch (e) {
      _logger.warning('Failed to verify encryption status: $e');
      return null;
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
