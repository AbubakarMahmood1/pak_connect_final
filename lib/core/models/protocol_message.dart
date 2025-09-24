import 'dart:convert';
import 'dart:typed_data';

enum ProtocolMessageType {
  identity,
  textMessage,
  ack,
  ping,
  keyExchange,
  pairingCode,
  pairingVerify,
  contactRequest,
  contactAccept,
  contactReject,
  contactStatus,
  cryptoVerification,
  cryptoVerificationResponse,
  meshRelay,
  queueSync,
  relayAck,
}

class ProtocolMessage {
  final ProtocolMessageType type;
  final int version;
  final Map<String, dynamic> payload;
  final DateTime timestamp;
  final String? signature;
  final bool useEphemeralSigning;
  final String? ephemeralSigningKey;
  
  ProtocolMessage({
    required this.type,
    this.version = 1,
    required this.payload,
    required this.timestamp,
    this.signature,
    this.useEphemeralSigning = false,
    this.ephemeralSigningKey,
  });
  
  Uint8List toBytes() {
    final json = {
      'type': type.index,
      'version': version,
      'payload': payload,
      'timestamp': timestamp.millisecondsSinceEpoch,
      if (signature != null) 'signature': signature,
      'useEphemeralSigning': useEphemeralSigning,
      if (ephemeralSigningKey != null) 'ephemeralSigningKey': ephemeralSigningKey,
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
      useEphemeralSigning: json['useEphemeralSigning'] ?? false,
      ephemeralSigningKey: json['ephemeralSigningKey'],
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

static ProtocolMessage pairingCode({
  required String code,
}) => ProtocolMessage(
  type: ProtocolMessageType.pairingCode,
  payload: {
    'code': code,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage pairingVerify({
  required String secretHash,
}) => ProtocolMessage(
  type: ProtocolMessageType.pairingVerify,
  payload: {
    'secretHash': secretHash,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage contactRequest({
  required String publicKey,
  required String displayName,
}) => ProtocolMessage(
  type: ProtocolMessageType.contactRequest,
  payload: {
    'publicKey': publicKey,
    'displayName': displayName,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage contactAccept({
  required String publicKey,
  required String displayName,
}) => ProtocolMessage(
  type: ProtocolMessageType.contactAccept,
  payload: {
    'publicKey': publicKey,
    'displayName': displayName,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage contactReject() => ProtocolMessage(
  type: ProtocolMessageType.contactReject,
  payload: {},
  timestamp: DateTime.now(),
);

static ProtocolMessage contactStatus({
  required bool hasAsContact,
  required String publicKey,
}) => ProtocolMessage(
  type: ProtocolMessageType.contactStatus,
  payload: {
    'hasAsContact': hasAsContact,
    'publicKey': publicKey,
  },
  timestamp: DateTime.now(),
);

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

String? get pairingCodeValue => type == ProtocolMessageType.pairingCode ? payload['code'] as String? : null;
String? get pairingSecretHash => type == ProtocolMessageType.pairingVerify ? payload['secretHash'] as String? : null;

String? get contactRequestPublicKey => type == ProtocolMessageType.contactRequest ? payload['publicKey'] as String? : null;
String? get contactRequestDisplayName => type == ProtocolMessageType.contactRequest ? payload['displayName'] as String? : null;
String? get contactAcceptPublicKey => type == ProtocolMessageType.contactAccept ? payload['publicKey'] as String? : null;
String? get contactAcceptDisplayName => type == ProtocolMessageType.contactAccept ? payload['displayName'] as String? : null;

// Crypto verification helpers
String? get cryptoVerificationChallenge => type == ProtocolMessageType.cryptoVerification ? payload['challenge'] as String? : null;
String? get cryptoVerificationTestMessage => type == ProtocolMessageType.cryptoVerification ? payload['testMessage'] as String? : null;
bool get cryptoVerificationRequiresResponse => type == ProtocolMessageType.cryptoVerification ? (payload['requiresResponse'] as bool? ?? false) : false;

String? get cryptoVerificationResponseChallenge => type == ProtocolMessageType.cryptoVerificationResponse ? payload['challenge'] as String? : null;
String? get cryptoVerificationResponseDecrypted => type == ProtocolMessageType.cryptoVerificationResponse ? payload['decryptedMessage'] as String? : null;
bool get cryptoVerificationSuccess => type == ProtocolMessageType.cryptoVerificationResponse ? (payload['success'] as bool? ?? false) : false;
Map<String, dynamic>? get cryptoVerificationResults => type == ProtocolMessageType.cryptoVerificationResponse ? payload['results'] as Map<String, dynamic>? : null;

// Quick constructors for crypto verification
static ProtocolMessage cryptoVerification({
  required String challenge,
  required String testMessage,
  bool requiresResponse = true,
}) => ProtocolMessage(
  type: ProtocolMessageType.cryptoVerification,
  payload: {
    'challenge': challenge,
    'testMessage': testMessage,
    'requiresResponse': requiresResponse,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage cryptoVerificationResponse({
  required String challenge,
  required String decryptedMessage,
  required bool success,
  Map<String, dynamic>? results,
}) => ProtocolMessage(
  type: ProtocolMessageType.cryptoVerificationResponse,
  payload: {
    'challenge': challenge,
    'decryptedMessage': decryptedMessage,
    'success': success,
    if (results != null) 'results': results,
  },
  timestamp: DateTime.now(),
);

// Mesh relay helpers
String? get meshRelayOriginalMessageId => type == ProtocolMessageType.meshRelay ? payload['originalMessageId'] as String? : null;
String? get meshRelayOriginalSender => type == ProtocolMessageType.meshRelay ? payload['originalSender'] as String? : null;
String? get meshRelayFinalRecipient => type == ProtocolMessageType.meshRelay ? payload['finalRecipient'] as String? : null;
Map<String, dynamic>? get meshRelayMetadata => type == ProtocolMessageType.meshRelay ? payload['relayMetadata'] as Map<String, dynamic>? : null;
Map<String, dynamic>? get meshRelayOriginalPayload => type == ProtocolMessageType.meshRelay ? payload['originalPayload'] as Map<String, dynamic>? : null;

// Queue sync helpers
String? get queueSyncHash => type == ProtocolMessageType.queueSync ? payload['queueHash'] as String? : null;
List<String>? get queueSyncMessageIds => type == ProtocolMessageType.queueSync ?
  (payload['messageIds'] as List<dynamic>?)?.cast<String>() : null;
int? get queueSyncTimestamp => type == ProtocolMessageType.queueSync ? payload['syncTimestamp'] as int? : null;

// Relay ack helpers
String? get relayAckOriginalMessageId => type == ProtocolMessageType.relayAck ? payload['originalMessageId'] as String? : null;
String? get relayAckRelayNode => type == ProtocolMessageType.relayAck ? payload['relayNode'] as String? : null;
bool get relayAckDelivered => type == ProtocolMessageType.relayAck ? (payload['delivered'] as bool? ?? false) : false;

// Mesh relay constructors
static ProtocolMessage meshRelay({
  required String originalMessageId,
  required String originalSender,
  required String finalRecipient,
  required Map<String, dynamic> relayMetadata,
  required Map<String, dynamic> originalPayload,
}) => ProtocolMessage(
  type: ProtocolMessageType.meshRelay,
  payload: {
    'originalMessageId': originalMessageId,
    'originalSender': originalSender,
    'finalRecipient': finalRecipient,
    'relayMetadata': relayMetadata,
    'originalPayload': originalPayload,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage queueSync({
  required String queueHash,
  required List<String> messageIds,
  int? syncTimestamp,
}) => ProtocolMessage(
  type: ProtocolMessageType.queueSync,
  payload: {
    'queueHash': queueHash,
    'messageIds': messageIds,
    'syncTimestamp': syncTimestamp ?? DateTime.now().millisecondsSinceEpoch,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage relayAck({
  required String originalMessageId,
  required String relayNode,
  required bool delivered,
}) => ProtocolMessage(
  type: ProtocolMessageType.relayAck,
  payload: {
    'originalMessageId': originalMessageId,
    'relayNode': relayNode,
    'delivered': delivered,
  },
  timestamp: DateTime.now(),
);

}