import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';

/// Provider for BluetoothStateMonitor singleton
final bluetoothStateMonitorProvider = Provider.autoDispose<BluetoothStateMonitor>((
  ref,
) {
  final monitor = BluetoothStateMonitor.instance;
  ref.onDispose(() {
    // Note: BluetoothStateMonitor is a singleton, managed at app lifecycle level
  });
  return monitor;
});

/// Stream provider for Bluetooth state changes
final bluetoothStateStreamProvider =
    StreamProvider.autoDispose<BluetoothStateInfo>((ref) async* {
      final monitor = ref.watch(bluetoothStateMonitorProvider);
      yield BluetoothStateInfo(
        state: monitor.currentState,
        previousState: monitor.currentState,
        isReady: monitor.isBluetoothReady,
        timestamp: DateTime.now(),
      );
      yield* monitor.stateStream;
    });

/// Stream provider for Bluetooth status messages
final bluetoothStatusMessageStreamProvider =
    StreamProvider.autoDispose<BluetoothStatusMessage>((ref) async* {
      final monitor = ref.watch(bluetoothStateMonitorProvider);
      yield* monitor.messageStream;
    });
