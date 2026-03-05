import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/performance_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PerformanceMonitor', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test(
      'restores persisted metrics and computes operation statistics',
      () async {
        final now = DateTime.now().toUtc();
        final payload = _buildStoredMetrics(now: now);
        SharedPreferences.setMockInitialValues(<String, Object>{
          'performance_metrics': jsonEncode(payload),
        });

        final monitor = PerformanceMonitor();
        await monitor.initialize();

        final metrics = monitor.getMetrics();
        expect(metrics.totalOperations, 4);
        expect(metrics.successfulOperations, 3);
        expect(metrics.failedOperations, 1);
        expect(metrics.memoryHistory, isA<List<MemorySnapshot>>());
        expect(metrics.cpuHistory, isA<List<CpuSnapshot>>());

        final syncMetrics = monitor.getOperationMetrics('sync');
        expect(syncMetrics, isNotNull);
        expect(syncMetrics!.totalCount, 3);
        expect(syncMetrics.successCount, 2);
        expect(syncMetrics.failureCount, 1);
        expect(syncMetrics.minDuration.inMilliseconds, 90);
        expect(syncMetrics.maxDuration.inMilliseconds, 1200);
        expect(syncMetrics.successRate, closeTo(2 / 3, 0.0001));

        final report = monitor.exportReport();
        expect(report['operations'], isA<Map<String, dynamic>>());
        expect(report['slow_operations'], isA<List<dynamic>>());
      },
    );

    test(
      'tracks operations, trims history, and reports aggregate counters',
      () async {
        final monitor = PerformanceMonitor();
        await monitor.initialize();

        for (var i = 0; i < 105; i++) {
          monitor.startOperation('relay');
          monitor.endOperation('relay', success: i.isEven);
        }

        final opMetrics = monitor.getOperationMetrics('relay');
        expect(opMetrics, isNotNull);
        expect(opMetrics!.totalCount, 100); // trimmed to latest 100 entries
        expect(opMetrics.successCount + opMetrics.failureCount, 100);

        final metrics = monitor.getMetrics();
        expect(metrics.totalOperations, 105);
        expect(metrics.successfulOperations, 53);
        expect(metrics.failedOperations, 52);
        expect(metrics.operationSuccessRate, closeTo(53 / 105, 0.0001));
      },
    );

    test(
      'collects snapshots in event-driven mode and supports idempotent start/stop',
      () async {
        final monitor = PerformanceMonitor();
        await monitor.initialize();

        monitor.startMonitoring(enablePeriodic: false);
        monitor.startMonitoring(enablePeriodic: false); // idempotent start

        final firstMetrics = monitor.getMetrics();
        expect(firstMetrics.memoryHistory, isNotEmpty);
        expect(firstMetrics.cpuHistory, isNotEmpty);

        monitor.collectSnapshot();
        final secondMetrics = monitor.getMetrics();
        expect(
          secondMetrics.memoryHistory.length,
          greaterThanOrEqualTo(firstMetrics.memoryHistory.length),
        );
        expect(
          secondMetrics.cpuHistory.length,
          greaterThanOrEqualTo(firstMetrics.cpuHistory.length),
        );

        monitor.stopMonitoring();
        monitor.stopMonitoring(); // idempotent stop
      },
    );

    test(
      'removes stale persisted operation entries via clearOldData',
      () async {
        final now = DateTime.now().toUtc();
        final payload = <String, dynamic>{
          'total_operations': 2,
          'successful_operations': 1,
          'failed_operations': 1,
          'monitoring_start_time': now
              .subtract(const Duration(hours: 26))
              .toIso8601String(),
          'operations': <String, dynamic>{
            'staleOp': <Map<String, dynamic>>[
              <String, dynamic>{
                'start_time': now
                    .subtract(const Duration(hours: 25))
                    .toIso8601String(),
                'end_time': now
                    .subtract(const Duration(hours: 25, seconds: -1))
                    .toIso8601String(),
                'duration_ms': 1000,
                'success': true,
              },
            ],
            'freshOp': <Map<String, dynamic>>[
              <String, dynamic>{
                'start_time': now
                    .subtract(const Duration(minutes: 10))
                    .toIso8601String(),
                'end_time': now
                    .subtract(const Duration(minutes: 10, seconds: -1))
                    .toIso8601String(),
                'duration_ms': 1000,
                'success': false,
              },
            ],
          },
        };
        SharedPreferences.setMockInitialValues(<String, Object>{
          'performance_metrics': jsonEncode(payload),
        });

        final monitor = PerformanceMonitor();
        await monitor.initialize();

        expect(monitor.getOperationMetrics('staleOp'), isNotNull);
        expect(monitor.getOperationMetrics('freshOp'), isNotNull);

        monitor.clearOldData();

        expect(monitor.getOperationMetrics('staleOp'), isNull);
        expect(monitor.getOperationMetrics('freshOp'), isNotNull);
      },
    );

    test(
      'recovers from malformed stored data and persists new metrics',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'performance_metrics': '{malformed_json',
        });

        final monitor = PerformanceMonitor();
        await monitor.initialize();

        final initial = monitor.getMetrics();
        expect(initial.totalOperations, 0);
        expect(initial.successfulOperations, 0);
        expect(initial.failedOperations, 0);

        monitor.startOperation('send');
        monitor.endOperation('send', success: true);

        await monitor.saveMetricsAsync();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final prefs = await SharedPreferences.getInstance();
        final savedRaw = prefs.getString('performance_metrics');
        expect(savedRaw, isNotNull);

        final saved = jsonDecode(savedRaw!) as Map<String, dynamic>;
        expect(saved['total_operations'], 1);
        expect(saved['successful_operations'], 1);
        expect(
          (saved['operations'] as Map<String, dynamic>).containsKey('send'),
          isTrue,
        );

        monitor.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      },
    );
  });

  group('PerformanceMetrics.performanceGrade', () {
    PerformanceMetrics metricsForScore(double score) {
      return PerformanceMetrics(
        monitoringDuration: const Duration(seconds: 1),
        totalOperations: 1,
        successfulOperations: 1,
        failedOperations: 0,
        memoryUsage: 0.2,
        cpuUsage: 0.2,
        averageOperationTime: const Duration(milliseconds: 50),
        operationSuccessRate: 1.0,
        overallScore: score,
        topSlowOperations: const <OperationMetrics>[],
        memoryHistory: const <MemorySnapshot>[],
        cpuHistory: const <CpuSnapshot>[],
      );
    }

    test('maps score buckets to grade letters', () {
      expect(metricsForScore(0.95).performanceGrade, 'A');
      expect(metricsForScore(0.85).performanceGrade, 'B');
      expect(metricsForScore(0.65).performanceGrade, 'C');
      expect(metricsForScore(0.45).performanceGrade, 'D');
      expect(metricsForScore(0.30).performanceGrade, 'F');
    });
  });
}

