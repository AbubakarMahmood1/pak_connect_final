// ignore_for_file: avoid_print

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/models/pairing_state.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/models/protocol_message.dart';
import '../../core/services/security_manager.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/interfaces/i_identity_manager.dart';
import 'chat_migration_service.dart';
import 'contact_request_controller.dart';
import 'contact_status_sync_controller.dart';
import 'pairing_flow_controller.dart';
import 'pairing_lifecycle_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/bluetooth/identity_session_state.dart';
import '../../domain/values/id_types.dart';

class BLEStateManager {
  final _logger = Logger('BLEStateManager');

  // User and contact management
  final ContactRepository _contactRepository = ContactRepository();
  final UserPreferences _userPreferences = UserPreferences();

  final Map<String, String> _conversationKeys = {};

  String? _myUserName;
  String? _otherUserName;
  String? _myPersistentId;
  final IIdentityManager? _identityManager;

  // ============================================================================
  // REFACTORED IDENTITY TRACKING (clearer naming for ephemeral vs persistent)
  // ============================================================================

  final IdentitySessionState _identityState = IdentitySessionState();

  // Proxies for existing code paths (migration aid)
  String? get _currentSessionId => _identityState.currentSessionId;
  set _currentSessionId(String? value) =>
      _identityState.currentSessionId = value;

  String? get _theirEphemeralId => _identityState.theirEphemeralId;
  set _theirEphemeralId(String? value) =>
      _identityState.theirEphemeralId = value;

  String? get _theirPersistentKey => _identityState.theirPersistentKey;
  set _theirPersistentKey(String? value) =>
      _identityState.theirPersistentKey = value;

  Map<String, String> get _ephemeralToPersistent =>
      _identityState.ephemeralToPersistent;

  // ============================================================================
  // END REFACTORED IDENTITY TRACKING
  // ============================================================================
  // Peripheral mode tracking
  bool _isPeripheralMode = false;

  // ========== SPY MODE CALLBACKS ==========

  /// Callback when spy mode is detected (chatting with friend anonymously)
  void Function(SpyModeInfo info)? _onSpyModeDetected;
  Function(SpyModeInfo info)? get onSpyModeDetected => _onSpyModeDetected;
  set onSpyModeDetected(Function(SpyModeInfo info)? callback) {
    _onSpyModeDetected = callback;
    _pairingController.onSpyModeDetected = callback;
  }

  /// Callback when identity is revealed in spy mode
  void Function(String contactName)? onIdentityRevealed;

  // Getters
  String? get myUserName => _myUserName;
  String? get otherUserName => _otherUserName;
  bool get isPeripheralMode => _isPeripheralMode;
  String? get myPersistentId => _myPersistentId;
  PairingInfo? get currentPairing => _pairingController.currentPairing;
  bool get hasContactRequest => _contactRequestController.hasPendingRequest;
  String? get pendingContactName =>
      _contactRequestController.pendingContactName;
  bool get theyHaveUsAsContact =>
      _contactStatusSyncController.theyHaveUsAsContact;

  // REFACTORED: Identity getters with clear naming
  // 🔧 FIX BUG #3: myEphemeralId now comes from EphemeralKeyManager (single source of truth)
  String? get myEphemeralId => EphemeralKeyManager.generateMyEphemeralKey();
  String? get theirEphemeralId => _theirEphemeralId;
  String? get theirPersistentKey => _theirPersistentKey;

  /// The currently active ID for this session
  /// Pre-pairing: ephemeral ID (8 chars)
  /// Post-pairing: persistent key (64 chars)
  String? get currentSessionId => _currentSessionId;

  late final ContactStatusSyncController _contactStatusSyncController;
  late final ContactRequestController _contactRequestController;
  late final PairingFlowController _pairingController;

  ContactRepository get contactRepository => _contactRepository;

  // Connection status getter for integration
  bool get isConnected => _otherUserName != null && _otherUserName!.isNotEmpty;

