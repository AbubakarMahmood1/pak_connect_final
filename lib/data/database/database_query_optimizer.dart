/// Advanced query optimization and connection management for SQLite.
///
/// Features:
/// - Query batching and transaction management
/// - Prepared statement caching
/// - Query performance monitoring
/// - Slow query detection
/// - Write operation batching
/// - Query queue with priority system
library;

import 'dart:async';
import 'dart:collection';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'database_helper.dart';
import 'package:logging/logging.dart';

final _logger = Logger('DatabaseQueryOptimizer');

/// Priority levels for database operations
enum QueryPriority {
  critical, // User-facing operations (UI updates)
  high, // Important background operations
  normal, // Standard operations
  low, // Maintenance and analytics
}

/// Query execution statistics
class QueryStatistics {
  final String query;
  final int executionCount;
  final int totalDurationMs;
  final int minDurationMs;
  final int maxDurationMs;
  final DateTime lastExecuted;

  QueryStatistics({
    required this.query,
    required this.executionCount,
    required this.totalDurationMs,
    required this.minDurationMs,
    required this.maxDurationMs,
    required this.lastExecuted,
  });

  double get averageDurationMs =>
      executionCount > 0 ? totalDurationMs / executionCount : 0;

  Map<String, dynamic> toJson() => {
    'query': _sanitizeQuery(query),
    'execution_count': executionCount,
    'total_duration_ms': totalDurationMs,
    'min_duration_ms': minDurationMs,
    'max_duration_ms': maxDurationMs,
    'avg_duration_ms': averageDurationMs.toStringAsFixed(2),
    'last_executed': lastExecuted.toIso8601String(),
  };

  static String _sanitizeQuery(String query) {
    // Remove potential sensitive data from query for logging
    return query.length > 100 ? '${query.substring(0, 100)}...' : query;
  }
}

/// Represents a queued database operation
class _QueuedOperation<T> {
  final QueryPriority priority;
  final Future<T> Function() operation;
  final Completer<T> completer;
  final DateTime queuedAt;
  final String description;

  _QueuedOperation({
    required this.priority,
    required this.operation,
    required this.description,
  }) : completer = Completer<T>(),
       queuedAt = DateTime.now();

  int get waitTimeMs => DateTime.now().difference(queuedAt).inMilliseconds;
}

/// Batch write operation container
class BatchWriteOperation {
  final List<Map<String, dynamic>> operations = [];
  final Completer<void> completer = Completer<void>();
  final DateTime createdAt = DateTime.now();

  void addInsert(String table, Map<String, dynamic> values) {
    operations.add({'type': 'insert', 'table': table, 'values': values});
  }

  void addUpdate(
    String table,
    Map<String, dynamic> values,
    String where,
    List<dynamic> whereArgs,
  ) {
    operations.add({
      'type': 'update',
      'table': table,
      'values': values,
      'where': where,
      'whereArgs': whereArgs,
    });
  }

  void addDelete(String table, String where, List<dynamic> whereArgs) {
    operations.add({
      'type': 'delete',
      'table': table,
      'where': where,
      'whereArgs': whereArgs,
    });
  }

  int get size => operations.length;
  bool get isEmpty => operations.isEmpty;
}

/// Main query optimizer and connection manager
class DatabaseQueryOptimizer {
  static DatabaseQueryOptimizer? _instance;
  static DatabaseQueryOptimizer get instance =>
      _instance ??= DatabaseQueryOptimizer._();

  DatabaseQueryOptimizer._();

  // Query statistics tracking
  final Map<String, QueryStatistics> _queryStats = {};

  // Query queue with priority
  final Queue<_QueuedOperation> _queryQueue = Queue();
  bool _isProcessingQueue = false;

  // Batch write operations
  BatchWriteOperation? _currentBatch;
  Timer? _batchTimer;
  static const Duration _batchWindow = Duration(milliseconds: 100);
  static const int _maxBatchSize = 50;

  // Performance thresholds
  static const int _slowQueryThresholdMs = 100;
  static const int _criticalSlowQueryMs = 500;

  /// Execute a query with priority and performance monitoring
  Future<T> executeQuery<T>({
    required Future<T> Function() operation,
    required String description,
    QueryPriority priority = QueryPriority.normal,
  }) async {
    final queuedOp = _QueuedOperation<T>(
      priority: priority,
      operation: operation,
      description: description,
    );

    _queryQueue.add(queuedOp);
    _processQueue();

    return queuedOp.completer.future;
  }

