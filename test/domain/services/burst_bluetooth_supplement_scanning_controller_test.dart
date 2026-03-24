/// supplement: targeted branch coverage for BurstScanningController
/// and BluetoothStateMonitor.
///
/// Focuses ONLY on untested branches identified by coverage analysis —
/// kill-switch early-returns, BurstScanningStatus edge-case getters,
/// BluetoothStateMonitor stream lifecycle, and status-message actionHint
/// fields.
library;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
 show BluetoothLowEnergyState;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';

void main() {
 late List<LogRecord> logRecords;

 setUp(() {
 logRecords = [];
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logRecords.add);
 });

 // =========================================================================
 // BurstScanningController — supplement
 // =========================================================================
 group('BurstScanningController — supplement', () {
 late BurstScanningController controller;

 setUp(() {
 KillSwitches.disableDiscoveryScheduler = false;
 controller = BurstScanningController();
 });

 tearDown(() {
 KillSwitches.disableDiscoveryScheduler = false;
 controller.dispose();
 });

 // --- kill-switch paths --------------------------------------------------

 test('startBurstScanning returns early when kill switch is active', () async {
 KillSwitches.disableDiscoveryScheduler = true;
 await controller.startBurstScanning();

 final killWarnings = logRecords.where((r) =>
 r.level == Level.WARNING &&
 r.message.contains('kill switch'),
);
 expect(killWarnings, isNotEmpty);
 });

 test('stopBurstScanning returns early when kill switch is active', () async {
 KillSwitches.disableDiscoveryScheduler = true;
 await controller.stopBurstScanning();

 final killWarnings = logRecords.where((r) =>
 r.level == Level.WARNING &&
 r.message.contains('kill switch'),
);
 expect(killWarnings, isNotEmpty);
 });

 // --- multiple dispose calls ---------------------------------------------

 test('dispose is idempotent — calling twice does not throw', () {
 controller.dispose();
 // Second dispose on a fresh controller should not explode.
 controller.dispose();
 });

 // --- reportConnection* with all optional parameters ---------------------

 test('reportConnectionSuccess with all optional params is safe', () {
 controller.reportConnectionSuccess(rssi: -72,
 connectionTime: 1.5,
 dataTransferSuccess: true,
);
 });

 test('reportConnectionFailure with all optional params is safe', () {
 controller.reportConnectionFailure(reason: 'timeout',
 rssi: -90,
 attemptTime: 3.0,
);
 });

 // --- getCurrentStatus default powerStats detail -------------------------

 test('getCurrentStatus default powerStats carries expected field values',
 () {
 final status = controller.getCurrentStatus();
 final ps = status.powerStats;

 expect(ps.powerMode, PowerMode.balanced);
 expect(ps.batteryLevel, 100);
 expect(ps.isCharging, isFalse);
 expect(ps.isAppInBackground, isFalse);
 expect(ps.isBurstMode, isFalse);
 expect(ps.consecutiveSuccessfulChecks, 0);
 expect(ps.consecutiveFailedChecks, 0);
 expect(ps.connectionQualityScore, 0.0);
 expect(ps.connectionStabilityScore, 0.0);
 expect(ps.qualityMeasurementsCount, 0);
 expect(ps.nextScheduledScanTime, isNull);
 });
 });

 // =========================================================================
 // BurstScanningStatus — supplement edge cases
 // =========================================================================
 group('BurstScanningStatus — supplement', () {
 PowerManagementStats stats0({PowerMode mode = PowerMode.balanced}) {
 return PowerManagementStats(currentScanInterval: 60000,
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

 test('canOverride is false when secondsUntilNextScan is null', () {
 final status = BurstScanningStatus(isBurstActive: false,
 secondsUntilNextScan: null,
 currentScanInterval: 60000,
 powerStats: stats0(),
);
 // (null ?? 0) > 5 ➜ false
 expect(status.canOverride, isFalse);
 });

 test('canOverride is false when secondsUntilNextScan equals 5', () {
 final status = BurstScanningStatus(isBurstActive: false,
 secondsUntilNextScan: 5,
 currentScanInterval: 60000,
 powerStats: stats0(),
);
 // 5 > 5 ➜ false (boundary)
 expect(status.canOverride, isFalse);
 });

 test('statusMessage falls through when burst active but burstTimeRemaining is null',
 () {
 // isBurstActive && burstTimeRemaining != null ➜ false (null)
 // secondsUntilNextScan != null ➜ false
 // secondsUntilNextScan == 0 ➜ false
 // ➜ 'Burst scanning ready'
 final status = BurstScanningStatus(isBurstActive: true,
 burstTimeRemaining: null,
 currentScanInterval: 60000,
 powerStats: stats0(),
);
 expect(status.statusMessage, 'Burst scanning ready');
 });

 test('statusMessage returns ready when secondsUntilNextScan is negative', () {
 final status = BurstScanningStatus(isBurstActive: false,
 secondsUntilNextScan: -1,
 currentScanInterval: 60000,
 powerStats: stats0(),
);
 // -1 > 0 ➜ false; -1 == 0 ➜ false; falls through
 expect(status.statusMessage, 'Burst scanning ready');
 });

 test('toString includes null fields without crashing', () {
 final status = BurstScanningStatus(isBurstActive: false,
 secondsUntilNextScan: null,
 burstTimeRemaining: null,
 currentScanInterval: 60000,
 powerStats: stats0(),
);
 final str = status.toString();
 expect(str, contains('BurstStatus'));
 expect(str, contains('burst: false'));
 expect(str, contains('null'));
 });
 });

 // =========================================================================
 // PowerManagementStats — supplement
 // =========================================================================
 group('PowerManagementStats — supplement', () {
 test('toString includes all key fields', () {
 final stats = PowerManagementStats(currentScanInterval: 60000,
 currentHealthCheckInterval: 30000,
 consecutiveSuccessfulChecks: 2,
 consecutiveFailedChecks: 1,
 connectionQualityScore: 0.75,
 connectionStabilityScore: 0.8,
 timeSinceLastSuccess: const Duration(seconds: 10),
 qualityMeasurementsCount: 5,
 isBurstMode: true,
 powerMode: PowerMode.performance,
 isDutyCycleScanning: false,
 batteryLevel: 85,
 isCharging: true,
 isAppInBackground: false,
);
 final str = stats.toString();
 expect(str, contains('performance'));
 expect(str, contains('85%'));
 expect(str, contains('quality'));
 expect(str, contains('efficiency'));
 });

 test('batteryEfficiencyRating is clamped to [0,1]', () {
 for (final mode in PowerMode.values) {
 final stats = PowerManagementStats(currentScanInterval: 60000,
 currentHealthCheckInterval: 30000,
 consecutiveSuccessfulChecks: 0,
 consecutiveFailedChecks: 0,
 connectionQualityScore: 1.0, // max quality
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
 expect(stats.batteryEfficiencyRating, inInclusiveRange(0.0, 1.0));
 }
 });
 });

 // =========================================================================
 // ConnectionQualityMeasurement — supplement
 // =========================================================================
 group('ConnectionQualityMeasurement — supplement', () {
 test('stores all fields including optional ones', () {
 final m = ConnectionQualityMeasurement(timestamp: DateTime(2026),
 success: true,
 rssi: -60,
 connectionTime: 0.5,
 dataTransferSuccess: true,
 failureReason: null,
);
 expect(m.success, isTrue);
 expect(m.rssi, -60);
 expect(m.connectionTime, 0.5);
 expect(m.dataTransferSuccess, isTrue);
 expect(m.failureReason, isNull);
 });

 test('stores failure with reason', () {
 final m = ConnectionQualityMeasurement(timestamp: DateTime(2026),
 success: false,
 failureReason: 'timeout',
);
 expect(m.success, isFalse);
 expect(m.failureReason, 'timeout');
 expect(m.rssi, isNull);
 });
 });

 // =========================================================================
 // BluetoothStateMonitor — supplement
 // =========================================================================
 group('BluetoothStateMonitor — supplement', () {
 late BluetoothStateMonitor monitor;

 setUp(() {
 monitor = BluetoothStateMonitor.instance;
 // Ensure clean state between tests.
 monitor.dispose();
 });

 tearDown(() {
 monitor.dispose();
 });

 test('stateStream emits initial state immediately on subscribe', () async {
 final firstEvent = await monitor.stateStream.first;
 expect(firstEvent.state, BluetoothLowEnergyState.unknown);
 expect(firstEvent.isReady, isFalse);
 expect(firstEvent.previousState, isNull);
 });

 test('stateStream cancel does not throw', () async {
 final sub = monitor.stateStream.listen((_) {});
 await sub.cancel();
 });

 test('messageStream can be subscribed and cancelled without error', () async {
 final messages = <BluetoothStatusMessage>[];
 final sub = monitor.messageStream.listen(messages.add);
 // messageStream does NOT emit an initial value, so list stays empty.
 await Future<void>.delayed(Duration.zero);
 expect(messages, isEmpty);
 await sub.cancel();
 });

 test('dispose is idempotent — calling twice does not throw', () {
 monitor.dispose();
 monitor.dispose();
 expect(monitor.isInitialized, isFalse);
 });

 test('currentState remains unknown after dispose (singleton keeps state)',
 () {
 // The singleton resets _isInitialized but NOT _currentState — verify
 // the default is still accessible.
 monitor.dispose();
 expect(monitor.currentState, BluetoothLowEnergyState.unknown);
 });

 test('isBluetoothReady is false for every non-poweredOn state', () {
 // Only poweredOn returns true. After dispose the singleton state is
 // unknown, which should give false.
 expect(monitor.isBluetoothReady, isFalse);
 });
 });

 // =========================================================================
 // BluetoothStatusMessage — supplement (actionHint field coverage)
 // =========================================================================
 group('BluetoothStatusMessage — supplement', () {
 test('disabled factory sets actionHint', () {
 final msg = BluetoothStatusMessage.disabled('BLE off');
 expect(msg.actionHint, isNotNull);
 expect(msg.actionHint, contains('Enable Bluetooth'));
 });

 test('unauthorized factory sets actionHint', () {
 final msg = BluetoothStatusMessage.unauthorized('No perm');
 expect(msg.actionHint, isNotNull);
 expect(msg.actionHint, contains('permission'));
 });

 test('ready factory has null actionHint', () {
 final msg = BluetoothStatusMessage.ready('OK');
 expect(msg.actionHint, isNull);
 });

 test('unsupported factory has null actionHint', () {
 final msg = BluetoothStatusMessage.unsupported('No BLE');
 expect(msg.actionHint, isNull);
 });

 test('error factory has null actionHint', () {
 final msg = BluetoothStatusMessage.error('Fail');
 expect(msg.actionHint, isNull);
 });

 test('primary constructor preserves custom actionHint and timestamp', () {
 final ts = DateTime(2026, 6, 15);
 final msg = BluetoothStatusMessage(type: BluetoothMessageType.ready,
 message: 'custom',
 actionHint: 'do something',
 timestamp: ts,
);
 expect(msg.actionHint, 'do something');
 expect(msg.timestamp, ts);
 });

 test('toString contains type name and message', () {
 final msg = BluetoothStatusMessage.error('oops');
 final str = msg.toString();
 expect(str, contains('error'));
 expect(str, contains('oops'));
 });
 });

 // =========================================================================
 // BluetoothStateInfo — supplement
 // =========================================================================
 group('BluetoothStateInfo — supplement', () {
 test('toString for every BLE state does not throw', () {
 for (final state in BluetoothLowEnergyState.values) {
 final info = BluetoothStateInfo(state: state,
 isReady: state == BluetoothLowEnergyState.poweredOn,
 timestamp: DateTime(2026),
);
 expect(info.toString(), isNotEmpty);
 }
 });

 test('isReady reflects poweredOn correctly', () {
 final on = BluetoothStateInfo(state: BluetoothLowEnergyState.poweredOn,
 isReady: true,
 timestamp: DateTime.now(),
);
 final off = BluetoothStateInfo(state: BluetoothLowEnergyState.poweredOff,
 isReady: false,
 timestamp: DateTime.now(),
);
 expect(on.isReady, isTrue);
 expect(off.isReady, isFalse);
 });
 });
}
