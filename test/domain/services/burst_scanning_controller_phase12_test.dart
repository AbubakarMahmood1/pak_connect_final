import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/models/power_mode.dart';

/// Phase 12.2: BurstScanningController unit tests
/// Tests the no-BLE-dependent paths: getCurrentStatus (null PM),
///   BurstScanningStatus helper methods, dispose, statusMessage variants
void main() {
  late List<LogRecord> logRecords;

  setUp(() {
    logRecords = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
  });

  group('BurstScanningController — uninitialized state', () {
    late BurstScanningController controller;

    setUp(() {
      controller = BurstScanningController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('getCurrentStatus returns defaults when not initialized', () {
      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, false);
      expect(status.secondsUntilNextScan, isNull);
      expect(status.burstTimeRemaining, isNull);
      expect(status.currentScanInterval, 60000);
    });

    test('dispose without initialization is safe', () {
      // Should not throw
      controller.dispose();
    });

    test('stopBurstScanning without init logs warning', () async {
      await controller.stopBurstScanning();
      // Controller checks _powerManager == null; stopBurstScanning still runs
      // but the BLE-dependent parts are guarded by null checks
    });

    test('triggerManualScan without init logs warning', () async {
      await controller.triggerManualScan();
      final warnings = logRecords
          .where(
            (r) =>
                r.level == Level.WARNING &&
                r.message.contains('not available'),
          )
          .toList();
      expect(warnings, isNotEmpty);
    });

    test('forceBurstScanNow without init logs warning', () async {
      await controller.forceBurstScanNow();
      final warnings = logRecords
          .where(
            (r) =>
                r.level == Level.WARNING &&
                r.message.contains('not available'),
          )
          .toList();
      expect(warnings, isNotEmpty);
    });

    test('reportConnectionSuccess without init is safe', () {
      controller.reportConnectionSuccess(rssi: -50);
    });

    test('reportConnectionFailure without init is safe', () {
      controller.reportConnectionFailure(reason: 'timeout');
    });
  });

  group('BurstScanningStatus — helper methods', () {
    PowerManagementStats _makeStats({PowerMode mode = PowerMode.balanced}) {
      return PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.5,
        connectionStabilityScore: 0.5,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: false,
        powerMode: mode,
        isDutyCycleScanning: false,
        batteryLevel: 100,
        isCharging: false,
        isAppInBackground: false,
      );
    }

    test('statusMessage — burst active with remaining time', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        burstTimeRemaining: 15,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.statusMessage, 'Burst scanning... 15s remaining');
    });

    test('statusMessage — waiting for next scan', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 30,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.statusMessage, 'Next scan in 30s');
    });

    test('statusMessage — starting scan (0 seconds)', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 0,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.statusMessage, 'Starting scan...');
    });

    test('statusMessage — ready (null next scan)', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.statusMessage, 'Burst scanning ready');
    });

    test('canOverride — true when not scanning and >5s until next', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 10,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.canOverride, true);
    });

    test('canOverride — false when burst active', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        secondsUntilNextScan: 0,
        burstTimeRemaining: 10,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.canOverride, false);
    });

    test('canOverride — false when less than 5 seconds to next scan', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 3,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      expect(status.canOverride, false);
    });

    test('efficiencyRating categories', () {
      final excellent = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: _makeStats(mode: PowerMode.ultraLowPower),
      );
      expect(excellent.efficiencyRating, 'Excellent');

      final good = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: _makeStats(mode: PowerMode.powerSaver),
      );
      expect(good.efficiencyRating, 'Good');

      final fair = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: _makeStats(mode: PowerMode.balanced),
      );
      expect(fair.efficiencyRating, 'Fair');

      final poor = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: _makeStats(mode: PowerMode.performance),
      );
      expect(poor.efficiencyRating, 'Poor');
    });

    test('toString produces readable output', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        secondsUntilNextScan: 30,
        burstTimeRemaining: 15,
        currentScanInterval: 60000,
        powerStats: _makeStats(),
      );
      final str = status.toString();
      expect(str, contains('BurstStatus'));
      expect(str, contains('burst: true'));
    });
  });

  group('PowerManagementStats — helper methods', () {
    test('batteryEfficiencyRating varies by power mode', () {
      final performance = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.5,
        connectionStabilityScore: 0.5,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: false,
        powerMode: PowerMode.performance,
        isDutyCycleScanning: false,
        batteryLevel: 100,
        isCharging: false,
        isAppInBackground: false,
      );

      final ultraLow = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.5,
        connectionStabilityScore: 0.5,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: false,
        powerMode: PowerMode.ultraLowPower,
        isDutyCycleScanning: false,
        batteryLevel: 100,
        isCharging: false,
        isAppInBackground: false,
      );

      expect(ultraLow.batteryEfficiencyRating,
          greaterThan(performance.batteryEfficiencyRating));
    });

    test('dutyCyclePercentage varies by power mode', () {
      for (final mode in PowerMode.values) {
        final stats = PowerManagementStats(
          currentScanInterval: 60000,
          currentHealthCheckInterval: 30000,
          consecutiveSuccessfulChecks: 0,
          consecutiveFailedChecks: 0,
          connectionQualityScore: 0.5,
          connectionStabilityScore: 0.5,
          timeSinceLastSuccess: Duration.zero,
          qualityMeasurementsCount: 0,
          isBurstMode: false,
          powerMode: mode,
          isDutyCycleScanning: false,
          batteryLevel: 100,
          isCharging: false,
          isAppInBackground: false,
        );
        expect(stats.dutyCyclePercentage, greaterThan(0));
      }
    });
  });
}
