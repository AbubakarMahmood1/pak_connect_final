import '../../core/models/protocol_message.dart';

/// BLE State Coordinator Interface
///
/// Enforces security invariants and orchestrates cross-service state transitions:
/// - Pairing → Persistent Key Exchange → Chat Migration
/// - Spy mode detection and identity reveal
/// - Security level upgrades with ECDH coordination
/// - Atomic state clearing during navigation
///
/// **CRITICAL**: This coordinator is the single choke point for security gates.
/// All state transitions MUST flow through here to prevent:
/// - Encryption before Noise handshake completes
/// - Persistent IDs sent before verification succeeds
/// - Message duplication across mode switches

abstract class IBLEStateCoordinator {
  // ============================================================================
  // PAIRING STATE MACHINE (Orchestrated Transitions)
  // ============================================================================

  /// Initiate pairing (user clicks "Pair" button)
  /// Sets timeout, sends request, waits for peer response
  Future<void> sendPairingRequest();

  /// Receive pairing request from peer, show accept/reject dialog
  Future<void> handlePairingRequest(ProtocolMessage message);

  /// User accepts pairing request, generate PIN and proceed to exchange
  Future<void> acceptPairingRequest();

  /// User rejects pairing request, send cancel, reset state
  void rejectPairingRequest();

  /// Receive pairing accept, generate PIN and proceed to code exchange
  Future<void> handlePairingAccept(ProtocolMessage message);

  /// Receive pairing cancel, close dialogs, reset state
  void handlePairingCancel(ProtocolMessage message);

  /// User/system cancels at any stage, send cancel, reset state
  void cancelPairing({String? reason});

  // ============================================================================
  // PERSISTENT KEY EXCHANGE (Security Gate #1)
  // ============================================================================

  /// STEP 4.2: Receive peer's persistent key, store mapping, create contact
  /// **SECURITY**: Must validate both keys match before accepting
  Future<void> handlePersistentKeyExchange(String theirPersistentKey);

  // ============================================================================
  // SPY MODE (Asymmetric Contact Detection)
  // ============================================================================

  /// Reveal identity to friend in spy mode (cryptographic proof)
  /// Emits onIdentityRevealed after success
  Future<void> revealIdentityToFriend();

  // ============================================================================
  // CHAT MIGRATION (Ephemeral → Persistent ID)
  // ============================================================================

  /// User initiates contact request, set timeout, send, wait for response
  Future<bool> initiateContactRequest();

  /// Receive contact request from peer (handled by BLEMessageHandler)
  Future<void> handleContactRequest(String publicKey, String displayName);

  /// User accepts pending contact request
  Future<void> acceptContactRequest();

  /// User rejects pending contact request
  void rejectContactRequest();

  /// Peer accepted contact request, finalize addition
  Future<void> handleContactRequestAcceptResponse(
    String publicKey,
    String displayName,
  );

  /// Peer rejected contact request, complete completer
  void handleContactRequestRejectResponse();

  /// Send contact request (legacy, largely superseded by pairing flow)
  Future<void> sendContactRequest();

  // ============================================================================
  // SECURITY LEVEL UPGRADES (ECDH Coordination)
  // ============================================================================

  /// Preserve contact across mode switch (navigation preservation)
  void preserveContactRelationship({
    required String contactKey,
    required String displayName,
  });

  // ============================================================================
  // CONTACT STATUS SYNCHRONIZATION
  // ============================================================================

  /// Initialize contact status exchange (send our status to peer)
  Future<void> initializeContactFlags();

  /// Clear session state with optional preservation of persistent ID during nav
  /// **SECURITY**: Atomic operation to prevent partial state
  void clearSessionState({bool preservePersistentId = false});

  /// Recover display name from contact repo if cleared during navigation
  Future<void> recoverIdentityFromStorage();

  /// Get identity info, falling back to repository if session cleared
  Future<Map<String, String>> getIdentityWithFallback();

  // ============================================================================
  // CALLBACKS (Cross-service event emissions)
  // ============================================================================

  /// Callback to send pairing request to peer
  void Function()? onSendPairingRequest;

  /// Callback to send pairing accept to peer
  void Function()? onSendPairingAccept;

  /// Callback to send pairing cancel to peer
  void Function()? onSendPairingCancel;

  /// Callback when contact request completed
  void Function()? onContactRequestCompleted;

  /// Callback to send persistent key to peer
  void Function(String persistentKey)? onSendPersistentKeyExchange;

  /// Callback when spy mode detected
  void Function()? onSpyModeDetected;

  /// Callback when identity revealed
  void Function()? onIdentityRevealed;

  /// Callback when asymmetric contact detected
  void Function()? onAsymmetricContactDetected;

  /// Callback when mutual consent required
  void Function()? onMutualConsentRequired;
}