  // Callbacks
  Function(String?)? onNameChanged;
  Function(String)? get onSendPairingCode =>
      _pairingController.onSendPairingCode;
  set onSendPairingCode(Function(String)? callback) =>
      _pairingController.onSendPairingCode = callback;
  Function(String)? get onSendPairingVerification =>
      _pairingController.onSendPairingVerification;
  set onSendPairingVerification(Function(String)? callback) =>
      _pairingController.onSendPairingVerification = callback;
  Function(String, String)? get onContactRequestReceived =>
      _contactRequestController.onContactRequestReceived;
  set onContactRequestReceived(Function(String, String)? callback) =>
      _contactRequestController.onContactRequestReceived = callback;
  Function(bool)? get onContactRequestCompleted =>
      _contactRequestController.onContactRequestCompleted;
  set onContactRequestCompleted(Function(bool)? callback) {
    _contactRequestController.onContactRequestCompleted = callback;
    _pairingController.onContactRequestCompleted = callback;
    _contactStatusSyncController.onContactRequestCompleted = callback;
  }

  Function(String, String)? get onSendContactRequest =>
      _contactRequestController.onSendContactRequest;
  set onSendContactRequest(Function(String, String)? callback) =>
      _contactRequestController.onSendContactRequest = callback;
  Function(String, String)? get onSendContactAccept =>
      _contactRequestController.onSendContactAccept;
  set onSendContactAccept(Function(String, String)? callback) =>
      _contactRequestController.onSendContactAccept = callback;
  Function()? get onSendContactReject =>
      _contactRequestController.onSendContactReject;
  set onSendContactReject(Function()? callback) =>
      _contactRequestController.onSendContactReject = callback;
  Function(ProtocolMessage)? get onSendContactStatus =>
      _contactStatusSyncController.onSendContactStatus;
  set onSendContactStatus(Function(ProtocolMessage)? callback) =>
      _contactStatusSyncController.onSendContactStatus = callback;
  Function(String, String)? get onAsymmetricContactDetected =>
      _contactStatusSyncController.onAsymmetricContactDetected;
  set onAsymmetricContactDetected(Function(String, String)? callback) =>
      _contactStatusSyncController.onAsymmetricContactDetected =
          callback == null
          ? null
          : (publicKey, _) => callback(publicKey, _otherUserName ?? 'Unknown');
  Function(String, String)? onMutualConsentRequired;

  // Additional BLE integration callbacks
  Function(String messageId, bool success)? onMessageSent;
  Function(MessageId messageId, bool success)? onMessageSentIds;
  Function(dynamic device, int? rssi)? onDeviceDiscovered;

  // USERNAME PROPAGATION FIX: Username change callback
  Function(String)? onMyUsernameChanged;

  // STEP 3: Pairing request/accept flow callbacks
  Function(ProtocolMessage)? get onSendPairingRequest =>
      _pairingController.onSendPairingRequest;
  set onSendPairingRequest(Function(ProtocolMessage)? callback) =>
      _pairingController.onSendPairingRequest = callback;
  Function(ProtocolMessage)? get onSendPairingAccept =>
      _pairingController.onSendPairingAccept;
  set onSendPairingAccept(Function(ProtocolMessage)? callback) =>
      _pairingController.onSendPairingAccept = callback;
  Function(ProtocolMessage)? get onSendPairingCancel =>
      _pairingController.onSendPairingCancel;
  set onSendPairingCancel(Function(ProtocolMessage)? callback) =>
      _pairingController.onSendPairingCancel = callback;
  Function(String ephemeralId, String displayName)?
  get onPairingRequestReceived => _pairingController.onPairingRequestReceived;
  set onPairingRequestReceived(
    Function(String ephemeralId, String displayName)? callback,
  ) => _pairingController.onPairingRequestReceived = callback;
  Function()? get onPairingCancelled => _pairingController.onPairingCancelled;
  set onPairingCancelled(Function()? callback) =>
      _pairingController.onPairingCancelled = callback;
  Function(ProtocolMessage)? get onSendPersistentKeyExchange =>
      _pairingController.onSendPersistentKeyExchange;
  set onSendPersistentKeyExchange(Function(ProtocolMessage)? callback) =>
      _pairingController.onSendPersistentKeyExchange = callback;

