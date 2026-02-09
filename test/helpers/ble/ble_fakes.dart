import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Fake UUID builder that uses a fixed-length byte list.
UUID makeUuid(int seed) {
  final bytes = List<int>.generate(16, (i) => (seed + i) & 0xFF);
  return UUID(bytes);
}

FakePeripheral fakePeripheralFromString(String uuid) =>
    FakePeripheral(uuid: UUID.fromString(uuid));

FakeCentral fakeCentralFromString(String uuid) =>
    FakeCentral(uuid: UUID.fromString(uuid));

/// Minimal fake peripheral for tests.
final class FakePeripheral implements Peripheral {
  const FakePeripheral({required this.uuid});

  @override
  final UUID uuid;
}

/// Minimal fake central for tests.
final class FakeCentral implements Central {
  const FakeCentral({required this.uuid});

  @override
  final UUID uuid;
}

/// Minimal fake characteristic for tests.
final class FakeGATTCharacteristic implements GATTCharacteristic {
  FakeGATTCharacteristic({
    UUID? uuid,
    List<GATTCharacteristicProperty>? properties,
    List<GATTDescriptor>? descriptors,
  }) : uuid = uuid ?? makeUuid(0),
       properties = properties ?? const <GATTCharacteristicProperty>[],
       descriptors = descriptors ?? const <GATTDescriptor>[];

  @override
  final UUID uuid;

  @override
  final List<GATTCharacteristicProperty> properties;

  @override
  final List<GATTDescriptor> descriptors;
}
