import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/domain/interfaces/i_ble_write_client.dart';

/// Default implementation of IBleWriteClient that delegates to the plugin APIs.
class BleWriteClient implements IBleWriteClient {
  @override
  Future<void> writeCentral({
    required CentralManager centralManager,
    required Peripheral device,
    required GATTCharacteristic characteristic,
    required List<int> value,
  }) async {
    await centralManager.writeCharacteristic(
      device,
      characteristic,
      value: Uint8List.fromList(value),
      type: GATTCharacteristicWriteType.withResponse,
    );
  }

  @override
  Future<void> writePeripheral({
    required PeripheralManager peripheralManager,
    required Central central,
    required GATTCharacteristic characteristic,
    required List<int> value,
    bool withoutResponse = true,
  }) async {
    if (withoutResponse) {
      await peripheralManager.notifyCharacteristic(
        central,
        characteristic,
        value: Uint8List.fromList(value),
      );
    } else {
      await peripheralManager.notifyCharacteristic(
        central,
        characteristic,
        value: Uint8List.fromList(value),
      );
    }
  }
}
