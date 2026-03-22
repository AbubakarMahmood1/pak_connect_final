import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/app_core.dart';
import 'package:pak_connect/core/di/service_locator.dart'
    show configureDataLayerRegistrar;
import 'package:pak_connect/data/di/data_layer_service_registrar.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/performance_monitor.dart';

void main() {
  setUp(() {
    configureDataLayerRegistrar(registerDataLayerServices);
  });

  tearDown(() {
    AppCore.initializationOverride = null;
    AppCore.resetForTesting();
  });

  group('AppCore phase 6.4 guardrails', () {
    test('status stream reaches ready and initialize is idempotent', () async {
      var overrideCalls = 0;
      AppCore.initializationOverride = () async {
        overrideCalls++;
      };

      final appCore = AppCore.instance;
      final statuses = <AppStatus>[];
      final sub = appCore.statusStream.listen(statuses.add);
      addTearDown(sub.cancel);

      await appCore.initialize();
      await appCore.initialize();
      await Future<void>.delayed(Duration.zero);

      expect(appCore.isInitialized, isTrue);
      expect(overrideCalls, 1);
      expect(statuses.first, AppStatus.initializing);
      expect(statuses, contains(AppStatus.ready));
    });

    test('dispose after override initialization is safe', () async {
      AppCore.initializationOverride = () async {};
      final appCore = AppCore.instance;
      await appCore.initialize();

      expect(() => appCore.dispose(), returnsNormally);
    });

    test('sendSecureMessage throws before initialization', () async {
      final appCore = AppCore.instance;

      await expectLater(
        appCore.sendSecureMessage(
          chatId: 'chat-a',
          content: 'hello',
          recipientPublicKey: 'peer-a',
        ),
        throwsA(isA<AppCoreException>()),
      );
    });

    test('getStatistics throws before initialization', () async {
      final appCore = AppCore.instance;

      await expectLater(
        appCore.getStatistics(),
        throwsA(isA<AppCoreException>()),
      );
    });

    test('AppStatistics helper properties compute health and optimization', () {
      final stats = AppStatistics(
        powerManagement: PowerManagementStats(
          currentScanInterval: 60000,
          currentHealthCheckInterval: 30000,
          consecutiveSuccessfulChecks: 10,
          consecutiveFailedChecks: 0,
          connectionQualityScore: 0.95,
          connectionStabilityScore: 0.9,
          timeSinceLastSuccess: const Duration(seconds: 5),
          qualityMeasurementsCount: 20,
          isBurstMode: false,
          powerMode: PowerMode.balanced,
          isDutyCycleScanning: false,
          batteryLevel: 80,
          isCharging: false,
          isAppInBackground: false,
        ),
        messageQueue: const QueueStatistics(
          totalQueued: 20,
          totalDelivered: 18,
          totalFailed: 2,
          pendingMessages: 1,
          sendingMessages: 0,
          retryingMessages: 0,
          failedMessages: 0,
          isOnline: true,
          averageDeliveryTime: Duration(milliseconds: 500),
        ),
        performance: const PerformanceMetrics(
          monitoringDuration: Duration(minutes: 5),
          totalOperations: 200,
          successfulOperations: 190,
          failedOperations: 10,
          memoryUsage: 12.5,
          cpuUsage: 18.0,
          averageOperationTime: Duration(milliseconds: 60),
          operationSuccessRate: 0.95,
          overallScore: 0.92,
          topSlowOperations: <OperationMetrics>[],
          memoryHistory: <MemorySnapshot>[],
          cpuHistory: <CpuSnapshot>[],
        ),
        replayProtection: const ReplayProtectionStats(
          processedMessagesCount: 25,
          blockedDuplicateCount: 2,
          averageProcessingTime: Duration(milliseconds: 2),
        ),
        uptime: const Duration(hours: 3),
      );

      expect(stats.overallHealthScore, greaterThan(0.8));
      expect(stats.needsOptimization, isFalse);
      expect(stats.toString(), contains('AppStats(health:'));
      expect(
        stats.replayProtection.toString(),
        contains('ReplayStats(processed: 25'),
      );
    });
  });
}
