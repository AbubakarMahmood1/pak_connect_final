import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late BurstScanningController controller;
  late _FakeBurstConnectionService bleService;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    KillSwitches.disableDiscoveryScheduler = false;
    BluetoothStateMonitor().dispose();

    controller = BurstScanningController();
    bleService = _FakeBurstConnectionService();
  });

  tearDown(() {
    controller.dispose();
    BluetoothStateMonitor().dispose();
    KillSwitches.disableDiscoveryScheduler = false;
  });

  group('BurstScanningController', () {
    test('returns safe default status before initialization', () {
      final status = controller.getCurrentStatus();

      expect(status.isBurstActive, isFalse);
      expect(status.secondsUntilNextScan, isNull);
      expect(status.currentScanInterval, 60000);
      expect(status.statusMessage, 'Burst scanning ready');
      expect(status.canOverride, isFalse);
      expect(status.efficiencyRating, isNotEmpty);
    });

    test('start/stop are safe before initialize', () async {
      await controller.startBurstScanning();
      await controller.stopBurstScanning();

      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, isFalse);
      expect(bleService.startScanningCalls, 0);
    });

    test('kill switch suppresses start and stop operations', () async {
      await controller.initialize(bleService);
      KillSwitches.disableDiscoveryScheduler = true;

      await controller.startBurstScanning();
      await controller.stopBurstScanning();

      expect(bleService.startScanningCalls, 0);
      expect(bleService.stopScanningCalls, 0);
    });

    test(
      'initialize wires power manager and start handles unavailable bluetooth',
      () async {
        await controller.initialize(bleService);
        await controller.startBurstScanning();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Default monitor state in tests is not-ready, so burst start is skipped.
        expect(bleService.startScanningCalls, 0);
        expect(controller.getCurrentStatus().isBurstActive, isFalse);
      },
    );

    test('manual trigger schedules immediate burst window when idle', () async {
      await controller.initialize(bleService);

      await controller.triggerManualScan(
        delay: const Duration(milliseconds: 50),
      );

      final status = controller.getCurrentStatus();
      expect(status.secondsUntilNextScan, isNotNull);
      expect(status.secondsUntilNextScan, greaterThanOrEqualTo(0));
    });

    test('forceBurstScanNow is safe when dependencies are missing', () async {
      await controller.forceBurstScanNow();

      final status = controller.getCurrentStatus();
      expect(status.isBurstActive, isFalse);
      expect(bleService.startScanningCalls, 0);
    });

    test('reportConnectionSuccess/failure feed adaptive stats', () async {
      await controller.initialize(bleService);

      controller.reportConnectionSuccess(
        rssi: -64,
        connectionTime: 110,
        dataTransferSuccess: true,
      );
      controller.reportConnectionFailure(
        reason: 'timeout',
        rssi: -92,
        attemptTime: 2800,
      );

      final stats = controller.getCurrentStatus().powerStats;
      expect(stats.qualityMeasurementsCount, 2);
      expect(stats.consecutiveSuccessfulChecks, 0);
      expect(stats.consecutiveFailedChecks, 1);
    });

    test(
      'status stream emits immediately and stays active until cancelled',
      () async {
        await controller.initialize(bleService);

        final emitted = <BurstScanningStatus>[];
        final sub = controller.statusStream.listen(emitted.add);

        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(emitted, isNotEmpty);

        await sub.cancel();
      },
    );
  });
}

class _FakeBurstConnectionService implements IConnectionService {
  int activeConnectionCountValue = 0;
  int maxCentralConnectionsValue = 1;
  bool canAcceptMoreConnectionsValue = true;
  List<String> activeConnectionDeviceIdsValue = const <String>[];

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
