import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

class BLEConstants {
  // Our custom service UUID for messaging
  static final serviceUUID = UUID.fromString('12345678-1234-1234-1234-123456789abc');
  
  // Characteristic UUIDs
  static final messageCharacteristicUUID = UUID.fromString('12345678-1234-1234-1234-123456789abd');
  static final nameCharacteristicUUID = UUID.fromString('12345678-1234-1234-1234-123456789abe');
  
  // Connection timeouts
  static const Duration connectionTimeout = Duration(seconds: 10);
  static const Duration scanTimeout = Duration(seconds: 30);
  
  // Message settings
  static const int maxMessageLength = 244; // Safe BLE packet size
}