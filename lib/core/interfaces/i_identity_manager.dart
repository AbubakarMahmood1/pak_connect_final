/// Identity Manager Interface
///
/// Manages user and contact identity:
/// - User's own username and persistent public key (Ed25519)
/// - Connected peer's display name and ephemeral/persistent keys
/// - Identity resolution (publicKey vs persistentKey)
/// - Ephemeral-to-persistent key mapping

abstract class IIdentityManager {
  // ============================================================================
  // USER IDENTITY (My side)
  // ============================================================================

  /// Initialize identity system: load username, create/load key pair, sign setup
  Future<void> initialize();

  /// Load user's username from persistent storage
  Future<void> loadUserName();

  /// Get user's Ed25519 public key (persistent, immutable identity)
  String? getMyPersistentId();

  /// Set user's display name (in memory and persistent storage)
  Future<void> setMyUserName(String name);

  /// Set username with cache invalidation and callbacks
  Future<void> setMyUserNameWithCallbacks(String name);

  // ============================================================================
  // PEER IDENTITY (Their side)
  // ============================================================================

  /// Set connected peer's display name
  void setOtherUserName(String? name);

  /// Set peer's both display name and session ID (from handshake)
  void setOtherDeviceIdentity(String deviceId, String displayName);

  /// Store peer's ephemeral ID (8-char session-specific ID from Noise handshake)
  void setTheirEphemeralId(String ephemeralId, String displayName);

  /// Store peer's persistent key and update mapping when available
  void setTheirPersistentKey(String persistentKey, {String? ephemeralId});

  /// Update the active session identifier (ephemeral or persistent)
  void setCurrentSessionId(String? sessionId);

  /// Look up peer's persistent public key by ephemeral ID
  String? getPersistentKeyFromEphemeral(String ephemeralId);

  /// Initialize SimpleCrypto with user's key pair for message signing
  void _initializeSigning();

  /// Initialize baseline encryption (SimpleCrypto)
  void _initializeCrypto();

  // ============================================================================
  // GETTERS (Active Session State)
  // ============================================================================

  /// User's username
  String? get myUserName;

  /// Connected peer's display name
  String? get otherUserName;

  /// User's Ed25519 public key (persistent)
  String? get myPersistentId;

  /// User's ephemeral ID (from EphemeralKeyManager, per-session)
  String? get myEphemeralId;

  /// Peer's ephemeral ID (8-char, session-specific, NULL until handshake)
  String? get theirEphemeralId;

  /// Peer's persistent public key (64-char, NULL until pairing complete)
  String? get theirPersistentKey;

  /// Currently active addressing ID for this contact
  /// - Pre-pairing: ephemeralId
  /// - Post-pairing: persistentKey
  String? get currentSessionId;

  // ============================================================================
  // CALLBACKS
  // ============================================================================

  /// Callback when user's username changes
  void Function(String newName)? onNameChanged;

  /// Callback when my username changes
  void Function(String newName)? onMyUsernameChanged;
}
