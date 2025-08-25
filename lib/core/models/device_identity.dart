import 'dart:convert';
import 'dart:typed_data';

class DeviceIdentity {
  final String persistentId;
  final String displayName;
  final DateTime timestamp;

  DeviceIdentity({
    required this.persistentId,
    required this.displayName,
    required this.timestamp,
  });

  // Protocol: "IDENTITY:persistentId:displayName"
  Uint8List toBytes() {
    final identityString = 'IDENTITY:$persistentId:$displayName';
    return Uint8List.fromList(utf8.encode(identityString));
  }

  static DeviceIdentity? fromBytes(Uint8List bytes) {
    try {
      final message = utf8.decode(bytes);
      if (message.startsWith('IDENTITY:')) {
        final parts = message.substring(9).split(':'); // Remove "IDENTITY:" prefix
        if (parts.length >= 2) {
          return DeviceIdentity(
            persistentId: parts[0],
            displayName: parts.sublist(1).join(':'), // Handle names with colons
            timestamp: DateTime.now(),
          );
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  static bool isIdentityMessage(Uint8List bytes) {
    try {
      final message = utf8.decode(bytes);
      return message.startsWith('IDENTITY:');
    } catch (e) {
      return false;
    }
  }
}
