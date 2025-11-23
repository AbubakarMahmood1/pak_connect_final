import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Fake UUID builder that uses a fixed-length byte list.
UUID makeUuid(int seed) {
  final bytes = List<int>.generate(16, (i) => (seed + i) & 0xFF);
  return UUID(bytes);
}

/// Minimal fake characteristic satisfying the base class requirements.
base class FakeGATTCharacteristic extends GATTCharacteristic {
  FakeGATTCharacteristic({UUID? uuid})
    : super(
        uuid: uuid ?? makeUuid(0),
        properties: const <GATTCharacteristicProperty>[],
        descriptors: const <GATTDescriptor>[],
      );
}
