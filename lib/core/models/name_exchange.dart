import 'dart:convert';
import 'dart:typed_data';

class NameExchange {
  final String userName;
  final DateTime timestamp;

  NameExchange({
    required this.userName,
    required this.timestamp,
  });

  // Simple protocol: "NAME:John"
  Uint8List toBytes() {
    final nameMessage = 'NAME:$userName';
    return Uint8List.fromList(utf8.encode(nameMessage));
  }

  static NameExchange? fromBytes(Uint8List bytes) {
    try {
      final message = utf8.decode(bytes);
      if (message.startsWith('NAME:')) {
        final userName = message.substring(5); // Remove "NAME:" prefix
        return NameExchange(
          userName: userName,
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  static bool isNameMessage(Uint8List bytes) {
    try {
      final message = utf8.decode(bytes);
      return message.startsWith('NAME:');
    } catch (e) {
      return false;
    }
  }
}