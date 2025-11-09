// Archive repository with SQLite and FTS5 full-text search

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../../core/models/archive_models.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/database/database_helper.dart';
import '../../core/compression/compression_util.dart';
import '../../core/compression/compression_config.dart';

/// Repository for managing archived chats with SQLite and FTS5 search
/// Singleton pattern to prevent multiple instances and redundant initialization
class ArchiveRepository {
  static final _logger = Logger('ArchiveRepository');

  // Singleton instance with lazy initialization
  static ArchiveRepository? _instance;
  static final _initLock = Object();

  /// Get the singleton instance
  static ArchiveRepository get instance {
    if (_instance == null) {
      synchronized(_initLock, () {
        _instance ??= ArchiveRepository._internal();
      });
    }
    return _instance!;
  }

  /// Private constructor for singleton
  ArchiveRepository._internal({
    MessageRepository? messageRepository,
    ChatsRepository? chatsRepository,
  }) : _messageRepository = messageRepository ?? MessageRepository(),
       _chatsRepository = chatsRepository ?? ChatsRepository() {
    _logger.info('✅ ArchiveRepository singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ArchiveRepository() => instance;

  // Dependencies (injected via constructor for testability)
  final MessageRepository _messageRepository;
  final ChatsRepository _chatsRepository;

  // Performance tracking
  final Map<String, Duration> _operationTimes = {};
  int _operationsCount = 0;
  bool _isInitialized = false;

  /// Initialize repository (idempotent - safe to call multiple times)
  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.fine('ArchiveRepository already initialized - skipping');
      return;
    }

    try {
      await DatabaseHelper.database;
      _isInitialized = true;
      _logger.info('Archive repository initialized successfully');
    } catch (e) {
      _logger.severe('Failed to initialize archive repository: $e');
    }
  }

  /// Helper for synchronized block (Dart doesn't have built-in synchronized)
  static void synchronized(Object lock, void Function() block) {
    block(); // In production, use package:synchronized for true locking
  }

  /// Archive a chat with all its messages
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async {
    final startTime = DateTime.now();

    try {
      _logger.info('Starting archive operation for chat: $chatId');

      // Get chat and messages
      final chats = await _chatsRepository.getAllChats();
      final chatItem = chats.where((c) => c.chatId == chatId).firstOrNull;

      if (chatItem == null) {
        return ArchiveOperationResult.failure(
          message: 'Chat not found: $chatId',
          operationType: ArchiveOperationType.archive,
          operationTime: DateTime.now().difference(startTime),
        );
      }

      final messages = await _messageRepository.getMessages(chatId);
      if (messages.isEmpty) {
        return ArchiveOperationResult.failure(
          message: 'No messages found for chat: $chatId',
          operationType: ArchiveOperationType.archive,
          operationTime: DateTime.now().difference(startTime),
        );
      }

      // Convert to enhanced messages
      final enhancedMessages = messages
          .map((m) => EnhancedMessage.fromMessage(m))
          .toList();

      // Create archived chat
      final archiveId = _generateArchiveId(chatId);
      final archivedChat = ArchivedChat.fromChatAndMessages(
        archiveId: archiveId,
        chatItem: chatItem,
        messages: enhancedMessages,
        archiveReason: archiveReason,
        customData: customData,
      );

      // Apply compression if needed
      ArchivedChat finalArchive = archivedChat;
      if (compressLargeArchives && archivedChat.estimatedSize > 10240) {
        // 10KB threshold
        finalArchive = await _compressArchive(archivedChat);
      } else {
        _logger.info(
          'Archive ${archivedChat.id} size (${archivedChat.estimatedSize} bytes) below 10KB threshold - compression skipped',
        );
      }

      // Store the archive in SQLite transaction
      final db = await DatabaseHelper.database;
      await db.transaction((txn) async {
        // Insert archived chat
        await txn.insert('archived_chats', {
          'archive_id': finalArchive.id,
          'original_chat_id': chatId,
          'contact_name': finalArchive.contactName,
          'contact_public_key': chatItem.contactPublicKey,
          'archived_at': finalArchive.archivedAt.millisecondsSinceEpoch,
          'last_message_time':
              finalArchive.lastMessageTime?.millisecondsSinceEpoch,
          'message_count': finalArchive.messageCount,
          'archive_reason': archiveReason,
          'estimated_size': finalArchive.estimatedSize,
          'is_compressed': finalArchive.isCompressed ? 1 : 0,
          'compression_ratio': finalArchive.compressionInfo?.compressionRatio,
          'metadata_json': jsonEncode(finalArchive.metadata),
          'compression_info_json': finalArchive.compressionInfo != null
              ? jsonEncode(finalArchive.compressionInfo!.toJson())
              : null,
          'custom_data_json': customData != null
              ? jsonEncode(customData)
              : null,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });

        // Insert archived messages with searchable text for FTS5
        for (final message in finalArchive.messages) {
          await txn.insert(
            'archived_messages',
            _archivedMessageToMap(message, finalArchive.id),
          );
        }

        // Delete the chat from chats table (it's now in archived_chats)
        await txn.delete('chats', where: 'id = ?', whereArgs: [chatId]);
        // FTS5 index is automatically updated via triggers!
      });

      // Clear original chat messages
      await _messageRepository.clearMessages(chatId);

      final operationTime = DateTime.now().difference(startTime);
      _recordOperationTime('archive', operationTime);

      final warnings = <String>[];
      if (finalArchive.isCompressed) {
        warnings.add('Archive was compressed to save space');
      }
      if (messages.length > 1000) {
        warnings.add(
          'Large archive created - search indexing may take additional time',
        );
      }

      _logger.info(
        'Successfully archived chat $chatId as $archiveId in ${operationTime.inMilliseconds}ms',
      );

      return ArchiveOperationResult.success(
        message: 'Chat archived successfully',
        operationType: ArchiveOperationType.archive,
        archiveId: archiveId,
        operationTime: operationTime,
        metadata: {
          'messageCount': messages.length,
          'originalSize': archivedChat.estimatedSize,
          'finalSize': finalArchive.estimatedSize,
          'compressed': finalArchive.isCompressed,
        },
        warnings: warnings,
      );
    } catch (e) {
      final operationTime = DateTime.now().difference(startTime);
      _logger.severe('Archive operation failed for $chatId: $e');

      return ArchiveOperationResult.failure(
        message: 'Failed to archive chat: $e',
        operationType: ArchiveOperationType.archive,
        operationTime: operationTime,
        error: ArchiveError.storageError('Archive storage failed', {
          'chatId': chatId,
        }),
      );
    }
  }