Map<String, dynamic> _buildStoredMetrics({required DateTime now}) {
  return <String, dynamic>{
    'save_timestamp': now.toIso8601String(),
    'total_operations': 4,
    'successful_operations': 3,
    'failed_operations': 1,
    'monitoring_start_time': now
        .subtract(const Duration(minutes: 45))
        .toIso8601String(),
    'operations': <String, dynamic>{
      'sync': <Map<String, dynamic>>[
        <String, dynamic>{
          'start_time': now
              .subtract(const Duration(minutes: 5, seconds: 5))
              .toIso8601String(),
          'end_time': now
              .subtract(const Duration(minutes: 5, seconds: 4))
              .toIso8601String(),
          'duration_ms': 1200,
          'success': true,
        },
        <String, dynamic>{
          'start_time': now
              .subtract(const Duration(minutes: 4, seconds: 5))
              .toIso8601String(),
          'end_time': now
              .subtract(const Duration(minutes: 4, seconds: 4))
              .toIso8601String(),
          'duration_ms': 400,
          'success': true,
        },
        <String, dynamic>{
          'start_time': now
              .subtract(const Duration(minutes: 3, seconds: 5))
              .toIso8601String(),
          'end_time': now
              .subtract(const Duration(minutes: 3, seconds: 4))
              .toIso8601String(),
          'duration_ms': 90,
          'success': false,
        },
      ],
      'send': <Map<String, dynamic>>[
        <String, dynamic>{
          'start_time': now
              .subtract(const Duration(minutes: 2, seconds: 3))
              .toIso8601String(),
          'end_time': now
              .subtract(const Duration(minutes: 2, seconds: 2))
              .toIso8601String(),
          'duration_ms': 250,
          'success': true,
        },
      ],
    },
  };
}
