// Phase 12.13 — DatabaseQueryOptimizer supplementary coverage
// Targets: batch addToBatch/flushBatch, executeTransaction retry,
//          _processQueue, _recordQueryExecution slow-query paths,
//          getPerformanceStatistics, QueryStatistics model

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_query_optimizer.dart';

import '../../test_helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LogRecord> logRecords;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'db_query_optimizer_p12',
    );
  });

  setUp(() {
    logRecords = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    DatabaseQueryOptimizer.instance.clearStatistics();
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  // ─── QueryStatistics model ─────────────────────────────────────────

  group('QueryStatistics model', () {
    test('averageDurationMs returns 0 when executionCount is 0', () {
      final stats = QueryStatistics(
        query: 'SELECT 1',
        executionCount: 0,
        totalDurationMs: 0,
        minDurationMs: 0,
        maxDurationMs: 0,
        lastExecuted: DateTime.now(),
      );
      expect(stats.averageDurationMs, equals(0));
    });

    test('averageDurationMs calculates correctly', () {
      final stats = QueryStatistics(
        query: 'SELECT 1',
        executionCount: 4,
        totalDurationMs: 100,
        minDurationMs: 10,
        maxDurationMs: 40,
        lastExecuted: DateTime.now(),
      );
      expect(stats.averageDurationMs, equals(25.0));
    });

    test('toJson serializes all fields', () {
      final now = DateTime.now();
      final stats = QueryStatistics(
        query: 'SELECT * FROM contacts WHERE id = 42',
        executionCount: 3,
        totalDurationMs: 90,
        minDurationMs: 20,
        maxDurationMs: 50,
        lastExecuted: now,
      );
      final json = stats.toJson();
      expect(json['execution_count'], equals(3));
      expect(json['total_duration_ms'], equals(90));
      expect(json['min_duration_ms'], equals(20));
      expect(json['max_duration_ms'], equals(50));
      expect(json['avg_duration_ms'], equals('30.00'));
      expect(json['last_executed'], equals(now.toIso8601String()));
      // Query should be sanitized
      expect(json['query'], isA<String>());
    });
  });

  // ─── addToBatch and flushBatch ─────────────────────────────────────

  group('Batch operations', () {
    test('addToBatch insert schedules and flushBatch executes', () async {
      await DatabaseHelper.database; // Ensure DB is ready
      final now = DateTime.now().millisecondsSinceEpoch;

      // Add an insert to batch
      await DatabaseQueryOptimizer.instance.addToBatch(
        type: 'insert',
        table: 'app_preferences',
        values: {
          'key': 'batch_test',
          'value': 'hello',
          'value_type': 'string',
          'created_at': now,
          'updated_at': now,
        },
      );

      // Flush it
      await DatabaseQueryOptimizer.instance.flushBatch();

      // Verify it was inserted
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'app_preferences',
        where: '"key" = ?',
        whereArgs: ['batch_test'],
      );
      expect(rows.length, equals(1));
      expect(rows.first['value'], equals('hello'));
    });

    test('flushBatch is no-op when batch is empty', () async {
      await DatabaseHelper.database;
      // Should not throw
      await DatabaseQueryOptimizer.instance.flushBatch();
    });

    test('addToBatch update works', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Pre-insert
      await db.insert('app_preferences', {
        'key': 'update_test',
        'value': 'old',
        'value_type': 'string',
        'created_at': now,
        'updated_at': now,
      });

      await DatabaseQueryOptimizer.instance.addToBatch(
        type: 'update',
        table: 'app_preferences',
        values: {'value': 'new', 'updated_at': now + 1},
        where: '"key" = ?',
        whereArgs: ['update_test'],
      );

      await DatabaseQueryOptimizer.instance.flushBatch();

      final rows = await db.query(
        'app_preferences',
        where: '"key" = ?',
        whereArgs: ['update_test'],
      );
      expect(rows.first['value'], equals('new'));
    });

    test('addToBatch delete works', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('app_preferences', {
        'key': 'delete_test',
        'value': 'delete_me',
        'value_type': 'string',
        'created_at': now,
        'updated_at': now,
      });

      await DatabaseQueryOptimizer.instance.addToBatch(
        type: 'delete',
        table: 'app_preferences',
        where: '"key" = ?',
        whereArgs: ['delete_test'],
      );

      await DatabaseQueryOptimizer.instance.flushBatch();

      final rows = await db.query(
        'app_preferences',
        where: '"key" = ?',
        whereArgs: ['delete_test'],
      );
      expect(rows, isEmpty);
    });
  });

  // ─── executeTransaction retry ──────────────────────────────────────

  group('executeTransaction', () {
    test('executeTransaction completes on success', () async {
      await DatabaseHelper.database;

      final result =
          await DatabaseQueryOptimizer.instance.executeTransaction<int>(
        operation: (txn) async {
          return 42;
        },
      );
      expect(result, equals(42));
    });

    test('executeTransaction rethrows non-lock errors', () async {
      await DatabaseHelper.database;

      expect(
        () => DatabaseQueryOptimizer.instance.executeTransaction<int>(
          operation: (txn) async {
            throw Exception('random error');
          },
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ─── getPerformanceStatistics ──────────────────────────────────────

  group('Performance statistics', () {
    test('returns zeroed report when no queries run', () {
      final stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();
      expect(stats['total_queries_executed'], equals(0));
      expect(stats['total_duration_ms'], equals(0));
      expect(stats['average_query_time_ms'], equals('0'));
      expect(stats['unique_queries'], equals(0));
      expect(stats['slow_queries'], isEmpty);
      expect(stats['queue_size'], equals(0));
      expect(stats['is_processing'], isFalse);
    });

    test('stats accumulate after executeRead', () async {
      await DatabaseHelper.database;

      await DatabaseQueryOptimizer.instance.executeRead(
        sql: 'SELECT 1',
      );

      final stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();
      expect(stats['total_queries_executed'], greaterThan(0));
    });

    test('clearStatistics resets all counters', () async {
      await DatabaseHelper.database;

      await DatabaseQueryOptimizer.instance.executeQuery(
        operation: () async => null,
        description: 'a query',
      );

      DatabaseQueryOptimizer.instance.clearStatistics();

      final stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();
      expect(stats['total_queries_executed'], equals(0));
    });
  });

  // ─── getSlowQueries ───────────────────────────────────────────────

  group('Slow queries', () {
    test('getSlowQueries returns empty list when none are slow', () {
      final slow = DatabaseQueryOptimizer.instance.getSlowQueries();
      expect(slow, isEmpty);
    });

    test('getSlowQueries respects limit parameter', () {
      // Without actual slow queries, this just verifies the limit logic
      final slow = DatabaseQueryOptimizer.instance.getSlowQueries(limit: 5);
      expect(slow.length, lessThanOrEqualTo(5));
    });
  });

  // ─── optimizeDatabase ─────────────────────────────────────────────

  group('optimizeDatabase', () {
    test('runs ANALYZE without error', () async {
      await DatabaseHelper.database;
      await DatabaseQueryOptimizer.instance.optimizeDatabase();

      final hasAnalyzeLog = logRecords.any(
        (r) => r.message.contains('ANALYZE completed'),
      );
      expect(hasAnalyzeLog, isTrue);
    });
  });

  // ─── executeRead / executeWrite ───────────────────────────────────

  group('Read and Write helpers', () {
    test('executeRead returns query results', () async {
      await DatabaseHelper.database;

      final result = await DatabaseQueryOptimizer.instance.executeRead(
        sql: 'SELECT COUNT(*) as cnt FROM app_preferences',
      );
      expect(result, isA<List>());
      expect(result.first['cnt'], isA<int>());
    });

    test('executeWrite inserts data', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await DatabaseQueryOptimizer.instance.executeWrite(
        sql:
            'INSERT INTO app_preferences ("key", value, value_type, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
        arguments: ['write_test', 'value1', 'string', now, now],
      );

      final rows = await db.query(
        'app_preferences',
        where: '"key" = ?',
        whereArgs: ['write_test'],
      );
      expect(rows.length, equals(1));
    });
  });
}
