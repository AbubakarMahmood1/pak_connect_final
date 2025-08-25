import 'dart:convert';
import 'dart:typed_data';

class ACKMessage {
  final String originalMessageId;
  final DateTime timestamp;

  ACKMessage({
    required this.originalMessageId,
    required this.timestamp,
  });

  // Simple protocol: "ACK:messageId"
  Uint8List toBytes() {
    final ackString = 'ACK:$originalMessageId';
    return Uint8List.fromList(utf8.encode(ackString));
  }

  static ACKMessage? fromBytes(Uint8List bytes) {
    try {
      final message = utf8.decode(bytes);
      if (message.startsWith('ACK:')) {
        final messageId = message.substring(4); // Remove "ACK:" prefix
        return ACKMessage(
          originalMessageId: messageId,
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  static bool isACKMessage(Uint8List bytes) {
    try {
      final message = utf8.decode(bytes);
      return message.startsWith('ACK:');
    } catch (e) {
      return false;
    }
  }
}