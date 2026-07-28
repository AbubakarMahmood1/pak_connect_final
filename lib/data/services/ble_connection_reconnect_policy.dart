import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

class BleConnectionReconnectPolicy {
  BleConnectionReconnectPolicy({required Logger logger}) : _logger = logger;

  final Logger _logger;
  Timer? _powerOnReconnectTimer;

  void cancelPendingReconnect() {
    _powerOnReconnectTimer?.cancel();
    _powerOnReconnectTimer = null;
  }

  void handleBluetoothStateChange({
    required BluetoothLowEnergyState state,
    required bool hasBleConnection,
    required Peripheral? connectedDevice,
    required Peripheral? lastConnectedDevice,
    required void Function(Peripheral? device) setLastConnectedDevice,
    required void Function(bool value) setReconnectionFlag,
    required void Function() startConnectionMonitoring,
    required void Function() stopConnectionMonitoring,
    required void Function({bool keepMonitoring}) clearConnectionState,
  }) {
    cancelPendingReconnect();

    if (state == BluetoothLowEnergyState.poweredOn) {
      if (lastConnectedDevice != null && !hasBleConnection) {
        _logger.info('Bluetooth powered on - starting immediate reconnection');

        stopConnectionMonitoring();
        _powerOnReconnectTimer = Timer(const Duration(milliseconds: 800), () {
          _powerOnReconnectTimer = null;
          setReconnectionFlag(true);
          startConnectionMonitoring();
        });
      } else {
        _logger.info(
          'Bluetooth powered on - no previous device, skipping reconnection',
        );
      }
      return;
    }

    if (state == BluetoothLowEnergyState.poweredOff) {
      final reconnectTarget = connectedDevice ?? lastConnectedDevice;
      if (reconnectTarget != null) {
        _logger.info(
          'Bluetooth powered off - preserving device for reconnection',
        );
      }
      clearConnectionState(keepMonitoring: false);
      setLastConnectedDevice(reconnectTarget);
    }
  }

  void dispose() => cancelPendingReconnect();
}
