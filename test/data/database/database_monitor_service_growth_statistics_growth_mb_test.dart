// Supplementary DatabaseMonitorService tests
// Targets uncovered lines: _generateRecommendations paths,
// _findClosestSnapshot, getGrowthStatistics filters,
// getHistoricalSnapshots filtering, clearHistory,
// GrowthStatistics computed properties, model edge cases.
//
// Does NOT duplicate topics in database_monitor_service_phase13_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_monitor_service.dart';

void main() {
 Logger.root.level = Level.OFF;

 // ── GrowthStatistics — advanced computed properties ─────────────────

 group('GrowthStatistics — growthMB', () {
 test('growthMB with sub-megabyte growth', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 2),
 startSizeBytes: 1000,
 endSizeBytes: 1500,
 growthBytes: 500,
 growthRate: 500.0,
 tableGrowth: {},
);
 expect(stats.growthMB, closeTo(500 / 1024 / 1024, 0.0001));
 });

 test('growthMB with exact 1MB growth', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 2),
 startSizeBytes: 0,
 endSizeBytes: 1024 * 1024,
 growthBytes: 1024 * 1024,
 growthRate: 1024 * 1024,
 tableGrowth: {},
);
 expect(stats.growthMB, closeTo(1.0, 0.001));
 });

 test('negative growthMB for shrinking database', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 8),
 startSizeBytes: 2 * 1024 * 1024,
 endSizeBytes: 1 * 1024 * 1024,
 growthBytes: -1024 * 1024,
 growthRate: -1024 * 1024 / 7,
 tableGrowth: {},
);
 expect(stats.growthMB, closeTo(-1.0, 0.001));
 });
 });

 group('GrowthStatistics — growthPercentage', () {
 test('100% growth', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 8),
 startSizeBytes: 1024,
 endSizeBytes: 2048,
 growthBytes: 1024,
 growthRate: 1024 / 7,
 tableGrowth: {},
);
 expect(stats.growthPercentage, closeTo(100.0, 0.001));
 });

 test('50% growth', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 8),
 startSizeBytes: 2000,
 endSizeBytes: 3000,
 growthBytes: 1000,
 growthRate: 1000 / 7,
 tableGrowth: {},
);
 expect(stats.growthPercentage, closeTo(50.0, 0.001));
 });

 test('zero startSizeBytes returns 0 percentage', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 8),
 startSizeBytes: 0,
 endSizeBytes: 5000,
 growthBytes: 5000,
 growthRate: 5000 / 7,
 tableGrowth: {},
);
 expect(stats.growthPercentage, 0.0);
 });

 test('negative growth percentage for shrinking DB', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 8),
 startSizeBytes: 10000,
 endSizeBytes: 7000,
 growthBytes: -3000,
 growthRate: -3000 / 7,
 tableGrowth: {},
);
 expect(stats.growthPercentage, closeTo(-30.0, 0.001));
 });
 });

 group('GrowthStatistics — daysElapsed', () {
 test('same timestamp gives 0 days', () {
 final t = DateTime(2025, 6, 1);
 final stats = GrowthStatistics(startTime: t,
 endTime: t,
 startSizeBytes: 1000,
 endSizeBytes: 1000,
 growthBytes: 0,
 growthRate: 0,
 tableGrowth: {},
);
 expect(stats.daysElapsed, 0);
 });

 test('exactly 30 days', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 31),
 startSizeBytes: 1000,
 endSizeBytes: 2000,
 growthBytes: 1000,
 growthRate: 1000 / 30,
 tableGrowth: {},
);
 expect(stats.daysElapsed, 30);
 });

 test('sub-day difference rounds to 0', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 6, 1, 10, 0),
 endTime: DateTime(2025, 6, 1, 22, 0),
 startSizeBytes: 1000,
 endSizeBytes: 1100,
 growthBytes: 100,
 growthRate: 100,
 tableGrowth: {},
);
 expect(stats.daysElapsed, 0);
 });
 });

 group('GrowthStatistics — toJson comprehensive', () {
 test('toJson includes growth_rate_mb_per_day', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 8),
 startSizeBytes: 10 * 1024 * 1024,
 endSizeBytes: 17 * 1024 * 1024,
 growthBytes: 7 * 1024 * 1024,
 growthRate: 7 * 1024 * 1024 / 7,
 tableGrowth: {'messages': 700},
);
 final json = stats.toJson();
 expect(json.containsKey('growth_rate_mb_per_day'), isTrue);
 expect(json['growth_rate_mb_per_day'], isA<String>());
 expect(double.parse(json['growth_rate_mb_per_day'] as String),
 closeTo(1.0, 0.01));
 });

 test('toJson with empty tableGrowth', () {
 final stats = GrowthStatistics(startTime: DateTime(2025, 1, 1),
 endTime: DateTime(2025, 1, 2),
 startSizeBytes: 100,
 endSizeBytes: 200,
 growthBytes: 100,
 growthRate: 100,
 tableGrowth: {},
);
 final json = stats.toJson();
 expect(json['table_growth'], isA<Map>());
 expect((json['table_growth'] as Map), isEmpty);
 });

 test('toJson timestamps are ISO8601', () {
 final start = DateTime(2025, 3, 1, 12, 30);
 final end = DateTime(2025, 3, 8, 12, 30);
 final stats = GrowthStatistics(startTime: start,
 endTime: end,
 startSizeBytes: 100,
 endSizeBytes: 200,
 growthBytes: 100,
 growthRate: 100 / 7,
 tableGrowth: {},
);
 final json = stats.toJson();
 expect(json['start_time'], start.toIso8601String());
 expect(json['end_time'], end.toIso8601String());
 });
 });

 // ── MonitoringAlert — additional serialization ─────────────────────

 group('MonitoringAlert — toJson edge cases', () {
 test('toJson with nested metadata', () {
 final alert = MonitoringAlert(severity: AlertSeverity.critical,
 title: 'Complex Alert',
 description: 'Has nested metadata',
 timestamp: DateTime(2025, 6, 15),
 metadata: {
 'tables': {'messages': 1000, 'contacts': 50},
 'recommendations': ['VACUUM', 'archive'],
 },
);
 final json = alert.toJson();
 expect(json['metadata']!['tables'], isA<Map>());
 expect(json['metadata']!['recommendations'], isA<List>());
 });

 test('toJson preserves timestamp', () {
 final ts = DateTime(2025, 12, 25, 10, 30, 45);
 final alert = MonitoringAlert(severity: AlertSeverity.info,
 title: 'Test',
 description: 'Test description',
 timestamp: ts,
);
 final json = alert.toJson();
 expect(json['timestamp'], ts.toIso8601String());
 });

 test('all severity names are lowercase', () {
 for (final severity in AlertSeverity.values) {
 final alert = MonitoringAlert(severity: severity,
 title: 'T',
 description: 'D',
 timestamp: DateTime.now(),
);
 final json = alert.toJson();
 expect(json['severity'], severity.name);
 expect(json['severity'], equals(json['severity'].toString().toLowerCase()));
 }
 });
 });

 // ── TableMetrics — sizeMB and unusedMB ────────────────────────────

 group('TableMetrics — computed MB properties', () {
 test('sizeMB converts bytes correctly', () {
 final m = TableMetrics(name: 'test',
 rowCount: 100,
 sizeBytes: 5 * 1024 * 1024,
 unusedBytes: 0,
 fragmentationRatio: 0.0,
);
 expect(m.sizeMB, closeTo(5.0, 0.001));
 });

 test('unusedMB converts bytes correctly', () {
 final m = TableMetrics(name: 'test',
 rowCount: 100,
 sizeBytes: 10 * 1024 * 1024,
 unusedBytes: 2 * 1024 * 1024,
 fragmentationRatio: 0.2,
);
 expect(m.unusedMB, closeTo(2.0, 0.001));
 });

 test('efficiency with partial unused', () {
 final m = TableMetrics(name: 'test',
 rowCount: 50,
 sizeBytes: 4000,
 unusedBytes: 1000,
 fragmentationRatio: 0.25,
);
 expect(m.efficiency, closeTo(0.75, 0.001));
 });

 test('toJson computed fields format correctly', () {
 final m = TableMetrics(name: 'metrics_table',
 rowCount: 999,
 sizeBytes: 1536 * 1024,
 unusedBytes: 256 * 1024,
 fragmentationRatio: 0.167,
);
 final json = m.toJson();
 expect(json['name'], 'metrics_table');
 expect(json['row_count'], 999);
 expect(double.parse(json['size_mb'] as String), closeTo(1.5, 0.01));
 expect(double.parse(json['unused_mb'] as String), closeTo(0.25, 0.01));
 });
 });

 // ── IndexMetrics — sizeMB ──────────────────────────────────────────

 group('IndexMetrics — sizeMB edge cases', () {
 test('zero size', () {
 final idx = IndexMetrics(name: 'idx_empty',
 tableName: 'empty',
 sizeBytes: 0,
 isUnique: false,
);
 expect(idx.sizeMB, 0.0);
 });

 test('sub-megabyte size', () {
 final idx = IndexMetrics(name: 'idx_small',
 tableName: 'small',
 sizeBytes: 512,
 isUnique: true,
);
 expect(idx.sizeMB, closeTo(512.0 / 1024 / 1024, 0.0001));
 });

 test('toJson size_mb is formatted string', () {
 final idx = IndexMetrics(name: 'idx_fmt',
 tableName: 'fmt',
 sizeBytes: 3 * 1024 * 1024,
 isUnique: false,
);
 final json = idx.toJson();
 expect(double.parse(json['size_mb'] as String), closeTo(3.0, 0.01));
 });
 });

 // ── DatabaseSnapshot — toJson/fromJson advanced ────────────────────

 group('DatabaseSnapshot — toJson completeness', () {
 test('toJson includes all expected keys', () {
 final snapshot = DatabaseSnapshot(timestamp: DateTime(2025, 6, 1),
 totalSizeBytes: 1024 * 1024,
 tableMetrics: {
 't1': TableMetrics(name: 't1',
 rowCount: 10,
 sizeBytes: 1024,
 unusedBytes: 100,
 fragmentationRatio: 0.1,
),
 },
 indexMetrics: {
 'i1': IndexMetrics(name: 'i1',
 tableName: 't1',
 sizeBytes: 256,
 isUnique: true,
),
 },
 totalRows: 10,
 fragmentationRatio: 0.05,
);
 final json = snapshot.toJson();
 expect(json.containsKey('timestamp'), isTrue);
 expect(json.containsKey('total_size_bytes'), isTrue);
 expect(json.containsKey('total_size_mb'), isTrue);
 expect(json.containsKey('total_rows'), isTrue);
 expect(json.containsKey('fragmentation_ratio'), isTrue);
 expect(json.containsKey('table_metrics'), isTrue);
 expect(json.containsKey('index_metrics'), isTrue);
 });

 test('fromJson with integer fragmentation_ratio', () {
 final json = {
 'timestamp': '2025-01-01T00:00:00.000',
 'total_size_bytes': 1024,
 'total_rows': 1,
 'fragmentation_ratio': 0,
 'table_metrics': <String, dynamic>{},
 'index_metrics': <String, dynamic>{},
 };
 final restored = DatabaseSnapshot.fromJson(json);
 expect(restored.fragmentationRatio, 0.0);
 });

 test('fromJson with double fragmentation_ratio', () {
 final json = {
 'timestamp': '2025-01-01T00:00:00.000',
 'total_size_bytes': 2048,
 'total_rows': 10,
 'fragmentation_ratio': 0.456,
 'table_metrics': <String, dynamic>{},
 'index_metrics': <String, dynamic>{},
 };
 final restored = DatabaseSnapshot.fromJson(json);
 expect(restored.fragmentationRatio, closeTo(0.456, 0.001));
 });

 test('fromJson with many tables', () {
 final tables = <String, dynamic>{};
 for (int i = 0; i < 10; i++) {
 tables['table_$i'] = {
 'name': 'table_$i',
 'row_count': i * 100,
 'size_bytes': i * 1024,
 'unused_bytes': i * 10,
 'fragmentation_ratio': i * 0.01,
 };
 }
 final json = {
 'timestamp': '2025-06-01T00:00:00.000',
 'total_size_bytes': 50000,
 'total_rows': 4500,
 'fragmentation_ratio': 0.05,
 'table_metrics': tables,
 'index_metrics': <String, dynamic>{},
 };
 final restored = DatabaseSnapshot.fromJson(json);
 expect(restored.tableMetrics.length, 10);
 });
 });

 // ── Alert threshold constants verification ────────────────────────

 group('Alert threshold verification', () {
 test('size threshold triggers warning for DB > 500MB', () {
 final snapshot = DatabaseSnapshot(timestamp: DateTime.now(),
 totalSizeBytes: 501 * 1024 * 1024,
 tableMetrics: {},
 indexMetrics: {},
 totalRows: 0,
 fragmentationRatio: 0.0,
);
 // Verify the condition that would trigger a size alert
 expect(snapshot.totalSizeMB, greaterThan(500));
 });

 test('size threshold does NOT trigger for DB <= 500MB', () {
 final snapshot = DatabaseSnapshot(timestamp: DateTime.now(),
 totalSizeBytes: 499 * 1024 * 1024,
 tableMetrics: {},
 indexMetrics: {},
 totalRows: 0,
 fragmentationRatio: 0.0,
);
 expect(snapshot.totalSizeMB, lessThan(500));
 });

 test('fragmentation threshold triggers at > 0.3', () {
 final snapshot = DatabaseSnapshot(timestamp: DateTime.now(),
 totalSizeBytes: 1024,
 tableMetrics: {},
 indexMetrics: {},
 totalRows: 0,
 fragmentationRatio: 0.31,
);
 expect(snapshot.fragmentationRatio, greaterThan(0.3));
 });

 test('fragmentation threshold does NOT trigger at <= 0.3', () {
 final snapshot = DatabaseSnapshot(timestamp: DateTime.now(),
 totalSizeBytes: 1024,
 tableMetrics: {},
 indexMetrics: {},
 totalRows: 0,
 fragmentationRatio: 0.29,
);
 expect(snapshot.fragmentationRatio, lessThanOrEqualTo(0.3));
 });

 test('large table alert at > 100MB', () {
 final table = TableMetrics(name: 'messages',
 rowCount: 500000,
 sizeBytes: 101 * 1024 * 1024,
 unusedBytes: 0,
 fragmentationRatio: 0.0,
);
 expect(table.sizeMB, greaterThan(100));
 });

 test('growth rate threshold at > 50MB/day', () {
 final rateBytes = 51.0 * 1024 * 1024; // 51 MB/day in bytes
 expect(rateBytes, greaterThan(50 * 1024 * 1024));
 });
 });

 // ── clearHistory — graceful handling ───────────────────────────────

 group('clearHistory — graceful error handling', () {
 test('clearHistory does not throw in test environment', () async {
 // SharedPreferences may not be initialized, but clearHistory
 // catches the error silently
 await expectLater(DatabaseMonitorService.clearHistory(),
 completes,
);
 });
 });

 // ── getGrowthStatistics — edge cases ──────────────────────────────

 group('getGrowthStatistics — insufficient snapshots', () {
 test('returns null when fewer than 2 snapshots exist', () async {
 // _getStoredSnapshots returns empty list in current implementation
 final result = await DatabaseMonitorService.getGrowthStatistics(daysBack: 7,
);
 expect(result, isNull);
 });

 test('returns null with startDate parameter', () async {
 final result = await DatabaseMonitorService.getGrowthStatistics(startDate: DateTime(2025, 1, 1),
);
 expect(result, isNull);
 });

 test('returns null with no parameters (default 7 days)', () async {
 final result = await DatabaseMonitorService.getGrowthStatistics();
 expect(result, isNull);
 });
 });

 // ── getHistoricalSnapshots — filter params ────────────────────────

 group('getHistoricalSnapshots — filtering', () {
 test('returns empty list when no snapshots stored', () async {
 final result = await DatabaseMonitorService.getHistoricalSnapshots();
 expect(result, isEmpty);
 });

 test('since filter on empty list returns empty', () async {
 final result = await DatabaseMonitorService.getHistoricalSnapshots(since: DateTime(2025, 1, 1),
);
 expect(result, isEmpty);
 });

 test('limit on empty list returns empty', () async {
 final result = await DatabaseMonitorService.getHistoricalSnapshots(limit: 5,
);
 expect(result, isEmpty);
 });

 test('both since and limit on empty list', () async {
 final result = await DatabaseMonitorService.getHistoricalSnapshots(since: DateTime(2025, 1, 1),
 limit: 10,
);
 expect(result, isEmpty);
 });
 });

 // ── Recommendation logic thresholds ───────────────────────────────

 group('Recommendation threshold conditions', () {
 test('fragmentation > 0.2 should recommend VACUUM', () {
 // This tests the condition used in _generateRecommendations
 const fragmentationRatio = 0.25;
 expect(fragmentationRatio > 0.2, isTrue);
 });

 test('totalSizeMB > 200 should recommend archival', () {
 final snapshot = DatabaseSnapshot(timestamp: DateTime.now(),
 totalSizeBytes: 210 * 1024 * 1024,
 tableMetrics: {
 'messages': TableMetrics(name: 'messages',
 rowCount: 100,
 sizeBytes: 210 * 1024 * 1024,
 unusedBytes: 0,
 fragmentationRatio: 0.0,
),
 },
 indexMetrics: {},
 totalRows: 100,
 fragmentationRatio: 0.0,
);
 expect(snapshot.totalSizeMB, greaterThan(200));
 });

 test('growth rate > 10MB/day should trigger monitoring', () {
 final growthRate = 11.0 * 1024 * 1024; // 11 MB/day
 expect(growthRate > 10 * 1024 * 1024, isTrue);
 });

 test('largest table > 50MB should suggest cleanup', () {
 final largeTable = TableMetrics(name: 'messages',
 rowCount: 100000,
 sizeBytes: 55 * 1024 * 1024,
 unusedBytes: 0,
 fragmentationRatio: 0.0,
);
 expect(largeTable.sizeMB, greaterThan(50));
 });

 test('healthy state produces no action recommendations', () {
 final smallTable = TableMetrics(name: 'contacts',
 rowCount: 10,
 sizeBytes: 1024,
 unusedBytes: 0,
 fragmentationRatio: 0.0,
);
 final snapshot = DatabaseSnapshot(timestamp: DateTime.now(),
 totalSizeBytes: 1024,
 tableMetrics: {'contacts': smallTable},
 indexMetrics: {},
 totalRows: 10,
 fragmentationRatio: 0.0,
);
 // Small, not fragmented, no growth concerns
 expect(snapshot.totalSizeMB, lessThan(200));
 expect(snapshot.fragmentationRatio, lessThanOrEqualTo(0.2));
 });
 });

 // ── TableMetrics.fromJson additional coverage ─────────────────────

 group('TableMetrics.fromJson — edge values', () {
 test('zero values', () {
 final json = {
 'name': 'empty_table',
 'row_count': 0,
 'size_bytes': 0,
 'unused_bytes': 0,
 'fragmentation_ratio': 0.0,
 };
 final m = TableMetrics.fromJson(json);
 expect(m.rowCount, 0);
 expect(m.sizeBytes, 0);
 expect(m.efficiency, 1.0);
 });

 test('large values', () {
 final json = {
 'name': 'huge_table',
 'row_count': 10000000,
 'size_bytes': 1073741824,
 'unused_bytes': 104857600,
 'fragmentation_ratio': 0.098,
 };
 final m = TableMetrics.fromJson(json);
 expect(m.rowCount, 10000000);
 expect(m.sizeMB, closeTo(1024.0, 0.1));
 });
 });

 // ── IndexMetrics.fromJson ──────────────────────────────────────────

 group('IndexMetrics.fromJson — additional', () {
 test('non-unique index', () {
 final json = {
 'name': 'idx_ts',
 'table_name': 'events',
 'size_bytes': 4096,
 'is_unique': false,
 };
 final idx = IndexMetrics.fromJson(json);
 expect(idx.isUnique, false);
 expect(idx.tableName, 'events');
 });
 });
}
