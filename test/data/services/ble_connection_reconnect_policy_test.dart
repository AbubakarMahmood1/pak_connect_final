import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/ble_connection_reconnect_policy.dart';

import '../../helpers/ble/ble_fakes.dart';

void main() {
  test('power-off cleanup preserves the connected reconnect target', () {
    final target = fakePeripheralFromString(
      '00000000-0000-0000-0000-000000000901',
    );
    Peripheral? storedTarget;
    final policy = BleConnectionReconnectPolicy(
      logger: Logger('BleConnectionReconnectPolicyTest'),
    );

    policy.handleBluetoothStateChange(
      state: BluetoothLowEnergyState.poweredOff,
      hasBleConnection: true,
      connectedDevice: target,
      lastConnectedDevice: null,
      setLastConnectedDevice: (device) => storedTarget = device,
      setReconnectionFlag: (_) {},
      startConnectionMonitoring: () {},
      stopConnectionMonitoring: () {},
      clearConnectionState: ({bool keepMonitoring = false}) {
        storedTarget = null;
      },
    );

    expect(storedTarget, same(target));
  });

  test('power-off preserves an existing target without an active link', () {
    final target = fakePeripheralFromString(
      '00000000-0000-0000-0000-000000000902',
    );
    Peripheral? storedTarget = target;
    final policy = BleConnectionReconnectPolicy(
      logger: Logger('BleConnectionReconnectPolicyTest'),
    );

    policy.handleBluetoothStateChange(
      state: BluetoothLowEnergyState.poweredOff,
      hasBleConnection: false,
      connectedDevice: null,
      lastConnectedDevice: target,
      setLastConnectedDevice: (device) => storedTarget = device,
      setReconnectionFlag: (_) {},
      startConnectionMonitoring: () {},
      stopConnectionMonitoring: () {},
      clearConnectionState: ({bool keepMonitoring = false}) {
        storedTarget = null;
      },
    );

    expect(storedTarget, same(target));
  });

  test('power-off cancels a pending power-on restart', () {
    fakeAsync((async) {
      final target = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000903',
      );
      final policy = BleConnectionReconnectPolicy(
        logger: Logger('BleConnectionReconnectPolicyTest'),
      );
      var starts = 0;

      void handle(BluetoothLowEnergyState state) {
        policy.handleBluetoothStateChange(
          state: state,
          hasBleConnection: false,
          connectedDevice: null,
          lastConnectedDevice: target,
          setLastConnectedDevice: (_) {},
          setReconnectionFlag: (_) {},
          startConnectionMonitoring: () => starts++,
          stopConnectionMonitoring: () {},
          clearConnectionState: ({bool keepMonitoring = false}) {},
        );
      }

      handle(BluetoothLowEnergyState.poweredOn);
      handle(BluetoothLowEnergyState.poweredOff);
      async.elapse(const Duration(seconds: 1));

      expect(starts, 0);
    });
  });

  test('dispose cancels a pending power-on restart', () {
    fakeAsync((async) {
      final target = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000904',
      );
      final policy = BleConnectionReconnectPolicy(
        logger: Logger('BleConnectionReconnectPolicyTest'),
      );
      var starts = 0;

      policy.handleBluetoothStateChange(
        state: BluetoothLowEnergyState.poweredOn,
        hasBleConnection: false,
        connectedDevice: null,
        lastConnectedDevice: target,
        setLastConnectedDevice: (_) {},
        setReconnectionFlag: (_) {},
        startConnectionMonitoring: () => starts++,
        stopConnectionMonitoring: () {},
        clearConnectionState: ({bool keepMonitoring = false}) {},
      );
      policy.dispose();
      async.elapse(const Duration(seconds: 1));

      expect(starts, 0);
    });
  });

  test('explicit cancellation prevents a pending power-on restart', () {
    fakeAsync((async) {
      final target = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000905',
      );
      final policy = BleConnectionReconnectPolicy(
        logger: Logger('BleConnectionReconnectPolicyTest'),
      );
      var starts = 0;

      policy.handleBluetoothStateChange(
        state: BluetoothLowEnergyState.poweredOn,
        hasBleConnection: false,
        connectedDevice: null,
        lastConnectedDevice: target,
        setLastConnectedDevice: (_) {},
        setReconnectionFlag: (_) {},
        startConnectionMonitoring: () => starts++,
        stopConnectionMonitoring: () {},
        clearConnectionState: ({bool keepMonitoring = false}) {},
      );
      policy.cancelPendingReconnect();
      async.elapse(const Duration(seconds: 1));

      expect(starts, 0);
    });
  });
}
