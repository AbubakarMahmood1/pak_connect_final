import 'dart:convert';
import 'dart:typed_data';
import 'package:pak_connect/core/compression/compression_util.dart';
import 'package:pak_connect/core/compression/compression_config.dart';
import '../constants/special_recipients.dart';
import '../models/mesh_relay_models.dart';

enum ProtocolMessageType {
  // ===== HANDSHAKE PROTOCOL (Sequential, No ACKs) =====
  // Phase 0: Connection establishment
  connectionReady,      // "I'm ready to start handshake" - sent by both devices (response IS ack)

  // Phase 1: Identity exchange (EPHEMERAL IDs only)
  identity,             // Send ephemeral identity information (response IS ack)
  
  // Phase 1.5: Noise Protocol Handshake (XX: 3 messages, KK: 2 messages)
  noiseHandshake1,      // XX: -> e (32 bytes) | KK: -> e, es, ss (96 bytes) [SIZE INDICATES PATTERN]
  noiseHandshake2,      // XX: <- e, ee, s, es (80 bytes) | KK: <- e, ee, se (48 bytes)
  noiseHandshake3,      // XX: -> s, se (48 bytes) [XX ONLY - KK has no message 3]
  noiseHandshakeRejected, // "I can't do KK" + reason + suggested pattern

  // Phase 2: Contact status sync
  contactStatus,        // Send contact relationship status (response IS ack)

  // ===== PAIRING PROTOCOL (Interactive, Atomic) =====
  pairingRequest,       // "I want to pair with you" - triggers popup on other device
  pairingAccept,        // "I accept pairing" - both devices show PIN dialogs
  pairingCancel,        // "I'm canceling pairing" - both devices close dialogs
  pairingCode,          // Exchange 4-digit PINs (existing)
  pairingVerify,        // Verify shared secret hash (existing)
  persistentKeyExchange, // Exchange persistent public keys AFTER PIN success

  // ===== NORMAL OPERATIONS =====
  textMessage,
  ack,
  ping,
  keyExchange,
  contactRequest,
  contactAccept,
  contactReject,
  cryptoVerification,
  cryptoVerificationResponse,
  meshRelay,
  queueSync,
  relayAck,

  // ===== SPY MODE =====
  friendReveal,         // Reveal persistent identity in spy mode
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
  
  /// Serializes this protocol message to bytes with optional compression.
  ///
  /// Format (with compression):
  /// - Flags: 1 byte (bit 0: IS_COMPRESSED = 0x01)
  /// - Original size: 2 bytes (if compressed, big-endian)
  /// - Data: Variable length (JSON or compressed JSON)
  ///
  /// Uses aggressive compression config for BLE transmission efficiency.
  /// Falls back to uncompressed if compression doesn't help.
  Uint8List toBytes({bool enableCompression = true}) {
    final json = {
      'type': type.index,
      'version': version,
      'payload': payload,
      'timestamp': timestamp.millisecondsSinceEpoch,
      if (signature != null) 'signature': signature,
      'useEphemeralSigning': useEphemeralSigning,
      if (ephemeralSigningKey != null) 'ephemeralSigningKey': ephemeralSigningKey,
    };
    final jsonBytes = utf8.encode(jsonEncode(json));

    // Try compression if enabled (using fast config for BLE - low latency priority)
    if (enableCompression) {
      final compressionResult = CompressionUtil.compress(
        Uint8List.fromList(jsonBytes),
        config: CompressionConfig.fast, // Fast compression for real-time BLE
      );

      if (compressionResult != null) {
        // Compression was beneficial!
        // Format: [flags:1][original_size:2][compressed_data]
        final originalSize = jsonBytes.length;
        final compressedData = compressionResult.compressed;
        final result = ByteData(1 + 2 + compressedData.length);

        // Flags byte (bit 0: IS_COMPRESSED)
        result.setUint8(0, 0x01);

        // Original size (2 bytes, big-endian)
        result.setUint16(1, originalSize, Endian.big);

        // Compressed data
        result.buffer.asUint8List(3).setAll(0, compressedData);

        return result.buffer.asUint8List();
      }
    }

    // No compression (either disabled or not beneficial)
    // Format: [flags:1][json_data]
    final result = ByteData(1 + jsonBytes.length);
    result.setUint8(0, 0x00); // Flags = 0 (uncompressed)
    result.buffer.asUint8List(1).setAll(0, jsonBytes);

    return result.buffer.asUint8List();
  }
  
