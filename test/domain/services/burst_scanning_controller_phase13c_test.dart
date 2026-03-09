/// Phase 13c: BurstScanningController deep callback coverage
/// Targets uncovered lines inside _handleBurstScanStart, _handleBurstScanStop,
/// _handleHealthCheck, _handleStatsUpdate, statusStream listener callback,
/// cooldown enforcement, max-connections skip (with BT ready), scan failure,
/// triggerManualScan during active burst, forceBurstScanNow, and the full
/// report-connection paths.
library;
import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    show BluetoothLowEnergyState;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
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
    BluetoothStateMonitor.overrideCurrentState(
      BluetoothLowEnergyState.unknown,
    );
    BluetoothStateMonitor().dispose();
    KillSwitches.disableDiscoveryScheduler = false;
  });

  // =========================================================================
  // Helper to initialise with Bluetooth ready
  // =========================================================================
  Future<(BurstScanningController, _FakeConnectionSvc)> initReady({
    bool canAcceptMore = true,
    int activeCount = 0,
    int maxConns = 1,
    bool failScan = false,
    bool failStop = false,
  }) async {
    BluetoothStateMonitor.overrideCurrentState(
      BluetoothLowEnergyState.poweredOn,
    );
    final ble = _FakeConnectionSvc()
      ..canAcceptMore = canAcceptMore
      ..activeCount = activeCount
      ..maxConns = maxConns
      ..failScan = failScan
      ..failStop = failStop;
    final controller = BurstScanningController();
    await controller.initialize(ble);
    return (controller, ble);
  }

  // =========================================================================
  // Full scan lifecycle with Bluetooth ready
  // =========================================================================
  group('BT ready – scan start happy path', () {
    test('startBurstScanning triggers actual BLE scan', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isTrue);
        expect(ble.startCalls, 1);

        // Clean up all timers
        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });

    test('burst auto-stops after duration timer expires', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isTrue);

        // Advance past 20-second burst duration
        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);
        expect(ble.stopCalls, greaterThanOrEqualTo(1));

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });

    test('scan logs success message', () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        expect(
          logRecords.any((r) => r.message.contains('Scan started successfully')),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // Cooldown enforcement
  // =========================================================================
  group('BT ready – cooldown enforcement', () {
    test('second scan start blocked by cooldown', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        // Start first burst
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(ble.startCalls, 1);

        // Let it auto-stop (20s) and the reschedule timer fire (~20s too).
        // The rescheduled _handleBurstScanStart hits the cooldown gate.
        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isFalse);

        // BLE.startScanning should NOT have been called a second time
        // because the cooldown gate returned early.
        expect(ble.startCalls, 1);

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // Max connections – scan skipped with BT ready
  // =========================================================================
  group('BT ready – max connections blocks scan', () {
    test('scan skipped when at max connections', () async {
      final (controller, ble) = await initReady(
        canAcceptMore: false,
        activeCount: 1,
        maxConns: 1,
      );
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);
        expect(ble.startCalls, 0);
        expect(
          logRecords.any(
            (r) => r.message.contains('already at max connections'),
          ),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // Scan failure handling with BT ready
  // =========================================================================
  group('BT ready – scan failure', () {
    test('failed startScanning resets state', () async {
      final (controller, _) = await initReady(failScan: true);
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);
        expect(
          logRecords.any(
            (r) => r.message.contains('Failed to start scanning'),
          ),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // _handleBurstScanStop paths
  // =========================================================================
  group('BT ready – scan stop paths', () {
    test('scan stop logs success and resets state', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isTrue);

        // Advance to trigger stop
        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);
        expect(
          logRecords.any(
            (r) => r.message.contains('Scan stopped successfully'),
          ),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });

    test('stopScanning exception in _handleBurstScanStop is caught', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isTrue);

        // Make stop fail
        ble.failStop = true;

        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();

        // Should still become inactive despite exception
        expect(controller.getCurrentStatus().isBurstActive, isFalse);
        expect(
          logRecords.any(
            (r) => r.message.contains('Error stopping scan'),
          ),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });

    test('idempotent stop is safe when burst already inactive', () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isTrue);

        // Let both the power-manager burst timer and the controller duration
        // timer fire — the second _handleBurstScanStop call hits the
        // idempotent guard (lines 214-218).
        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // _handleHealthCheck and _handleStatsUpdate via timer
  // =========================================================================
  group('BT ready – health check & stats callbacks', () {
    test('health check fires via power manager timer', () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        // Health check is ~30s; advance past it
        async.elapse(const Duration(seconds: 35));
        async.flushMicrotasks();

        expect(
          logRecords.any(
            (r) => r.message.contains('connection health check'),
          ),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });

    test('stats update fires after health check', () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 35));
        async.flushMicrotasks();

        expect(
          logRecords.any(
            (r) => r.message.contains('Power stats updated'),
          ),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // statusStream listener receives updates
  // =========================================================================
  group('BT ready – statusStream listener callback', () {
    test('listener gets notified on scan start', () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        final events = <BurstScanningStatus>[];
        final sub = controller.statusStream.listen(events.add);
        async.flushMicrotasks();
        final initialCount = events.length;

        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        expect(events.length, greaterThan(initialCount));
        expect(events.any((e) => e.isBurstActive), isTrue);

        sub.cancel();
        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // triggerManualScan during active burst
  // =========================================================================
  group('BT ready – triggerManualScan during active burst', () {
    test('shortens active burst to given delay', () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isTrue);

        // Shorten burst
        unawaited(controller.triggerManualScan(
          delay: const Duration(milliseconds: 100),
        ));
        async.flushMicrotasks();

        // Advance past the shortened delay
        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // triggerManualScan when not scanning
  // =========================================================================
  group('BT ready – triggerManualScan when idle', () {
    test('schedules next scan via power manager', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        unawaited(controller.triggerManualScan(
          delay: const Duration(milliseconds: 50),
        ));
        async.flushMicrotasks();

        // Advance past the delay – scan should start
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();

        expect(ble.startCalls, greaterThanOrEqualTo(1));

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // forceBurstScanNow with BT ready
  // =========================================================================
  group('BT ready – forceBurstScanNow', () {
    test('triggers immediate scan', () async {
      final (controller, ble) = await initReady();
      fakeAsync((async) {
        unawaited(controller.forceBurstScanNow());
        async.flushMicrotasks();

        // Timer(Duration.zero) fires on next tick
        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();

        expect(ble.startCalls, greaterThanOrEqualTo(1));

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });

    test('forceBurstScanNow during active burst delegates to triggerManualScan',
        () async {
      final (controller, _) = await initReady();
      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();
        expect(controller.getCurrentStatus().isBurstActive, isTrue);

        unawaited(controller.forceBurstScanNow());
        async.flushMicrotasks();

        // The burst should be shortened; advance to let it end
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(controller.getCurrentStatus().isBurstActive, isFalse);

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
    });
  });

  // =========================================================================
  // reportConnectionSuccess / reportConnectionFailure (BT ready path)
  // =========================================================================
  group('BT ready – report methods', () {
    test('reportConnectionSuccess delegates to power manager', () async {
      final (controller, _) = await initReady();
      controller.reportConnectionSuccess(
        rssi: -55,
        connectionTime: 200,
        dataTransferSuccess: true,
      );
      expect(
        controller.getCurrentStatus().powerStats.qualityMeasurementsCount,
        greaterThanOrEqualTo(1),
      );
      controller.dispose();
    });

    test('reportConnectionFailure delegates to power manager', () async {
      final (controller, _) = await initReady();
      controller.reportConnectionFailure(
        reason: 'timeout',
        rssi: -90,
        attemptTime: 5000,
      );
      expect(
        controller.getCurrentStatus().powerStats.consecutiveFailedChecks,
        greaterThanOrEqualTo(1),
      );
      controller.dispose();
    });
  });

  // =========================================================================
  // BT not ready — scan skipped (ensures lines 150-155 hit)
  // =========================================================================
  group('BT not ready – scan skipped in callback', () {
    test('scan skipped when Bluetooth unavailable during callback', () async {
      // Leave monitor at unknown state (default)
      // But we need the power manager to think BT is available so it calls
      // the callback. Override state *after* init to simulate BT going away.
      BluetoothStateMonitor.overrideCurrentState(
        BluetoothLowEnergyState.poweredOn,
      );
      final ble = _FakeConnectionSvc();
      final controller = BurstScanningController();
      await controller.initialize(ble);

      // Now set BT to unavailable so the callback's check fails
      BluetoothStateMonitor.overrideCurrentState(
        BluetoothLowEnergyState.poweredOff,
      );

      fakeAsync((async) {
        unawaited(controller.startBurstScanning());
        async.flushMicrotasks();

        // Scan should not have started because BT check inside callback fails
        expect(ble.startCalls, 0);
        expect(
          logRecords.any((r) => r.message.contains('Bluetooth not ready')),
          isTrue,
        );

        unawaited(controller.stopBurstScanning());
        async.flushMicrotasks();
      });
      controller.dispose();
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
  bool failStop = false;
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
    if (failStop) throw Exception('stop fail');
    stopCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
