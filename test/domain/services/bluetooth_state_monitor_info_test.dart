/// BluetoothStateMonitor & bluetooth_state_models tests.
///
/// The monitor uses a singleton with hardcoded BLE platform deps, so only
/// the data-model layer and the default-state getters are testable without
/// hardware. We cover BluetoothStateInfo, BluetoothStatusMessage factories,
/// and the singleton's pre-init getters.
library;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';

void main() {
 // -----------------------------------------------------------------------
 // BluetoothStateInfo
 // -----------------------------------------------------------------------
 group('BluetoothStateInfo', () {
 test('stores fields and formats toString', () {
 final info = BluetoothStateInfo(state: BluetoothLowEnergyState.poweredOn,
 previousState: BluetoothLowEnergyState.unknown,
 isReady: true,
 timestamp: DateTime(2026, 1, 1),
);

 expect(info.state, BluetoothLowEnergyState.poweredOn);
 expect(info.previousState, BluetoothLowEnergyState.unknown);
 expect(info.isReady, isTrue);
 expect(info.toString(), contains('poweredOn'));
 expect(info.toString(), contains('ready: true'));
 });

 test('previousState defaults to null', () {
 final info = BluetoothStateInfo(state: BluetoothLowEnergyState.poweredOff,
 isReady: false,
 timestamp: DateTime(2026),
);
 expect(info.previousState, isNull);
 });
 });

 // -----------------------------------------------------------------------
 // BluetoothStatusMessage
 // -----------------------------------------------------------------------
 group('BluetoothStatusMessage', () {
 test('primary constructor stores fields', () {
 final msg = BluetoothStatusMessage(type: BluetoothMessageType.ready,
 message: 'BLE ready',
 actionHint: 'tap to scan',
 timestamp: DateTime(2026),
);
 expect(msg.type, BluetoothMessageType.ready);
 expect(msg.message, 'BLE ready');
 expect(msg.actionHint, 'tap to scan');
 expect(msg.toString(), contains('ready'));
 });

 test('.ready factory sets correct type', () {
 final msg = BluetoothStatusMessage.ready('all good');
 expect(msg.type, BluetoothMessageType.ready);
 expect(msg.message, 'all good');
 });

 test('.disabled factory sets correct type', () {
 final msg = BluetoothStatusMessage.disabled('BLE off');
 expect(msg.type, BluetoothMessageType.disabled);
 });

 test('.unauthorized factory sets correct type', () {
 final msg = BluetoothStatusMessage.unauthorized('no perm');
 expect(msg.type, BluetoothMessageType.unauthorized);
 });

 test('.unsupported factory sets correct type', () {
 final msg = BluetoothStatusMessage.unsupported('no BLE');
 expect(msg.type, BluetoothMessageType.unsupported);
 });

 test('.unknown factory sets correct type', () {
 final msg = BluetoothStatusMessage.unknown('??');
 expect(msg.type, BluetoothMessageType.unknown);
 });

 test('.initializing factory sets correct type', () {
 final msg = BluetoothStatusMessage.initializing('starting');
 expect(msg.type, BluetoothMessageType.initializing);
 });

 test('.error factory sets correct type', () {
 final msg = BluetoothStatusMessage.error('fail');
 expect(msg.type, BluetoothMessageType.error);
 });
 });

 // -----------------------------------------------------------------------
 // BluetoothMessageType enum
 // -----------------------------------------------------------------------
 group('BluetoothMessageType', () {
 test('has all expected values', () {
 expect(BluetoothMessageType.values, containsAll([
 BluetoothMessageType.ready,
 BluetoothMessageType.disabled,
 BluetoothMessageType.unauthorized,
 BluetoothMessageType.unsupported,
 BluetoothMessageType.unknown,
 BluetoothMessageType.initializing,
 BluetoothMessageType.error,
]));
 });
 });

 // -----------------------------------------------------------------------
 // BluetoothStateMonitor singleton
 // -----------------------------------------------------------------------
 group('BluetoothStateMonitor singleton', () {
 test('instance and factory return same object', () {
 final a = BluetoothStateMonitor.instance;
 final b = BluetoothStateMonitor();
 expect(identical(a, b), isTrue);
 });

 test('pre-init getters return safe defaults', () {
 final monitor = BluetoothStateMonitor.instance;
 expect(monitor.currentState, BluetoothLowEnergyState.unknown);
 expect(monitor.isBluetoothReady, isFalse);
 // isInitialized may be true if another test called initialize —
 // just verify it does not throw
 monitor.isInitialized;
 });

 test('dispose resets isInitialized', () {
 final monitor = BluetoothStateMonitor.instance;
 monitor.dispose();
 expect(monitor.isInitialized, isFalse);
 });
 });
}