  /// Deserializes a protocol message from bytes with automatic decompression.
  ///
  /// Handles both compressed and uncompressed formats transparently.
  /// Falls back gracefully if decompression fails (tries to parse as JSON directly).
  static ProtocolMessage fromBytes(Uint8List bytes) {
    // Minimum size check (at least 1 byte for flags)
    if (bytes.isEmpty) {
      throw ArgumentError('Cannot decode empty bytes');
    }

    try {
      // Read flags byte
      final flags = bytes[0];
      final isCompressed = (flags & 0x01) != 0;

      Uint8List jsonBytes;

      if (isCompressed) {
        // Compressed format: [flags:1][original_size:2][compressed_data]
        if (bytes.length < 4) {
          throw ArgumentError('Compressed message too short (need at least 4 bytes)');
        }

        // Read original size (2 bytes, big-endian)
        final byteData = ByteData.sublistView(bytes);
        final originalSize = byteData.getUint16(1, Endian.big);

        // Extract compressed data (skip flags:1 + size:2 = 3 bytes)
        final compressedData = bytes.sublist(3);

        // Decompress
        final decompressed = CompressionUtil.decompress(
          compressedData,
          originalSize: originalSize,
        );

        if (decompressed == null) {
          throw ArgumentError('Failed to decompress protocol message');
        }

        jsonBytes = decompressed;
      } else {
        // Uncompressed format: [flags:1][json_data]
        jsonBytes = bytes.sublist(1);
      }

      // Parse JSON
      final json = jsonDecode(utf8.decode(jsonBytes));
      return ProtocolMessage(
        type: ProtocolMessageType.values[json['type']],
        version: json['version'] ?? 1,
        payload: Map<String, dynamic>.from(json['payload']),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
        signature: json['signature'],
        useEphemeralSigning: json['useEphemeralSigning'] ?? false,
        ephemeralSigningKey: json['ephemeralSigningKey'],
      );
    } catch (e) {
      // Backward compatibility: Try parsing as raw JSON (old format without flags)
      // This handles messages from old clients that don't have compression support
      try {
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
      } catch (_) {
        // Both compressed and raw JSON parsing failed
        rethrow;
      }
    }
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

  // Noise Protocol XX Handshake messages
  static ProtocolMessage noiseHandshake1({
    required Uint8List handshakeData,
    required String peerId,
  }) => ProtocolMessage(
    type: ProtocolMessageType.noiseHandshake1,
    payload: {
      'handshakeData': base64.encode(handshakeData),
      'peerId': peerId,
    },
    timestamp: DateTime.now(),
  );

  static ProtocolMessage noiseHandshake2({
    required Uint8List handshakeData,
    required String peerId,
  }) => ProtocolMessage(
    type: ProtocolMessageType.noiseHandshake2,
    payload: {
      'handshakeData': base64.encode(handshakeData),
      'peerId': peerId,
    },
    timestamp: DateTime.now(),
  );

  static ProtocolMessage noiseHandshake3({
    required Uint8List handshakeData,
    required String peerId,
  }) => ProtocolMessage(
    type: ProtocolMessageType.noiseHandshake3,
    payload: {
      'handshakeData': base64.encode(handshakeData),
      'peerId': peerId,
    },
    timestamp: DateTime.now(),
  );

  // Noise handshake rejection (KK pattern coordination)
  static ProtocolMessage noiseHandshakeRejected({
    required String reason,           // 'missing_key', 'crypto_failure', 'pattern_unsupported'
    required String attemptedPattern, // 'kk'
    required String suggestedPattern, // 'xx'
    String? peerEphemeralId,         // Who is rejecting
    Map<String, dynamic>? contactStatus, // Optional: signal desync
  }) => ProtocolMessage(
    type: ProtocolMessageType.noiseHandshakeRejected,
    payload: {
      'reason': reason,
      'attemptedPattern': attemptedPattern,
      'suggestedPattern': suggestedPattern,
      if (peerEphemeralId != null) 'peerId': peerEphemeralId,
      if (contactStatus != null) 'contactStatus': contactStatus,
    },
    timestamp: DateTime.now(),
  );
  
  static ProtocolMessage textMessage({
    required String messageId,
    required String content,
    bool encrypted = false,
    String? recipientId,  // STEP 7: Recipient's ID (ephemeral or persistent)
    bool useEphemeralAddressing = false,  // STEP 7: Flag for routing
  }) => ProtocolMessage(
    type: ProtocolMessageType.textMessage,
    payload: {
      'messageId': messageId,
      'content': content,
      'encrypted': encrypted,
      if (recipientId != null) 'recipientId': recipientId,
      'useEphemeralAddressing': useEphemeralAddressing,
    },
    timestamp: DateTime.now(),
  );

  /// Priority 2: Broadcast message to all nodes in mesh network
  ///
  /// Creates a text message with broadcast recipient sentinel.
  /// Will be delivered to ALL nodes and forwarded through the mesh.
  ///
  /// Inspired by BitChat's BROADCAST recipient pattern
  static ProtocolMessage broadcastMessage({
    required String messageId,
    required String content,
    bool encrypted = false,
  }) => ProtocolMessage(
    type: ProtocolMessageType.textMessage,
    payload: {
      'messageId': messageId,
      'content': content,
      'encrypted': encrypted,
      'recipientId': SpecialRecipients.broadcast, // Broadcast sentinel
      'useEphemeralAddressing': false,
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

// ===== PAIRING PROTOCOL MESSAGES =====

static ProtocolMessage pairingRequest({
  required String ephemeralId,
  required String displayName,
}) => ProtocolMessage(
  type: ProtocolMessageType.pairingRequest,
  payload: {
    'ephemeralId': ephemeralId,
    'displayName': displayName,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage pairingAccept({
  required String ephemeralId,
  required String displayName,
}) => ProtocolMessage(
  type: ProtocolMessageType.pairingAccept,
  payload: {
    'ephemeralId': ephemeralId,
    'displayName': displayName,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage pairingCancel({
  String? reason,
}) => ProtocolMessage(
  type: ProtocolMessageType.pairingCancel,
  payload: {
    if (reason != null) 'reason': reason,
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage persistentKeyExchange({
  required String persistentPublicKey,
}) => ProtocolMessage(
  type: ProtocolMessageType.persistentKeyExchange,
  payload: {
    'persistentPublicKey': persistentPublicKey,
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

// Noise Protocol XX Handshake data helpers
Uint8List? get noiseHandshakeData {
  if (type == ProtocolMessageType.noiseHandshake1 ||
      type == ProtocolMessageType.noiseHandshake2 ||
      type == ProtocolMessageType.noiseHandshake3) {
    final encoded = payload['handshakeData'] as String?;
    return encoded != null ? base64.decode(encoded) : null;
  }
  return null;
}

String? get noiseHandshakePeerId {
  if (type == ProtocolMessageType.noiseHandshake1 ||
      type == ProtocolMessageType.noiseHandshake2 ||
      type == ProtocolMessageType.noiseHandshake3) {
    return payload['peerId'] as String?;
  }
  return null;
}

// Noise handshake rejection helpers
String? get noiseHandshakeRejectReason => 
  type == ProtocolMessageType.noiseHandshakeRejected ? payload['reason'] as String? : null;
String? get noiseHandshakeRejectAttemptedPattern => 
  type == ProtocolMessageType.noiseHandshakeRejected ? payload['attemptedPattern'] as String? : null;
String? get noiseHandshakeRejectSuggestedPattern => 
  type == ProtocolMessageType.noiseHandshakeRejected ? payload['suggestedPattern'] as String? : null;
String? get noiseHandshakeRejectPeerId => 
  type == ProtocolMessageType.noiseHandshakeRejected ? payload['peerId'] as String? : null;
Map<String, dynamic>? get noiseHandshakeRejectContactStatus => 
  type == ProtocolMessageType.noiseHandshakeRejected ? payload['contactStatus'] as Map<String, dynamic>? : null;

// Helper to extract message info
String? get textMessageId => type == ProtocolMessageType.textMessage ? payload['messageId'] as String? : null;
String? get textContent => type == ProtocolMessageType.textMessage ? payload['content'] as String? : null;
bool get isEncrypted => type == ProtocolMessageType.textMessage ? (payload['encrypted'] as bool? ?? false) : false;

// STEP 7: Message addressing helpers
String? get recipientId => type == ProtocolMessageType.textMessage ? payload['recipientId'] as String? : null;
bool get useEphemeralAddressing => type == ProtocolMessageType.textMessage ? (payload['useEphemeralAddressing'] as bool? ?? false) : false;

// Priority 2: Broadcast message helper
/// Check if this message is a broadcast message
bool get isBroadcast => SpecialRecipients.isBroadcast(recipientId);

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
bool get meshRelayUseEphemeralAddressing => type == ProtocolMessageType.meshRelay ? (payload['useEphemeralAddressing'] as bool? ?? false) : false;  // STEP 7
ProtocolMessageType? get meshRelayOriginalMessageType {
  if (type == ProtocolMessageType.meshRelay) {
    final typeIndex = payload['originalMessageType'] as int?;
    return typeIndex != null ? ProtocolMessageType.values[typeIndex] : null;
  }
  return null;
}

// Queue sync helpers
QueueSyncMessage? get queueSyncMessage =>
    type == ProtocolMessageType.queueSync ? QueueSyncMessage.fromJson(payload) : null;

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
  bool useEphemeralAddressing = false,  // STEP 7: Preserve addressing type
  ProtocolMessageType? originalMessageType,  // PHASE 2: Message type filtering
}) => ProtocolMessage(
  type: ProtocolMessageType.meshRelay,
  payload: {
    'originalMessageId': originalMessageId,
    'originalSender': originalSender,
    'finalRecipient': finalRecipient,
    'relayMetadata': relayMetadata,
    'originalPayload': originalPayload,
    'useEphemeralAddressing': useEphemeralAddressing,  // STEP 7
    if (originalMessageType != null) 'originalMessageType': originalMessageType.index,  // PHASE 2
  },
  timestamp: DateTime.now(),
);

static ProtocolMessage queueSync({
  required QueueSyncMessage queueMessage,
}) => ProtocolMessage(
  type: ProtocolMessageType.queueSync,
  payload: queueMessage.toJson(),
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

// ===== SPY MODE CONSTRUCTORS =====

/// Reveal persistent identity in spy mode
/// Used when user chooses to reveal their identity to a friend during anonymous chat
static ProtocolMessage friendReveal({
  required String myPersistentKey,
  required String proof,
  required int timestamp,
}) => ProtocolMessage(
  type: ProtocolMessageType.friendReveal,
  payload: {
    'myPersistentKey': myPersistentKey,
    'proof': proof,
    'timestamp': timestamp,
  },
  timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
);

// ===== HANDSHAKE PROTOCOL CONSTRUCTORS =====

/// Phase 0: Connection ready signal
/// Sent by both devices to indicate BLE stack is initialized and ready
/// Response IS the acknowledgment (no separate ACK message)
static ProtocolMessage connectionReady({
  required String deviceId,
  String? deviceName,
}) => ProtocolMessage(
  type: ProtocolMessageType.connectionReady,
  payload: {
    'deviceId': deviceId,
    if (deviceName != null) 'deviceName': deviceName,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  },
  timestamp: DateTime.now(),
);


// ===== HANDSHAKE PROTOCOL HELPERS =====

String? get connectionReadyDeviceId =>
  type == ProtocolMessageType.connectionReady ? payload['deviceId'] as String? : null;

String? get connectionReadyDeviceName =>
  type == ProtocolMessageType.connectionReady ? payload['deviceName'] as String? : null;

}