  BLEStateManager({IIdentityManager? identityManager})
    : _identityManager = identityManager {
    _contactStatusSyncController = ContactStatusSyncController(
      logger: _logger,
      contactRepository: _contactRepository,
      myPersistentIdProvider: () => getMyPersistentId(),
      weHaveThemAsContactProvider: () async {
        if (_currentSessionId == null) return false;
        final contact = await _contactRepository.getContact(_currentSessionId!);
        return contact != null && contact.trustStatus == TrustStatus.verified;
      },
      currentSessionIdProvider: () => _currentSessionId,
      triggerMutualConsentPrompt: _triggerMutualConsentPrompt,
    );
    _contactRequestController = ContactRequestController(
      logger: _logger,
      contactRepository: _contactRepository,
      contactRequestTimeout: Duration(seconds: 30),
      myPersistentIdProvider: () => getMyPersistentId(),
      currentSessionIdProvider: () => _currentSessionId,
      otherUserNameProvider: () => _otherUserName,
      myUserNameProvider: () => _myUserName,
      conversationKeys: _conversationKeys,
      markBilateralSyncComplete:
          _contactStatusSyncController.markBilateralSyncComplete,
    );
    final pairingLifecycleService = PairingLifecycleService(
      logger: _logger,
      contactRepository: _contactRepository,
      identityState: _identityState,
      conversationKeys: _conversationKeys,
      myPersistentIdProvider: () => getMyPersistentId(),
      triggerChatMigration:
          ({
            required String ephemeralId,
            required String persistentKey,
            String? contactName,
          }) => _triggerChatMigration(
            ephemeralId: ephemeralId,
            persistentKey: persistentKey,
            contactName: contactName,
          ),
      identityManager: _identityManager,
    );
    _pairingController = PairingFlowController(
      logger: _logger,
      contactRepository: _contactRepository,
      identityState: _identityState,
      conversationKeys: _conversationKeys,
      myPersistentIdProvider: () => getMyPersistentId(),
      myUserNameProvider: () => _myUserName,
      otherUserNameProvider: () => _otherUserName,
      pairingLifecycleService: pairingLifecycleService,
    );
  }

  Future<void> initialize() async {
    _logger.info('🚀 Starting BLEStateManager initialization...');
    final startTime = DateTime.now();

    _logger.info('👤 Loading user name...');
    final nameStart = DateTime.now();
    await loadUserName();
    _logger.info(
      '✅ User name loaded in ${DateTime.now().difference(nameStart).inMilliseconds}ms: "$_myUserName"',
    );

    _logger.info('🔑 Getting or creating key pair...');
    final keyStart = DateTime.now();
    await _userPreferences.getOrCreateKeyPair();
    _logger.info(
      '✅ Key pair ready in ${DateTime.now().difference(keyStart).inMilliseconds}ms',
    );

    _logger.info('[BLEStateManager] 🆔 Getting public key...');
    final pubKeyStart = DateTime.now();
    _myPersistentId = await _userPreferences.getPublicKey();
    _logger.info(
      '[BLEStateManager] ✅ Public key retrieved in ${DateTime.now().difference(pubKeyStart).inMilliseconds}ms: "${_truncateId(_myPersistentId)}"',
    );

    // 🔧 FIX BUG #3: Removed duplicate ephemeral ID generation
    // Now using EphemeralKeyManager exclusively (single source of truth)
    // Ephemeral ID is obtained via myEphemeralId getter which calls EphemeralKeyManager.generateMyEphemeralKey()
    _logger.info(
      '[BLEStateManager] ✅ Using EphemeralKeyManager for ephemeral ID (single source of truth)',
    );

    _logger.info('🔐 Initializing crypto...');
    final cryptoStart = DateTime.now();
    await _initializeCrypto();
    _logger.info(
      '✅ Crypto initialized in ${DateTime.now().difference(cryptoStart).inMilliseconds}ms',
    );

    _logger.info('✍️ Initializing signing...');
    final signStart = DateTime.now();
    await _initializeSigning();
    _logger.info(
      '✅ Signing initialized in ${DateTime.now().difference(signStart).inMilliseconds}ms',
    );

    final totalTime = DateTime.now().difference(startTime);
    _logger.info(
      '🎉 BLEStateManager initialization complete in ${totalTime.inMilliseconds}ms',
    );
  }

  Future<void> loadUserName() async {
    _myUserName = await _userPreferences.getUserName();
    print('🐛 DEBUG NAME: loadUserName() loaded: "$_myUserName"');
  }

