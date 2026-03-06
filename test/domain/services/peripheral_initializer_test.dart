import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/peripheral_initializer.dart';

void main() {
  group('PeripheralInitializer', () {
    late _FakePeripheralManager manager;
    late PeripheralInitializer initializer;

    setUp(() {
      manager = _FakePeripheralManager();
      initializer = PeripheralInitializer(manager);
    });

    test('waitUntilReady succeeds when bluetooth is powered on', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOn;

      final ready = await initializer.waitUntilReady(
        timeout: const Duration(milliseconds: 50),
      );

      expect(ready, isTrue);
      expect(initializer.isReady, isTrue);
    });

    test('waitUntilReady fails fast when bluetooth state is unusable', () async {
      manager.currentState = BluetoothLowEnergyState.unauthorized;

      final ready = await initializer.waitUntilReady(
        timeout: const Duration(milliseconds: 50),
      );

      expect(ready, isFalse);
      expect(initializer.isReady, isFalse);
    });

    test('waitUntilReady handles timeout when state access keeps failing', () async {
      manager.throwOnStateRead = true;

      final ready = await initializer.waitUntilReady(
        timeout: const Duration(milliseconds: 120),
      );

      expect(ready, isFalse);
      expect(initializer.isReady, isFalse);
    });

    test('safelyAddService removes existing services and adds service', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOn;

      final result = await initializer.safelyAddService(_service());

      expect(result, isTrue);
      expect(manager.removeAllServicesCalls, 1);
      expect(manager.addServiceCalls, 1);
    });

    test('safelyAddService tolerates remove failure but fails on add error', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOn;
      manager.throwOnRemoveAllServices = true;
      manager.throwOnAddService = true;

      final result = await initializer.safelyAddService(_service());

      expect(result, isFalse);
      expect(manager.removeAllServicesCalls, 1);
      expect(manager.addServiceCalls, 1);
    });

    test('safelyAddService returns false when peripheral is not ready', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOff;

      final result = await initializer.safelyAddService(
        _service(),
        timeout: const Duration(milliseconds: 50),
      );

      expect(result, isFalse);
      expect(manager.addServiceCalls, 0);
    });

    test('safelyStartAdvertising starts advertising and optionally stops prior session', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOn;
      final ad = _advertisement();

      final withStop = await initializer.safelyStartAdvertising(ad);
      final stopCallsAfterFirst = manager.stopAdvertisingCalls;
      final withoutStop = await initializer.safelyStartAdvertising(
        ad,
        skipIfAlreadyAdvertising: false,
      );

      expect(withStop, isTrue);
      expect(withoutStop, isTrue);
      expect(manager.startAdvertisingCalls, 2);
      expect(stopCallsAfterFirst, 1);
      expect(manager.stopAdvertisingCalls, 1);
    });

    test('safelyStartAdvertising handles stop and start failures', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOn;
      manager.throwOnStopAdvertising = true;

      final recoverable = await initializer.safelyStartAdvertising(
        _advertisement(),
      );
      expect(recoverable, isTrue);

      manager.throwOnStartAdvertising = true;
      final failed = await initializer.safelyStartAdvertising(_advertisement());
      expect(failed, isFalse);
    });

    test('reset clears ready state', () async {
      manager.currentState = BluetoothLowEnergyState.poweredOn;
      await initializer.waitUntilReady(timeout: const Duration(milliseconds: 50));
      expect(initializer.isReady, isTrue);

      initializer.reset();
      expect(initializer.isReady, isFalse);
    });
  });
}

Advertisement _advertisement() {
  return Advertisement(
    name: 'PakConnect',
    serviceUUIDs: <UUID>[UUID.fromString('0000180F-0000-1000-8000-00805F9B34FB')],
    manufacturerSpecificData: <ManufacturerSpecificData>[
      ManufacturerSpecificData(id: 0x1234, data: Uint8List.fromList(<int>[1, 2])),
    ],
  );
}

GATTService _service() {
  return GATTService(
    uuid: UUID.fromString('0000180A-0000-1000-8000-00805F9B34FB'),
    isPrimary: true,
    includedServices: const <GATTService>[],
    characteristics: const <GATTCharacteristic>[],
  );
}

class _FakePeripheralManager extends Fake implements PeripheralManager {
  BluetoothLowEnergyState currentState = BluetoothLowEnergyState.poweredOn;
  bool throwOnStateRead = false;
  bool throwOnRemoveAllServices = false;
  bool throwOnAddService = false;
  bool throwOnStopAdvertising = false;
  bool throwOnStartAdvertising = false;
  int removeAllServicesCalls = 0;
  int addServiceCalls = 0;
  int stopAdvertisingCalls = 0;
  int startAdvertisingCalls = 0;

  @override
  BluetoothLowEnergyState get state {
    if (throwOnStateRead) {
      throw StateError('manager not initialized');
    }
    return currentState;
  }

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      const Stream<BluetoothLowEnergyStateChangedEventArgs>.empty();

  @override
  Future<bool> authorize() async => true;

  @override
  Future<void> showAppSettings() async {}

  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged =>
      const Stream<CentralConnectionStateChangedEventArgs>.empty();

  @override
  Stream<CentralMTUChangedEventArgs> get mtuChanged =>
      const Stream<CentralMTUChangedEventArgs>.empty();

  @override
  Stream<GATTCharacteristicReadRequestedEventArgs>
  get characteristicReadRequested =>
      const Stream<GATTCharacteristicReadRequestedEventArgs>.empty();

  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested =>
      const Stream<GATTCharacteristicWriteRequestedEventArgs>.empty();

  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged =>
      const Stream<GATTCharacteristicNotifyStateChangedEventArgs>.empty();

  @override
  Stream<GATTDescriptorReadRequestedEventArgs> get descriptorReadRequested =>
      const Stream<GATTDescriptorReadRequestedEventArgs>.empty();

  @override
  Stream<GATTDescriptorWriteRequestedEventArgs> get descriptorWriteRequested =>
      const Stream<GATTDescriptorWriteRequestedEventArgs>.empty();

  @override
  Future<void> addService(GATTService service) async {
    addServiceCalls++;
    if (throwOnAddService) {
      throw StateError('add failed');
    }
  }

  @override
  Future<void> removeAllServices() async {
    removeAllServicesCalls++;
    if (throwOnRemoveAllServices) {
      throw StateError('remove failed');
    }
  }

  @override
  Future<void> startAdvertising(Advertisement advertisement) async {
    startAdvertisingCalls++;
    if (throwOnStartAdvertising) {
      throw StateError('start failed');
    }
  }

  @override
  Future<void> stopAdvertising() async {
    stopAdvertisingCalls++;
    if (throwOnStopAdvertising) {
      throw StateError('stop failed');
    }
  }
}
