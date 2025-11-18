// Persistent store for message IDs we've already acknowledged (DELIVERED) or READ
// Based on BitChat's SeenMessageStore.kt
// Limits to last MAX_IDS entries per type to avoid memory bloat

import 'dart:async';
import 'dart:collection'; // For LinkedHashSet
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../database/database_helper.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../core/interfaces/i_seen_message_store.dart';

/// Persistent store for tracking seen messages (delivered and read)
///
/// Prevents duplicate processing of:
/// - DELIVERED acknowledgments
/// - READ receipts
/// - Message relay operations
///
/// Based on BitChat Android's SeenMessageStore implementation
class SeenMessageStore implements ISeenMessageStore {
  static final _logger = Logger('SeenMessageStore');

  // Constants
  static const int maxIdsPerType = 10000; // Match BitChat's MAX_IDS
  static int? _maxIdsOverride;

  // Singleton
  static SeenMessageStore? _instance;
  static SeenMessageStore get instance {
    _instance ??= SeenMessageStore._();
    return _instance!;
  }

  SeenMessageStore._();

  // In-memory cache for fast lookups (populated from DB)
  // Use LinkedHashSet to preserve insertion order for LRU semantics (matches BitChat)
  final LinkedHashSet<String> _deliveredIds = LinkedHashSet<String>();
  final LinkedHashSet<String> _readIds = LinkedHashSet<String>();

  bool _initialized = false;

  /// Initialize the store (load from database)
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _ensureTableExists();
      await _loadFromDatabase();
      _initialized = true;

