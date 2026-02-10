// Session Service Interface
//
// Manages active session state:
// - Ephemeral and session IDs
// - Contact status synchronization
// - Message addressing (which ID to use)
// - Bilateral contact sync and asymmetric detection

abstract class ISessionService {
  // ============================================================================
  // SESSION ID MANAGEMENT
  // ============================================================================

  /// Store peer's ephemeral ID from Noise handshake
  void setTheirEphemeralId(String ephemeralId, String displayName);

  /// Return appropriate ID for addressing this contact
  /// - Uses persistent key if paired, else ephemeral ID
  String? getRecipientId();

  /// Return ID type for logging ("persistent" or "ephemeral")
  String getIdType();

  /// Retrieve cached conversation/shared secret key for a contact
  String? getConversationKey(String publicKey);

  // ============================================================================
  // CONTACT STATUS SYNCHRONIZATION
  // ============================================================================

  /// Initiate contact status exchange with peer
  Future<void> requestContactStatusExchange();

  /// Process incoming contact status from peer, trigger bilateral sync
  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  );

  /// Update session's view of peer's contact claim
  void updateTheirContactStatus(bool theyHaveUs);

  /// Update session's view of peer's contact claim with callback
  void updateTheirContactClaim(bool theyClaimUs);

  // ============================================================================
  // STATE QUERIES
  // ============================================================================

  /// Check if persistent key exchange complete for this contact
  bool get isPaired;

  // ============================================================================
  // CALLBACKS (Events emitted to Coordinator)
  // ============================================================================

  /// Callback to send contact status protocol message to peer
  void Function(bool weHaveThem, String theirPublicKey)? onSendContactStatus;

  /// Callback when contact request completed
  void Function()? onContactRequestCompleted;

  /// Callback when asymmetric contact detected
  void Function()? onAsymmetricContactDetected;

  /// Callback when mutual consent required
  void Function()? onMutualConsentRequired;

  /// Callback to send message to peer
  void Function(String content)? onSendMessage;
}