  Future<void> _initializeSigning() async {
    try {
      final publicKey = await _userPreferences.getPublicKey();
      final privateKey = await _userPreferences.getPrivateKey();

      if (publicKey.isNotEmpty && privateKey.isNotEmpty) {
        SimpleCrypto.initializeSigning(privateKey, publicKey);
        _logger.info('Message signing initialized');
      } else {
        _logger.warning('Cannot initialize signing - missing keys');
      }
    } catch (e) {
      _logger.warning('Failed to initialize signing: $e');
    }
  }

  Future<String> getMyPersistentId() async {
    return await _userPreferences.getPublicKey();
  }

  Future<void> setMyUserName(String name) async {
    print('🔧 NAME DEBUG: setMyUserName called with: "$name"');
    final oldName = _myUserName;

    // Update internal cache
    _myUserName = name;

    // Update persistent storage
    await _userPreferences.setUserName(name);

    // USERNAME PROPAGATION FIX: Trigger callback for reactive updates
    if (oldName != name && onMyUsernameChanged != null) {
      onMyUsernameChanged!(name);
      print('🔧 NAME DEBUG: Triggered username change callback');
    }

    print(
      '🔧 NAME DEBUG: setMyUserName completed, _myUserName is now: "$_myUserName"',
    );
  }

  /// ENHANCED: Set username with immediate cache invalidation and callback trigger
  Future<void> setMyUserNameWithCallbacks(String name) async {
    await setMyUserName(name);

    // Force reload from storage to ensure consistency
    await loadUserName();

    // If connected, the identity re-exchange should be handled by the caller
    print(
      '🔧 NAME DEBUG: Username set with enhanced callbacks and cache invalidation',
    );
  }

  void setOtherUserName(String? name) {
    print(
      '🐛 NAV DEBUG: setOtherUserName called with: "$name" (was: "$_otherUserName")',
    );
    _logger.info('Setting other user name: "$name" (was: "$_otherUserName")');
    _otherUserName = name;
    _identityState.lastKnownDisplayName = name;
    onNameChanged?.call(_otherUserName);

    if (name != null && name.isNotEmpty) {
      _logger.info('✅ Name exchange complete - UI should show connected now');
    } else {
      _logger.warning('❌ Name cleared - UI will show disconnected');
    }
  }

  void setOtherDeviceIdentity(String deviceId, String displayName) {
    print('🐛 NAV DEBUG: setOtherDeviceIdentity called');
    print('🐛 NAV DEBUG: - deviceId: $deviceId');
    print('🐛 NAV DEBUG: - displayName: "$displayName"');
    print('🐛 NAV DEBUG: - previous _currentSessionId: $_currentSessionId');

    _logger.info(
      'Setting other device identity: "$displayName" (ID: $deviceId)',
    );

    // INFINITE LOOP FIX: Reset sync state for new connection
    if (_currentSessionId != deviceId) {
      // This is a new contact, reset sync state
      _contactStatusSyncController.resetBilateralSyncStatus(deviceId);
    }

    _otherUserName = displayName;

    // REFACTORED: Set the current session ID
    // This will be the ephemeral ID initially, and updated to persistent key after pairing
    _currentSessionId = deviceId;

    onNameChanged?.call(_otherUserName);

    if (displayName.isNotEmpty) {
      _logger.info(
        '✅ Identity exchange complete - UI should show connected now',
      );
    } else {
      _logger.warning('⚠️ Identity cleared - UI will show disconnected');
    }
  }

  Future<void> saveContact(String publicKey, String userName) async {
    await _contactRepository.saveContact(publicKey, userName);
    _logger.info(
      '[BLEStateManager] Contact saved: $userName (${_truncateId(publicKey)})',
    );
  }

  Future<Contact?> getContact(String publicKey) async {
    return await _contactRepository.getContact(publicKey);
  }

  Future<Map<String, Contact>> getAllContacts() async {
    return await _contactRepository.getAllContacts();
  }

  Future<String?> getContactName(String publicKey) async {
    return await _contactRepository.getContactName(publicKey);
  }

  Future<void> markContactVerified(String publicKey) async {
    await _contactRepository.markContactVerified(publicKey);
  }

  Future<TrustStatus> getContactTrustStatus(String publicKey) async {
    final contact = await _contactRepository.getContact(publicKey);
    return contact?.trustStatus ?? TrustStatus.newContact;
  }