      _logger.info(
        'SeenMessageStore initialized: ${_deliveredIds.length} delivered, ${_readIds.length} read',
      );
    } catch (e) {
      _logger.severe('Failed to initialize SeenMessageStore: $e');
      rethrow;
    }
  }

  /// Check if message was already delivered
  bool hasDelivered(String messageId) {
    if (!_initialized) {
      _logger.warning('hasDelivered called before initialization');
      return false;
    }
    return _deliveredIds.contains(messageId);
  }

  /// Check if message was already read
  bool hasRead(String messageId) {
    if (!_initialized) {
      _logger.warning('hasRead called before initialization');
      return false;
    }
    return _readIds.contains(messageId);
  }

  /// Mark message as delivered
  Future<void> markDelivered(String messageId) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // If already exists, just move to end (LRU)
      if (_deliveredIds.contains(messageId)) {
        _deliveredIds.remove(messageId);
      }

      _deliveredIds.add(messageId);

      // Enforce limit (LRU eviction)
      await _trimSet(_deliveredIds, SeenType.delivered);

      // Persist to database
      await _persistMessage(messageId, SeenType.delivered);

      _logger.fine('Marked message as delivered: ${messageId.shortId()}...');
    } catch (e) {
      _logger.warning('Failed to mark delivered: $e');
    }
  }

  /// Mark message as read
  Future<void> markRead(String messageId) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // If already exists, just move to end (LRU)
      if (_readIds.contains(messageId)) {
        _readIds.remove(messageId);
      }

      _readIds.add(messageId);

      // Enforce limit (LRU eviction)
      await _trimSet(_readIds, SeenType.read);

      // Persist to database
      await _persistMessage(messageId, SeenType.read);

      _logger.fine('Marked message as read: ${messageId.shortId()}...');
    } catch (e) {
      _logger.warning('Failed to mark read: $e');
    }
  }

  /// Get statistics
  Map<String, dynamic> getStatistics() {
    return {
      'deliveredCount': _deliveredIds.length,
      'readCount': _readIds.length,
      'totalTracked': _deliveredIds.length + _readIds.length,
      'maxPerType': _currentMaxIdsPerType,
      'initialized': _initialized,
    };
  }

  /// Clear all seen messages (for testing)
  Future<void> clear() async {
    try {
      _deliveredIds.clear();
      _readIds.clear();

      final db = await DatabaseHelper.database;
      await db.delete('seen_messages');

      _logger.info('Cleared all seen messages');
    } catch (e) {
      _logger.warning('Failed to clear seen messages: $e');
    }
  }

  @visibleForTesting
  void resetForTests() {
    _initialized = false;
    _deliveredIds.clear();
    _readIds.clear();
    _maxIdsOverride = null;
  }

  @visibleForTesting
  void setMaxIdsPerTypeForTests(int value) {
    _maxIdsOverride = value;
  }

  @visibleForTesting
  void resetMaxIdsPerTypeForTests() {
    _maxIdsOverride = null;
  }

  int get _currentMaxIdsPerType => _maxIdsOverride ?? maxIdsPerType;

  // Private methods

  /// Ensure seen_messages table exists
  ///
  /// **NOTE (FIX-005)**: As of v10, this table is created by DatabaseHelper._onCreate()
  /// and DatabaseHelper._onUpgrade(). This method is kept for backward compatibility
  /// with databases created before v10 (where table was created dynamically).
  ///
  /// For new installations: Table created by schema
  /// For upgrades from v9→v10: Table created by migration
  /// For older versions: This method creates it (safety net)
  Future<void> _ensureTableExists() async {
    try {
      final db = await DatabaseHelper.database;

      // Check if table exists
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='seen_messages'",
      );

      if (tables.isEmpty) {
        _logger.info(
          'Creating seen_messages table (backward compatibility)...',
        );

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

        _logger.info('✅ seen_messages table created');
      }
    } catch (e) {
      _logger.severe('Failed to ensure table exists: $e');
      rethrow;
    }
  }

  /// Load seen messages from database
  Future<void> _loadFromDatabase() async {
    try {
      final db = await DatabaseHelper.database;

      // Load delivered messages (OLDEST first for proper LRU order in LinkedHashSet)
      // LinkedHashSet: first items = oldest, last items = newest
      // This matches BitChat's LRU semantics where oldest are evicted first
      final deliveredResults = await db.query(
        'seen_messages',
        where: 'seen_type = ?',
        whereArgs: [SeenType.delivered.name],
        orderBy: 'seen_at ASC', // Changed from DESC to ASC for LRU
        limit: maxIdsPerType,
      );

      _deliveredIds.clear();
      for (final row in deliveredResults) {
        _deliveredIds.add(row['message_id'] as String);
      }

      // Load read messages (OLDEST first for proper LRU order in LinkedHashSet)
      final readResults = await db.query(
        'seen_messages',
        where: 'seen_type = ?',
        whereArgs: [SeenType.read.name],
        orderBy: 'seen_at ASC', // Changed from DESC to ASC for LRU
        limit: maxIdsPerType,
      );

      _readIds.clear();
      for (final row in readResults) {
        _readIds.add(row['message_id'] as String);
      }

      _logger.info(
        'Loaded ${_deliveredIds.length} delivered, ${_readIds.length} read from database',
      );
    } catch (e) {
      _logger.severe('Failed to load from database: $e');
      rethrow;
    }
  }

  /// Trim set to maxIdsPerType (LRU eviction)
  /// LinkedHashSet.toList() preserves insertion order (oldest first)
  /// So we take from the start to remove oldest entries (LRU semantics)
  Future<void> _trimSet(LinkedHashSet<String> set, SeenType type) async {
    final limit = _currentMaxIdsPerType;
    if (set.length <= limit) return;

    try {
      final db = await DatabaseHelper.database;

      // Convert LinkedHashSet to list (preserves order: oldest first)
      final list = set.toList();
      // Take oldest entries from start (LRU eviction)
      final toRemove = list.take(set.length - limit).toList();

      // Remove from database
      for (final messageId in toRemove) {
        await db.delete(
          'seen_messages',
          where: 'message_id = ? AND seen_type = ?',
          whereArgs: [messageId, type.name],
        );
      }

      // Remove from in-memory set
      for (final messageId in toRemove) {
        set.remove(messageId);
      }

      _logger.fine('Trimmed ${toRemove.length} old ${type.name} entries');
    } catch (e) {
      _logger.warning('Failed to trim set: $e');
    }
  }

  /// Persist message to database
  Future<void> _persistMessage(String messageId, SeenType type) async {
    try {
      final db = await DatabaseHelper.database;

      await db.insert('seen_messages', {
        'message_id': messageId,
        'seen_type': type.name,
        'seen_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      _logger.warning('Failed to persist message: $e');
    }
  }

  /// Cleanup old entries (called periodically)
  Future<void> performMaintenance() async {
    try {
      final db = await DatabaseHelper.database;

      // Get count for each type
      final deliveredCount = await db.rawQuery(
        'SELECT COUNT(*) as count FROM seen_messages WHERE seen_type = ?',
        [SeenType.delivered.name],
      );

      final readCount = await db.rawQuery(
        'SELECT COUNT(*) as count FROM seen_messages WHERE seen_type = ?',
        [SeenType.read.name],
      );

      final deliveredTotal = Sqflite.firstIntValue(deliveredCount) ?? 0;
      final readTotal = Sqflite.firstIntValue(readCount) ?? 0;

      // Clean up if over limit
      if (deliveredTotal > maxIdsPerType) {
        await _cleanupOldEntries(
          SeenType.delivered,
          deliveredTotal - maxIdsPerType,
        );
      }

      if (readTotal > maxIdsPerType) {
        await _cleanupOldEntries(SeenType.read, readTotal - maxIdsPerType);
      }

      _logger.info(
        'Maintenance complete: delivered=$deliveredTotal, read=$readTotal',
      );
    } catch (e) {
      _logger.warning('Maintenance failed: $e');
    }
  }

  /// Clean up oldest entries for a type
  Future<void> _cleanupOldEntries(SeenType type, int countToRemove) async {
    try {
      final db = await DatabaseHelper.database;

      // Delete oldest entries
      await db.rawDelete(
        '''
        DELETE FROM seen_messages
        WHERE rowid IN (
          SELECT rowid FROM seen_messages
          WHERE seen_type = ?
          ORDER BY seen_at ASC
          LIMIT ?
        )
      ''',
        [type.name, countToRemove],
      );

      _logger.info('Cleaned up $countToRemove old ${type.name} entries');
    } catch (e) {
      _logger.warning('Failed to cleanup old entries: $e');
    }
  }
}

/// Type of seen message
enum SeenType { delivered, read }