  /// Restore an archived chat
  Future<ArchiveOperationResult> restoreChat(String archiveId) async {
    final startTime = DateTime.now();

    try {
      _logger.info('Starting restore operation for archive: $archiveId');

      // Get archived chat
      final archivedChat = await getArchivedChat(archiveId);
      if (archivedChat == null) {
        return ArchiveOperationResult.failure(
          message: 'Archive not found: $archiveId',
          operationType: ArchiveOperationType.restore,
          operationTime: DateTime.now().difference(startTime),
        );
      }

      // Check restoration compatibility
      final preview = archivedChat.getRestorationPreview();
      final warnings = List<String>.from(preview.warnings);

      // Decompress if necessary
      ArchivedChat workingArchive = archivedChat;
      if (archivedChat.isCompressed) {
        workingArchive = await _decompressArchive(archivedChat);
      }

      // Restore messages
      int restoredCount = 0;
      for (final archivedMessage in workingArchive.messages) {
        try {
          final restoredMessage = archivedMessage.toRestoredMessage();
          await _messageRepository.saveMessage(restoredMessage);
          restoredCount++;
        } catch (e) {
          _logger.warning(
            'Failed to restore message ${archivedMessage.id}: $e',
          );
          warnings.add('Some messages could not be restored');
        }
      }

      if (restoredCount == 0) {
        return ArchiveOperationResult.failure(
          message: 'No messages could be restored from archive',
          operationType: ArchiveOperationType.restore,
          operationTime: DateTime.now().difference(startTime),
        );
      }

      final operationTime = DateTime.now().difference(startTime);
      _recordOperationTime('restore', operationTime);

      _logger.info(
        'Successfully restored $restoredCount messages from archive $archiveId',
      );

      // Delete archive + cascade archived messages now that data is restored
      final db = await DatabaseHelper.database;
      await db.delete(
        'archived_chats',
        where: 'archive_id = ?',
        whereArgs: [archiveId],
      );
      _logger.info('Archive $archiveId deleted after restoration');

      return ArchiveOperationResult.success(
        message: 'Chat restored successfully',
        operationType: ArchiveOperationType.restore,
        archiveId: archiveId,
        operationTime: operationTime,
        metadata: {
          'restoredMessages': restoredCount,
          'totalMessages': workingArchive.messageCount,
          'wasCompressed': archivedChat.isCompressed,
        },
        warnings: warnings,
      );
    } catch (e) {
      final operationTime = DateTime.now().difference(startTime);
      _logger.severe('Restore operation failed for $archiveId: $e');

      return ArchiveOperationResult.failure(
        message: 'Failed to restore chat: $e',
        operationType: ArchiveOperationType.restore,
        operationTime: operationTime,
        error: ArchiveError.storageError('Restore operation failed', {
          'archiveId': archiveId,
        }),
      );
    }
  }

