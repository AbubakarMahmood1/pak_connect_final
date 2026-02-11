import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/services/performance_metrics.dart';

/// Unit tests for PerformanceMonitor
///
/// Tests metrics recording, aggregation, jank detection, and recommendations.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerformanceMonitor', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      SharedPreferences.setMockInitialValues({});
      await PerformanceMonitor.reset();
    });

    tearDown(() async {
      await PerformanceMonitor.reset();
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('empty metrics returns default values', () async {
      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.totalEncryptions, equals(0));
      expect(metrics.totalDecryptions, equals(0));
      expect(metrics.avgEncryptMs, equals(0));
      expect(metrics.jankPercentage, equals(0));
      expect(metrics.shouldUseIsolate, isFalse);
    });

    test('recordEncryption increments count', () async {
      await PerformanceMonitor.recordEncryption(
        durationMs: 5,
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();
      expect(metrics.totalEncryptions, equals(1));
    });

    test('recordDecryption increments count', () async {
      await PerformanceMonitor.recordDecryption(
        durationMs: 5,
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();
      expect(metrics.totalDecryptions, equals(1));
    });

    test('metrics aggregate correctly', () async {
      // Record 3 encryptions: 2ms, 10ms, 20ms
      await PerformanceMonitor.recordEncryption(
        durationMs: 2,
        messageSize: 500,
      );
      await PerformanceMonitor.recordEncryption(
        durationMs: 10,
        messageSize: 1000,
      );
      await PerformanceMonitor.recordEncryption(
        durationMs: 20,
        messageSize: 2000,
      );

      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.totalEncryptions, equals(3));
      expect(
        metrics.avgEncryptMs,
        closeTo(10.67, 0.1),
        reason: 'Average should be (2+10+20)/3 = 10.67',
      );
      expect(metrics.minEncryptMs, equals(2));
      expect(metrics.maxEncryptMs, equals(20));
      expect(
        metrics.avgMessageSize,
        closeTo(1166.67, 0.1),
        reason: 'Average size should be (500+1000+2000)/3',
      );
    });

    test('jank detection at 16ms threshold', () async {
      // Record 2 fast operations and 1 janky operation
      await PerformanceMonitor.recordEncryption(
        durationMs: 5,
        messageSize: 1000,
      );
      await PerformanceMonitor.recordEncryption(
        durationMs: 10,
        messageSize: 1000,
      );
      await PerformanceMonitor.recordEncryption(
        durationMs: 20, // >16ms = jank
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.jankyEncryptions, equals(1));
      expect(
        metrics.jankPercentage,
        closeTo(33.33, 0.1),
        reason: '1 janky out of 3 operations = 33.33%',
      );
    });

    test('decryption jank is also tracked', () async {
      // Record 1 fast encryption and 1 janky decryption
      await PerformanceMonitor.recordEncryption(
        durationMs: 5,
        messageSize: 1000,
      );
      await PerformanceMonitor.recordDecryption(
        durationMs: 20, // >16ms = jank
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.totalEncryptions, equals(1));
      expect(metrics.totalDecryptions, equals(1));
      expect(
        metrics.jankyEncryptions,
        equals(1),
        reason: 'Jank counter includes both encrypt and decrypt',
      );
      expect(
        metrics.jankPercentage,
        closeTo(50.0, 0.1),
        reason: '1 janky out of 2 total operations = 50%',
      );
    });

    test('recommendation: no isolate for <5% jank', () async {
      // Record 100 fast operations (0% jank)
      for (int i = 0; i < 100; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 5,
          messageSize: 1000,
        );
      }

      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.jankPercentage, equals(0));
      expect(
        metrics.shouldUseIsolate,
        isFalse,
        reason: '0% jank should not recommend isolate',
      );
    });

    test('recommendation: use isolate for >5% jank', () async {
      // Record 95 fast + 5 janky = 5% jank (should NOT trigger)
      for (int i = 0; i < 95; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 5,
          messageSize: 1000,
        );
      }
      for (int i = 0; i < 5; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 20,
          messageSize: 1000,
        );
      }

      var metrics = await PerformanceMonitor.getMetrics();
      expect(metrics.jankPercentage, equals(5.0));
      expect(
        metrics.shouldUseIsolate,
        isFalse,
        reason: 'Exactly 5% jank should NOT trigger isolate',
      );

      // Add 1 more janky operation (5.94% jank)
      await PerformanceMonitor.recordEncryption(
        durationMs: 20,
        messageSize: 1000,
      );

      metrics = await PerformanceMonitor.getMetrics();
      expect(metrics.jankPercentage, greaterThan(5.0));
      expect(
        metrics.shouldUseIsolate,
        isTrue,
        reason: '>5% jank should recommend isolate',
      );
    });

    test('reset clears all metrics', () async {
      // Record some metrics
      await PerformanceMonitor.recordEncryption(
        durationMs: 10,
        messageSize: 1000,
      );
      await PerformanceMonitor.recordDecryption(
        durationMs: 15,
        messageSize: 1000,
      );

      var metrics = await PerformanceMonitor.getMetrics();
      expect(metrics.totalEncryptions, equals(1));
      expect(metrics.totalDecryptions, equals(1));

      // Reset
      await PerformanceMonitor.reset();

      metrics = await PerformanceMonitor.getMetrics();
      expect(metrics.totalEncryptions, equals(0));
      expect(metrics.totalDecryptions, equals(0));
      expect(metrics.jankyEncryptions, equals(0));
    });

    test('samples limit at 1000 entries', () async {
      // Record 1500 operations (should keep last 1000)
      for (int i = 0; i < 1500; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 5,
          messageSize: 1000,
        );
      }

      final metrics = await PerformanceMonitor.getMetrics();

      // Total count should be 1500
      expect(metrics.totalEncryptions, equals(1500));

      // But samples should be limited (we can't directly check, but metrics
      // should still be calculated correctly)
      expect(metrics.avgEncryptMs, closeTo(5.0, 0.1));
    });

    test('export metrics produces valid text', () async {
      await PerformanceMonitor.recordEncryption(
        durationMs: 10,
        messageSize: 1000,
      );
      await PerformanceMonitor.recordDecryption(
        durationMs: 15,
        messageSize: 2000,
      );

      final export = await PerformanceMonitor.exportMetrics();

      expect(export, contains('PakConnect Performance Metrics'));
      expect(export, contains('Total Encryptions: 1'));
      expect(export, contains('Total Decryptions: 1'));
      expect(export, contains('Average: 10.00ms'));
      expect(export, contains('Average: 15.00ms'));
    });

    test('export includes recommendation', () async {
      // High jank case
      for (int i = 0; i < 10; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 25,
          messageSize: 1000,
        );
      }

      final export = await PerformanceMonitor.exportMetrics();

      expect(
        export,
        contains('USE ISOLATE'),
        reason: 'Export should include isolate recommendation for high jank',
      );
      expect(export, contains('FIX-013'));

      // Low jank case
      await PerformanceMonitor.reset();
      for (int i = 0; i < 100; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 5,
          messageSize: 1000,
        );
      }

      final exportLowJank = await PerformanceMonitor.exportMetrics();

      expect(
        exportLowJank,
        contains('NO ISOLATE NEEDED'),
        reason: 'Export should indicate no isolate needed for low jank',
      );
    });

    test('metrics handle edge case: no encryption times', () async {
      // Record decryption only (no encryption)
      await PerformanceMonitor.recordDecryption(
        durationMs: 10,
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.totalEncryptions, equals(0));
      expect(metrics.totalDecryptions, equals(1));
      expect(metrics.avgEncryptMs, equals(0));
      expect(metrics.minEncryptMs, equals(0));
      expect(metrics.maxEncryptMs, equals(0));
      expect(metrics.avgDecryptMs, closeTo(10.0, 0.1));
    });

    test('metrics handle edge case: no decryption times', () async {
      // Record encryption only (no decryption)
      await PerformanceMonitor.recordEncryption(
        durationMs: 10,
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();

      expect(metrics.totalEncryptions, equals(1));
      expect(metrics.totalDecryptions, equals(0));
      expect(metrics.avgDecryptMs, equals(0));
      expect(metrics.minDecryptMs, equals(0));
      expect(metrics.maxDecryptMs, equals(0));
      expect(metrics.avgEncryptMs, closeTo(10.0, 0.1));
    });

    test('toString provides useful debug output', () async {
      await PerformanceMonitor.recordEncryption(
        durationMs: 10,
        messageSize: 1000,
      );

      final metrics = await PerformanceMonitor.getMetrics();
      final str = metrics.toString();

      expect(str, contains('encryptions: 1'));
      expect(str, contains('avgEncrypt: 10.00ms'));
      expect(str, contains('useIsolate: false'));
    });
  });
}
