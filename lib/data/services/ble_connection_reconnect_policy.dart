import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

class BleConnectionReconnectPolicy {
  BleConnectionReconnectPolicy({required Logger logger}) : _logger = logger;

  final Logger _logger;

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
    if (state == BluetoothLowEnergyState.poweredOn) {
      if (lastConnectedDevice != null && !hasBleConnection) {
        _logger.info('Bluetooth powered on - starting immediate reconnection');

        stopConnectionMonitoring();
        Timer(const Duration(milliseconds: 800), () {
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
      if (hasBleConnection) {
        _logger.info(
          'Bluetooth powered off - preserving device for reconnection',
        );
        setLastConnectedDevice(connectedDevice);
      }
      clearConnectionState(keepMonitoring: false);
    }
  }
}
