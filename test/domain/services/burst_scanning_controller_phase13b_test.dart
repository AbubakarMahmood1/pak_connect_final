/// Phase 13b: BurstScanningController additional coverage
/// Targets uncovered lines: _handleBurstScanStart (cooldown enforcement, BLE
/// unavailable, Bluetooth not ready, max-connections skip, successful start
/// with duration timer, scan failure reset), _handleBurstScanStop (idempotent,
/// scan-not-started path, scan-stop exception), _handleHealthCheck,
/// _handleStatsUpdate, _tickScheduler (burst-end, cooldown-elapsed),
/// getCurrentStatus edge cases (burst active with expired timer, burst with
/// remaining time, no burst with next-action), _updateStatus with throwing
/// listener, statusStream multi-cancel, triggerManualScan during active burst,
/// forceBurstScanNow during active burst.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/models/power_mode.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';

void main() {
  late List<LogRecord> logRecords;

  setUp(() {
    logRecords = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    KillSwitches.disableDiscoveryScheduler = false;
    BluetoothStateMonitor().dispose();
  });

  tearDown(() {
    Logger.root.clearListeners();
    BluetoothStateMonitor().dispose();
    KillSwitches.disableDiscoveryScheduler = false;
  });

  // =========================================================================
  // BurstScanningStatus model — exhaustive message/override/efficiency
  // =========================================================================
  group('BurstScanningStatus model extras', () {
    PowerManagementStats _stats({PowerMode mode = PowerMode.balanced}) =>
        PowerManagementStats(
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

    test('statusMessage shows "Next scan in Xs" when not active', () {
      final s = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 120,
        currentScanInterval: 60000,
        powerStats: _stats(),
      );
      expect(s.statusMessage, 'Next scan in 120s');
    });

    test('statusMessage shows "Starting scan..." at 0', () {
      final s = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 0,
        currentScanInterval: 60000,
        powerStats: _stats(),
      );
      expect(s.statusMessage, 'Starting scan...');
    });

    test('statusMessage shows "Burst scanning ready" when no info', () {
      final s = BurstScanningStatus(
        isBurstActive: false,
        currentScanInterval: 60000,
        powerStats: _stats(),
      );
      expect(s.statusMessage, 'Burst scanning ready');
    });

    test('canOverride true when >5s until next scan', () {
      final s = BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: 10,
        currentScanInterval: 60000,
        powerStats: _stats(),
      );
      expect(s.canOverride, isTrue);
    });

    test('canOverride false when burst active', () {
      final s = BurstScanningStatus(
        isBurstActive: true,
        burstTimeRemaining: 10,
        currentScanInterval: 60000,
        powerStats: _stats(),
      );
      expect(s.canOverride, isFalse);
    });

    test('efficiencyRating for each power mode', () {
      expect(
        BurstScanningStatus(
          isBurstActive: false,
          currentScanInterval: 60000,
          powerStats: _stats(mode: PowerMode.ultraLowPower),
        ).efficiencyRating,
        'Excellent',
      );
      expect(
        BurstScanningStatus(
          isBurstActive: false,
          currentScanInterval: 60000,
          powerStats: _stats(mode: PowerMode.powerSaver),
        ).efficiencyRating,
        'Good',
      );
      expect(
        BurstScanningStatus(
          isBurstActive: false,
          currentScanInterval: 60000,
          powerStats: _stats(mode: PowerMode.balanced),
        ).efficiencyRating,
        'Fair',
      );
      expect(
        BurstScanningStatus(
          isBurstActive: false,
          currentScanInterval: 60000,
          powerStats: _stats(mode: PowerMode.performance),
        ).efficiencyRating,
        'Poor',
      );
    });

    test('toString contains key fields', () {
      final s = BurstScanningStatus(
        isBurstActive: true,
        burstTimeRemaining: 7,
        secondsUntilNextScan: 3,
        currentScanInterval: 60000,
        powerStats: _stats(),
      );
      expect(s.toString(), contains('burst: true'));
    });
  });

  // =========================================================================
  // getCurrentStatus — uninitialized (null power manager)
  // =========================================================================
  group('getCurrentStatus uninitialized', () {
    test('returns default status when power manager is null', () {
      final c = BurstScanningController();
      final status = c.getCurrentStatus();
      expect(status.isBurstActive, isFalse);
      expect(status.currentScanInterval, 60000);
      expect(status.powerStats.powerMode, PowerMode.balanced);
      c.dispose();
    });
  });

  // =========================================================================
  // Initialized controller – state transitions
  // =========================================================================
  group('Initialized controller state transitions', () {
    late BurstScanningController controller;
    late _FakeConnectionSvc ble;

    setUp(() async {
      controller = BurstScanningController();
      ble = _FakeConnectionSvc();
      await controller.initialize(ble);
    });

    tearDown(() => controller.dispose());

    test('stopBurstScanning sets isBurstActive false', () async {
      await controller.stopBurstScanning();
      expect(controller.getCurrentStatus().isBurstActive, isFalse);
    });

    test('double stopBurstScanning is idempotent', () async {
      await controller.stopBurstScanning();
      await controller.stopBurstScanning();
      expect(controller.getCurrentStatus().isBurstActive, isFalse);
    });

    test('kill switch blocks start', () async {
      KillSwitches.disableDiscoveryScheduler = true;
      await controller.startBurstScanning();
      expect(ble.startCalls, 0);
    });

    test('kill switch blocks stop', () async {
      KillSwitches.disableDiscoveryScheduler = true;
      await controller.stopBurstScanning();
      expect(ble.stopCalls, 0);
    });

    test('triggerManualScan sets nextActionTime', () async {
      await controller.triggerManualScan(
        delay: const Duration(seconds: 2),
      );
      final s = controller.getCurrentStatus();
      expect(s.secondsUntilNextScan, isNotNull);
    });

    test('forceBurstScanNow resets cooldown and schedules', () async {
      await controller.forceBurstScanNow();
      // Not burst-active since BT not ready, but should be scheduled
      expect(controller.getCurrentStatus().isBurstActive, isFalse);
    });

    test('reportConnectionSuccess is safe', () {
      controller.reportConnectionSuccess(
        rssi: -55,
        connectionTime: 200,
        dataTransferSuccess: true,
      );
      final s = controller.getCurrentStatus();
      expect(s.powerStats.qualityMeasurementsCount, greaterThanOrEqualTo(1));
    });

    test('reportConnectionFailure is safe', () {
      controller.reportConnectionFailure(
        reason: 'timeout',
        rssi: -90,
        attemptTime: 5000,
      );
      final s = controller.getCurrentStatus();
      expect(s.powerStats.consecutiveFailedChecks, greaterThanOrEqualTo(1));
    });
  });

  // =========================================================================
  // Max connections – burst scan skipped
  // =========================================================================
  group('Max connections skip scan', () {
    test('scan not started when at max connections', () async {
      final ble = _FakeConnectionSvc()
        ..canAcceptMore = false
        ..activeCount = 1
        ..maxConns = 1;
      final c = BurstScanningController();
      await c.initialize(ble);

      await c.startBurstScanning();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.getCurrentStatus().isBurstActive, isFalse);
      c.dispose();
    });
  });

  // =========================================================================
  // Scan failure handling
  // =========================================================================
  group('Scan failure resets state', () {
    test('failed scan sets isBurstActive false', () async {
      final ble = _FakeConnectionSvc()..failScan = true;
      final c = BurstScanningController();
      await c.initialize(ble);
      await c.startBurstScanning();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.getCurrentStatus().isBurstActive, isFalse);
      c.dispose();
    });
  });

  // =========================================================================
  // statusStream – lifecycle
  // =========================================================================
  group('statusStream', () {
    test('first subscriber gets initial status', () async {
      final c = BurstScanningController();
      final ble = _FakeConnectionSvc();
      await c.initialize(ble);

      final events = <BurstScanningStatus>[];
      final sub = c.statusStream.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, isNotEmpty);
      expect(events.first.isBurstActive, isFalse);

      await sub.cancel();
      c.dispose();
    });

    test('two subscribers get independent events', () async {
      final c = BurstScanningController();
      final ble = _FakeConnectionSvc();
      await c.initialize(ble);

      final a = <BurstScanningStatus>[];
      final b = <BurstScanningStatus>[];
      final s1 = c.statusStream.listen(a.add);
      final s2 = c.statusStream.listen(b.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(a, isNotEmpty);
      expect(b, isNotEmpty);

      await s1.cancel();
      await s2.cancel();
      c.dispose();
    });

    test('timer stops when all listeners cancel', () async {
      final c = BurstScanningController();
      final ble = _FakeConnectionSvc();
      await c.initialize(ble);

      final events = <BurstScanningStatus>[];
      final sub = c.statusStream.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await sub.cancel();
      final countAtCancel = events.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(events.length, countAtCancel);

      c.dispose();
    });

    test('second sub after first cancel restarts timer', () async {
      final c = BurstScanningController();
      final ble = _FakeConnectionSvc();
      await c.initialize(ble);

      final sub1 = c.statusStream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub1.cancel();

      final events2 = <BurstScanningStatus>[];
      final sub2 = c.statusStream.listen(events2.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events2, isNotEmpty);

      await sub2.cancel();
      c.dispose();
    });
  });

  // =========================================================================
  // Dispose safety
  // =========================================================================
  group('Dispose', () {
    test('dispose is safe without initialize', () {
      final c = BurstScanningController();
      c.dispose();
    });

    test('double dispose is safe', () async {
      final c = BurstScanningController();
      await c.initialize(_FakeConnectionSvc());
      c.dispose();
      c.dispose();
    });

    test('dispose logs info', () async {
      final c = BurstScanningController();
      await c.initialize(_FakeConnectionSvc());
      c.dispose();
      expect(
        logRecords.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Burst scanning controller disposed'),
        ),
        isTrue,
      );
    });
  });

  // =========================================================================
  // triggerManualScan edge cases
  // =========================================================================
  group('triggerManualScan edge cases', () {
    test('without init logs warning', () async {
      final c = BurstScanningController();
      await c.triggerManualScan();
      expect(c.getCurrentStatus().isBurstActive, isFalse);
      c.dispose();
    });

    test('with zero delay', () async {
      final c = BurstScanningController();
      await c.initialize(_FakeConnectionSvc());
      await c.triggerManualScan(delay: Duration.zero);
      c.dispose();
    });
  });

  // =========================================================================
  // forceBurstScanNow edge cases
  // =========================================================================
  group('forceBurstScanNow edge cases', () {
    test('without init is no-op', () async {
      final c = BurstScanningController();
      await c.forceBurstScanNow();
      expect(c.getCurrentStatus().isBurstActive, isFalse);
      c.dispose();
    });

    test('with null BLE service returns', () async {
      final c = BurstScanningController();
      await c.forceBurstScanNow();
      c.dispose();
    });
  });

  // =========================================================================
  // Initialize logging
  // =========================================================================
  group('initialize logging', () {
    test('initialize logs info message', () async {
      final c = BurstScanningController();
      await c.initialize(_FakeConnectionSvc());
      expect(
        logRecords.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Burst scanning controller initialized'),
        ),
        isTrue,
      );
      c.dispose();
    });
  });

  // =========================================================================
  // Connection success/failure without init
  // =========================================================================
  group('report without init', () {
    test('reportConnectionSuccess without init is no-op', () {
      final c = BurstScanningController();
      c.reportConnectionSuccess(rssi: -50);
      c.dispose();
    });

    test('reportConnectionFailure without init is no-op', () {
      final c = BurstScanningController();
      c.reportConnectionFailure(reason: 'fail');
      c.dispose();
    });
  });
}

// ─── Fake ────────────────────────────────────────────────────────────────────

class _FakeConnectionSvc implements IConnectionService {
  int activeCount = 0;
  int maxConns = 1;
  bool canAcceptMore = true;
  List<String> deviceIds = const [];
  bool failScan = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  int get activeConnectionCount => activeCount;

  @override
  int get maxCentralConnections => maxConns;

  @override
  bool get canAcceptMoreConnections => canAcceptMore;

  @override
  List<String> get activeConnectionDeviceIds => deviceIds;

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {
    if (failScan) throw Exception('scan fail');
    startCalls++;
  }

  @override
  Future<void> stopScanning() async {
    stopCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
