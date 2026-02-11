import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// BLE State Manager Facade Interface
///
/// High-level public API for BLE state management.
/// Delegates to underlying services: PairingService, SessionService, etc.
///
/// **Design Pattern**: Facade pattern provides drop-in replacement for original
/// BLEStateManager while coordinating internal services behind the scenes.
abstract class IBLEStateManagerFacade {
  // ============================================================================
  // INITIALIZATION & LIFECYCLE
  // ============================================================================

  /// Initialize BLE state system: load identity, setup crypto.
  Future<void> initialize();

  /// Load user's username from persistent storage.
  Future<void> loadUserName();

  /// Get user's Ed25519 persistent public key.
  Future<String> getMyPersistentId();

  /// Cleanup and disposal.
  void dispose();

  // ============================================================================
  // USER IDENTITY
  // ============================================================================

  /// Set user's display name (in memory and persistent storage).
  Future<void> setMyUserName(String name);

  /// Set username with cache invalidation.
  Future<void> setMyUserNameWithCallbacks(String name);

  /// Clear display name (preserves persistent ID for navigation).
  void clearOtherUserName();

  // ============================================================================
  // PEER IDENTITY
  // ============================================================================

  /// Set connected peer's display name.
  void setOtherUserName(String? name);

  /// Set peer's both display name and session ID (from handshake).
  void setOtherDeviceIdentity(String deviceId, String displayName);

  /// Store peer's ephemeral ID (from Noise handshake).
  void setTheirEphemeralId(String ephemeralId, String displayName);

  /// Get appropriate ID for addressing this contact.
  String? getRecipientId();

  /// Get ID type for logging ("persistent" or "ephemeral").
  String getIdType();

  /// Look up persistent key by ephemeral ID.
  String? getPersistentKeyFromEphemeral(String ephemeralId);

  // ============================================================================
  // CONTACT REPOSITORY ACCESS (CRUD)
  // ============================================================================

  /// Save contact to repository.
  Future<void> saveContact(String publicKey, String userName);

  /// Retrieve single contact by key.
  Future<Contact?> getContact(String publicKey);

  /// Get all contacts from repository.
  Future<Map<String, Contact>> getAllContacts();

  /// Get display name for a contact key.
  Future<String?> getContactName(String publicKey);

  /// Mark contact as verified (trusted).
  Future<void> markContactVerified(String publicKey);

  /// Get trust status (newContact/trusted/verified).
  Future<TrustStatus> getContactTrustStatus(String publicKey);

  /// Detect if display name's public key changed (impersonation check).
  Future<bool> hasContactKeyChanged(
    String publicKey,
    String currentDisplayName,
  );

  // ============================================================================
  // PAIRING FLOW (Delegates to StateCoordinator)
  // ============================================================================

  /// Initiate pairing (user clicks "Pair" button).
  Future<void> sendPairingRequest();

  /// Receive pairing request from peer.
  Future<void> handlePairingRequest(ProtocolMessage message);

  /// User accepts pairing request.
  Future<void> acceptPairingRequest();

  /// User rejects pairing request.
  void rejectPairingRequest();

  /// Receive pairing accept response.
  Future<void> handlePairingAccept(ProtocolMessage message);

  /// Receive pairing cancel.
  void handlePairingCancel(ProtocolMessage message);

  /// Cancel pairing at any stage.
  void cancelPairing({String? reason});

  // ============================================================================
  // CONTACT REQUEST FLOW (Delegates to StateCoordinator)
  // ============================================================================

  /// Receive contact request from peer.
  Future<void> handleContactRequest(String publicKey, String displayName);

  /// User accepts pending contact request.
  Future<void> acceptContactRequest();

  /// User rejects pending contact request.
  void rejectContactRequest();

  /// Send contact request (legacy).
  Future<bool> sendContactRequest();

  /// Receive contact accept response.
  Future<void> handleContactAccept(String publicKey, String displayName);

  /// Receive contact reject response.
  void handleContactReject();

  /// Initiate contact request.
  Future<bool> initiateContactRequest();

  // ============================================================================
  // SECURITY & CONTACT STATUS
  // ============================================================================

  /// Ensure contact has both ECDH and conversation keys.
  Future<void> ensureContactMaximumSecurity(String contactPublicKey);

  /// Check if shared secret cached, restore in crypto.
  Future<bool> checkExistingPairing(String publicKey);

  /// Check for QR intro data (informational).
  Future<void> checkForQRIntroduction(String otherPublicKey, String otherName);

  /// Request security level sync from peer.
  Future<void> requestSecurityLevelSync();

  /// Handle security level sync response.
  Future<void> handleSecurityLevelSync(Map<String, dynamic> payload);

  /// Confirm and apply security level upgrade.
  Future<bool> confirmSecurityUpgrade(String publicKey, SecurityLevel newLevel);

