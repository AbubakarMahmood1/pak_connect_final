import 'dart:convert';
import 'dart:typed_data';

enum BLEMessageType {
  text,
  ack,
  typing,
  encryptedText,
}

class BLEMessage {
  final String id;
  final BLEMessageType type;
  final String payload;
  final DateTime timestamp;
   final bool isEncrypted;

  BLEMessage({
    required this.id,
    required this.type,
    required this.payload,
    required this.timestamp,
    this.isEncrypted = false,
  });

  // Convert to bytes for BLE transmission
  Uint8List toBytes() {
    final json = {
      'id': id,
      'type': type.index,
      'payload': payload,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'encrypted': isEncrypted,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // Parse from bytes received via BLE
  static BLEMessage fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    return BLEMessage(
      id: json['id'],
      type: BLEMessageType.values[json['type']],
      payload: json['payload'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      isEncrypted: json['encrypted'] ?? false,
    );
  }

  // Quick constructors
  static BLEMessage text(String content) => BLEMessage(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    type: BLEMessageType.text,
    payload: content,
    timestamp: DateTime.now(),
  );

  static BLEMessage ack(String messageId) => BLEMessage(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    type: BLEMessageType.ack,
    payload: messageId,
    timestamp: DateTime.now(),
  );

   static BLEMessage encryptedText(String content) => BLEMessage(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    type: BLEMessageType.encryptedText,
    payload: content,
    timestamp: DateTime.now(),
    isEncrypted: true,
  );
}