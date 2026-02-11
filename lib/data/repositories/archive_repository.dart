// Archive repository with SQLite and FTS5 full-text search

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/database/database_helper.dart';
import '../../domain/utils/compression_config.dart';
import '../../domain/utils/compression_util.dart';
import 'archive_data_helper.dart';
import 'archive_storage_utils.dart';
import '../../domain/services/archive_crypto.dart';

import 'package:pak_connect/domain/values/id_types.dart';

part 'archive_repository_mapping_helper.dart';

/// Repository for managing archived chats with SQLite and FTS5 search
/// Singleton pattern to prevent multiple instances and redundant initialization
class ArchiveRepository implements IArchiveRepository {
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
    ArchiveDataHelper? dataHelper,
    ArchiveStorageUtils? storageUtils,
  }) : _messageRepository = messageRepository ?? MessageRepository(),
       _chatsRepository = chatsRepository ?? ChatsRepository(),
       _dataHelper = dataHelper ?? const ArchiveDataHelper(),
       _storageUtils = storageUtils ?? ArchiveStorageUtils() {
    _logger.info('✅ ArchiveRepository singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ArchiveRepository() => instance;

  // Dependencies (injected via constructor for testability)
  final MessageRepository _messageRepository;
  final ChatsRepository _chatsRepository;
  final ArchiveDataHelper _dataHelper;
  final ArchiveStorageUtils _storageUtils;
  late final _ArchiveRepositoryMappingHelper _mappingHelper =
      _ArchiveRepositoryMappingHelper(this);

  bool _isInitialized = false;

  /// Initialize repository (idempotent - safe to call multiple times)
  @override
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
  @override
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
      final chatItem = chats.where((c) => c.chatId.value == chatId).firstOrNull;

      if (chatItem == null) {
        return ArchiveOperationResult.failure(
          message: 'Chat not found: $chatId',
          operationType: ArchiveOperationType.archive,
          operationTime: DateTime.now().difference(startTime),
        );
      }

      final messages = await _messageRepository.getMessages(ChatId(chatId));
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

      ArchivedChat finalArchive = archivedChat;
      if (compressLargeArchives && archivedChat.estimatedSize > 10240) {
        finalArchive = await _compressArchive(archivedChat);
      }

      // Store the archive in SQLite transaction
      final db = await DatabaseHelper.database;
      await db.transaction((txn) async {
        // Insert archived chat
        await txn.insert(
          'archived_chats',
          _dataHelper.archivedChatToMap(
            finalArchive,
            ChatId(chatId),
            archiveReason,
            customData,
          ),
        );

        // Insert archived messages with searchable text for FTS5
        for (final message in finalArchive.messages) {
          await txn.insert(
            'archived_messages',
            _dataHelper.archivedMessageToMap(message, finalArchive.id),
          );
        }

        // Delete the chat from chats table (it's now in archived_chats)
        await txn.delete('chats', where: 'chat_id = ?', whereArgs: [chatId]);
        // FTS5 index is automatically updated via triggers!
      });

      // Clear original chat messages
      await _messageRepository.clearMessages(ChatId(chatId));

      final operationTime = DateTime.now().difference(startTime);
      _storageUtils.recordOperationTime('archive', operationTime);

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
  @override
  Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async {
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
        whereArgs: [archiveId.value],
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
  @override
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

  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
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
        offset: offset,
      );

      return results.map((row) => _mapToArchivedChatSummary(row)).toList();
    } catch (e) {
      _logger.severe('Failed to get archived chats: $e');
      return [];
    }
  }

  /// Look up an archived chat by its original chat id
  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(
    String chatId,
  ) async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'archived_chats',
        where: 'original_chat_id = ?',
        whereArgs: [chatId],
        limit: 1,
      );

      if (result.isEmpty) return null;
      return _mapToArchivedChatSummary(result.first);
    } catch (e) {
      _logger.severe('Failed to get archive for chat $chatId: $e');
      return null;
    }
  }

  /// Get specific archived chat with full data
  @override
  Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async {
    try {
      final db = await DatabaseHelper.database;

      // Get archive metadata
      final archiveResults = await db.query(
        'archived_chats',
        where: 'archive_id = ?',
        whereArgs: [archiveId.value],
      );

      if (archiveResults.isEmpty) {
        return null;
      }

      final archiveRow = archiveResults.first;

      // Get all messages for this archive
      final messageResults = await db.query(
        'archived_messages',
        where: 'archive_id = ?',
        whereArgs: [archiveId.value],
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
  @override
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async {
    final effectiveLimit = limit ?? 50;
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

      final results = await db.rawQuery(searchQuery, [
        query,
        effectiveLimit * 2,
      ]);

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
          whereArgs: [archiveId.value],
        );
        if (chatResult.isNotEmpty) {
          chatSummaries.add(_mapToArchivedChatSummary(chatResult.first));
        }
      }

      // Limit results
      final limitedMessages = filteredMessages.take(effectiveLimit).toList();

      final searchTime = DateTime.now().difference(startTime);
      _recordOperationTime('search', searchTime);

      final result = ArchiveSearchResult.fromResults(
        messages: limitedMessages,
        chats: chatSummaries,
        query: query,
        filter: filter,
        searchTime: searchTime,
        hasMore: filteredMessages.length > effectiveLimit,
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
  @override
  Future<ArchiveOperationResult> permanentlyDeleteArchive(
    ArchiveId archiveId,
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
        whereArgs: [archiveId.value],
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
  @override
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
        averageArchiveTime:
            _storageUtils.operationTimes['archive'] ?? Duration.zero,
        averageRestoreTime:
            _storageUtils.operationTimes['restore'] ?? Duration.zero,
        averageSearchTime:
            _storageUtils.operationTimes['search'] ?? Duration.zero,
        averageMemoryUsage: 0.0, // No in-memory cache with SQLite
        operationsCount: _storageUtils.operationsCount,
        operationCounts: {
          'archive': _storageUtils.operationTimes.containsKey('archive')
              ? 1
              : 0,
          'restore': _storageUtils.operationTimes.containsKey('restore')
              ? 1
              : 0,
          'search': _storageUtils.operationTimes.containsKey('search') ? 1 : 0,
        },
        recentOperationTimes: _storageUtils.operationTimes.values.toList(),
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
  @override
  void clearCache() {
    _logger.info('Archive repository cache cleared (no-op for SQLite)');
  }

  /// Dispose and cleanup
  @override
  Future<void> dispose() async {
    _logger.info('Archive repository disposed');
  }

  // Private helper methods

  ArchiveId _generateArchiveId(String chatId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final hash = '${chatId}_$timestamp'.hashCode.abs();
    return ArchiveId('archive_$hash');
  }

  Future<ArchivedChat> _compressArchive(ArchivedChat archive) =>
      _mappingHelper.compressArchive(archive);

  Future<ArchivedChat> _decompressArchive(ArchivedChat archive) =>
      _mappingHelper.decompressArchive(archive);

  void _recordOperationTime(String operation, Duration time) =>
      _mappingHelper.recordOperationTime(operation, time);

  List<ArchivedMessage> _applyMessageTypeFilter(
    List<ArchivedMessage> messages,
    ArchiveMessageTypeFilter filter,
  ) => _mappingHelper.applyMessageTypeFilter(messages, filter);

  // Mapping methods

  ArchivedMessage _mapToArchivedMessage(Map<String, dynamic> row) =>
      _mappingHelper.mapToArchivedMessage(row);

  ArchivedChatSummary _mapToArchivedChatSummary(Map<String, dynamic> row) =>
      _mappingHelper.mapToArchivedChatSummary(row);

  ArchivedChat _mapToArchivedChat(
    Map<String, dynamic> archiveRow,
    List<ArchivedMessage> messages,
  ) => _mappingHelper.mapToArchivedChat(archiveRow, messages);
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
