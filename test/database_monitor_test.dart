// Test database monitoring service

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_monitor_service.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
    await DatabaseMonitorService.clearHistory();
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  group('DatabaseMonitorService Tests', () {
    test('Captures database snapshot successfully', () async {
      // Initialize database
      await DatabaseHelper.database;

      final snapshot = await DatabaseMonitorService.captureSnapshot();

      expect(snapshot, isNotNull);
      expect(snapshot.timestamp, isNotNull);
      expect(snapshot.totalSizeBytes, greaterThan(0));
      expect(snapshot.tableMetrics, isNotEmpty);
      expect(snapshot.totalRows, greaterThanOrEqualTo(0));
      expect(snapshot.fragmentationRatio, greaterThanOrEqualTo(0));
    });

    test('Snapshot includes all core tables', () async {
      await DatabaseHelper.database;

      final snapshot = await DatabaseMonitorService.captureSnapshot();

      final expectedTables = [
        'contacts',
        'chats',
        'messages',
        'archived_chats',
        'archived_messages',
      ];

      for (final table in expectedTables) {
        expect(
          snapshot.tableMetrics.keys,
          contains(table),
          reason: 'Should track $table',
        );
      }
    });

    test('Table metrics are accurate', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final testKey = 'test_monitor_key_${now}_${DateTime.now().microsecond}';

      // Insert test data
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

      final snapshot = await DatabaseMonitorService.captureSnapshot();
      final contactsMetrics = snapshot.tableMetrics['contacts'];

      expect(contactsMetrics, isNotNull);
      expect(contactsMetrics!.rowCount, greaterThanOrEqualTo(1));
      expect(contactsMetrics.sizeBytes, greaterThan(0));
      expect(contactsMetrics.efficiency, greaterThan(0));

      // Cleanup
      await db.delete('contacts', where: 'public_key = ?', whereArgs: [testKey]);
    });

    test('Snapshot JSON serialization works', () async {
      await DatabaseHelper.database;

      final snapshot = await DatabaseMonitorService.captureSnapshot();
      final json = snapshot.toJson();

      expect(json['timestamp'], isNotNull);
      expect(json['total_size_bytes'], isA<int>());
      expect(json['total_size_mb'], isA<String>());
      expect(json['total_rows'], isA<int>());
      expect(json['fragmentation_ratio'], isA<String>());
      expect(json['table_metrics'], isA<Map>());
      expect(json['index_metrics'], isA<Map>());
    });

    test('Alert generation works for various conditions', () async {
      await DatabaseHelper.database;

      final alerts = await DatabaseMonitorService.analyzeAndGenerateAlerts();

      expect(alerts, isNotNull);
      expect(alerts, isA<List<MonitoringAlert>>());

      // Should have at least some informational alerts
      for (final alert in alerts) {
        expect(alert.severity, isNotNull);
        expect(alert.title, isNotEmpty);
        expect(alert.description, isNotEmpty);
        expect(alert.timestamp, isNotNull);
      }
    });

    test('Dashboard data includes all sections', () async {
      await DatabaseHelper.database;

      final dashboard = await DatabaseMonitorService.getDashboardData();

      expect(dashboard['current_snapshot'], isNotNull);
      expect(dashboard['alerts'], isA<List>());
      expect(dashboard['recommendations'], isA<List>());
    });

    test('Table metrics calculate efficiency correctly', () {
      final metrics = TableMetrics(
        name: 'test_table',
        rowCount: 100,
        sizeBytes: 10000,
        unusedBytes: 2000,
        fragmentationRatio: 0.2,
      );

      expect(metrics.efficiency, closeTo(0.8, 0.01));
      expect(metrics.sizeMB, closeTo(0.0095, 0.001));
    });

    test('Alert severity levels are respected', () {
      final criticalAlert = MonitoringAlert(
        severity: AlertSeverity.critical,
        title: 'Critical Issue',
        description: 'This is critical',
        timestamp: DateTime.now(),
      );

      final warningAlert = MonitoringAlert(
        severity: AlertSeverity.warning,
        title: 'Warning',
        description: 'This is a warning',
        timestamp: DateTime.now(),
      );

      final infoAlert = MonitoringAlert(
        severity: AlertSeverity.info,
        title: 'Info',
        description: 'This is info',
        timestamp: DateTime.now(),
      );

      expect(criticalAlert.severity, equals(AlertSeverity.critical));
      expect(warningAlert.severity, equals(AlertSeverity.warning));
      expect(infoAlert.severity, equals(AlertSeverity.info));
    });
  });
}