  /// Reset contact security to LOW (for debugging/recovery).
  Future<bool> resetContactSecurity(String publicKey, String reason);

  // ============================================================================
  // CONTACT STATUS SYNCHRONIZATION (Delegates to SessionService)
  // ============================================================================

  /// Process incoming contact status from peer.
  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  );

  /// Request contact status exchange.
  Future<void> requestContactStatusExchange();

  /// Preserve last known contact relationship across mode switch.
  void preserveContactRelationship({
    String? otherPublicKey,
    String? otherName,
    bool? theyHaveUs,
    bool? weHaveThem,
  });

  // ============================================================================
  // SPY MODE (Delegates to StateCoordinator)
  // ============================================================================

  /// Reveal identity to friend in spy mode.
  Future<ProtocolMessage?> revealIdentityToFriend();

  // ============================================================================
  // SESSION LIFECYCLE
  // ============================================================================

  /// Track whether in peripheral or central mode.
  void setPeripheralMode(bool isPeripheral);

  /// Clear session state with optional preservation.
  void clearSessionState({bool preservePersistentId = false});

  /// Recover identity from storage after navigation.
  Future<void> recoverIdentityFromStorage();

  /// Get identity with fallback to repository.
  Future<Map<String, String?>> getIdentityWithFallback();

  // ============================================================================
  // STATE QUERIES & GETTERS
  // ============================================================================

  /// User's username.
  String? get myUserName;

  /// Connected peer's display name.
  String? get otherUserName;

  /// Is connected to a peer.
  bool get isConnected;

  /// Whether in peripheral mode.
  bool get isPeripheralMode;

  /// Has pending contact request.
  bool get hasContactRequest;

  /// Display name of pending contact requester.
  String? get pendingContactName;

  /// Whether peer has us in their contacts.
  bool get theyHaveUsAsContact;

  /// Whether we already have the peer in contacts (legacy async check).
  Future<bool> get weHaveThemAsContact;

  /// User's persistent public key.
  String? get myPersistentId;

  /// Peer's ephemeral ID (session-specific).
  String? get myEphemeralId;

  /// Peer's ephemeral ID.
  String? get theirEphemeralId;

  /// Peer's persistent public key.
  String? get theirPersistentKey;

  /// Currently active session ID.
  String? get currentSessionId;

  /// Current pairing state.
  dynamic get currentPairing;

  /// Whether paired (persistent key exchange complete).
  bool get isPaired;

  // ============================================================================
  // CALLBACKS (Event emissions to UI/Providers)
  // ============================================================================

  /// Callback when new device discovered via BLE.
  void Function(dynamic device, int? rssi)? onDeviceDiscovered;

  /// Callback when message successfully sent.
  void Function(String messageId, bool success)? onMessageSent;

  /// Typed callback when message successfully sent (wraps string payload).
  void Function(MessageId messageId, bool success)? onMessageSentIds;

  /// Callback when user name changes.
  void Function(String? newName)? onNameChanged;
  void Function(String newName)? onMyUsernameChanged;

  /// Callback to send pairing code to peer.
  void Function(String code)? onSendPairingCode;

  /// Callback to send pairing verification.
  void Function(String verification)? onSendPairingVerification;

  /// Callback when contact request received.
  void Function(String publicKey, String displayName)? onContactRequestReceived;

  /// Callback when contact request completed.
  void Function(bool success)? onContactRequestCompleted;

  /// Callback to send contact request.
  void Function(String publicKey, String displayName)? onSendContactRequest;

  /// Callback to send contact accept.
  void Function(String publicKey, String displayName)? onSendContactAccept;

  /// Callback to send contact reject.
  void Function()? onSendContactReject;

  /// Callback to send contact status.
  void Function(ProtocolMessage message)? onSendContactStatus;

  /// Callback when asymmetric contact detected.
  void Function(String publicKey, String displayName)?
  onAsymmetricContactDetected;

  /// Callback when mutual consent required.
  void Function(String publicKey, String displayName)? onMutualConsentRequired;

  /// Callback when spy mode detected.
  void Function(SpyModeInfo info)? onSpyModeDetected;

  /// Callback when identity revealed.
  void Function(String contactId)? onIdentityRevealed;

  /// Callback to send pairing request.
  void Function(ProtocolMessage message)? onSendPairingRequest;

  /// Callback to send pairing accept.
  void Function(ProtocolMessage message)? onSendPairingAccept;

  /// Callback to send pairing cancel.
  void Function(ProtocolMessage message)? onSendPairingCancel;

  /// Callback when pairing cancelled.
  void Function()? onPairingCancelled;

  /// Callback to send persistent key exchange.
  void Function(ProtocolMessage message)? onSendPersistentKeyExchange;
}

extension BleStateManagerFacadeIds on IBLEStateManagerFacade {
  set onMessageSentIdCallback(
    void Function(MessageId messageId, bool success)? callback,
  ) => onMessageSentIds = callback;
}
