import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Represents a BLE connection where we acted as CENTRAL (connected TO a peripheral device).
///
/// This connection was initiated by us - we discovered the device and connected to it.
/// The remote device was acting as a peripheral (GATT server).
class BLEClientConnection {
  /// Remote device MAC address
  final String address;

  /// The peripheral we connected to
  final Peripheral peripheral;

  /// When this connection was established
  final DateTime connectedAt;

  /// Optional: Discovered GATT services/characteristics
  final List<GATTService>? discoveredServices;

  /// Optional: The message characteristic we're using for communication
  final GATTCharacteristic? messageCharacteristic;

  /// Optional: Current RSSI (signal strength)
  int? rssi;

  /// Optional: Current MTU size
  int? mtu;

  BLEClientConnection({
    required this.address,
    required this.peripheral,
    required this.connectedAt,
    this.discoveredServices,
    this.messageCharacteristic,
    this.rssi,
    this.mtu,
  });

  /// Duration since connection was established
  Duration get connectedDuration => DateTime.now().difference(connectedAt);

  /// Copy with updated fields
  BLEClientConnection copyWith({
    String? address,
    Peripheral? peripheral,
    DateTime? connectedAt,
    List<GATTService>? discoveredServices,
    GATTCharacteristic? messageCharacteristic,
    int? rssi,
    int? mtu,
  }) {
    return BLEClientConnection(
      address: address ?? this.address,
      peripheral: peripheral ?? this.peripheral,
      connectedAt: connectedAt ?? this.connectedAt,
      discoveredServices: discoveredServices ?? this.discoveredServices,
      messageCharacteristic:
          messageCharacteristic ?? this.messageCharacteristic,
      rssi: rssi ?? this.rssi,
      mtu: mtu ?? this.mtu,
    );
  }

  @override
  String toString() {
    return 'BLEClientConnection(address: $address, connectedFor: ${connectedDuration.inSeconds}s, rssi: $rssi)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BLEClientConnection && other.address == address;
  }

  @override
  int get hashCode => address.hashCode;
}
