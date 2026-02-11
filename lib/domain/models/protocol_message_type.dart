/// Message type enum shared between protocol payloads and relay metadata.
///
/// Keep value ordering stable because type indexes are serialized on the wire.
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
