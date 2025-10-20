import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Represents a BLE connection where we acted as PERIPHERAL (device connected TO us).
///
/// This connection was initiated by a remote central - they discovered us and connected.
/// We were acting as a peripheral (GATT server) advertising our mesh service.
class BLEServerConnection {
  /// Remote central MAC address
  final String address;

  /// The central that connected to us
  final Central central;

  /// When this connection was established
  final DateTime connectedAt;

  /// Optional: The characteristic they subscribed to (for notifications)
  final GATTCharacteristic? subscribedCharacteristic;

  /// Optional: Current MTU size
  int? mtu;

  BLEServerConnection({
    required this.address,
    required this.central,
    required this.connectedAt,
    this.subscribedCharacteristic,
    this.mtu,
  });

  /// Duration since connection was established
  Duration get connectedDuration => DateTime.now().difference(connectedAt);

  /// Whether the central has subscribed to notifications
  bool get isSubscribed => subscribedCharacteristic != null;

  /// Copy with updated fields
  BLEServerConnection copyWith({
    String? address,
    Central? central,
    DateTime? connectedAt,
    GATTCharacteristic? subscribedCharacteristic,
    int? mtu,
  }) {
    return BLEServerConnection(
      address: address ?? this.address,
      central: central ?? this.central,
      connectedAt: connectedAt ?? this.connectedAt,
      subscribedCharacteristic: subscribedCharacteristic ?? this.subscribedCharacteristic,
      mtu: mtu ?? this.mtu,
    );
  }

  @override
  String toString() {
    return 'BLEServerConnection(address: $address, connectedFor: ${connectedDuration.inSeconds}s, subscribed: $isSubscribed)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BLEServerConnection && other.address == address;
  }

  @override
  int get hashCode => address.hashCode;
}
