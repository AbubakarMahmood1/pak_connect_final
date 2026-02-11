/// Connection phases for the sequential handshake protocol.
/// Response IS the acknowledgment (no separate ACK messages).
enum ConnectionPhase {
  // Initial state - BLE connected but handshake not started
  bleConnected,

  // Phase 0: Ready check - ensure both devices' BLE stacks are ready
  readySent, // We sent connectionReady
  readyComplete, // Both devices exchanged ready (response IS ack)
  // Phase 1: Identity exchange - exchange public keys and display names
  identitySent, // We sent identity
  identityComplete, // Both devices exchanged identity (response IS ack)
  // Phase 1.5: Noise Protocol XX Handshake - establish encrypted session
  noiseHandshake1Sent, // We sent Noise message 1 (-> e)
  noiseHandshake2Sent, // We sent Noise message 2 (<- e, ee, s, es)
  noiseHandshakeComplete, // Noise session established
  // Phase 2: Contact status sync - exchange relationship status
  contactStatusSent, // We sent contact status
  contactStatusComplete, // Both devices exchanged contact status (response IS ack)
  // Final state - handshake complete
  complete,

  // Error states
  timeout,
  failed,
}