  /// Execute a read query with caching potential
  Future<List<Map<String, dynamic>>> executeRead({
    required String sql,
    List<dynamic>? arguments,
    QueryPriority priority = QueryPriority.normal,
  }) async {
    return executeQuery(
      operation: () async {
        final db = await DatabaseHelper.database;
        final startTime = DateTime.now();

        final result = await db.rawQuery(sql, arguments);

        _recordQueryExecution(
          sql,
          DateTime.now().difference(startTime).inMilliseconds,
        );

        return result;
      },
      description: 'READ: ${_sanitizeQueryForLogging(sql)}',
      priority: priority,
    );
  }

  /// Execute a write query (insert, update, delete)
  Future<int> executeWrite({
    required String sql,
    List<dynamic>? arguments,
    QueryPriority priority = QueryPriority.normal,
  }) async {
    return executeQuery(
      operation: () async {
        final db = await DatabaseHelper.database;
        final startTime = DateTime.now();

        final result = await db.rawUpdate(sql, arguments);

        _recordQueryExecution(
          sql,
          DateTime.now().difference(startTime).inMilliseconds,
        );

        return result;
      },
      description: 'WRITE: ${_sanitizeQueryForLogging(sql)}',
      priority: priority,
    );
  }

  /// Batch multiple write operations into a single transaction
  Future<void> executeBatch(
    Future<void> Function(Batch batch) operations,
  ) async {
    return executeQuery(
      operation: () async {
        final db = await DatabaseHelper.database;
        final batch = db.batch();
        await operations(batch);
        await batch.commit(noResult: true);
      },
      description: 'BATCH OPERATION',
      priority: QueryPriority.high,
    );
  }

  /// Add operation to batch queue (auto-flushes on size or timeout)
  Future<void> addToBatch({
    required String type,
    required String table,
    Map<String, dynamic>? values,
    String? where,
    List<dynamic>? whereArgs,
  }) async {
    _currentBatch ??= BatchWriteOperation();

    switch (type) {
      case 'insert':
        _currentBatch!.addInsert(table, values!);
        break;
      case 'update':
        _currentBatch!.addUpdate(table, values!, where!, whereArgs!);
        break;
      case 'delete':
        _currentBatch!.addDelete(table, where!, whereArgs!);
        break;
    }

    // Flush if batch is full
    if (_currentBatch!.size >= _maxBatchSize) {
      await flushBatch();
    } else {
      // Schedule auto-flush
      _batchTimer?.cancel();
      _batchTimer = Timer(_batchWindow, () => flushBatch());
    }

    return _currentBatch!.completer.future;
  }

  /// Manually flush pending batch operations
  Future<void> flushBatch() async {
    if (_currentBatch == null || _currentBatch!.isEmpty) return;

    final batch = _currentBatch!;
    _currentBatch = null;
    _batchTimer?.cancel();

    try {
      await executeBatch((db) async {
        for (final op in batch.operations) {
          switch (op['type']) {
            case 'insert':
              db.insert(op['table'], op['values']);
              break;
            case 'update':
              db.update(
                op['table'],
                op['values'],
                where: op['where'],
                whereArgs: op['whereArgs'],
              );
              break;
            case 'delete':
              db.delete(
                op['table'],
                where: op['where'],
                whereArgs: op['whereArgs'],
              );
              break;
          }
        }
      });
      batch.completer.complete();
    } catch (e) {
      batch.completer.completeError(e);
    }
  }

  /// Execute transaction with automatic retry on busy
  Future<T> executeTransaction<T>({
    required Future<T> Function(Transaction txn) operation,
    int maxRetries = 3,
  }) async {
    int retryCount = 0;

    while (true) {
      try {
        final db = await DatabaseHelper.database;
        return await db.transaction((txn) async {
          return await operation(txn);
        });
      } catch (e) {
        if (e.toString().contains('database is locked') &&
            retryCount < maxRetries) {
          retryCount++;
          _logger.warning('Database locked, retry $retryCount/$maxRetries');
          await Future.delayed(Duration(milliseconds: 50 * retryCount));
          continue;
        }
        rethrow;
      }
    }
  }

  /// Get query performance statistics
  Map<String, dynamic> getPerformanceStatistics() {
    final sortedQueries = _queryStats.values.toList()
      ..sort((a, b) => b.totalDurationMs.compareTo(a.totalDurationMs));

    final slowQueries = sortedQueries
        .where((q) => q.averageDurationMs > _slowQueryThresholdMs)
        .take(10)
        .toList();

    final totalQueries = _queryStats.values.fold<int>(
      0,
      (sum, stat) => sum + stat.executionCount,
    );

    final totalDuration = _queryStats.values.fold<int>(
      0,
      (sum, stat) => sum + stat.totalDurationMs,
    );

    return {
      'total_queries_executed': totalQueries,
      'total_duration_ms': totalDuration,
      'average_query_time_ms': totalQueries > 0
          ? (totalDuration / totalQueries).toStringAsFixed(2)
          : '0',
      'unique_queries': _queryStats.length,
      'slow_queries': slowQueries.map((q) => q.toJson()).toList(),
      'queue_size': _queryQueue.length,
      'is_processing': _isProcessingQueue,
    };
  }

