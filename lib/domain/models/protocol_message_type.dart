/// Message type enum shared between protocol payloads and relay metadata.
///
/// DO NOT reorder, rename, or remove existing values. New values must be
/// appended at the end AND registered in [_wireTypeByMessageType] below.
enum ProtocolMessageType {
  // ===== HANDSHAKE PROTOCOL (Sequential, No ACKs) =====
  // Phase 0: Connection establishment
  connectionReady, // "I'm ready to start handshake" - sent by both devices (response IS ack)
  // Phase 1: Identity exchange (EPHEMERAL IDs only)
  identity, // Send ephemeral identity information (response IS ack)
  // Phase 1.5: Noise Protocol Handshake (XX: 3 messages, KK: 2 messages)
  noiseHandshake1, // XX: -> e (32 bytes) | KK: -> e, es, ss (96 bytes) [SIZE INDICATES PATTERN]
  noiseHandshake2, // XX: <- e, ee, s, es (80 bytes) | KK: <- e, ee, se (48 bytes)
  noiseHandshake3, // XX: -> s, se (48 bytes) [XX ONLY - KK has no message 3]
  noiseHandshakeRejected, // "I can't do KK" + reason + suggested pattern
  // Phase 2: Contact status sync
  contactStatus, // Send contact relationship status (response IS ack)
  // ===== PAIRING PROTOCOL (Interactive, Atomic) =====
  pairingRequest, // "I want to pair with you" - triggers popup on other device
  pairingAccept, // "I accept pairing" - both devices show PIN dialogs
  pairingCancel, // "I'm canceling pairing" - both devices close dialogs
  pairingCode, // Exchange 4-digit PINs (existing)
  pairingVerify, // Verify shared secret hash (existing)
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
  friendReveal, // Reveal persistent identity in spy mode
}

/// Stable numeric IDs for wire serialization.
///
/// Values mirror the current [ProtocolMessageType] enum indices so that
/// already-transmitted messages remain parseable.  Future enum additions
/// MUST be appended here with an explicit, unique integer — never rely on
/// dart enum `.index` for wire format.
const Map<ProtocolMessageType, int> _wireTypeByMessageType = {
  ProtocolMessageType.connectionReady: 0,
  ProtocolMessageType.identity: 1,
  ProtocolMessageType.noiseHandshake1: 2,
  ProtocolMessageType.noiseHandshake2: 3,
  ProtocolMessageType.noiseHandshake3: 4,
  ProtocolMessageType.noiseHandshakeRejected: 5,
  ProtocolMessageType.contactStatus: 6,
  ProtocolMessageType.pairingRequest: 7,
  ProtocolMessageType.pairingAccept: 8,
  ProtocolMessageType.pairingCancel: 9,
  ProtocolMessageType.pairingCode: 10,
  ProtocolMessageType.pairingVerify: 11,
  ProtocolMessageType.persistentKeyExchange: 12,
  ProtocolMessageType.textMessage: 13,
  ProtocolMessageType.ack: 14,
  ProtocolMessageType.ping: 15,
  ProtocolMessageType.keyExchange: 16,
  ProtocolMessageType.contactRequest: 17,
  ProtocolMessageType.contactAccept: 18,
  ProtocolMessageType.contactReject: 19,
  ProtocolMessageType.cryptoVerification: 20,
  ProtocolMessageType.cryptoVerificationResponse: 21,
  ProtocolMessageType.meshRelay: 22,
  ProtocolMessageType.queueSync: 23,
  ProtocolMessageType.relayAck: 24,
  ProtocolMessageType.friendReveal: 25,
};

final Map<int, ProtocolMessageType> _messageTypeByWireType = {
  for (final entry in _wireTypeByMessageType.entries) entry.value: entry.key,
};

/// Extension providing stable wire-format integer IDs for
/// [ProtocolMessageType] values.
extension ProtocolMessageTypeWireId on ProtocolMessageType {
  /// The stable integer sent/received over the wire.
  int get wireType => _wireTypeByMessageType[this]!;

  /// Deserialize a wire-type integer back to [ProtocolMessageType].
  ///
  /// Accepts both [int] and stringified int for JSON flexibility.
  static ProtocolMessageType fromWireType(Object? rawType) {
    final wireType = rawType is int ? rawType : int.tryParse('$rawType');
    if (wireType == null) {
      throw ArgumentError('Invalid protocol message type: $rawType');
    }

    final type = _messageTypeByWireType[wireType];
    if (type != null) {
      return type;
    }

    throw ArgumentError('Unknown protocol message type id: $wireType');
  }
}
