// Test database query optimizer

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_query_optimizer.dart';
import 'test_helpers/test_setup.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'database_query_optimizer',
    );
  });

  setUp(() async {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.fullDatabaseReset();
    DatabaseQueryOptimizer.instance.clearStatistics();
  });

  void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

  tearDown(() {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  group('DatabaseQueryOptimizer Tests', () {
    test('Singleton pattern works correctly', () {
      final instance1 = DatabaseQueryOptimizer.instance;
      final instance2 = DatabaseQueryOptimizer.instance;

      expect(instance1, equals(instance2));
    });

    test('Execute query with priority works', () async {
      await DatabaseHelper.database;

      final result = await DatabaseQueryOptimizer.instance.executeQuery(
        operation: () async {
          return 42;
        },
        description: 'Test operation',
        priority: QueryPriority.high,
      );

      expect(result, equals(42));
    });

    test('Execute read query tracks statistics', () async {
      await DatabaseHelper.database;

      await DatabaseQueryOptimizer.instance.executeRead(
        sql: 'SELECT COUNT(*) as count FROM contacts',
        priority: QueryPriority.normal,
      );

      final stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();

      expect(stats['total_queries_executed'], greaterThan(0));
      expect(stats['unique_queries'], greaterThan(0));
    });

    test('Execute write query works correctly', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final testKey = 'test_optimizer_$now';

      // First insert the contact
      await db.insert('contacts', {
        'public_key': testKey,
        'display_name': 'Test User',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      // Update using optimizer
      final rowsAffected = await DatabaseQueryOptimizer.instance.executeWrite(
        sql: 'UPDATE contacts SET display_name = ? WHERE public_key = ?',
        arguments: ['Updated Name', testKey],
        priority: QueryPriority.normal,
      );

      expect(rowsAffected, equals(1));

      // Verify update
      final result = await db.query(
        'contacts',
        where: 'public_key = ?',
        whereArgs: [testKey],
      );

      expect(result.first['display_name'], equals('Updated Name'));

      // Cleanup
      await db.delete(
        'contacts',
        where: 'public_key = ?',
        whereArgs: [testKey],
      );
    });

    test('Batch operations are executed correctly', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await DatabaseQueryOptimizer.instance.executeBatch((batch) async {
        for (int i = 0; i < 5; i++) {
          batch.insert('contacts', {
            'public_key': 'batch_test_${i}_$now',
            'display_name': 'Batch User $i',
            'trust_status': 0,
            'security_level': 0,
            'first_seen': now,
            'last_seen': now,
            'created_at': now,
            'updated_at': now,
          });
        }
      });

      // Verify all inserted
      final result = await db.query(
        'contacts',
        where: 'public_key LIKE ?',
        whereArgs: ['batch_test_%_$now'],
      );

      expect(result.length, equals(5));

      // Cleanup
      await db.delete(
        'contacts',
        where: 'public_key LIKE ?',
        whereArgs: ['batch_test_%_$now'],
      );
    });

    test('Transaction with retry works', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final testKey = 'txn_test_$now';

      final result = await DatabaseQueryOptimizer.instance.executeTransaction(
        operation: (txn) async {
          await txn.insert('contacts', {
            'public_key': testKey,
            'display_name': 'Transaction Test',
            'trust_status': 0,
            'security_level': 0,
            'first_seen': now,
            'last_seen': now,
            'created_at': now,
            'updated_at': now,
          });
          return true;
        },
      );

      expect(result, isTrue);

      // Verify insertion
      final query = await db.query(
        'contacts',
        where: 'public_key = ?',
        whereArgs: [testKey],
      );

      expect(query.length, equals(1));

      // Cleanup
      await db.delete(
        'contacts',
        where: 'public_key = ?',
        whereArgs: [testKey],
      );
    });

    test('Performance statistics are tracked correctly', () async {
      await DatabaseHelper.database;

      // Execute multiple queries
      for (int i = 0; i < 5; i++) {
        await DatabaseQueryOptimizer.instance.executeRead(
          sql: 'SELECT COUNT(*) FROM contacts',
        );
      }

      final stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();

      expect(stats['total_queries_executed'], greaterThanOrEqualTo(5));
      expect(stats['total_duration_ms'], greaterThanOrEqualTo(0));
      expect(stats['average_query_time_ms'], isNotNull);
      expect(stats['unique_queries'], greaterThan(0));
    });

    test('Slow queries are detected and reported', () async {
      await DatabaseHelper.database;

      // Execute some queries
      await DatabaseQueryOptimizer.instance.executeRead(
        sql: 'SELECT * FROM contacts',
      );

      final slowQueries = DatabaseQueryOptimizer.instance.getSlowQueries();

      // Slow queries list should exist (may be empty for fast queries)
      expect(slowQueries, isNotNull);
      expect(slowQueries, isA<List<QueryStatistics>>());
    });

    test('Query priority system works', () async {
      await DatabaseHelper.database;

      // Execute queries with different priorities
      // Just verify they all complete successfully
      final futures = <Future>[];

      futures.add(
        DatabaseQueryOptimizer.instance.executeQuery(
          operation: () async => 'low',
          description: 'Low priority',
          priority: QueryPriority.low,
        ),
      );

      futures.add(
        DatabaseQueryOptimizer.instance.executeQuery(
          operation: () async => 'critical',
          description: 'Critical priority',
          priority: QueryPriority.critical,
        ),
      );

      futures.add(
        DatabaseQueryOptimizer.instance.executeQuery(
          operation: () async => 'normal',
          description: 'Normal priority',
          priority: QueryPriority.normal,
        ),
      );

      final results = await Future.wait(futures);

      // All operations should complete
      expect(results.length, equals(3));
      expect(results, contains('low'));
      expect(results, contains('critical'));
      expect(results, contains('normal'));
    });

    test('Statistics can be cleared', () async {
      await DatabaseHelper.database;

      // Execute some queries
      await DatabaseQueryOptimizer.instance.executeRead(
        sql: 'SELECT COUNT(*) FROM contacts',
      );

      var stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();
      expect(stats['total_queries_executed'], greaterThan(0));

      // Clear statistics
      DatabaseQueryOptimizer.instance.clearStatistics();

      stats = DatabaseQueryOptimizer.instance.getPerformanceStatistics();
      expect(stats['total_queries_executed'], equals(0));
    });

    test('Database optimization (ANALYZE) completes successfully', () async {
      await DatabaseHelper.database;

      await expectLater(
        DatabaseQueryOptimizer.instance.optimizeDatabase(),
        completes,
      );
    });

    test('Extension methods work correctly', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Batch insert using extension
      await DatabaseHelperOptimizedExtension.batchInsertOptimized('contacts', [
        {
          'public_key': 'ext_test_1_$now',
          'display_name': 'Extension Test 1',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': now,
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        },
        {
          'public_key': 'ext_test_2_$now',
          'display_name': 'Extension Test 2',
          'trust_status': 0,
          'security_level': 0,
          'first_seen': now,
          'last_seen': now,
          'created_at': now,
          'updated_at': now,
        },
      ]);

      // Query using optimized extension
      final results = await DatabaseHelperOptimizedExtension.queryOptimized(
        'contacts',
        where: 'public_key LIKE ?',
        whereArgs: ['ext_test_%_$now'],
        priority: QueryPriority.high,
      );

      expect(results.length, equals(2));

      // Cleanup
      await db.delete(
        'contacts',
        where: 'public_key LIKE ?',
        whereArgs: ['ext_test_%_$now'],
      );
    });
  });
}
