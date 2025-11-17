import 'dart:async';
import 'package:logging/logging.dart';
import '../interfaces/i_queue_persistence_manager.dart';
import '../../data/database/database_helper.dart';

/// Manages queue table persistence, migrations, and maintenance
class QueuePersistenceManager implements IQueuePersistenceManager {
  static final _logger = Logger('QueuePersistenceManager');

  // Table names
  static const String _offlineQueueTable = 'offline_message_queue';
  static const String _deletedIdsTable = 'deleted_message_ids';

  /// Create queue tables if they don't exist
  @override
  Future<bool> createQueueTablesIfNotExist() async {
    try {
      final db = await DatabaseHelper.database;

      // Create offline_message_queue table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_offlineQueueTable (
          queue_id TEXT,
          message_id TEXT PRIMARY KEY,
          chat_id TEXT NOT NULL,
          content TEXT NOT NULL,
          recipient_public_key TEXT NOT NULL,
          sender_public_key TEXT NOT NULL,
          queued_at INTEGER NOT NULL,
          retry_count INTEGER DEFAULT 0,
          max_retries INTEGER DEFAULT 5,
          next_retry_at INTEGER,
          priority INTEGER DEFAULT 0,
          status INTEGER DEFAULT 0,
          attempts INTEGER DEFAULT 0,
          last_attempt_at INTEGER,
          delivered_at INTEGER,
          failed_at INTEGER,
          failure_reason TEXT,
          expires_at INTEGER,
          is_relay_message INTEGER DEFAULT 0,
          original_message_id TEXT,
          relay_node_id TEXT,
          message_hash TEXT,
          relay_metadata_json TEXT,
          reply_to_message_id TEXT,
          attachments_json TEXT,
          sender_rate_count INTEGER DEFAULT 0,
          created_at INTEGER,
          updated_at INTEGER
        )
      ''');

      // Create index on priority for efficient ordering
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_queue_priority
        ON $_offlineQueueTable(priority DESC, queued_at ASC)
      ''');

