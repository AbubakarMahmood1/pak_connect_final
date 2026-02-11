// SQLite database helper with comprehensive schema
// Supports messages, contacts, chats, offline queue, archives with FTS5
// Features: SQLCipher encryption, WAL mode, FTS5 search, foreign key constraints

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:path/path.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/utils/app_logger.dart';
import 'database_encryption.dart';
import 'archive_db_utilities.dart';
import 'database_migration_runner.dart';
import 'database_schema_builder.dart';

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
        _logger.info(AppLogger.event(type: 'db_encryption_key_loaded'));
      } catch (e) {
        _logger.severe(
          AppLogger.event(
            type: 'db_encryption_key_load_failed',
            fields: {'error': e},
          ),
        );
        // On mobile, encryption is required - fail closed
        rethrow;
      }

      // Check if we need to migrate an existing unencrypted database
      if (await File(path).exists()) {
        final isEncrypted = await _isDatabaseEncrypted(path);
        if (!isEncrypted) {
          _logger.warning(
            AppLogger.event(type: 'db_encryption_migration_required'),
          );
          await _migrateUnencryptedDatabase(path, encryptionKey, factory);
        }
      }
    } else {
      _logger.info(
        AppLogger.event(
          type: 'db_encryption_unavailable',
          fields: {'mode': 'plaintext'},
        ),
      );
    }

    if (kReleaseMode) {
      _logger.info(
        AppLogger.event(
          type: 'db_initialize',
          fields: {'encrypted': encryptionKey != null},
        ),
      );
    } else {
      _logger.info(
        'Initializing database at: $path (factory: ${factory.runtimeType}, encrypted: ${encryptionKey != null})',
      );
    }

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
    await DatabaseSchemaBuilder.createSchema(db, version, logger: _logger);
  }

  /// Handle database upgrades
  static Future<void> _onUpgrade(
    sqlcipher.Database db,
    int oldVersion,
    int newVersion,
  ) async {
    await DatabaseMigrationRunner.runMigrations(
      db,
      oldVersion,
      newVersion,
      logger: _logger,
    );
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
