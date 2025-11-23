import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/core/interfaces/i_ble_write_client.dart';

class FakeBleWriteClient implements IBleWriteClient {
  bool throwCentral = false;
  bool throwPeripheral = false;

  CentralManager? lastCentralManager;
  Peripheral? lastPeripheral;
  GATTCharacteristic? lastCentralCharacteristic;
  Uint8List? lastCentralValue;

  PeripheralManager? lastPeripheralManager;
  Central? lastCentral;
  GATTCharacteristic? lastPeripheralCharacteristic;
  Uint8List? lastPeripheralValue;
  bool? lastWithoutResponse;

  @override
  Future<void> writeCentral({
    required CentralManager centralManager,
    required Peripheral device,
    required GATTCharacteristic characteristic,
    required List<int> value,
  }) async {
    if (throwCentral) throw Exception('central boom');
    lastCentralManager = centralManager;
    lastPeripheral = device;
    lastCentralCharacteristic = characteristic;
    lastCentralValue = Uint8List.fromList(value);
  }

  @override
  Future<void> writePeripheral({
    required PeripheralManager peripheralManager,
    required Central central,
    required GATTCharacteristic characteristic,
    required List<int> value,
    bool withoutResponse = true,
  }) async {
    if (throwPeripheral) throw Exception('peripheral boom');
    lastPeripheralManager = peripheralManager;
    lastCentral = central;
    lastPeripheralCharacteristic = characteristic;
    lastPeripheralValue = Uint8List.fromList(value);
    lastWithoutResponse = withoutResponse;
  }
}