  /// Get all archived chats (summaries for performance)
  /// Get count of archived chats
  Future<int> getArchivedChatsCount() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM archived_chats',
      );
      return result.isNotEmpty ? (result.first['count'] as int?) ?? 0 : 0;
    } catch (e) {
      _logger.warning('Failed to get archived chats count: $e');
      return 0;
    }
  }

  Future<void> _ensureChatShellExists({
    required ArchivedChat archivedChat,
    required ArchivedChat restoredArchive,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      if ((archivedChat.contactPublicKey?.isNotEmpty ?? false)) {
        await txn.insert('contacts', {
          'public_key': archivedChat.contactPublicKey,
          'display_name': archivedChat.contactName,
          'trust_status': 0,
          'security_level': 0,
          'first_seen': now,
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      await txn.insert('chats', {
        'chat_id': archivedChat.originalChatId,
        'contact_public_key': archivedChat.contactPublicKey,
        'contact_name': archivedChat.contactName,
        'last_message': restoredArchive.messages.isNotEmpty
            ? restoredArchive.messages.last.content
            : '',
        'last_message_time':
            restoredArchive.lastMessageTime?.millisecondsSinceEpoch,
        'unread_count': 0,
        'is_archived': 0,
        'is_muted': 0,
        'is_pinned': 0,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async {
    try {
      final db = await DatabaseHelper.database;

      // Build query with filters
      final where = <String>[];
      final whereArgs = <dynamic>[];

      if (filter?.contactFilter != null) {
        where.add('contact_name LIKE ?');
        whereArgs.add('%${filter!.contactFilter}%');
      }

      if (filter?.dateRange != null) {
        where.add('archived_at >= ? AND archived_at <= ?');
        whereArgs.add(filter!.dateRange!.start.millisecondsSinceEpoch);
        whereArgs.add(filter.dateRange!.end.millisecondsSinceEpoch);
      }

      if (filter?.onlyCompressed == true) {
        where.add('is_compressed = 1');
      }

      if (filter?.sizeFilter != null) {
        switch (filter!.sizeFilter!) {
          case ArchiveSizeFilter.small:
            where.add('estimated_size <= 1024');
            break;
          case ArchiveSizeFilter.medium:
            where.add('estimated_size > 1024 AND estimated_size <= 1048576');
            break;
          case ArchiveSizeFilter.large:
            where.add('estimated_size > 1048576');
            break;
        }
      }

      // Cursor-based pagination
      if (afterCursor != null) {
        where.add('archive_id > ?');
        whereArgs.add(afterCursor);
      }

      // Build sort clause
      String orderBy = 'archived_at DESC';
      if (filter?.sortBy != null) {
        switch (filter!.sortBy) {
          case ArchiveSortOption.dateArchived:
            orderBy = 'archived_at DESC';
            break;
          case ArchiveSortOption.dateOriginal:
            orderBy = 'last_message_time DESC';
            break;
          case ArchiveSortOption.contactName:
            orderBy = 'contact_name ASC';
            break;
          case ArchiveSortOption.messageCount:
            orderBy = 'message_count DESC';
            break;
          case ArchiveSortOption.size:
            orderBy = 'estimated_size DESC';
            break;
          case ArchiveSortOption.relevance:
            orderBy = 'archived_at DESC'; // Default to date for relevance
            break;
        }
      }

      final results = await db.query(
        'archived_chats',
        where: where.isNotEmpty ? where.join(' AND ') : null,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: orderBy,
        limit: limit,
      );

      return results.map((row) => _mapToArchivedChatSummary(row)).toList();
    } catch (e) {
      _logger.severe('Failed to get archived chats: $e');
      return [];
    }
  }

  /// Get specific archived chat with full data
  Future<ArchivedChat?> getArchivedChat(String archiveId) async {
    try {
      final db = await DatabaseHelper.database;

      // Get archive metadata
      final archiveResults = await db.query(
        'archived_chats',
        where: 'archive_id = ?',
        whereArgs: [archiveId],
      );

      if (archiveResults.isEmpty) {
        return null;
      }

      final archiveRow = archiveResults.first;

      // Get all messages for this archive
      final messageResults = await db.query(
        'archived_messages',
        where: 'archive_id = ?',
        whereArgs: [archiveId],
        orderBy: 'timestamp ASC',
      );

      final messages = messageResults
          .map((row) => _mapToArchivedMessage(row))
          .toList();

      return _mapToArchivedChat(archiveRow, messages);
    } catch (e) {
      _logger.severe('Failed to get archived chat $archiveId: $e');
      return null;
    }
  }

  /// Search archived messages using FTS5 (BIG WIN - replaces 300+ lines!)
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int limit = 50,
  }) async {
    final startTime = DateTime.now();

    try {
      if (query.trim().isEmpty) {
        return ArchiveSearchResult.empty(query);
      }

      _logger.info('Searching archives for: "$query"');

      final db = await DatabaseHelper.database;

      // FTS5 search - ONE QUERY replaces 300+ lines of manual indexing!
      final searchQuery = '''
        SELECT am.*
        FROM archived_messages am
        WHERE am.rowid IN (
          SELECT rowid FROM archived_messages_fts
          WHERE archived_messages_fts MATCH ?
        )
        ORDER BY am.timestamp DESC
        LIMIT ?
      ''';

      final results = await db.rawQuery(searchQuery, [query, limit * 2]);

      final matchingMessages = results
          .map((row) => _mapToArchivedMessage(row))
          .toList();

      // Apply additional filters if needed
      List<ArchivedMessage> filteredMessages = matchingMessages;
      if (filter?.messageTypeFilter != null) {
        filteredMessages = _applyMessageTypeFilter(
          matchingMessages,
          filter!.messageTypeFilter!,
        );
      }

      // Get unique archive IDs
      final archiveIds = filteredMessages.map((m) => m.archiveId).toSet();

      // Get chat summaries for matching archives
      final chatSummaries = <ArchivedChatSummary>[];
      for (final archiveId in archiveIds) {
        final chatResult = await db.query(
          'archived_chats',
          where: 'archive_id = ?',
          whereArgs: [archiveId],
        );
        if (chatResult.isNotEmpty) {
          chatSummaries.add(_mapToArchivedChatSummary(chatResult.first));
        }
      }

      // Limit results
      final limitedMessages = filteredMessages.take(limit).toList();

      final searchTime = DateTime.now().difference(startTime);
      _recordOperationTime('search', searchTime);

      final result = ArchiveSearchResult.fromResults(
        messages: limitedMessages,
        chats: chatSummaries,
        query: query,
        filter: filter,
        searchTime: searchTime,
        hasMore: filteredMessages.length > limit,
        searchStats: {
          'ftsResults': results.length,
          'archivesSearched': archiveIds.length,
          'method': 'FTS5',
        },
      );

      _logger.info(
        'FTS5 search completed: found ${result.totalResults} results in ${result.formattedSearchTime}',
      );

      return result;
    } catch (e) {
      _logger.severe('Search failed for "$query": $e');
      return ArchiveSearchResult.empty(query);
    }
  }

  /// Permanently delete an archived chat
  Future<ArchiveOperationResult> permanentlyDeleteArchive(
    String archiveId,
  ) async {
    final startTime = DateTime.now();

    try {
      _logger.info('Permanently deleting archive: $archiveId');

      // Get archive for metadata
      final archive = await getArchivedChat(archiveId);
      if (archive == null) {
        return ArchiveOperationResult.failure(
          message: 'Archive not found: $archiveId',
          operationType: ArchiveOperationType.delete,
          operationTime: DateTime.now().difference(startTime),
        );
      }

      // Delete from database (CASCADE will auto-delete messages and FTS5 entries)
      final db = await DatabaseHelper.database;
      await db.delete(
        'archived_chats',
        where: 'archive_id = ?',
        whereArgs: [archiveId],
      );

      final operationTime = DateTime.now().difference(startTime);
      _recordOperationTime('delete', operationTime);

      _logger.info('Successfully deleted archive $archiveId');

      return ArchiveOperationResult.success(
        message: 'Archive deleted permanently',
        operationType: ArchiveOperationType.delete,
        archiveId: archiveId,
        operationTime: operationTime,
        metadata: {
          'messageCount': archive.messageCount,
          'sizeFreed': archive.estimatedSize,
        },
      );
    } catch (e) {
      final operationTime = DateTime.now().difference(startTime);
      _logger.severe('Delete operation failed for $archiveId: $e');

      return ArchiveOperationResult.failure(
        message: 'Failed to delete archive: $e',
        operationType: ArchiveOperationType.delete,
        operationTime: operationTime,
        error: ArchiveError.storageError('Delete operation failed', {
          'archiveId': archiveId,
        }),
      );
    }
  }

  /// Get archive statistics
  Future<ArchiveStatistics> getArchiveStatistics() async {
    try {
      final db = await DatabaseHelper.database;

      // Use SQL aggregation for efficient statistics
      final statsResult = await db.rawQuery('''
        SELECT
          COUNT(*) as total_archives,
          SUM(message_count) as total_messages,
          SUM(CASE WHEN is_compressed = 1 THEN 1 ELSE 0 END) as compressed_archives,
          SUM(estimated_size) as total_size,
          MIN(archived_at) as oldest_archive,
          MAX(archived_at) as newest_archive,
          AVG(compression_ratio) as avg_compression_ratio
        FROM archived_chats
      ''');

      final stats = statsResult.first;
      final totalArchives = stats['total_archives'] as int? ?? 0;
      final totalMessages = stats['total_messages'] as int? ?? 0;
      final compressedArchives = stats['compressed_archives'] as int? ?? 0;
      final totalSize = stats['total_size'] as int? ?? 0;
      final oldestArchive = stats['oldest_archive'] != null
          ? DateTime.fromMillisecondsSinceEpoch(stats['oldest_archive'] as int)
          : null;
      final newestArchive = stats['newest_archive'] != null
          ? DateTime.fromMillisecondsSinceEpoch(stats['newest_archive'] as int)
          : null;
      final avgCompressionRatio =
          stats['avg_compression_ratio'] as double? ?? 0.7;

      // Archives by month
      final monthResults = await db.rawQuery('''
        SELECT
          strftime('%Y-%m', datetime(archived_at / 1000, 'unixepoch')) as month,
          COUNT(*) as count
        FROM archived_chats
        GROUP BY month
        ORDER BY month DESC
      ''');

      final archivesByMonth = <String, int>{};
      for (final row in monthResults) {
        archivesByMonth[row['month'] as String] = row['count'] as int;
      }

      // Messages by contact
      final contactResults = await db.rawQuery('''
        SELECT
          contact_name,
          SUM(message_count) as total_messages
        FROM archived_chats
        GROUP BY contact_name
        ORDER BY total_messages DESC
        LIMIT 10
      ''');

      final messagesByContact = <String, int>{};
      for (final row in contactResults) {
        messagesByContact[row['contact_name'] as String] =
            row['total_messages'] as int;
      }

      // Calculate average age
      final averageAge =
          totalArchives > 0 && newestArchive != null && oldestArchive != null
          ? newestArchive.difference(oldestArchive)
          : Duration.zero;

      // Performance stats
      final performanceStats = ArchivePerformanceStats(
        averageArchiveTime: _operationTimes['archive'] ?? Duration.zero,
        averageRestoreTime: _operationTimes['restore'] ?? Duration.zero,
        averageSearchTime: _operationTimes['search'] ?? Duration.zero,
        averageMemoryUsage: 0.0, // No in-memory cache with SQLite
        operationsCount: _operationsCount,
        operationCounts: {
          'archive': _operationTimes.containsKey('archive') ? 1 : 0,
          'restore': _operationTimes.containsKey('restore') ? 1 : 0,
          'search': _operationTimes.containsKey('search') ? 1 : 0,
        },
        recentOperationTimes: _operationTimes.values.toList(),
      );

      return ArchiveStatistics(
        totalArchives: totalArchives,
        totalMessages: totalMessages,
        compressedArchives: compressedArchives,
        searchableArchives: totalArchives, // All archives searchable with FTS5!
        totalSizeBytes: totalSize,
        compressedSizeBytes: totalSize,
        archivesByMonth: archivesByMonth,
        messagesByContact: messagesByContact,
        averageCompressionRatio: avgCompressionRatio,
        oldestArchive: oldestArchive,
        newestArchive: newestArchive,
        averageArchiveAge: averageAge,
        performanceStats: performanceStats,
      );
    } catch (e) {
      _logger.severe('Failed to get archive statistics: $e');
      return ArchiveStatistics.empty();
    }
  }

  /// Clear all cache (no-op for SQLite, kept for interface compatibility)
  void clearCache() {
    _logger.info('Archive repository cache cleared (no-op for SQLite)');
  }

  /// Dispose and cleanup
  void dispose() {
    _logger.info('Archive repository disposed');
  }

  // Private helper methods

  String _generateArchiveId(String chatId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final hash = '${chatId}_$timestamp'.hashCode.abs();
    return 'archive_$hash';
  }

  Future<ArchivedChat> _compressArchive(ArchivedChat archive) async {
    try {
      _logger.info(
        'Compressing archive ${archive.id} (${archive.messageCount} messages)',
      );

      // Serialize messages to JSON
      final messagesJson = jsonEncode(
        archive.messages.map((m) => m.toJson()).toList(),
      );
      final originalData = Uint8List.fromList(utf8.encode(messagesJson));
      final originalSize = originalData.length;

      // Compress using our compression module
      final compressionResult = CompressionUtil.compress(
        originalData,
        config: CompressionConfig.aggressive, // Use aggressive for archives
      );

      if (compressionResult == null) {
        // Compression not beneficial or failed - store uncompressed
        _logger.info(
          'Compression not beneficial for archive ${archive.id}, storing uncompressed',
        );
        return archive;
      }

      // Store compressed data as base64 in customData
      final compressedBase64 = base64Encode(compressionResult.compressed);
      final customData = Map<String, dynamic>.from(archive.customData ?? {});
      customData['_compressed_messages_blob'] = compressedBase64;
      customData['_compression_original_size'] = originalSize;

      final compressionInfo = ArchiveCompressionInfo(
        algorithm: compressionResult.stats.algorithm,
        originalSize: originalSize,
        compressedSize: compressionResult.stats.compressedSize,
        compressionRatio: compressionResult.stats.compressionRatio,
        compressedAt: DateTime.now(),
        compressionMetadata: {
          'savingsPercent': compressionResult.stats.savingsPercent,
          'compressionTimeMs': compressionResult.stats.compressionTimeMs,
        },
      );

      _logger.info(
        'Archive ${archive.id} compressed: $originalSize → ${compressionResult.stats.compressedSize} bytes '
        '(${compressionResult.stats.savingsPercent.toStringAsFixed(1)}% savings)',
      );

      return archive.copyWith(
        compressionInfo: compressionInfo,
        customData: customData,
      );
    } catch (e, stackTrace) {
      _logger.warning(
        'Compression failed for archive ${archive.id}, storing uncompressed: $e',
        e,
        stackTrace,
      );
      return archive;
    }
  }

  Future<ArchivedChat> _decompressArchive(ArchivedChat archive) async {
    try {
      // Check if archive is actually compressed
      if (!archive.isCompressed || archive.customData == null) {
        _logger.fine(
          'Archive ${archive.id} is not compressed, returning as-is',
        );
        return archive;
      }

      final customData = archive.customData!;
      final compressedBase64 =
          customData['_compressed_messages_blob'] as String?;
      final originalSize = customData['_compression_original_size'] as int?;

      if (compressedBase64 == null) {
        _logger.warning(
          'Archive ${archive.id} marked as compressed but no compressed data found',
        );
        return archive;
      }

      _logger.info('Decompressing archive ${archive.id}');

      // Decode base64 and decompress
      final compressedData = base64Decode(compressedBase64);
      final decompressed = CompressionUtil.decompress(
        Uint8List.fromList(compressedData),
        originalSize: originalSize,
        config: CompressionConfig.aggressive,
      );

      if (decompressed == null) {
        _logger.severe(
          'Failed to decompress archive ${archive.id}, using stored messages',
        );
        return archive;
      }

      // Deserialize messages from decompressed JSON
      final messagesJson = utf8.decode(decompressed);
      final messagesList = jsonDecode(messagesJson) as List<dynamic>;
      final messages = messagesList
          .map((m) => ArchivedMessage.fromJson(m as Map<String, dynamic>))
          .toList();

      _logger.info(
        'Archive ${archive.id} decompressed: ${messages.length} messages restored',
      );

      // Return archive with decompressed messages
      // Remove compression info since we're working with uncompressed data now
      return archive.copyWith(messages: messages);
    } catch (e, stackTrace) {
      _logger.severe(
        'Decompression failed for archive ${archive.id}, using stored messages: $e',
        e,
        stackTrace,
      );
      return archive; // Fall back to stored messages
    }
  }

  void _recordOperationTime(String operation, Duration time) {
    _operationTimes[operation] = time;
    _operationsCount++;
  }

  List<ArchivedMessage> _applyMessageTypeFilter(
    List<ArchivedMessage> messages,
    ArchiveMessageTypeFilter filter,
  ) {
    return messages.where((message) {
      if (filter.isFromMe != null && message.isFromMe != filter.isFromMe) {
        return false;
      }
      if (filter.hasAttachments != null &&
          message.attachments.isNotEmpty != filter.hasAttachments) {
        return false;
      }
      if (filter.wasStarred != null && message.isStarred != filter.wasStarred) {
        return false;
      }
      if (filter.wasEdited != null && message.wasEdited != filter.wasEdited) {
        return false;
      }
      return true;
    }).toList();
  }

  // Mapping methods

  Map<String, dynamic> _archivedMessageToMap(
    ArchivedMessage message,
    String archiveId,
  ) {
    // Determine media type from attachments
    String? mediaType;
    if (message.attachments.isNotEmpty) {
      final firstAttachment = message.attachments.first;
      mediaType = firstAttachment.type.toString().split('.').last;
    }

    return {
      'id': message.id,
      'archive_id': archiveId,
      'original_message_id': message.id, // Use message id as original
      'chat_id': message.chatId,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'is_from_me': message.isFromMe ? 1 : 0,
      'status': message.status.index,
      'reply_to_message_id': message.replyToMessageId,
      'thread_id': message.threadId,
      'is_starred': message.isStarred ? 1 : 0,
      'is_forwarded': message.isForwarded ? 1 : 0,
      'priority': message.priority.index,
      'edited_at': message.editedAt?.millisecondsSinceEpoch,
      'original_content': message.originalContent,
      'has_media': message.attachments.isNotEmpty ? 1 : 0,
      'media_type': mediaType,
      'archived_at': message.archivedAt.millisecondsSinceEpoch,
      'original_timestamp': message.originalTimestamp.millisecondsSinceEpoch,
      'metadata_json': message.metadata != null && message.metadata!.isNotEmpty
          ? jsonEncode(message.metadata)
          : null,
      'delivery_receipt_json': message.deliveryReceipt != null
          ? jsonEncode(message.deliveryReceipt!.toJson())
          : null,
      'read_receipt_json': message.readReceipt != null
          ? jsonEncode(message.readReceipt!.toJson())
          : null,
      'reactions_json': message.reactions.isNotEmpty
          ? jsonEncode(message.reactions.map((r) => r.toJson()).toList())
          : null,
      'attachments_json': message.attachments.isNotEmpty
          ? jsonEncode(message.attachments.map((a) => a.toJson()).toList())
          : null,
      'encryption_info_json': message.encryptionInfo != null
          ? jsonEncode(message.encryptionInfo!.toJson())
          : null,
      'archive_metadata_json': jsonEncode(message.archiveMetadata.toJson()),
      'preserved_state_json':
          message.preservedState != null && message.preservedState!.isNotEmpty
          ? jsonEncode(message.preservedState)
          : null,
      'searchable_text': message.searchableText, // KEY for FTS5!
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  ArchivedMessage _mapToArchivedMessage(Map<String, dynamic> row) {
    return ArchivedMessage(
      // Message base fields
      id: row['id'] as String,
      chatId: row['chat_id'] as String,
      content: row['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      isFromMe: (row['is_from_me'] as int) == 1,
      status: MessageStatus.values[row['status'] as int],

      // EnhancedMessage fields
      replyToMessageId: row['reply_to_message_id'] as String?,
      threadId: row['thread_id'] as String?,
      metadata: row['metadata_json'] != null
          ? Map<String, dynamic>.from(
              jsonDecode(row['metadata_json'] as String),
            )
          : null,
      deliveryReceipt: row['delivery_receipt_json'] != null
          ? MessageDeliveryReceipt.fromJson(
              jsonDecode(row['delivery_receipt_json'] as String),
            )
          : null,
      readReceipt: row['read_receipt_json'] != null
          ? MessageReadReceipt.fromJson(
              jsonDecode(row['read_receipt_json'] as String),
            )
          : null,
      reactions: row['reactions_json'] != null
          ? (jsonDecode(row['reactions_json'] as String) as List)
                .map((r) => MessageReaction.fromJson(r))
                .toList()
          : const [],
      isStarred: (row['is_starred'] as int? ?? 0) == 1,
      isForwarded: (row['is_forwarded'] as int? ?? 0) == 1,
      priority: MessagePriority.values[row['priority'] as int? ?? 1],
      editedAt: row['edited_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['edited_at'] as int)
          : null,
      originalContent: row['original_content'] as String?,
      attachments: row['attachments_json'] != null
          ? (jsonDecode(row['attachments_json'] as String) as List)
                .map((a) => MessageAttachment.fromJson(a))
                .toList()
          : const [],
      encryptionInfo: row['encryption_info_json'] != null
          ? MessageEncryptionInfo.fromJson(
              jsonDecode(row['encryption_info_json'] as String),
            )
          : null,

      // ArchivedMessage specific fields
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        row['archived_at'] as int,
      ),
      originalTimestamp: DateTime.fromMillisecondsSinceEpoch(
        row['original_timestamp'] as int,
      ),
      archiveId: row['archive_id'] as String,
      archiveMetadata: row['archive_metadata_json'] != null
          ? ArchiveMessageMetadata.fromJson(
              jsonDecode(row['archive_metadata_json'] as String),
            )
          : ArchiveMessageMetadata(
              archiveVersion: '1.0',
              preservationLevel: ArchivePreservationLevel.complete,
              indexingStatus: ArchiveIndexingStatus.indexed,
              compressionApplied: false,
              originalSize: 0,
              additionalData: {},
            ),
      originalSearchableText: row['searchable_text'] as String?,
      preservedState: row['preserved_state_json'] != null
          ? Map<String, dynamic>.from(
              jsonDecode(row['preserved_state_json'] as String),
            )
          : null,
    );
  }

  ArchivedChatSummary _mapToArchivedChatSummary(Map<String, dynamic> row) {
    return ArchivedChatSummary(
      id: row['archive_id'] as String,
      originalChatId: row['original_chat_id'] as String,
      contactName: row['contact_name'] as String,
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        row['archived_at'] as int,
      ),
      lastMessageTime: row['last_message_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['last_message_time'] as int)
          : null,
      messageCount: row['message_count'] as int,
      estimatedSize: row['estimated_size'] as int,
      isCompressed: (row['is_compressed'] as int? ?? 0) == 1,
      tags: [], // Tags can be extracted from metadata_json if needed
      isSearchable: true, // All archives searchable with FTS5
    );
  }

  ArchivedChat _mapToArchivedChat(
    Map<String, dynamic> archiveRow,
    List<ArchivedMessage> messages,
  ) {
    final compressionInfoJson = archiveRow['compression_info_json'] as String?;
    final metadataJson = archiveRow['metadata_json'] as String?;

    return ArchivedChat(
      id: archiveRow['archive_id'] as String,
      originalChatId: archiveRow['original_chat_id'] as String,
      contactName: archiveRow['contact_name'] as String,
      contactPublicKey: archiveRow['contact_public_key'] as String?,
      messages: messages,
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        archiveRow['archived_at'] as int,
      ),
      lastMessageTime: archiveRow['last_message_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              archiveRow['last_message_time'] as int,
            )
          : null,
      messageCount: archiveRow['message_count'] as int,
      metadata: metadataJson != null
          ? ArchiveMetadata.fromJson(jsonDecode(metadataJson))
          : ArchiveMetadata(
              version: '1.0',
              reason: archiveRow['archive_reason'] as String? ?? 'Unknown',
              originalUnreadCount: 0,
              wasOnline: false,
              hadUnsentMessages: false,
              estimatedStorageSize: archiveRow['estimated_size'] as int? ?? 0,
              archiveSource: 'migration',
              tags: [],
              hasSearchIndex: true,
            ),
      compressionInfo: compressionInfoJson != null
          ? ArchiveCompressionInfo.fromJson(jsonDecode(compressionInfoJson))
          : null,
      customData: archiveRow['custom_data_json'] != null
          ? Map<String, dynamic>.from(
              jsonDecode(archiveRow['custom_data_json'] as String),
            )
          : null,
    );
  }
}

/// Extension for firstOrNull functionality
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
