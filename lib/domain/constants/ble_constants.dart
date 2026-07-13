import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

class BLEConstants {
  // PakConnect's application-specific GATT UUIDs.
  //
  // Random UUIDv4 base (generated, not a sequential placeholder) with the
  // three roles distinguished by the final nibble. A random base avoids
  // colliding with the many apps/tutorials that use the "12345678-1234-..."
  // sample UUID for scanning/advertising. Both peers must share these values,
  // so change them only in lockstep across all devices.
  static final serviceUUID = UUID.fromString(
    'effb4bc7-485c-4b47-8666-e1cca40d84e0',
  );

  // Characteristic UUIDs
  static final messageCharacteristicUUID = UUID.fromString(
    'effb4bc7-485c-4b47-8666-e1cca40d84e1',
  );
  static final nameCharacteristicUUID = UUID.fromString(
    'effb4bc7-485c-4b47-8666-e1cca40d84e2',
  );

  // Connection timeouts
  static const Duration connectionTimeout = Duration(seconds: 10);
  static const Duration scanTimeout = Duration(seconds: 30);

  // Message settings
  static const int maxMessageLength = 244; // Safe BLE packet size
}
