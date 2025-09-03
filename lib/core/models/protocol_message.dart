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
  final String? signature;
  
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
  required String publicKey,
  required String displayName,
  String? legacyDeviceId, // Backward compatibility
}) => ProtocolMessage(
  type: ProtocolMessageType.identity,
  payload: {
    'publicKey': publicKey,
    'displayName': displayName,
    if (legacyDeviceId != null) 'deviceId': legacyDeviceId,
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

// Helper to extract identity info  
String? get identityDeviceId => type == ProtocolMessageType.identity ? payload['deviceId'] as String? : null;
String? get identityDisplayName => type == ProtocolMessageType.identity ? payload['displayName'] as String? : null;

// Helper to extract public key from identity
String? get identityPublicKey => type == ProtocolMessageType.identity ? payload['publicKey'] as String? : null;

// Backward compatibility helper
String? get identityDeviceIdCompat => type == ProtocolMessageType.identity ? 
  (payload['publicKey'] as String? ?? payload['deviceId'] as String?) : null;

// Helper to extract message info
String? get textMessageId => type == ProtocolMessageType.textMessage ? payload['messageId'] as String? : null;
String? get textContent => type == ProtocolMessageType.textMessage ? payload['content'] as String? : null;
bool get isEncrypted => type == ProtocolMessageType.textMessage ? (payload['encrypted'] as bool? ?? false) : false;

// Helper for ACK
String? get ackOriginalId => type == ProtocolMessageType.ack ? payload['originalMessageId'] as String? : null;

}