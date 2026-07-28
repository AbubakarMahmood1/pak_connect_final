import 'dart:typed_data';

import 'package:pak_connect/domain/models/connection_phase.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';

/// Manages BLE handshake protocol execution and identity resolution including:
/// - 4-phase handshake coordination (CONNECTION_READY → IDENTITY_EXCHANGE → NOISE_HANDSHAKE → CONTACT_STATUS_SYNC)
/// - Noise session establishment (XX/KK pattern selection)
/// - Identity collision detection and resolution
/// - Spy mode and identity exposure detection
/// - Processing of buffered messages after handshake completion
///
/// Single responsibility: Handle all handshake and identity-related operations
/// Dependencies: HandshakeCoordinator, BLEStateManager, SecurityManager, ContactRepository
/// Consumers: All via facade (high criticality)
abstract class IBLEHandshakeService {
  // ============================================================================
  // HANDSHAKE PROTOCOL EXECUTION
  // ============================================================================

  /// Execute the 4-phase BLE handshake protocol
  /// Initiates HandshakeCoordinator, manages phase progression, processes buffered messages
  /// CRITICAL: Must reach ConnectionPhase.complete before regular messages
  ///
  /// Args:
  ///   startAsInitiatorOverride - Force initiator role (defaults to device role)
  /// Throws:
  ///   StateError if not connected or connection manager unavailable
  ///   HandshakeException if any phase fails
  /// Starts a handshake and returns false when another coordinator already
  /// owns the session. [onStartAccepted] runs after the new coordinator is
  /// created but before buffered messages or the first wire frame are handled;
  /// returning false aborts that new coordinator.
  Future<bool> performHandshake({
    bool? startAsInitiatorOverride,
    bool Function()? onStartAccepted,
  });

  /// Handle successful handshake completion
  /// Dequeues buffered messages, broadcasts identity-established event
  ///
  /// Called internally when HandshakeCoordinator reaches COMPLETE phase
  Future<void> onHandshakeComplete();

  /// Cleanup old handshake coordinator after successful completion
  /// Prevents stale coordinator from interfering with future handshakes
  void disposeHandshakeCoordinator();

  // ============================================================================
  // IDENTITY EXCHANGE (HANDSHAKE PHASE 1)
  // ============================================================================

  /// Request manual identity re-exchange with peer
  /// Recovers from identity desync by resending identity information
  ///
  /// Throws:
  ///   StateError if not connected
  Future<void> requestIdentityExchange();

  /// Trigger identity re-exchange after username change
  /// Propagates updated identity immediately to peer
  ///
  /// Throws:
  ///   StateError if not connected
  Future<void> triggerIdentityReExchange();

  /// Build deterministic collision hint for identity resolution
  /// Used to detect when two devices think they're talking to each other
  ///
  /// Returns:
  ///   Hint string or null if identity unavailable
  Future<String?> buildLocalCollisionHint();

  // ============================================================================
  // COLLISION & ASYMMETRIC CONTACT HANDLING
  // ============================================================================

  /// Dormant compatibility hook for a mutual-consent prompt.
  ///
  /// The current implementation is a no-op and has no active runtime caller.
  /// Do not use it as evidence that asymmetric relationships are repaired.
  Future<void> handleMutualConsentRequired();

  /// Dormant compatibility hook for an asymmetric-contact event.
  ///
  /// The current implementation is a no-op and has no active runtime caller.
  ///
  /// Args:
  ///   contactKey - Public key of contact in asymmetric relationship
  Future<void> handleAsymmetricContact(String contactKey);

  // ============================================================================
  // SECURITY & PRIVACY EVENTS
  // ============================================================================

  /// Stream of spy mode detection events
  /// Emitted when user sends messages to peer while in spy mode
  /// (i.e., has contact but hasn't revealed identity)
  Stream<SpyModeInfo> get spyModeDetectedStream;

  /// Stream of identity exposure events
  /// Emitted when user's identity is revealed to contact (via message)
  /// Contains contact name
  Stream<String> get identityRevealedStream;

  /// Emit a spy-mode detection event to listeners.
  void emitSpyModeDetected(SpyModeInfo info);

  /// Emit an identity revealed event to listeners.
  void emitIdentityRevealed(String contactId);

  /// Stream of handshake phase changes (for UI/diagnostics).
  /// READ-ONLY: Do not push messages into the underlying coordinator.
  Stream<ConnectionPhase> get handshakePhaseStream;

  // ============================================================================
  // HANDSHAKE STATE & UTILITIES
  // ============================================================================

  /// Convert ConnectionPhase enum to user-friendly string
  /// Used for logging and UI display
  ///
  /// Args:
  ///   phase - Handshake phase enum
  /// Returns:
  ///   Human-readable phase name
  String getPhaseMessage(String phase);

  /// Check if protocol message type is part of handshake
  /// Distinguishes handshake messages from regular chat messages
  ///
  /// Args:
  ///   messageType - Protocol message type to check
  /// Returns:
  ///   true if this is a handshake-related message
  bool isHandshakeMessage(String messageType);

  /// Get buffered messages awaiting identity establishment
  /// Used for debugging and diagnostics
  ///
  /// Returns:
  ///   List of buffered messages (in order received)
  List<dynamic> getBufferedMessages();

  /// Check if handshake is currently in progress
  bool get isHandshakeInProgress;

  /// Has handshake been completed at least once?
  /// (Used to determine if we can process regular messages)
  bool get hasHandshakeCompleted;

  /// Current handshake phase (if in progress)
  /// Returns null if no active handshake
  String? get currentHandshakePhase;

  /// Handle an incoming handshake protocol message (regardless of link
  /// direction). Buffers if the coordinator is not yet initialized.
  ///
  /// Returns true if the payload was recognized as a handshake protocol
  /// message (even if it was buffered).
  Future<bool> handleIncomingHandshakeMessage(
    Uint8List data, {
    bool isFromPeripheral,
  });
}
