import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_identity_manager.dart';
import '../repositories/user_preferences.dart';
import '../../core/security/ephemeral_key_manager.dart';

/// Identity Manager
///
/// Manages user and peer identity:
/// - User's own username and persistent Ed25519 public key
/// - Connected peer's display name and ephemeral/persistent keys
/// - Identity resolution (ephemeral vs persistent)
/// - Ephemeral-to-persistent key mapping
class IdentityManager implements IIdentityManager {
  final _logger = Logger('IdentityManager');

  final UserPreferences _userPreferences;

  // ============================================================================
  // USER IDENTITY (My side)
  // ============================================================================

  /// User's display name (cached, synced to storage)
  String? _myUserName;

  /// User's Ed25519 public key (persistent, immutable)
  String? _myPersistentId;

  // ============================================================================
  // PEER IDENTITY (Their side)
  // ============================================================================

  /// Connected peer's display name
  String? _otherUserName;

  /// Peer's ephemeral ID (8-char session-specific ID from Noise handshake)
  /// Pre-pairing: used for addressing
  /// Post-pairing: updated when connection changes
  String? _theirEphemeralId;

  /// Peer's persistent public key (64-char Ed25519, NULL until pairing complete)
  /// Only set after successful pairing verification
  String? _theirPersistentKey;

  /// Currently active addressing ID for this contact
  /// - Pre-pairing: _theirEphemeralId
  /// - Post-pairing: _theirPersistentKey
  String? _currentSessionId;

  /// Mapping from ephemeral ID → persistent public key (for identity resolution)
  final Map<String, String> _ephemeralToPersistent = {};

  // ============================================================================
  // CALLBACKS
  // ============================================================================

  @override
  void Function(String newName)? onNameChanged;

  @override
  void Function(String newName)? onMyUsernameChanged;

  // ============================================================================
  // CONSTRUCTOR
  // ============================================================================

  IdentityManager({UserPreferences? userPreferences})
    : _userPreferences = userPreferences ?? UserPreferences();

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

