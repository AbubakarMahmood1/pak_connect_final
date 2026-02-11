import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';

/// Registers no-op BLE platform managers so tests can instantiate [BLEService]
/// without hitting platform channels (which are unavailable in `flutter test`).
class FakeBlePlatform {
  static bool _registered = false;

  static void ensureRegistered() {
    if (_registered) return;

    CentralManagerChannel.instance = _FakeCentralManagerChannel();
    PeripheralManagerChannel.instance = _FakePeripheralManagerChannel();
    _registered = true;
  }
}

final class _FakeCentralManagerChannel extends CentralManagerChannel {
  final CentralManager _manager = _FakeCentralManager();

  @override
  CentralManager create() => _manager;
}

final class _FakePeripheralManagerChannel extends PeripheralManagerChannel {
  final PeripheralManager _manager = _FakePeripheralManager();

  @override
  PeripheralManager create() => _manager;
}

final class _FakePeripheral implements Peripheral {
  const _FakePeripheral(this.uuid);

  @override
  final UUID uuid;
}

final class _FakeCentral implements Central {
  const _FakeCentral(this.uuid);

  @override
  final UUID uuid;
}

UUID _uuidFromAddress(String address) {
  try {
    return UUID.fromString(address);
  } catch (_) {
    final bytes = List<int>.filled(16, 0);
    final codeUnits = address.codeUnits;
    for (var i = 0; i < codeUnits.length; i++) {
      bytes[i % 16] = (bytes[i % 16] + codeUnits[i]) & 0xFF;
    }
    return UUID(bytes);
  }
}

final class _FakeCentralManager implements CentralManager {
  final _stateController =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final _discoveredController =
      StreamController<DiscoveredEventArgs>.broadcast();
  final _connectionStateController =
      StreamController<PeripheralConnectionStateChangedEventArgs>.broadcast();
  final _mtuController =
      StreamController<PeripheralMTUChangedEventArgs>.broadcast();
  final _notifyController =
      StreamController<GATTCharacteristicNotifiedEventArgs>.broadcast();

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateController.stream;

  @override
  Future<bool> authorize() async => true;

  @override
  Future<void> showAppSettings() async {}

  @override
  Stream<DiscoveredEventArgs> get discovered => _discoveredController.stream;

  @override
  Stream<PeripheralConnectionStateChangedEventArgs>
  get connectionStateChanged => _connectionStateController.stream;

  @override
  Stream<PeripheralMTUChangedEventArgs> get mtuChanged => _mtuController.stream;

  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      _notifyController.stream;

  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<Peripheral> getPeripheral(String address) async =>
      _FakePeripheral(_uuidFromAddress(address));

  @override
  Future<List<Peripheral>> retrieveConnectedPeripherals() async => const [];

  @override
  Future<void> connect(Peripheral peripheral) async {}

  @override
  Future<void> disconnect(Peripheral peripheral) async {}

  @override
  Future<int> requestMTU(Peripheral peripheral, {required int mtu}) async =>
      mtu;

  @override
  Future<int> getMaximumWriteLength(
    Peripheral peripheral, {
    required GATTCharacteristicWriteType type,
  }) async => 512;

  @override
  Future<int> readRSSI(Peripheral peripheral) async => -60;

  @override
  Future<List<GATTService>> discoverGATT(Peripheral peripheral) async =>
      const [];

  @override
  Future<Uint8List> readCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
  ) async => Uint8List(0);

  @override
  Future<void> writeCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required Uint8List value,
    required GATTCharacteristicWriteType type,
  }) async {}

  @override
  Future<void> setCharacteristicNotifyState(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required bool state,
  }) async {}

  @override
  Future<Uint8List> readDescriptor(
    Peripheral peripheral,
    GATTDescriptor descriptor,
  ) async => Uint8List(0);

  @override
  Future<void> writeDescriptor(
    Peripheral peripheral,
    GATTDescriptor descriptor, {
    required Uint8List value,
  }) async {}
}

final class _FakePeripheralManager implements PeripheralManager {
  final _stateController =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final _connectionStateController =
      StreamController<CentralConnectionStateChangedEventArgs>.broadcast();
  final _mtuController =
      StreamController<CentralMTUChangedEventArgs>.broadcast();
  final _charReadController =
      StreamController<GATTCharacteristicReadRequestedEventArgs>.broadcast();
  final _charWriteController =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final _notifyController =
      StreamController<
        GATTCharacteristicNotifyStateChangedEventArgs
      >.broadcast();
  final _descReadController =
      StreamController<GATTDescriptorReadRequestedEventArgs>.broadcast();
  final _descWriteController =
      StreamController<GATTDescriptorWriteRequestedEventArgs>.broadcast();

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateController.stream;

  @override
  Future<bool> authorize() async => true;

  @override
  Future<void> showAppSettings() async {}

  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged =>
      _connectionStateController.stream;

  @override
  Stream<CentralMTUChangedEventArgs> get mtuChanged => _mtuController.stream;

  @override
  Stream<GATTCharacteristicReadRequestedEventArgs>
  get characteristicReadRequested => _charReadController.stream;

  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested => _charWriteController.stream;

  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged => _notifyController.stream;

  @override
  Stream<GATTDescriptorReadRequestedEventArgs> get descriptorReadRequested =>
      _descReadController.stream;

  @override
  Stream<GATTDescriptorWriteRequestedEventArgs> get descriptorWriteRequested =>
      _descWriteController.stream;

  @override
  Future<void> addService(GATTService service) async {}

  @override
  Future<void> removeService(GATTService service) async {}

  @override
  Future<void> removeAllServices() async {}

  @override
  Future<void> startAdvertising(Advertisement advertisement) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<Central> getCentral(String address) async =>
      _FakeCentral(_uuidFromAddress(address));

  @override
  Future<List<Central>> retrieveConnectedCentrals() async => const [];

  @override
  Future<void> disconnect(Central central) async {}

  @override
  Future<int> getMaximumNotifyLength(Central central) async => 512;

  @override
  Future<void> respondReadRequestWithValue(
    GATTReadRequest request, {
    required Uint8List value,
  }) async {}

  @override
  Future<void> respondReadRequestWithError(
    GATTReadRequest request, {
    required GATTError error,
  }) async {}

  @override
  Future<void> respondWriteRequest(GATTWriteRequest request) async {}

  @override
  Future<void> respondWriteRequestWithError(
    GATTWriteRequest request, {
    required GATTError error,
  }) async {}

  @override
  Future<void> notifyCharacteristic(
    Central central,
    GATTCharacteristic characteristic, {
    required Uint8List value,
  }) async {}
}
