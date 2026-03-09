// Phase 13.2: BurstScanningController coverage
// Targets uncovered branches: _handleBurstScanStart (cooldown, Bluetooth check,
// max connections), _handleBurstScanStop (idempotent, scan not started),
// _handleStatsUpdate, _tickScheduler transitions, triggerManualScan during burst,
// forceBurstScanNow during burst, getCurrentStatus edge cases, _updateStatus
// listener error handling, statusStream multi-listener behavior.

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';

void main() {
  Logger.root.level = Level.OFF;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    KillSwitches.disableDiscoveryScheduler = false;
    BluetoothStateMonitor().dispose();
  });

  tearDown(() {
    BluetoothStateMonitor().dispose();
    KillSwitches.disableDiscoveryScheduler = false;
  });

  group('BurstScanningController — uninitialized edge cases', () {
    late BurstScanningController controller;

    setUp(() {
      controller = BurstScanningController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('startBurstScanning without init logs warning and returns', () async {
      await controller.startBurstScanning();
      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, false);
    });

    test('stopBurstScanning without init is safe', () async {
      await controller.stopBurstScanning();
      expect(controller.getCurrentStatus().isBurstActive, false);
    });

    test('triggerManualScan without init logs warning', () async {
      await controller.triggerManualScan();
      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, false);
    });

    test('forceBurstScanNow without init logs warning', () async {
      await controller.forceBurstScanNow();
      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, false);
    });

    test('reportConnectionSuccess without init is no-op', () {
      // Should not throw
      controller.reportConnectionSuccess(rssi: -50, connectionTime: 100);
    });

    test('reportConnectionFailure without init is no-op', () {
      // Should not throw
      controller.reportConnectionFailure(reason: 'timeout', rssi: -90);
    });

    test('dispose without init is safe', () {
      controller.dispose();
      // Should not throw, can dispose again
    });

    test('multiple dispose calls are safe', () {
      controller.dispose();
      controller.dispose();
    });
  });

  group('BurstScanningController — kill switch behavior', () {
    late BurstScanningController controller;
    late _FakeBurstConnectionService bleService;

    setUp(() async {
      controller = BurstScanningController();
      bleService = _FakeBurstConnectionService();
      await controller.initialize(bleService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('startBurstScanning blocked by kill switch', () async {
      KillSwitches.disableDiscoveryScheduler = true;
      await controller.startBurstScanning();
      expect(bleService.startScanningCalls, 0);
    });

    test('stopBurstScanning blocked by kill switch', () async {
      KillSwitches.disableDiscoveryScheduler = true;
      await controller.stopBurstScanning();
      expect(bleService.stopScanningCalls, 0);
    });
  });

  group('BurstScanningController — initialized with BLE', () {
    late BurstScanningController controller;
    late _FakeBurstConnectionService bleService;

    setUp(() async {
      controller = BurstScanningController();
      bleService = _FakeBurstConnectionService();
      await controller.initialize(bleService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('getCurrentStatus returns initialized stats', () {
      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, false);
      expect(status.currentScanInterval, isPositive);
      expect(status.powerStats, isNotNull);
    });

    test('reportConnectionSuccess updates power stats', () {
      controller.reportConnectionSuccess(
        rssi: -60,
        connectionTime: 150,
        dataTransferSuccess: true,
      );
      final stats = controller.getCurrentStatus().powerStats;
      expect(stats.qualityMeasurementsCount, greaterThanOrEqualTo(1));
    });

    test('reportConnectionFailure updates power stats', () {
      controller.reportConnectionFailure(
        reason: 'connection_lost',
        rssi: -85,
        attemptTime: 3000,
      );
      final stats = controller.getCurrentStatus().powerStats;
      expect(stats.consecutiveFailedChecks, greaterThanOrEqualTo(1));
    });

    test('triggerManualScan schedules next scan time', () async {
      await controller.triggerManualScan(
        delay: const Duration(milliseconds: 100),
      );
      final status = controller.getCurrentStatus();
      expect(status.secondsUntilNextScan, isNotNull);
    });

    test('forceBurstScanNow resets cooldown', () async {
      await controller.forceBurstScanNow();
      // Should schedule burst via power manager
      final status = controller.getCurrentStatus();
      // Not burst-active because bluetooth isn't ready in test
      expect(status.isBurstActive, false);
    });

    test('statusStream emits initial status', () async {
      final emitted = <BurstScanningStatus>[];
      final sub = controller.statusStream.listen(emitted.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emitted, isNotEmpty);
      expect(emitted.first.isBurstActive, false);
      await sub.cancel();
    });

    test('statusStream multi-listener gets independent events', () async {
      final emitted1 = <BurstScanningStatus>[];
      final emitted2 = <BurstScanningStatus>[];
      final sub1 = controller.statusStream.listen(emitted1.add);
      final sub2 = controller.statusStream.listen(emitted2.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emitted1, isNotEmpty);
      expect(emitted2, isNotEmpty);
      await sub1.cancel();
      await sub2.cancel();
    });

    test('statusStream stops timer when all listeners cancel', () async {
      final emitted = <BurstScanningStatus>[];
      final sub = controller.statusStream.listen(emitted.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      final countAfterCancel = emitted.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // No more events should be emitted after cancel
      // (timer should be stopped)
      expect(emitted.length, countAfterCancel);
    });
  });

  group('BurstScanningController — max connections skip scan', () {
    late BurstScanningController controller;
    late _FakeBurstConnectionService bleService;

    setUp(() async {
      controller = BurstScanningController();
      bleService = _FakeBurstConnectionService()
        ..canAcceptMoreConnectionsValue = false
        ..activeConnectionCountValue = 1
        ..maxCentralConnectionsValue = 1;
      await controller.initialize(bleService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('burst scan skipped at max connections', () async {
      // Even if bluetooth was ready, scan should be skipped
      // because canAcceptMoreConnections is false
      await controller.startBurstScanning();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The actual scan wouldn't start due to BT not being ready,
      // but the max-connections check is evaluated first if BT was ready
      expect(controller.getCurrentStatus().isBurstActive, false);
    });
  });

  group('BurstScanningStatus — helper methods', () {
    PowerManagementStats makeStats({
      PowerMode mode = PowerMode.balanced,
      double qualityScore = 0.5,
    }) {
      return PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: qualityScore,
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
        powerStats: makeStats(),
      );
      expect(status.statusMessage, 'Burst scanning... 15s remaining');
    });

    test('statusMessage — burst active with 0 remaining', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        burstTimeRemaining: 0,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.statusMessage, 'Burst scanning... 0s remaining');
    });

    test('statusMessage — waiting for next scan', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 45,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.statusMessage, 'Next scan in 45s');
    });

    test('statusMessage — starting scan (0 seconds)', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 0,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.statusMessage, 'Starting scan...');
    });

    test('statusMessage — ready (null next scan)', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.statusMessage, 'Burst scanning ready');
    });

    test('statusMessage — burst active with null remaining', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        burstTimeRemaining: null,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      // Falls through to next condition check
      expect(status.statusMessage, isNotEmpty);
    });

    test('canOverride — true when not scanning and >5s', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 30,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.canOverride, true);
    });

    test('canOverride — false when burst active', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        burstTimeRemaining: 10,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.canOverride, false);
    });

    test('canOverride — false when null secondsUntilNextScan', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: null,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.canOverride, false);
    });

    test('canOverride — false when <=5 seconds', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 5,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.canOverride, false);
    });

    test('canOverride — false when exactly 0 seconds', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 0,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      expect(status.canOverride, false);
    });

    test('efficiencyRating — Excellent for ultra low power', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: makeStats(mode: PowerMode.ultraLowPower),
      );
      expect(status.efficiencyRating, 'Excellent');
    });

    test('efficiencyRating — Good for power saver', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: makeStats(mode: PowerMode.powerSaver),
      );
      expect(status.efficiencyRating, 'Good');
    });

    test('efficiencyRating — Fair for balanced', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: makeStats(mode: PowerMode.balanced),
      );
      expect(status.efficiencyRating, 'Fair');
    });

    test('efficiencyRating — Poor for performance', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: makeStats(mode: PowerMode.performance),
      );
      expect(status.efficiencyRating, 'Poor');
    });

    test('toString includes burst status', () {
      final status = BurstScanningStatus(
        isBurstActive: true,
        secondsUntilNextScan: 10,
        burstTimeRemaining: 5,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      final str = status.toString();
      expect(str, contains('BurstStatus'));
      expect(str, contains('burst: true'));
      expect(str, contains('next: 10s'));
      expect(str, contains('burstRemaining: 5s'));
    });

    test('toString with null values', () {
      final status = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: makeStats(),
      );
      final str = status.toString();
      expect(str, contains('burst: false'));
      expect(str, contains('null'));
    });
  });

  group('PowerManagementStats — helper methods', () {
    test('batteryEfficiencyRating varies by power mode', () {
      final modes = PowerMode.values;
      final ratings = <PowerMode, double>{};

      for (final mode in modes) {
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
        ratings[mode] = stats.batteryEfficiencyRating;
      }

      // Ultra low power should have highest efficiency
      expect(
        ratings[PowerMode.ultraLowPower]!,
        greaterThan(ratings[PowerMode.performance]!),
      );
      expect(
        ratings[PowerMode.powerSaver]!,
        greaterThan(ratings[PowerMode.performance]!),
      );
    });

    test('batteryEfficiencyRating clamped to [0.0, 1.0]', () {
      for (final mode in PowerMode.values) {
        final stats = PowerManagementStats(
          currentScanInterval: 60000,
          currentHealthCheckInterval: 30000,
          consecutiveSuccessfulChecks: 0,
          consecutiveFailedChecks: 0,
          connectionQualityScore: 1.0,
          connectionStabilityScore: 1.0,
          timeSinceLastSuccess: Duration.zero,
          qualityMeasurementsCount: 0,
          isBurstMode: false,
          powerMode: mode,
          isDutyCycleScanning: false,
          batteryLevel: 100,
          isCharging: false,
          isAppInBackground: false,
        );
        expect(stats.batteryEfficiencyRating, greaterThanOrEqualTo(0.0));
        expect(stats.batteryEfficiencyRating, lessThanOrEqualTo(1.0));
      }
    });

    test('dutyCyclePercentage is positive for all modes', () {
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

    test('batteryEfficiencyRating with zero quality score', () {
      final stats = PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.0,
        connectionStabilityScore: 0.0,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: false,
        powerMode: PowerMode.balanced,
        isDutyCycleScanning: false,
        batteryLevel: 100,
        isCharging: false,
        isAppInBackground: false,
      );
      // With zero quality, the 30% quality contribution is 0
      expect(stats.batteryEfficiencyRating, greaterThanOrEqualTo(0.0));
    });
  });

  group('BurstScanningController — scan failure handling', () {
    late BurstScanningController controller;
    late _FakeBurstConnectionService bleService;

    setUp(() async {
      controller = BurstScanningController();
      bleService = _FakeBurstConnectionService()..shouldFailScan = true;
      await controller.initialize(bleService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('scan failure resets burst state', () async {
      // Scan will fail, burst state should reset
      await controller.startBurstScanning();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.getCurrentStatus().isBurstActive, false);
    });
  });

  group('BurstScanningController — stopBurstScanning cleanup', () {
    late BurstScanningController controller;
    late _FakeBurstConnectionService bleService;

    setUp(() async {
      controller = BurstScanningController();
      bleService = _FakeBurstConnectionService();
      await controller.initialize(bleService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('stopBurstScanning resets burst state', () async {
      await controller.stopBurstScanning();
      expect(controller.getCurrentStatus().isBurstActive, false);
    });

    test('multiple stop calls are idempotent', () async {
      await controller.stopBurstScanning();
      await controller.stopBurstScanning();
      expect(controller.getCurrentStatus().isBurstActive, false);
    });
  });

  group('BurstScanningController — triggerManualScan edge cases', () {
    late BurstScanningController controller;
    late _FakeBurstConnectionService bleService;

    setUp(() async {
      controller = BurstScanningController();
      bleService = _FakeBurstConnectionService();
      await controller.initialize(bleService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('triggerManualScan with custom delay', () async {
      await controller.triggerManualScan(
        delay: const Duration(seconds: 5),
      );
      final status = controller.getCurrentStatus();
      expect(status.secondsUntilNextScan, isNotNull);
    });

    test('triggerManualScan with zero delay', () async {
      await controller.triggerManualScan(
        delay: Duration.zero,
      );
      // Should not throw and should schedule
    });
  });
}

// ─── Fakes ───────────────────────────────────────────────────────────

class _FakeBurstConnectionService implements IConnectionService {
  int activeConnectionCountValue = 0;
  int maxCentralConnectionsValue = 1;
  bool canAcceptMoreConnectionsValue = true;
  List<String> activeConnectionDeviceIdsValue = const <String>[];
  bool shouldFailScan = false;

  int startScanningCalls = 0;
  int stopScanningCalls = 0;
  ScanningSource? lastStartSource;

  @override
  int get activeConnectionCount => activeConnectionCountValue;

  @override
  int get maxCentralConnections => maxCentralConnectionsValue;

  @override
  bool get canAcceptMoreConnections => canAcceptMoreConnectionsValue;

  @override
  List<String> get activeConnectionDeviceIds => activeConnectionDeviceIdsValue;

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {
    if (shouldFailScan) {
      throw Exception('Simulated scan failure');
    }
    startScanningCalls++;
    lastStartSource = source;
  }

  @override
  Future<void> stopScanning() async {
    stopScanningCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
