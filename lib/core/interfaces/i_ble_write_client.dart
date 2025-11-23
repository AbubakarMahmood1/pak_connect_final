import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Small seam to allow mocking BLE writes without importing plugin base classes.
abstract interface class IBleWriteClient {
  Future<void> writeCentral({
    required CentralManager centralManager,
    required Peripheral device,
    required GATTCharacteristic characteristic,
    required List<int> value,
  });

  Future<void> writePeripheral({
    required PeripheralManager peripheralManager,
    required Central central,
    required GATTCharacteristic characteristic,
    required List<int> value,
    bool withoutResponse,
  });
}
