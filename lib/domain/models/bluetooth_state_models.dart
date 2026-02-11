import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Information about current Bluetooth state.
class BluetoothStateInfo {
  final BluetoothLowEnergyState state;
  final BluetoothLowEnergyState? previousState;
  final bool isReady;
  final DateTime timestamp;

  const BluetoothStateInfo({
    required this.state,
    this.previousState,
    required this.isReady,
    required this.timestamp,
  });

  @override
  String toString() => 'BluetoothStateInfo(state: $state, ready: $isReady)';
}

/// User-friendly Bluetooth status messages.
class BluetoothStatusMessage {
  final BluetoothMessageType type;
  final String message;
  final String? actionHint;
  final DateTime timestamp;

  const BluetoothStatusMessage({
    required this.type,
    required this.message,
    this.actionHint,
    required this.timestamp,
  });

  factory BluetoothStatusMessage.ready(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.ready,
        message: message,
        timestamp: DateTime.now(),
      );

  factory BluetoothStatusMessage.disabled(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.disabled,
        message: message,
        actionHint: 'Enable Bluetooth in device settings',
        timestamp: DateTime.now(),
      );

  factory BluetoothStatusMessage.unauthorized(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.unauthorized,
        message: message,
        actionHint: 'Grant Bluetooth permission in app settings',
        timestamp: DateTime.now(),
      );

  factory BluetoothStatusMessage.unsupported(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.unsupported,
        message: message,
        timestamp: DateTime.now(),
      );

  factory BluetoothStatusMessage.unknown(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.unknown,
        message: message,
        timestamp: DateTime.now(),
      );

  factory BluetoothStatusMessage.initializing(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.initializing,
        message: message,
        timestamp: DateTime.now(),
      );

  factory BluetoothStatusMessage.error(String message) =>
      BluetoothStatusMessage(
        type: BluetoothMessageType.error,
        message: message,
        timestamp: DateTime.now(),
      );

  @override
  String toString() => 'BluetoothStatusMessage(${type.name}: $message)';
}

/// Types of Bluetooth status messages.
enum BluetoothMessageType {
  ready,
  disabled,
  unauthorized,
  unsupported,
  unknown,
  initializing,
  error,
}