  Future<bool> hasContactKeyChanged(
    String publicKey,
    String currentDisplayName,
  ) async {
    final existingContact = await _contactRepository.getContact(publicKey);

    if (existingContact == null) {
      return false;
    }

    // Check if we've seen this display name with a different public key
    final allContacts = await _contactRepository.getAllContacts();
    final sameNameContacts = allContacts.values
        .where(
          (c) =>
              c.displayName == currentDisplayName && c.publicKey != publicKey,
        )
        .toList();

    return sameNameContacts.isNotEmpty;
  }

  String generatePairingCode() => _pairingController.generatePairingCode();
  Future<bool> completePairing(String theirCode) =>
      _pairingController.completePairing(theirCode);
  void handleReceivedPairingCode(String theirCode) =>
      _pairingController.handleReceivedPairingCode(theirCode);
  void handlePairingVerification(String theirSecretHash) =>
      _pairingController.handlePairingVerification(theirSecretHash);
  void setTheirEphemeralId(String ephemeralId, String displayName) =>
      _pairingController.setTheirEphemeralId(ephemeralId, displayName);
  Future<void> sendPairingRequest() => _pairingController.sendPairingRequest();
  void handlePairingRequest(ProtocolMessage message) =>
      _pairingController.handlePairingRequest(message);
  Future<void> acceptPairingRequest() =>
      _pairingController.acceptPairingRequest();
  Future<void> rejectPairingRequest() =>
      _pairingController.rejectPairingRequest();
  void handlePairingAccept(ProtocolMessage message) =>
      _pairingController.handlePairingAccept(message);
  void handlePairingCancel(ProtocolMessage message) =>
      _pairingController.handlePairingCancel(message);
  Future<void> cancelPairing({String? reason}) =>
      _pairingController.cancelPairing(reason: reason);
  Future<void> handlePersistentKeyExchange(String theirPersistentKey) =>
      _pairingController.handlePersistentKeyExchange(theirPersistentKey);
  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) => _pairingController.confirmSecurityUpgrade(publicKey, newLevel);
  Future<bool> resetContactSecurity(String publicKey, String reason) =>
      _pairingController.resetContactSecurity(publicKey, reason);
  Future<void> handleSecurityLevelSync(Map<String, dynamic> payload) =>
      _pairingController.handleSecurityLevelSync(payload);
  void clearPairing() => _pairingController.clearPairing();

  /// Reveal identity to friend in spy mode
  /// Call this when user chooses to reveal their identity
  Future<ProtocolMessage?> revealIdentityToFriend() async {
    try {
      final userPrefs = UserPreferences();
      final myPersistentKey = await userPrefs.getPublicKey();

      return await _identityState.createRevealMessage(
        myPersistentKey: myPersistentKey,
        nowMillis: () => DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      _logger.severe('🕵️ Failed to create reveal message: $e');
      return null;
    }
  }

  /// Helper: Look up persistent key from ephemeral ID
  String? getPersistentKeyFromEphemeral(String ephemeralId) {
    return _identityState.getPersistentKeyFromEphemeral(ephemeralId);
  }

  // ============================================================================
  // STEP 7: MESSAGE ADDRESSING
  // ============================================================================

  /// STEP 7.1: Get the appropriate ID to use when addressing this contact
  /// - Returns persistent public key if paired (after key exchange)
  /// - Returns ephemeral ID if not paired (privacy preserved)
  String? getRecipientId() {
    return _identityState.getRecipientId();
  }

  /// STEP 7.2: Check if we're paired with the current contact
  /// Paired = we've completed persistent key exchange
  bool get isPaired => _theirPersistentKey != null;

  /// STEP 7.3: Get ID type for logging
  String getIdType() {
    return _identityState.getIdType();
  }

  // ============================================================================
  // END STEP 7
  // ============================================================================

  // ============================================================================
  // STEP 6: CHAT ID MIGRATION
  // ============================================================================

  /// STEP 6: Trigger chat migration from ephemeral to persistent ID
  /// This is called automatically after persistent key exchange completes
  Future<void> _triggerChatMigration({
    required String ephemeralId,
    required String persistentKey,
    String? contactName,
  }) async {
    _logger.info('🔄 STEP 6: Triggering chat migration');
    _logger.info('   From: $ephemeralId');
    _logger.info('   To: $persistentKey');

    try {
      final migrationService = ChatMigrationService();

      final success = await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
        contactName: contactName,
      );

      if (success) {
        _logger.info('✅ STEP 6: Chat migration completed successfully');
      } else {
        _logger.info('ℹ️ STEP 6: No chat migration needed (no messages)');
      }
    } catch (e, stackTrace) {
      _logger.severe('❌ STEP 6: Chat migration failed', e, stackTrace);
    }
  }

  // ============================================================================
  // END STEP 6
  // ============================================================================

  // ============================================================================
  // END STEP 4
  // ============================================================================

  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  ) async {
    await _contactStatusSyncController.handleContactStatus(
      theyHaveUsAsContact,
      theirPublicKey,
    );
  }

  Future<void> initializeContactFlags() =>
      _contactStatusSyncController.initializeContactFlags();

  // Add this method back (simplified version):
  void preserveContactRelationship({
    String? otherPublicKey,
    String? otherName,
    bool? theyHaveUs,
    bool? weHaveThem,
  }) {
    if (otherPublicKey != null && otherName != null) {
      _logger.info(
        '[BLEStateManager] 🔄 Preserving contact relationship across mode switch:',
      );
      _logger.info('  Other: $otherName (${_truncateId(otherPublicKey)})');

      // Preserve identity
      _currentSessionId = otherPublicKey;
      _otherUserName = otherName;

      // Preserve their claim status if provided
      if (theyHaveUs != null) {
        _contactStatusSyncController.updateTheirContactClaim(theyHaveUs);
      }
    } else {
      _logger.info(
        '[BLEStateManager] 🔄 No previous relationship to preserve during mode switch',
      );

      // Clear session state for fresh start - don't preserve persistent ID for fresh connections
      clearSessionState(preservePersistentId: false);
    }
  }

  /// Trigger mutual consent prompt instead of automatic addition
  void _triggerMutualConsentPrompt(String theirPublicKey) {
    if (onMutualConsentRequired != null && _otherUserName != null) {
      _logger.info(
        '📱 MUTUAL CONSENT: Prompting user to initiate contact request for $_otherUserName',
      );
      onMutualConsentRequired?.call(theirPublicKey, _otherUserName!);
    }
  }

  /// User-initiated contact request (replaces automatic addition)
  Future<bool> initiateContactRequest() async {
    return await _contactRequestController.initiateContactRequest();
  }

  /// Handle contact request acceptance response
  void handleContactRequestAcceptResponse(
    String publicKey,
    String displayName,
  ) {
    _contactRequestController.handleContactRequestAcceptResponse(
      publicKey,
      displayName,
    );
  }

  /// Handle contact request rejection response
  void handleContactRequestRejectResponse() {
    _contactRequestController.handleContactRequestRejectResponse();
  }

  Future<bool> sendContactRequest() =>
      _contactRequestController.sendContactRequest();

  Future<bool> get weHaveThemAsContact =>
      _contactRequestController.weHaveThemAsContact;

  Future<void> handleContactRequest(String publicKey, String displayName) =>
      _contactRequestController.handleContactRequest(publicKey, displayName);

  Future<void> acceptContactRequest() =>
      _contactRequestController.acceptContactRequest();

  void rejectContactRequest() {
    _contactRequestController.rejectContactRequest();
  }

  void handleContactAccept(String publicKey, String displayName) {
    _contactRequestController.handleContactAccept(publicKey, displayName);
  }

  Future<void> sendPairingCode(String code) async {
    onSendPairingCode?.call(code);
  }

  Future<void> sendPairingVerification(String hash) async {
    onSendPairingVerification?.call(hash);
  }

  Future<bool> checkExistingPairing(String publicKey) async {
    try {
      // Check if we have a cached shared secret for this contact
      final cachedSecret = await _contactRepository.getCachedSharedSecret(
        publicKey,
      );

      if (cachedSecret != null) {
        _logger.info(
          'Found cached pairing/ECDH secret for ${publicKey.shortId(8)}...',
        );

        // Restore it in SimpleCrypto
        await SimpleCrypto.restoreConversationKey(publicKey, cachedSecret);

        // Update local cache
        _conversationKeys[publicKey] = cachedSecret;

        return true;
      }

      return false;
    } catch (e) {
      _logger.warning('Failed to check existing pairing: $e');
      return false;
    }
  }

  Future<void> ensureContactMaximumSecurity(String contactPublicKey) =>
      _pairingController.ensureContactMaximumSecurity(contactPublicKey);

  void handleContactReject() {
    _logger.info('📱 MUTUAL CONSENT: Contact request rejected');

    // Use the new mutual consent rejection handling
    handleContactRequestRejectResponse();

    onContactRequestCompleted?.call(false);
  }

  Future<void> checkForQRIntroduction(
    String otherPublicKey,
    String otherName,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final introData = prefs.getString('scanned_intro_$otherPublicKey');

    if (introData != null) {
      _logger.info(
        '👋 QR introduction found for $otherName - using normal pairing',
      );

      // Clean up the introduction data
      await prefs.remove('scanned_intro_$otherPublicKey');
    }

    // Always use existing pairing system - QR is just context
    // The existing onPairingRequired callback will be triggered by normal connection flow
  }

  Future<void> requestSecurityLevelSync() async {
    if (_currentSessionId == null) return;

    try {
      final myPublicKey = await getMyPersistentId();
      final mySecurityLevel = await _contactRepository.getContactSecurityLevel(
        _currentSessionId!,
      );

      final syncMessage = ProtocolMessage(
        type: ProtocolMessageType.contactStatus,
        payload: {
          'securityLevel': mySecurityLevel.index,
          'publicKey': myPublicKey,
          'requestSync': true,
        },
        timestamp: DateTime.now(),
      );

      onSendContactStatus?.call(syncMessage);
      print(
        '🔒 SECURITY SYNC: Requested sync with current level: ${mySecurityLevel.name}',
      );
    } catch (e) {
      _logger.warning('🔒 SECURITY SYNC FAILED: $e');
    }
  }

  void updateTheirContactClaim(bool theyClaimUs) =>
      _contactStatusSyncController.updateTheirContactClaim(theyClaimUs);

  String? getConversationKey(String publicKey) {
    return _conversationKeys[publicKey];
  }

  void setPeripheralMode(bool isPeripheral) {
    // ✅ DUAL-ROLE: In dual-role architecture, this tracks active connection type
    // (peripheral connection vs central connection), not device operating mode
    // Device is always BOTH peripheral (advertising) and central (scanning) simultaneously
    _isPeripheralMode = isPeripheral;

    // ✅ REMOVED CONFUSING LOG: No need to log "mode switch" in dual-role architecture
    // Ephemeral ID regeneration is handled by EphemeralKeyManager on session lifecycle
  }

  Future<void> requestContactStatusExchange() =>
      _contactStatusSyncController.requestContactStatusExchange();

  /// HELPER: Safe substring for logging IDs of any length
  String _truncateId(String? id, {int maxLength = 16}) {
    if (id == null) return 'null';
    if (id.length <= maxLength) return id;
    return '${id.substring(0, maxLength)}...';
  }

  void clearSessionState({bool preservePersistentId = false}) {
    _logger.warning(
      '🔍 [BLEStateManager] SESSION STATE CLEARING - CRITICAL NAVIGATION EVENT',
    );
    _logger.warning('  - BEFORE: otherUserName = "$_otherUserName"');
    _logger.warning(
      '  - BEFORE: otherDevicePersistentId = "${_truncateId(_currentSessionId)}"',
    );
    _logger.warning('  - preservePersistentId = $preservePersistentId');
    _logger.warning(
      '  - Called from: ${StackTrace.current.toString().split('\n').take(5).join(' -> ')}',
    );

    // FIX: Preserve identity during navigation to maintain connection state
    final previousName = _otherUserName;
    final previousId = _currentSessionId;

    if (!preservePersistentId) {
      // Actual disconnection - clear everything
      _otherUserName = null;
      _logger.warning(
        '  - ⚠️  CLEARED otherUserName: "$previousName" -> null (disconnection)',
      );

      _identityState.clear(preservePersistentId: false);
      _identityState.clearMappings();
      _logger.warning(
        '  - ⚠️  CLEARED persistent ID: "${_truncateId(previousId)}" -> null (connection loss)',
      );

      // 🔧 FIX: Removed SecurityManager.unregisterSessionMapping() - now using database ephemeral_id column
    } else {
      // Navigation only - preserve identity to maintain connection state
      _logger.warning(
        '  - ✅ PRESERVED otherUserName: "$_otherUserName" (navigation)',
      );
      _logger.warning(
        '  - ✅ PRESERVED persistent ID: "${_truncateId(_currentSessionId)}" (navigation)',
      );
      _identityState.clear(preservePersistentId: true);
    }

    _contactStatusSyncController.reset();

    // FIX: Only broadcast null name if we're actually clearing it (disconnection)
    if (!preservePersistentId) {
      _logger.warning(
        '  - 🚨 BROADCASTING NULL NAME TO UI (triggers disconnected state)',
      );
      onNameChanged?.call(null);
      _logger.warning(
        '🔍 [BLEStateManager] SESSION CLEAR COMPLETE - UI will now show DISCONNECTED',
      );
    } else {
      _logger.warning(
        '  - ✅ PRESERVING NAME BROADCAST (UI stays connected during navigation)',
      );
      _logger.warning(
        '🔍 [BLEStateManager] SESSION CLEAR COMPLETE - UI connection state preserved',
      );
    }
  }

  Future<void> _initializeCrypto() async {
    try {
      SimpleCrypto.initialize();
      _logger.info('Global baseline encryption initialized');
    } catch (e) {
      _logger.warning('Failed to initialize encryption: $e');
    }
  }

  void clearOtherUserName() {
    print('🐛 NAV DEBUG: clearOtherUserName() called');
    // For navigation, preserve persistent ID to maintain security state
    clearSessionState(preservePersistentId: true);
  }

  /// Recover identity information from persistent storage when session state is cleared during navigation
  Future<void> recoverIdentityFromStorage() async {
    if (_currentSessionId == null) {
      _logger.info(
        '[BLEStateManager] 🔄 RECOVERY: No persistent ID available for identity recovery',
      );
      return;
    }

    try {
      final displayName = await _identityState.recoverDisplayName((
        publicKey,
      ) async {
        final contact = await _contactRepository.getContact(publicKey);
        return contact?.displayName;
      });

      if (displayName != null && displayName.isNotEmpty) {
        _logger.info(
          '[BLEStateManager] 🔄 RECOVERY: Restored identity from contacts',
        );
        _logger.info('  - Public key: ${_truncateId(_currentSessionId)}');
        _logger.info('  - Display name: $displayName');

        // Restore session identity without triggering full connection flow
        _otherUserName = displayName;
        onNameChanged?.call(_otherUserName);

        _logger.info(
          '[BLEStateManager] ✅ RECOVERY: Identity successfully recovered from storage',
        );
      } else {
        _logger.warning(
          '[BLEStateManager] 🔄 RECOVERY: No contact found in repository for persistent ID',
        );
      }
    } catch (e) {
      _logger.warning(
        '[BLEStateManager] 🔄 RECOVERY: Failed to recover identity from storage: $e',
      );
    }
  }

  /// Get identity information with fallback to persistent storage
  Future<Map<String, String?>> getIdentityWithFallback() async {
    // Primary: Use session state if available
    if (_otherUserName != null && _otherUserName!.isNotEmpty) {
      return {
        'displayName': _otherUserName,
        'publicKey': _currentSessionId ?? '',
        'source': 'session',
      };
    }

    // Secondary: Use last known display name tracked in identity state
    if (_identityState.lastKnownDisplayName != null &&
        _identityState.lastKnownDisplayName!.isNotEmpty &&
        _currentSessionId != null) {
      return {
        'displayName': _identityState.lastKnownDisplayName,
        'publicKey': _currentSessionId!,
        'source': 'cache',
      };
    }

    // Fallback: Try to get from persistent storage
    if (_currentSessionId != null) {
      try {
        final contact = await _contactRepository.getContact(_currentSessionId!);
        if (contact != null) {
          return {
            'displayName': contact.displayName,
            'publicKey': _currentSessionId!,
            'source': 'repository',
          };
        }
      } catch (e) {
        _logger.warning('Failed to get fallback identity: $e');
      }
    }

    // Last resort: Return what we have
    return {
      'displayName': _otherUserName ?? 'Connected Device',
      'publicKey': _currentSessionId ?? '',
      'source': 'fallback',
    };
  }

  void dispose() {
    _contactStatusSyncController.dispose();
  }
}
