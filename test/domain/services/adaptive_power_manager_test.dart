import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AdaptivePowerManager', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test(
      'loads persisted intervals with clamp and resets back to defaults',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'power_mgmt_scan_interval': 999999,
          'power_mgmt_health_interval': 1,
        });

        final manager = AdaptivePowerManager();
        await manager.initialize();

        final restored = manager.getCurrentStats();
        expect(restored.currentScanInterval, 120000);
        expect(restored.currentHealthCheckInterval, 30000);

        await manager.resetToDefaults();
        final reset = manager.getCurrentStats();
        expect(reset.currentScanInterval, 60000);
        expect(reset.currentHealthCheckInterval, 30000);
      },
    );

    test(
      'starts burst mode, supports immediate trigger guard, and shortens active burst',
      () async {
        var startCount = 0;
        var stopCount = 0;

        final manager = AdaptivePowerManager();
        await manager.initialize(
          onStartScan: () {
            startCount++;
          },
          onStopScan: () {
            stopCount++;
          },
        );

        await manager.startAdaptiveScanning();
        expect(startCount, 1);
        expect(manager.getCurrentStats().isBurstMode, isTrue);

        await manager.triggerImmediateScan(); // ignored while burst is active
        expect(startCount, 1);

        manager.shortenActiveBurst(const Duration(milliseconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(stopCount, greaterThanOrEqualTo(1));
        expect(manager.getCurrentStats().isBurstMode, isFalse);
      },
    );

    test(
      'manual burst scheduling fires callbacks and sets next scan time',
      () async {
        var startCount = 0;
        final manager = AdaptivePowerManager();
        await manager.initialize(
          onStartScan: () {
            startCount++;
          },
        );

        await manager.scheduleManualBurstAfter(const Duration(milliseconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(startCount, 1);
        expect(manager.nextScheduledScanTime, isNotNull);
        expect(manager.nextScheduledScanTime!.isAfter(DateTime.now()), isTrue);
      },
    );

    test(
      'pauses and resumes scanning when bluetooth availability changes',
      () async {
        var startCount = 0;
        var stopCount = 0;

        final manager = AdaptivePowerManager();
        await manager.initialize(
          onStartScan: () {
            startCount++;
          },
          onStopScan: () {
            stopCount++;
          },
        );

        await manager.startAdaptiveScanning();
        expect(startCount, 1);

        await manager.updateBluetoothAvailability(false);
        expect(stopCount, greaterThanOrEqualTo(1));

        await manager.updateBluetoothAvailability(true);
        expect(startCount, greaterThanOrEqualTo(2));
      },
    );

    test(
      'reports connection success and failure with adaptive statistics updates',
      () async {
        final manager = AdaptivePowerManager();
        await manager.initialize();

        manager.overrideScanInterval(1); // clamp to min
        expect(manager.getCurrentStats().currentScanInterval, 20000);

        manager.overrideScanInterval(999999); // clamp to max
        expect(manager.getCurrentStats().currentScanInterval, 120000);

        manager.reportConnectionSuccess(
          rssi: -62,
          connectionTime: 120,
          dataTransferSuccess: true,
        );
        manager.reportConnectionFailure(
          reason: 'timeout',
          rssi: -91,
          attemptTime: 3200,
        );

        final stats = manager.getCurrentStats();
        expect(stats.qualityMeasurementsCount, 2);
        expect(stats.consecutiveSuccessfulChecks, 0);
        expect(stats.consecutiveFailedChecks, 1);
        expect(stats.connectionQualityScore, inInclusiveRange(0.0, 1.0));
        expect(stats.connectionStabilityScore, inInclusiveRange(0.0, 1.0));
      },
    );

    test('power mode and stat model expose expected computed values', () {
      final performance = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 3,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.8,
        connectionStabilityScore: 0.9,
        timeSinceLastSuccess: const Duration(seconds: 2),
        qualityMeasurementsCount: 5,
        isBurstMode: false,
        powerMode: PowerMode.performance,
        isDutyCycleScanning: true,
        batteryLevel: 90,
        isCharging: false,
        isAppInBackground: false,
      );

      final ultraLow = PowerManagementStats(
        currentScanInterval: 120000,
        currentHealthCheckInterval: 60000,
        consecutiveSuccessfulChecks: 1,
        consecutiveFailedChecks: 2,
        connectionQualityScore: 0.7,
        connectionStabilityScore: 0.6,
        timeSinceLastSuccess: const Duration(minutes: 1),
        qualityMeasurementsCount: 2,
        isBurstMode: false,
        powerMode: PowerMode.ultraLowPower,
        isDutyCycleScanning: true,
        batteryLevel: 8,
        isCharging: false,
        isAppInBackground: true,
      );

      expect(performance.dutyCyclePercentage, 100.0);
      expect(ultraLow.dutyCyclePercentage, 9.0);
      expect(
        ultraLow.batteryEfficiencyRating,
        greaterThan(performance.batteryEfficiencyRating),
      );
      expect(ultraLow.toString(), contains('ultraLowPower'));
      expect(ultraLow.toString(), contains('battery: 8%'));
    });

    test('dispose is safe after start and stop cycles', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      await manager.startAdaptiveScanning();
      await manager.stopScanning();

      // Should not throw and should be safe to call after stop.
      manager.dispose();
    });
  });
}