  @override
  Future<void> initialize() async {
    _logger.info('🚀 Starting IdentityManager initialization...');
    final startTime = DateTime.now();

    try {
      // Load user's username
      _logger.info('👤 Loading user name...');
      final nameStart = DateTime.now();
      await loadUserName();
      _logger.info(
        '✅ User name loaded in ${DateTime.now().difference(nameStart).inMilliseconds}ms: "$_myUserName"',
      );

      // Get or create key pair
      _logger.info('🔑 Getting or creating key pair...');
      final keyStart = DateTime.now();
      await _userPreferences.getOrCreateKeyPair();
      _logger.info(
        '✅ Key pair ready in ${DateTime.now().difference(keyStart).inMilliseconds}ms',
      );

      // Load persistent public key
      _logger.info('🆔 Getting public key...');
      final pubKeyStart = DateTime.now();
      _myPersistentId = await _userPreferences.getPublicKey();
      _logger.info(
        '✅ Public key retrieved in ${DateTime.now().difference(pubKeyStart).inMilliseconds}ms: "${_truncateId(_myPersistentId)}"',
      );

      // Initialize signing
      _logger.info('✍️ Initializing signing...');
      final signStart = DateTime.now();
      _initializeSigning();
      _logger.info(
        '✅ Signing initialized in ${DateTime.now().difference(signStart).inMilliseconds}ms',
      );

      // Initialize crypto
      _logger.info('🔐 Initializing crypto...');
      final cryptoStart = DateTime.now();
      _initializeCrypto();
      _logger.info(
        '✅ Crypto initialized in ${DateTime.now().difference(cryptoStart).inMilliseconds}ms',
      );

      final totalTime = DateTime.now().difference(startTime);
      _logger.info(
        '🎉 IdentityManager initialization complete in ${totalTime.inMilliseconds}ms',
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Failed to initialize IdentityManager', e, stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> loadUserName() async {
    try {
      _myUserName = await _userPreferences.getUserName();
      _logger.fine('Loaded user name: "$_myUserName"');
    } catch (e) {
      _logger.warning('Failed to load user name: $e');
      _myUserName = null;
    }
  }

  // ============================================================================
  // PRIVATE INITIALIZATION HELPERS
  // ============================================================================

  void _initializeSigning() {
    try {
      _logger.fine('Initializing SimpleCrypto signing...');
      // Note: SimpleCrypto initialization happens during initialize()
      // This method is kept for interface compliance but the actual
      // initialization happens via getOrCreateKeyPair and getPublicKey/getPrivateKey
      _logger.fine('Signing initialization complete');
    } catch (e) {
      _logger.warning('Failed to initialize signing: $e');
    }
  }

  void _initializeCrypto() {
    try {
      _logger.fine('Initializing baseline encryption (SimpleCrypto)...');
      // SimpleCrypto initialization is handled by UserPreferences
      // This method is kept for interface compliance
      _logger.fine('Crypto initialization complete');
    } catch (e) {
      _logger.warning('Failed to initialize crypto: $e');
    }
  }

  /// Synchronize cached identity fields from an existing state manager.
  ///
  /// This is used by BLEStateManagerFacade to keep the extracted
  /// IdentityManager in sync with the legacy BLEStateManager during
  /// the migration period.
  void syncFromLegacy({
    String? myUserName,
    String? otherUserName,
    String? myPersistentId,
    String? theirEphemeralId,
    String? theirPersistentKey,
    String? currentSessionId,
  }) {
    _myUserName = myUserName ?? _myUserName;
    _otherUserName = otherUserName ?? _otherUserName;
    _myPersistentId = myPersistentId ?? _myPersistentId;
    _theirEphemeralId = theirEphemeralId ?? _theirEphemeralId;
    _theirPersistentKey = theirPersistentKey ?? _theirPersistentKey;
    _currentSessionId = currentSessionId ?? _currentSessionId;
  }

  // ============================================================================
  // USER IDENTITY (My side)
  // ============================================================================

  @override
  String? getMyPersistentId() {
    return _myPersistentId;
  }

  @override
  Future<void> setMyUserName(String name) async {
    try {
      _logger.fine('Setting my user name to: "$name"');
      final oldName = _myUserName;

      // Update internal cache
      _myUserName = name;

      // Update persistent storage
      await _userPreferences.setUserName(name);

      // Trigger callback if changed
      if (oldName != name && onMyUsernameChanged != null) {
        onMyUsernameChanged!(name);
      }

      _logger.fine('User name updated successfully: "$name"');
    } catch (e) {
      _logger.warning('Failed to set user name: $e');
      _myUserName = null;
      rethrow;
    }
  }

  @override
  Future<void> setMyUserNameWithCallbacks(String name) async {
    try {
      // Set username and trigger callback
      await setMyUserName(name);

      // Force reload from storage to ensure consistency
      await loadUserName();

      _logger.fine(
        'User name set with enhanced callbacks and cache invalidation',
      );
    } catch (e) {
      _logger.warning('Failed to set user name with callbacks: $e');
      rethrow;
    }
  }

  // ============================================================================
  // PEER IDENTITY (Their side)
  // ============================================================================

  @override
  void setOtherUserName(String? name) {
    try {
      _logger.fine(
        'Setting other user name to: "$name" (was: "$_otherUserName")',
      );
      _otherUserName = name;

      // Trigger callback
      onNameChanged?.call(_otherUserName ?? '');

      if (name != null && name.isNotEmpty) {
        _logger.fine('✅ Name exchange complete');
      } else {
        _logger.fine('⚠️ Name cleared');
      }
    } catch (e) {
      _logger.warning('Failed to set other user name: $e');
    }
  }

  @override
  void setOtherDeviceIdentity(String deviceId, String displayName) {
    try {
      _logger.fine(
        'Setting other device identity: "$displayName" (ID: $deviceId)',
      );

      _otherUserName = displayName;
      _currentSessionId = deviceId;

      // Trigger callback
      onNameChanged?.call(_otherUserName ?? '');

      if (displayName.isNotEmpty) {
        _logger.fine('✅ Device identity exchange complete');
      } else {
        _logger.fine('⚠️ Device identity cleared');
      }
    } catch (e) {
      _logger.warning('Failed to set other device identity: $e');
    }
  }

  @override
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    try {
      _logger.fine('Storing their ephemeral ID: $ephemeralId ($displayName)');
      _theirEphemeralId = ephemeralId;

      // Update current session ID to ephemeral (will be updated to persistent after pairing)
      if (_currentSessionId == null || _currentSessionId!.isEmpty) {
        _currentSessionId = ephemeralId;
      }

      _logger.fine('Ephemeral ID stored successfully');
    } catch (e) {
      _logger.warning('Failed to set their ephemeral ID: $e');
    }
  }

  @override
  void setTheirPersistentKey(String persistentKey, {String? ephemeralId}) {
    try {
      _logger.fine(
        'Storing their persistent key: ${_truncateId(persistentKey)}',
      );
      _theirPersistentKey = persistentKey;
      if (ephemeralId != null && ephemeralId.isNotEmpty) {
        _ephemeralToPersistent[ephemeralId] = persistentKey;
      }

      // Prefer persistent key as the active session identifier once available
      _currentSessionId = persistentKey;
    } catch (e) {
      _logger.warning('Failed to set their persistent key: $e');
    }
  }

  @override
  void setCurrentSessionId(String? sessionId) {
    try {
      _currentSessionId = sessionId;
      _logger.fine('Updated current session ID: ${_truncateId(sessionId)}');
    } catch (e) {
      _logger.warning('Failed to update session id: $e');
    }
  }

  @override
  String? getPersistentKeyFromEphemeral(String ephemeralId) {
    final persistentKey = _ephemeralToPersistent[ephemeralId];
    if (persistentKey != null) {
      _logger.fine(
        'Resolved ephemeral ID $ephemeralId → ${_truncateId(persistentKey)}',
      );
    }
    return persistentKey;
  }

  // ============================================================================
  // GETTERS (Active Session State)
  // ============================================================================

  @override
  String? get myUserName => _myUserName;

  @override
  String? get otherUserName => _otherUserName;

  @override
  String? get myPersistentId => _myPersistentId;

  @override
  String? get myEphemeralId => EphemeralKeyManager.generateMyEphemeralKey();

  @override
  String? get theirEphemeralId => _theirEphemeralId;

  @override
  String? get theirPersistentKey => _theirPersistentKey;

  @override
  String? get currentSessionId => _currentSessionId;

  // ============================================================================
  // HELPER METHODS
  // ============================================================================

  /// Truncate long IDs for logging (show first 8 + last 8 chars)
  String _truncateId(String? id) {
    if (id == null || id.length <= 16) return id ?? '';
    return '${id.substring(0, 8)}...${id.substring(id.length - 8)}';
  }
}