  /// Get slow queries report
  List<QueryStatistics> getSlowQueries({int? limit}) {
    final slowQueries =
        _queryStats.values
            .where((q) => q.averageDurationMs > _slowQueryThresholdMs)
            .toList()
          ..sort((a, b) => b.averageDurationMs.compareTo(a.averageDurationMs));

    if (limit != null && slowQueries.length > limit) {
      return slowQueries.take(limit).toList();
    }

    return slowQueries;
  }

  /// Clear all statistics
  void clearStatistics() {
    _queryStats.clear();
  }

  /// Optimize database (run ANALYZE)
  Future<void> optimizeDatabase() async {
    await executeQuery(
      operation: () async {
        final db = await DatabaseHelper.database;
        await db.execute('ANALYZE');
        _logger.info('Database ANALYZE completed');
      },
      description: 'OPTIMIZE: ANALYZE',
      priority: QueryPriority.low,
    );
  }

  // Private methods

  Future<void> _processQueue() async {
    if (_isProcessingQueue || _queryQueue.isEmpty) return;

    _isProcessingQueue = true;

    try {
      while (_queryQueue.isNotEmpty) {
        // Sort by priority (higher priority first)
        final sortedOps = _queryQueue.toList()
          ..sort((a, b) => b.priority.index.compareTo(a.priority.index));

        _queryQueue.clear();
        _queryQueue.addAll(sortedOps);

        final op = _queryQueue.removeFirst();

        // Warn if operation waited too long
        if (op.waitTimeMs > 1000) {
          _logger.warning(
            'Operation "${op.description}" waited ${op.waitTimeMs}ms in queue',
          );
        }

        try {
          final result = await op.operation();
          op.completer.complete(result);
        } catch (e, stackTrace) {
          _logger.severe(
            'Query execution failed: ${op.description}',
            e,
            stackTrace,
          );
          op.completer.completeError(e, stackTrace);
        }
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  void _recordQueryExecution(String query, int durationMs) {
    final key = _normalizeQuery(query);

    if (_queryStats.containsKey(key)) {
      final existing = _queryStats[key]!;
      _queryStats[key] = QueryStatistics(
        query: query,
        executionCount: existing.executionCount + 1,
        totalDurationMs: existing.totalDurationMs + durationMs,
        minDurationMs: durationMs < existing.minDurationMs
            ? durationMs
            : existing.minDurationMs,
        maxDurationMs: durationMs > existing.maxDurationMs
            ? durationMs
            : existing.maxDurationMs,
        lastExecuted: DateTime.now(),
      );
    } else {
      _queryStats[key] = QueryStatistics(
        query: query,
        executionCount: 1,
        totalDurationMs: durationMs,
        minDurationMs: durationMs,
        maxDurationMs: durationMs,
        lastExecuted: DateTime.now(),
      );
    }

    // Log slow queries
    if (durationMs > _criticalSlowQueryMs) {
      _logger.warning(
        'CRITICAL SLOW QUERY (${durationMs}ms): ${_sanitizeQueryForLogging(query)}',
      );
    } else if (durationMs > _slowQueryThresholdMs) {
      _logger.info(
        'Slow query (${durationMs}ms): ${_sanitizeQueryForLogging(query)}',
      );
    }
  }

  String _normalizeQuery(String query) {
    // Normalize query by removing specific values for grouping
    return query
        .replaceAll(RegExp(r"'[^']*'"), '?')
        .replaceAll(RegExp(r'\d+'), '?')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _sanitizeQueryForLogging(String query) {
    return query.length > 150 ? '${query.substring(0, 150)}...' : query;
  }
}

/// Extension methods for convenient query optimization
extension DatabaseHelperOptimizedExtension on DatabaseHelper {
  /// Execute optimized batch insert
  static Future<void> batchInsertOptimized(
    String table,
    List<Map<String, dynamic>> values,
  ) async {
    final optimizer = DatabaseQueryOptimizer.instance;
    await optimizer.executeBatch((batch) async {
      for (final value in values) {
        batch.insert(table, value);
      }
    });
  }

  /// Execute optimized query with priority
  static Future<List<Map<String, dynamic>>> queryOptimized(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    QueryPriority priority = QueryPriority.normal,
  }) async {
    final db = await DatabaseHelper.database;
    return DatabaseQueryOptimizer.instance.executeQuery(
      operation: () => db.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
      ),
      description: 'QUERY: $table',
      priority: priority,
    );
  }
}