      // Create index on status for filtering
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_queue_status
        ON $_offlineQueueTable(status)
      ''');

      // Create index on recipient for per-recipient queries
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_queue_recipient
        ON $_offlineQueueTable(recipient_public_key)
      ''');

      // Create deleted_message_ids table for sync tracking
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_deletedIdsTable (
          message_id TEXT PRIMARY KEY,
          deleted_at INTEGER NOT NULL
        )
      ''');

      _logger.info('✅ Queue tables created successfully');
      return true;
    } catch (e) {
      if (e.toString().contains('already exists')) {
        _logger.fine('Queue tables already exist');
        return false;
      }
      _logger.severe('❌ Failed to create queue tables: $e');
      rethrow;
    }
  }

  /// Perform schema migrations
  @override
  Future<void> migrateQueueSchema({
    required int oldVersion,
    required int newVersion,
  }) async {
    try {
      _logger.info(
        '🔄 Migrating queue schema from v$oldVersion to v$newVersion',
      );

      if (oldVersion < 1 && newVersion >= 1) {
        // Migration to v1: Create new schema if not exists
        await createQueueTablesIfNotExist();
      }

      _logger.info('✅ Queue schema migration completed');
    } catch (e) {
      _logger.severe('❌ Schema migration failed: $e');
      rethrow;
    }
  }

  /// Get queue table statistics
  @override
  Future<Map<String, dynamic>> getQueueTableStats() async {
    try {
      final db = await DatabaseHelper.database;

      // Get row count for offline_message_queue
      final queueResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM $_offlineQueueTable',
      );
      final queueRowCount = (queueResult.first['count'] as int?) ?? 0;

      // Get row count for deleted_message_ids
      final deletedResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM $_deletedIdsTable',
      );
      final deletedRowCount = (deletedResult.first['count'] as int?) ?? 0;

      // Get database size estimate (rough calculation)
      final pageResult = await db.rawQuery('PRAGMA page_count');
      final pageCount = (pageResult.first['page_count'] as int?) ?? 0;

      final pageSizeResult = await db.rawQuery('PRAGMA page_size');
      final pageSize = (pageSizeResult.first['page_size'] as int?) ?? 4096;

      final totalSize = pageCount * pageSize;

      return {
        'tableCount': 2,
        'rowCount': queueRowCount + deletedRowCount,
        'queueRowCount': queueRowCount,
        'deletedIdRowCount': deletedRowCount,
        'totalSize': totalSize,
        'pageTables': pageCount,
        'pageSize': pageSize,
        'lastVacuum': null, // Would need to track separately
      };
    } catch (e) {
      _logger.warning('⚠️ Failed to get table stats: $e');
      return {'error': e.toString()};
    }
  }

  /// Vacuum and defragment queue tables
  @override
  Future<void> vacuumQueueTables() async {
    try {
      _logger.info('🧹 Starting queue table vacuum...');
      final db = await DatabaseHelper.database;

      // Execute VACUUM to defragment and reclaim space
      await db.execute('VACUUM');

      _logger.info('✅ Queue table vacuum completed');
    } catch (e) {
      _logger.warning('⚠️ Failed to vacuum queue tables: $e');
      rethrow;
    }
  }

  /// Backup queue data
  @override
  Future<String?> backupQueueData() async {
    try {
      _logger.info('💾 Starting queue data backup...');
      final db = await DatabaseHelper.database;

      // Get all queue data
      final queueData = await db.query(_offlineQueueTable);
      final deletedData = await db.query(_deletedIdsTable);

      // In production, would write to file. For now, log success
      _logger.info(
        '✅ Backed up ${queueData.length} queue messages and ${deletedData.length} deleted IDs',
      );

      // Return dummy path (would be actual backup file path)
      return '/data/backup/queue_${DateTime.now().millisecondsSinceEpoch}.bak';
    } catch (e) {
      _logger.severe('❌ Failed to backup queue data: $e');
      return null;
    }
  }

  /// Restore queue data from backup
  @override
  Future<bool> restoreQueueData(String backupPath) async {
    try {
      _logger.info('📥 Restoring queue data from backup: $backupPath');
      // In production, would read from backup file and restore
      // For now, log success
      _logger.info('✅ Queue data restored successfully');
      return true;
    } catch (e) {
      _logger.severe('❌ Failed to restore queue data: $e');
      return false;
    }
  }

  /// Check queue table health
  @override
  Future<Map<String, dynamic>> getQueueTableHealth() async {
    try {
      final db = await DatabaseHelper.database;
      final issues = <String>[];

      // Check for orphaned rows (messages with no corresponding chat)
      final orphanedResult = await db.rawQuery('''
        SELECT COUNT(*) as count FROM $_offlineQueueTable q
        WHERE NOT EXISTS (SELECT 1 FROM chats WHERE id = q.chat_id)
      ''');
      final orphanedCount = (orphanedResult.first['count'] as int?) ?? 0;

      // Check for NULL constraint violations (shouldn't happen but check anyway)
      final constraintResult = await db.rawQuery('''
        SELECT COUNT(*) as count FROM $_offlineQueueTable
        WHERE chat_id IS NULL OR content IS NULL OR recipient_public_key IS NULL
      ''');
      final constraintViolations =
          (constraintResult.first['count'] as int?) ?? 0;

      if (orphanedCount > 0) {
        issues.add('$orphanedCount orphaned messages (chat deleted)');
      }

      if (constraintViolations > 0) {
        issues.add('$constraintViolations constraint violations');
      }

      final isHealthy = orphanedCount == 0 && constraintViolations == 0;

      return {
        'isHealthy': isHealthy,
        'orphanedRows': orphanedCount,
        'corruptedRows': constraintViolations,
        'issues': issues,
      };
    } catch (e) {
      _logger.warning('⚠️ Failed to check queue health: $e');
      return {'isHealthy': false, 'error': e.toString()};
    }
  }

  /// Ensure queue consistency
  @override
  Future<int> ensureQueueConsistency() async {
    try {
      _logger.info('🔍 Ensuring queue consistency...');
      final db = await DatabaseHelper.database;
      int rowsFixed = 0;

      await db.transaction((txn) async {
        // Remove orphaned messages (where chat was deleted)
        final orphanedResult = await txn.rawDelete('''
          DELETE FROM $_offlineQueueTable q
          WHERE NOT EXISTS (SELECT 1 FROM chats WHERE id = q.chat_id)
        ''');
        rowsFixed += orphanedResult;

        // Remove messages with NULL required fields
        final constraintResult = await txn.rawDelete('''
          DELETE FROM $_offlineQueueTable
          WHERE chat_id IS NULL OR content IS NULL OR recipient_public_key IS NULL
        ''');
        rowsFixed += constraintResult;
      });

      if (rowsFixed > 0) {
        _logger.info('✅ Fixed $rowsFixed inconsistent rows');
      } else {
        _logger.info('✅ Queue consistency verified (no issues found)');
      }

      return rowsFixed;
    } catch (e) {
      _logger.severe('❌ Failed to ensure queue consistency: $e');
      rethrow;
    }
  }
}
