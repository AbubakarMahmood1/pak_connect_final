import '../../core/models/pairing_state.dart';

/// Pairing Service Interface
///
/// Manages the pairing flow (PIN code exchange and verification):
/// - Generate and handle pairing codes (4-digit PIN)
/// - Verify codes match between both devices
/// - Complete pairing state machine transitions

abstract class IPairingService {
  // ============================================================================
  // PAIRING STATE MACHINE
  // ============================================================================

  /// Generate random 4-digit PIN code, initialize pairing state
  String generatePairingCode();

  /// User enters peer's code, send our code, wait for verification
  Future<void> completePairing(String theirCode);

  /// Receive peer's code, compare with our entered code, trigger verification
  void handleReceivedPairingCode(String theirCode);

  /// Core verification logic: compute shared secret from codes & keys
  /// Upgrade contact security, establish persistent key exchange
  Future<void> _performVerification();

  /// Receive peer's verification hash, compare with our computed hash
  Future<void> handlePairingVerification(String theirSecretHash);

  /// Reset all pairing state after completion or failure
  void clearPairing();

  // ============================================================================
  // STATE QUERIES
  // ============================================================================

  /// Current pairing state (initiated, requested, accepted, etc.)
  PairingInfo? get currentPairing;

  /// Peer's received code during verification
  String? get theirReceivedCode;

  /// Whether we entered our PIN code
  bool get weEnteredCode;

  // ============================================================================
  // CALLBACKS (Events emitted to UI/Coordinator)
  // ============================================================================

  /// Callback to send pairing code to peer
  void Function(String code)? onSendPairingCode;

  /// Callback to send pairing verification hash to peer
  void Function(String verificationHash)? onSendPairingVerification;

  /// Callback when pairing request received from peer
  void Function()? onPairingRequestReceived;

  /// Callback when pairing cancelled
  void Function()? onPairingCancelled;

  /// Send pairing request with our ephemeral ID/display name
  void initiatePairingRequest({
    required String myEphemeralId,
    required String displayName,
  });

  /// Receive pairing request from peer
  void receivePairingRequest({
    required String theirEphemeralId,
    required String displayName,
  });

  /// Accept incoming pairing request and emit accept message
  void acceptIncomingRequest({
    required String myEphemeralId,
    required String displayName,
  });

  /// Reject incoming pairing request
  void rejectIncomingRequest();

  /// Process pairing accept message from peer
  void receivePairingAccept({
    required String theirEphemeralId,
    required String displayName,
  });

  /// Process pairing cancel from peer
  void receivePairingCancel({String? reason});
}
