/// Phase 12.4: Supplementary tests for DatabaseMonitorService
/// Covers: model serialization round-trips, GrowthStatistics edge cases,
///   getHistoricalSnapshots filters, clearHistory, recommendation generation,
///   MonitoringAlert toJson, IndexMetrics.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_monitor_service.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'db_monitor_p12');
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  // ── Model unit tests (no DB required) ───────────────────────────────

  group('DatabaseSnapshot serialization', () {
    test('toJson produces expected keys', () {
      final snapshot = DatabaseSnapshot(
        timestamp: DateTime(2025, 6, 1),
        totalSizeBytes: 1048576,
        tableMetrics: {
          'messages': TableMetrics(
            name: 'messages',
            rowCount: 500,
            sizeBytes: 524288,
            unusedBytes: 10240,
            fragmentationRatio: 0.0195,
          ),
        },
        indexMetrics: {
          'idx_msg_ts': IndexMetrics(
            name: 'idx_msg_ts',
            tableName: 'messages',
            sizeBytes: 8192,
            isUnique: false,
          ),
        },
        totalRows: 500,
        fragmentationRatio: 0.01,
      );

      final json = snapshot.toJson();
      expect(json['total_size_bytes'], 1048576);
      expect(json['total_rows'], 500);
      expect(json['timestamp'], isA<String>());
      expect(json['total_size_mb'], isA<String>());
      expect(json['fragmentation_ratio'], isA<String>());
      expect((json['table_metrics'] as Map).containsKey('messages'), isTrue);
      expect((json['index_metrics'] as Map).containsKey('idx_msg_ts'), isTrue);
    });

    test('fromJson with numeric fragmentation_ratio', () {
      final json = {
        'timestamp': '2025-06-01T00:00:00.000',
        'total_size_bytes': 2048,
        'total_rows': 10,
        'fragmentation_ratio': 0.05,
        'table_metrics': <String, dynamic>{},
        'index_metrics': <String, dynamic>{},
      };
      final restored = DatabaseSnapshot.fromJson(json);
      expect(restored.totalSizeBytes, 2048);
      expect(restored.totalRows, 10);
      expect(restored.fragmentationRatio, closeTo(0.05, 0.001));
    });

    test('totalSizeMB computes correctly', () {
      final snapshot = DatabaseSnapshot(
        timestamp: DateTime.now(),
        totalSizeBytes: 5 * 1024 * 1024,
        tableMetrics: {},
        indexMetrics: {},
        totalRows: 0,
        fragmentationRatio: 0.0,
      );
      expect(snapshot.totalSizeMB, closeTo(5.0, 0.001));
    });
  });

  group('TableMetrics', () {
    test('sizeMB and unusedMB compute correctly', () {
      final m = TableMetrics(
        name: 't',
        rowCount: 10,
        sizeBytes: 2 * 1024 * 1024,
        unusedBytes: 512 * 1024,
        fragmentationRatio: 0.25,
      );
      expect(m.sizeMB, closeTo(2.0, 0.001));
      expect(m.unusedMB, closeTo(0.5, 0.001));
    });

    test('efficiency is 1.0 when sizeBytes is 0', () {
      final m = TableMetrics(
        name: 'empty',
        rowCount: 0,
        sizeBytes: 0,
        unusedBytes: 0,
        fragmentationRatio: 0.0,
      );
      expect(m.efficiency, 1.0);
    });

    test('toJson produces expected keys, fromJson with numeric values', () {
      final original = TableMetrics(
        name: 'contacts',
        rowCount: 42,
        sizeBytes: 100000,
        unusedBytes: 5000,
        fragmentationRatio: 0.05,
      );
      final json = original.toJson();
      expect(json['name'], 'contacts');
      expect(json['row_count'], 42);
      expect(json['size_bytes'], 100000);

      // fromJson expects numeric fragmentation_ratio
      final rawJson = {
        'name': 'contacts',
        'row_count': 42,
        'size_bytes': 100000,
        'unused_bytes': 5000,
        'fragmentation_ratio': 0.05,
      };
      final restored = TableMetrics.fromJson(rawJson);
      expect(restored.name, 'contacts');
      expect(restored.rowCount, 42);
      expect(restored.sizeBytes, 100000);
      expect(restored.unusedBytes, 5000);
    });
  });

  group('IndexMetrics', () {
    test('sizeMB computes correctly', () {
      final idx = IndexMetrics(
        name: 'idx_1',
        tableName: 'messages',
        sizeBytes: 1024 * 1024,
        isUnique: true,
      );
      expect(idx.sizeMB, closeTo(1.0, 0.001));
    });

    test('toJson/fromJson round-trip', () {
      final original = IndexMetrics(
        name: 'idx_pk',
        tableName: 'contacts',
        sizeBytes: 8192,
        isUnique: true,
      );
      final json = original.toJson();
      expect(json['is_unique'], true);
      expect(json['table_name'], 'contacts');
      final restored = IndexMetrics.fromJson(json);
      expect(restored.name, 'idx_pk');
      expect(restored.isUnique, true);
    });
  });

  group('GrowthStatistics', () {
    test('growthMB and growthPercentage compute correctly', () {
      final stats = GrowthStatistics(
        startTime: DateTime(2025, 1, 1),
        endTime: DateTime(2025, 1, 8),
        startSizeBytes: 1024 * 1024,
        endSizeBytes: 2 * 1024 * 1024,
        growthBytes: 1024 * 1024,
        growthRate: 1024 * 1024 / 7,
        tableGrowth: {'messages': 100},
      );
      expect(stats.growthMB, closeTo(1.0, 0.001));
      expect(stats.growthPercentage, closeTo(100.0, 0.001));
      expect(stats.daysElapsed, 7);
    });

    test('growthPercentage is 0 when startSizeBytes is 0', () {
      final stats = GrowthStatistics(
        startTime: DateTime(2025, 1, 1),
        endTime: DateTime(2025, 1, 2),
        startSizeBytes: 0,
        endSizeBytes: 1000,
        growthBytes: 1000,
        growthRate: 1000,
        tableGrowth: {},
      );
      expect(stats.growthPercentage, 0.0);
    });

    test('toJson includes all fields', () {
      final stats = GrowthStatistics(
        startTime: DateTime(2025, 1, 1),
        endTime: DateTime(2025, 1, 3),
        startSizeBytes: 5000,
        endSizeBytes: 8000,
        growthBytes: 3000,
        growthRate: 1500,
        tableGrowth: {'chats': 5},
      );
      final json = stats.toJson();
      expect(json['days_elapsed'], 2);
      expect(json['start_size_bytes'], 5000);
      expect(json['end_size_bytes'], 8000);
      expect(json['growth_bytes'], 3000);
      expect(json['table_growth'], {'chats': 5});
    });
  });

  group('MonitoringAlert', () {
    test('toJson includes metadata when present', () {
      final alert = MonitoringAlert(
        severity: AlertSeverity.critical,
        title: 'Critical DB',
        description: 'DB too big',
        timestamp: DateTime(2025, 6, 1),
        metadata: {'size_mb': 999},
      );
      final json = alert.toJson();
      expect(json['severity'], 'critical');
      expect(json['metadata'], isNotNull);
      expect(json['metadata']['size_mb'], 999);
    });

    test('toJson omits metadata key when null', () {
      final alert = MonitoringAlert(
        severity: AlertSeverity.info,
        title: 'Info',
        description: 'All good',
        timestamp: DateTime.now(),
      );
      final json = alert.toJson();
      expect(json.containsKey('metadata'), isFalse);
    });
  });

  // ── Static method tests (require DB) ───────────────────────────────

  group('getGrowthStatistics', () {
    setUp(() async {
      await TestSetup.fullDatabaseReset();
      await DatabaseMonitorService.clearHistory();
    });

    test('returns null when fewer than 2 snapshots exist', () async {
      final result = await DatabaseMonitorService.getGrowthStatistics(
        daysBack: 7,
      );
      expect(result, isNull);
    });
  });

  group('getHistoricalSnapshots', () {
    setUp(() async {
      await TestSetup.fullDatabaseReset();
      await DatabaseMonitorService.clearHistory();
    });

    test('returns empty list when no history exists', () async {
      final snapshots = await DatabaseMonitorService.getHistoricalSnapshots();
      expect(snapshots, isEmpty);
    });

    test('respects since filter (returns empty when no data)', () async {
      final snapshots = await DatabaseMonitorService.getHistoricalSnapshots(
        since: DateTime(2025, 1, 1),
      );
      expect(snapshots, isEmpty);
    });

    test('respects limit filter', () async {
      final snapshots = await DatabaseMonitorService.getHistoricalSnapshots(
        limit: 5,
      );
      expect(snapshots.length, lessThanOrEqualTo(5));
    });
  });

  group('clearHistory', () {
    test('completes without error', () async {
      await expectLater(
        DatabaseMonitorService.clearHistory(),
        completes,
      );
    });
  });

  group('captureSnapshot integration', () {
    setUp(() async {
      await TestSetup.fullDatabaseReset();
      await DatabaseMonitorService.clearHistory();
    });

    test('captures snapshot with real DB', () async {
      await DatabaseHelper.database;
      final snapshot = await DatabaseMonitorService.captureSnapshot();
      expect(snapshot.totalSizeBytes, greaterThan(0));
      expect(snapshot.tableMetrics, isNotEmpty);
    });
  });

  group('analyzeAndGenerateAlerts', () {
    setUp(() async {
      await TestSetup.fullDatabaseReset();
      await DatabaseMonitorService.clearHistory();
    });

    test('generates alerts without error on fresh DB', () async {
      await DatabaseHelper.database;
      final alerts = await DatabaseMonitorService.analyzeAndGenerateAlerts();
      expect(alerts, isA<List<MonitoringAlert>>());
    });
  });

  group('getDashboardData', () {
    setUp(() async {
      await TestSetup.fullDatabaseReset();
      await DatabaseMonitorService.clearHistory();
    });

    test('returns recommendations list', () async {
      await DatabaseHelper.database;
      final dashboard = await DatabaseMonitorService.getDashboardData();
      final recs = dashboard['recommendations'] as List;
      expect(recs, isNotEmpty);
    });
  });
}
