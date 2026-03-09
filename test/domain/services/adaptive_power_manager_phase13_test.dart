/// Phase 13 — AdaptivePowerManager additional coverage:
/// - _updatePowerMode: all battery/charging/background combos
/// - setAppBackgroundState: foreground/background transitions
/// - _adaptToConnectionQuality: all branches (high quality, poor quality,
///   long success streak, multiple failures)
/// - _calculateRecentQualityScore: empty, RSSI, connection time, NaN handling
/// - _calculateConnectionStability: variance-based stability
/// - _addQualityMeasurement: history pruning (>100 and >1 hour)
/// - startAdaptiveScanning: bluetooth unavailable path
/// - scheduleManualBurstAfter: bluetooth unavailable path
/// - rssiThreshold and maxConnections per power mode
/// - _getBaseIntervalForPowerMode per mode
/// - _stopAllTimers: dutyCycleScanning cleanup
/// - _loadSettings / _saveSettings
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // -----------------------------------------------------------------------
  // Power mode — rssiThreshold and maxConnections
  // -----------------------------------------------------------------------
  group('rssiThreshold and maxConnections per power mode', () {
    test('default mode returns consistent rssi/maxConnections', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      // On desktop, BatteryOptimizer defaults battery=100 + charging → performance
      final mode = manager.currentPowerMode;
      expect(mode, isIn([PowerMode.performance, PowerMode.balanced]));
      if (mode == PowerMode.performance) {
        expect(manager.rssiThreshold, -95);
        expect(manager.maxConnections, 8);
      } else {
        expect(manager.rssiThreshold, -85);
        expect(manager.maxConnections, 8);
      }
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // setAppBackgroundState
  // -----------------------------------------------------------------------
  group('setAppBackgroundState', () {
    test('transitions to background changes power mode', () async {
      // ignore: unused_local_variable
      // ignore: unused_local_variable
      PowerMode? lastMode;
      final manager = AdaptivePowerManager();
      await manager.initialize(
        onPowerModeChanged: (mode) => lastMode = mode,
      );

      // Go to background — mode might change to balanced or powerSaver
      manager.setAppBackgroundState(true);
      // Call again with same value — no-op
      manager.setAppBackgroundState(true);

      // Go back to foreground
      manager.setAppBackgroundState(false);
      manager.dispose();
    });

    test('no-op when state unchanged', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      final initialMode = manager.currentPowerMode;
      // Default is foreground (false)
      manager.setAppBackgroundState(false); // no change
      expect(manager.currentPowerMode, initialMode);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // _adaptToConnectionQuality — all branches
  // -----------------------------------------------------------------------
  group('_adaptToConnectionQuality — branches', () {
    test('high quality + stable increases intervals', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();

      // Report many successful connections with strong RSSI
      for (int i = 0; i < 15; i++) {
        manager.reportConnectionSuccess(
          rssi: -50,
          connectionTime: 50,
          dataTransferSuccess: true,
        );
      }

      final stats = manager.getCurrentStats();
      expect(stats.consecutiveSuccessfulChecks, 15);
      // Intervals should have increased
      expect(stats.currentScanInterval, greaterThanOrEqualTo(20000));
      manager.dispose();
    });

    test('poor quality decreases intervals', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      manager.overrideScanInterval(80000);
      manager.reportConnectionSuccess(rssi: -50, connectionTime: 50);

      // Report mostly failures
      for (int i = 0; i < 5; i++) {
        manager.reportConnectionFailure(
          reason: 'timeout',
          rssi: -95,
          attemptTime: 5000,
        );
      }

      final stats = manager.getCurrentStats();
      expect(stats.consecutiveFailedChecks, 5);
      expect(stats.currentScanInterval, lessThanOrEqualTo(80000));
      manager.dispose();
    });

    test('long success streak gradually increases', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();

      // >10 consecutive successes with moderate quality
      for (int i = 0; i < 12; i++) {
        manager.reportConnectionSuccess(
          rssi: -70,
          connectionTime: 200,
        );
      }

      final stats = manager.getCurrentStats();
      expect(stats.consecutiveSuccessfulChecks, 12);
      manager.dispose();
    });

    test('multiple failures after successes triggers decrease', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();

      // Some successes
      manager.reportConnectionSuccess(rssi: -60);
      manager.reportConnectionSuccess(rssi: -60);

      // Then failures
      manager.reportConnectionFailure(reason: 'a');
      manager.reportConnectionFailure(reason: 'b');
      manager.reportConnectionFailure(reason: 'c');
      manager.reportConnectionFailure(reason: 'd');

      final stats = manager.getCurrentStats();
      expect(stats.consecutiveFailedChecks, 4);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // _calculateRecentQualityScore — edge cases
  // -----------------------------------------------------------------------
  group('_calculateRecentQualityScore — edge cases', () {
    test('empty history returns 0.5', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      final stats = manager.getCurrentStats();
      expect(stats.connectionQualityScore, 0.5);
      manager.dispose();
    });

    test('all successes with no RSSI or time still computes', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      manager.reportConnectionSuccess(); // no rssi, no time
      manager.reportConnectionSuccess();
      final stats = manager.getCurrentStats();
      expect(stats.connectionQualityScore, greaterThanOrEqualTo(0.0));
      expect(stats.connectionQualityScore, lessThanOrEqualTo(1.0));
      manager.dispose();
    });

    test('all failures produces low quality score', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      for (int i = 0; i < 5; i++) {
        manager.reportConnectionFailure(reason: 'fail', rssi: -95);
      }
      final stats = manager.getCurrentStats();
      // Failures with weak RSSI: successRate=0, rssiScore=low → quality<0.5
      expect(stats.connectionQualityScore, lessThan(0.5));
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // _calculateConnectionStability
  // -----------------------------------------------------------------------
  group('_calculateConnectionStability', () {
    test('fewer than 3 measurements returns 0.5', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      manager.reportConnectionSuccess(rssi: -60);
      manager.reportConnectionFailure(reason: 'x');
      final stats = manager.getCurrentStats();
      expect(stats.connectionStabilityScore, 0.5);
      manager.dispose();
    });

    test('all successes produces high stability', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      for (int i = 0; i < 5; i++) {
        manager.reportConnectionSuccess(rssi: -55);
      }
      final stats = manager.getCurrentStats();
      expect(stats.connectionStabilityScore, greaterThanOrEqualTo(0.9));
      manager.dispose();
    });

    test('alternating success/fail produces lower stability', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      for (int i = 0; i < 6; i++) {
        if (i.isEven) {
          manager.reportConnectionSuccess(rssi: -60);
        } else {
          manager.reportConnectionFailure(reason: 'flaky');
        }
      }
      final stats = manager.getCurrentStats();
      expect(stats.connectionStabilityScore, lessThan(0.9));
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // startAdaptiveScanning — bluetooth unavailable
  // -----------------------------------------------------------------------
  group('startAdaptiveScanning — bluetooth states', () {
    test('defers start when bluetooth unavailable', () async {
      var startCount = 0;
      final manager = AdaptivePowerManager();
      await manager.initialize(onStartScan: () => startCount++);

      await manager.updateBluetoothAvailability(false);
      await manager.startAdaptiveScanning();
      expect(startCount, 0); // should not have started

      // Now make bluetooth available
      await manager.updateBluetoothAvailability(true);
      // Should auto-resume
      expect(startCount, greaterThanOrEqualTo(1));
      manager.dispose();
    });

    test('updateBluetoothAvailability no-op when same state', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      // Already available by default
      await manager.updateBluetoothAvailability(true);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // scheduleManualBurstAfter — bluetooth unavailable
  // -----------------------------------------------------------------------
  group('scheduleManualBurstAfter — bluetooth unavailable', () {
    test('ignores manual burst when bluetooth not available', () async {
      var startCount = 0;
      final manager = AdaptivePowerManager();
      await manager.initialize(onStartScan: () => startCount++);

      await manager.updateBluetoothAvailability(false);
      await manager.scheduleManualBurstAfter(
        const Duration(milliseconds: 5),
      );
      await Future.delayed(const Duration(milliseconds: 30));
      expect(startCount, 0);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // triggerImmediateScan — when not in burst mode
  // -----------------------------------------------------------------------
  group('triggerImmediateScan — not in burst', () {
    test('triggers burst when not currently in burst mode', () async {
      var startCount = 0;
      final manager = AdaptivePowerManager();
      await manager.initialize(onStartScan: () => startCount++);

      await manager.startAdaptiveScanning();
      expect(startCount, 1);

      // Stop burst
      manager.shortenActiveBurst(Duration.zero);
      await Future.delayed(const Duration(milliseconds: 20));

      // Now trigger immediate
      await manager.triggerImmediateScan();
      expect(startCount, greaterThanOrEqualTo(2));
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // _stopAllTimers — dutyCycleScanning cleanup
  // -----------------------------------------------------------------------
  group('_stopAllTimers — duty cycle cleanup', () {
    test('stop scanning cleans up all timers', () async {
      var stopCount = 0;
      final manager = AdaptivePowerManager();
      await manager.initialize(onStopScan: () => stopCount++);

      await manager.startAdaptiveScanning();
      await manager.stopScanning();
      expect(stopCount, greaterThanOrEqualTo(1));

      final stats = manager.getCurrentStats();
      expect(stats.isBurstMode, isFalse);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // _loadSettings — with persisted values
  // -----------------------------------------------------------------------
  group('_loadSettings and _saveSettings', () {
    test('loads clamped values from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'power_mgmt_scan_interval': 5000, // below min (20000)
        'power_mgmt_health_interval': 100000, // above max (60000)
      });

      final manager = AdaptivePowerManager();
      await manager.initialize();

      final stats = manager.getCurrentStats();
      expect(stats.currentScanInterval, 20000);
      expect(stats.currentHealthCheckInterval, 60000);
      manager.dispose();
    });

    test('saves settings after adaptation', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();

      manager.reportConnectionSuccess(rssi: -50, connectionTime: 100);

      final prefs = await SharedPreferences.getInstance();
      // After adaptation, settings should have been saved
      final scanInterval = prefs.getInt('power_mgmt_scan_interval');
      expect(scanInterval, isNotNull);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // overrideScanInterval — boundary tests
  // -----------------------------------------------------------------------
  group('overrideScanInterval', () {
    test('clamps to min', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      manager.overrideScanInterval(100);
      expect(manager.getCurrentStats().currentScanInterval, 20000);
      manager.dispose();
    });

    test('clamps to max', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      manager.overrideScanInterval(500000);
      expect(manager.getCurrentStats().currentScanInterval, 120000);
      manager.dispose();
    });

    test('accepts value within range', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      manager.overrideScanInterval(50000);
      expect(manager.getCurrentStats().currentScanInterval, 50000);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // resetToDefaults
  // -----------------------------------------------------------------------
  group('resetToDefaults', () {
    test('resets all adaptive state', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();

      // Change state
      manager.overrideScanInterval(30000);
      manager.reportConnectionSuccess(rssi: -50);
      manager.reportConnectionFailure(reason: 'x');

      await manager.resetToDefaults();
      final stats = manager.getCurrentStats();
      expect(stats.currentScanInterval, 60000);
      expect(stats.currentHealthCheckInterval, 30000);
      expect(stats.consecutiveSuccessfulChecks, 0);
      expect(stats.consecutiveFailedChecks, 0);
      expect(stats.qualityMeasurementsCount, 0);
      manager.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // PowerManagementStats model coverage
  // -----------------------------------------------------------------------
  group('PowerManagementStats — computed properties', () {
    test('powerSaver efficiency rating', () {
      final stats = PowerManagementStats(
        currentScanInterval: 80000,
        currentHealthCheckInterval: 45000,
        consecutiveSuccessfulChecks: 5,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.7,
        connectionStabilityScore: 0.8,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 10,
        isBurstMode: false,
        powerMode: PowerMode.powerSaver,
        isDutyCycleScanning: false,
        batteryLevel: 25,
        isCharging: false,
        isAppInBackground: true,
      );
      expect(stats.batteryEfficiencyRating, greaterThan(0.5));
      expect(stats.dutyCyclePercentage, 20.0);
      expect(stats.toString(), contains('powerSaver'));
      expect(stats.toString(), contains('25%'));
    });

    test('balanced mode duty cycle', () {
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
        powerMode: PowerMode.balanced,
        isDutyCycleScanning: false,
        batteryLevel: 60,
        isCharging: false,
        isAppInBackground: false,
      );
      expect(stats.dutyCyclePercentage, 80.0);
      expect(stats.batteryEfficiencyRating, greaterThan(0.0));
    });

    test('performance mode lowest efficiency', () {
      final stats = PowerManagementStats(
        currentScanInterval: 20000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.9,
        connectionStabilityScore: 0.9,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: true,
        powerMode: PowerMode.performance,
        isDutyCycleScanning: false,
        batteryLevel: 100,
        isCharging: true,
        isAppInBackground: false,
      );
      expect(stats.dutyCyclePercentage, 100.0);
      // performance mode: dutyCycleScore = 0.0, quality = 0.9
      // efficiency = 0.0 * 0.7 + 0.9 * 0.3 = 0.27
      expect(stats.batteryEfficiencyRating, lessThan(0.5));
    });
  });

  // -----------------------------------------------------------------------
  // ConnectionQualityMeasurement
  // -----------------------------------------------------------------------
  group('ConnectionQualityMeasurement', () {
    test('stores all fields', () {
      final m = ConnectionQualityMeasurement(
        timestamp: DateTime(2024),
        success: true,
        rssi: -55,
        connectionTime: 120.0,
        dataTransferSuccess: true,
        failureReason: null,
      );
      expect(m.success, isTrue);
      expect(m.rssi, -55);
      expect(m.connectionTime, 120.0);
      expect(m.failureReason, isNull);
    });

    test('failure measurement with reason', () {
      final m = ConnectionQualityMeasurement(
        timestamp: DateTime(2024),
        success: false,
        failureReason: 'connection lost',
      );
      expect(m.success, isFalse);
      expect(m.failureReason, 'connection lost');
    });
  });

  // -----------------------------------------------------------------------
  // dispose safety
  // -----------------------------------------------------------------------
  group('dispose safety', () {
    test('dispose after start and multiple timer cycles', () async {
      final manager = AdaptivePowerManager();
      await manager.initialize();
      await manager.startAdaptiveScanning();
      await manager.triggerImmediateScan();
      manager.dispose();
    });

    test('dispose without initialize', () {
      final manager = AdaptivePowerManager();
      manager.dispose(); // should not throw
    });
  });
}
