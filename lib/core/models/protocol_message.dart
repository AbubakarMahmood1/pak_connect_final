import 'dart:convert';
import 'dart:typed_data';

enum ProtocolMessageType {
  identity,        // Device identity with future public key
  textMessage,     // Regular chat message
  ack,            // Message acknowledgment
  ping,           // Connection health check
  keyExchange,    // Future: public key exchange
}

class ProtocolMessage {
  final ProtocolMessageType type;
  final int version;
  final Map<String, dynamic> payload;
  final DateTime timestamp;
  final String? signature; // Future: digital signature
  
  ProtocolMessage({
    required this.type,
    this.version = 1,
    required this.payload,
    required this.timestamp,
    this.signature,
  });
  
  Uint8List toBytes() {
    final json = {
      'type': type.index,
      'version': version,
      'payload': payload,
      'timestamp': timestamp.millisecondsSinceEpoch,
      if (signature != null) 'signature': signature,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }
  
  static ProtocolMessage fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    return ProtocolMessage(
      type: ProtocolMessageType.values[json['type']],
      version: json['version'] ?? 1,
      payload: Map<String, dynamic>.from(json['payload']),
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      signature: json['signature'],
    );
  }
  
  // Quick constructors
  static ProtocolMessage identity({
    required String deviceId,
    required String displayName,
    String? publicKey, // Future use
  }) => ProtocolMessage(
    type: ProtocolMessageType.identity,
    payload: {
      'deviceId': deviceId,
      'displayName': displayName,
      if (publicKey != null) 'publicKey': publicKey,
    },
    timestamp: DateTime.now(),
  );
  
  static ProtocolMessage textMessage({
    required String messageId,
    required String content,
    bool encrypted = false,
  }) => ProtocolMessage(
    type: ProtocolMessageType.textMessage,
    payload: {
      'messageId': messageId,
      'content': content,
      'encrypted': encrypted,
    },
    timestamp: DateTime.now(),
  );
  
  static ProtocolMessage ack({
    required String originalMessageId,
  }) => ProtocolMessage(
    type: ProtocolMessageType.ack,
    payload: {
      'originalMessageId': originalMessageId,
    },
    timestamp: DateTime.now(),
  );
  
  static ProtocolMessage ping() => ProtocolMessage(
    type: ProtocolMessageType.ping,
    payload: {},
    timestamp: DateTime.now(),
  );
  
  static bool isProtocolMessage(String jsonString) {
    try {
      final json = jsonDecode(jsonString);
      return json.containsKey('type') && json.containsKey('version') && json.containsKey('payload');
    } catch (e) {
      return false;
    }
  }
}