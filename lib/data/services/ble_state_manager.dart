// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/models/pairing_state.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/models/protocol_message.dart';
import '../../core/services/security_manager.dart';
import '../../core/security/ephemeral_key_manager.dart';
import 'chat_migration_service.dart';

class BLEStateManager {
  final _logger = Logger('BLEStateManager');

  // User and contact management
  final ContactRepository _contactRepository = ContactRepository();
  final UserPreferences _userPreferences = UserPreferences();

  PairingInfo? _currentPairing;
  final Map<String, String> _conversationKeys = {};

  String? _myUserName;
  String? _otherUserName;
  String? _myPersistentId;

  // ============================================================================
  // REFACTORED IDENTITY TRACKING (clearer naming for ephemeral vs persistent)
  // ============================================================================

  // SESSION STATE: The currently active ID for addressing this contact
  // Pre-pairing: points to _theirEphemeralId
  // Post-pairing: points to _theirPersistentKey
  String? _currentSessionId;

  // EPHEMERAL IDENTITY: Session-specific 8-char ID from handshake
  // - Generated per session, changes on reconnect
  // - Used for privacy-preserving initial communication
  // - NOT suitable for long-term storage or contact relationships
  // 🔧 FIX BUG #3: Removed _myEphemeralId - now use EphemeralKeyManager exclusively
  String? _theirEphemeralId;

  // PERSISTENT IDENTITY: Long-term 64-char Ed25519 public key
  // - Exchanged during pairing process (AFTER handshake)
  // - Used for contact relationships and encrypted communication
  // - Suitable for database storage and long-term identification
  String? _theirPersistentKey;

  // MAPPING: Ephemeral → Persistent (populated after key exchange)
  final Map<String, String> _ephemeralToPersistent = {};

  // ============================================================================
  // END REFACTORED IDENTITY TRACKING
  // ============================================================================

  String? _theirReceivedCode;
  bool _weEnteredCode = false;
  String? _lastSyncedTheirStatus;

  // Peripheral mode tracking
  bool _isPeripheralMode = false;

  Timer? _contactSyncRetryTimer;
  final Set<String> _processedContactMessages = {};

  // INFINITE LOOP FIX: Add status tracking and debouncing
  final Map<String, bool> _lastSentContactStatus =
      {}; // Track last sent status per contact
  final Map<String, DateTime> _lastStatusSentTime = {}; // Debouncing timestamps
  final Map<String, bool> _lastReceivedContactStatus =
      {}; // Track last received status
  final Map<String, bool> _bilateralSyncComplete =
      {}; // Track sync completion per contact
  static const Duration _statusCooldownDuration = Duration(
    seconds: 2,
  ); // Minimum time between status sends

  // ========== SPY MODE CALLBACKS ==========

  /// Callback when spy mode is detected (chatting with friend anonymously)
  void Function(SpyModeInfo info)? onSpyModeDetected;

  /// Callback when identity is revealed in spy mode
  void Function(String contactName)? onIdentityRevealed;

  // Getters
  String? get myUserName => _myUserName;
  String? get otherUserName => _otherUserName;
  bool get isPeripheralMode => _isPeripheralMode;
  String? get myPersistentId => _myPersistentId;
  PairingInfo? get currentPairing => _currentPairing;
  bool get hasContactRequest => _contactRequestPending;
  String? get pendingContactName => _pendingContactName;
  bool get theyHaveUsAsContact => _lastSyncedTheirStatus == 'yes';

  // REFACTORED: Identity getters with clear naming
  // 🔧 FIX BUG #3: myEphemeralId now comes from EphemeralKeyManager (single source of truth)
  String? get myEphemeralId => EphemeralKeyManager.generateMyEphemeralKey();
  String? get theirEphemeralId => _theirEphemeralId;
  String? get theirPersistentKey => _theirPersistentKey;

  /// The currently active ID for this session
  /// Pre-pairing: ephemeral ID (8 chars)
  /// Post-pairing: persistent key (64 chars)
  String? get currentSessionId => _currentSessionId;

  bool _contactRequestPending = false;
  String? _pendingContactPublicKey;
  String? _pendingContactName;
  Completer<bool>? _contactRequestCompleter;
  Completer<bool>? _pairingCompleter;
  Timer? _pairingTimeout;
  String? _receivedPairingCode;

  // Pending outgoing contact requests tracking
  final Map<String, Timer> _pendingOutgoingRequests = {};
  final Map<String, Completer<bool>> _outgoingRequestCompleters = {};
  static const Duration _contactRequestTimeout = Duration(seconds: 30);

  ContactRepository get contactRepository => _contactRepository;

  // Connection status getter for integration
  bool get isConnected => _otherUserName != null && _otherUserName!.isNotEmpty;

  // Callbacks
  Function(String?)? onNameChanged;
  Function(String)? onSendPairingCode;
  Function(String)? onSendPairingVerification;
  Function(String, String)? onContactRequestReceived;
  Function(bool)? onContactRequestCompleted;
  Function(String, String)? onSendContactRequest;
  Function(String, String)? onSendContactAccept;
  Function()? onSendContactReject;
  Function(ProtocolMessage)? onSendContactStatus;
  Function(String, String)? onAsymmetricContactDetected;
  Function(String, String)? onMutualConsentRequired;

  // Additional BLE integration callbacks
  Function(String messageId, bool success)? onMessageSent;
  Function(dynamic device, int? rssi)? onDeviceDiscovered;

  // USERNAME PROPAGATION FIX: Username change callback
  Function(String)? onMyUsernameChanged;

  // STEP 3: Pairing request/accept flow callbacks
  Function(ProtocolMessage)? onSendPairingRequest;
  Function(ProtocolMessage)? onSendPairingAccept;
  Function(ProtocolMessage)? onSendPairingCancel;
  Function(String ephemeralId, String displayName)? onPairingRequestReceived;
  Function()? onPairingCancelled;
  Function(ProtocolMessage)? onSendPersistentKeyExchange;

  BLEStateManager() {
    // Any synchronous initialization here
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
      _resetBilateralSyncStatus(deviceId);
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

  // In ble_state_manager.dart, update generatePairingCode method
  String generatePairingCode() {
    if (_currentPairing != null &&
        _currentPairing!.state == PairingState.displaying) {
      _logger.info(
        'Returning existing pairing code: ${_currentPairing!.myCode}',
      );
      return _currentPairing!.myCode;
    }

    final random = Random();
    final code = (random.nextInt(9000) + 1000).toString();
    _currentPairing = PairingInfo(myCode: code, state: PairingState.displaying);

    // Reset for new pairing attempt
    _receivedPairingCode = null;
    _pairingCompleter = Completer<bool>();

    // Set timeout for pairing
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 60), () {
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(false);
        _logger.warning('Pairing timeout');
      }
    });

    _logger.info('Generated new pairing code: $code');
    return code;
  }

  Future<bool> completePairing(String theirCode) async {
    if (_currentPairing == null) {
      _logger.warning('No pairing in progress');
      return false;
    }

    _logger.info('User entered code: $theirCode');

    // Mark that we've entered their code
    _weEnteredCode = true;
    _receivedPairingCode = theirCode;

    _currentPairing = _currentPairing!.copyWith(
      theirCode: theirCode,
      state: PairingState.verifying,
    );

    try {
      // Send our code to them (so they know we're ready)
      _logger.info(
        'Sending our code to other device: ${_currentPairing!.myCode}',
      );
      await sendPairingCode(_currentPairing!.myCode);

      // If we already received their code, we can verify immediately
      if (_theirReceivedCode != null) {
        _logger.info('We already have their code, proceeding to verify');
        return await _performVerification();
      } else {
        _logger.info('Waiting for other device to send their code...');

        // Set up completer if needed
        if (_pairingCompleter == null || _pairingCompleter!.isCompleted) {
          _pairingCompleter = Completer<bool>();
        }

        // Wait for the other device to send their code
        final success = await _pairingCompleter!.future.timeout(
          Duration(seconds: 60),
          onTimeout: () {
            _logger.warning('Timeout waiting for other device code');
            return false;
          },
        );
        print(
          '🔒 PAIRING DEBUG: Verification result - success=$success, sharedSecret=${_currentPairing?.sharedSecret?.substring(0, 8)}...',
        );
        return success;
      }
    } catch (e) {
      _logger.severe('Pairing failed: $e');
      _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
      return false;
    } finally {
      _pairingTimeout?.cancel();
    }
  }

  void handleReceivedPairingCode(String theirCode) {
    _logger.info('Received pairing code from other device: $theirCode');

    // Store their code
    _theirReceivedCode = theirCode;

    // If we haven't entered a code yet, just store it
    if (!_weEnteredCode || _receivedPairingCode == null) {
      _logger.info('Storing their code, waiting for user to enter code');
      return;
    }

    // Both sides have entered codes - verify they match!
    if (theirCode != _receivedPairingCode) {
      _logger.severe(
        'CODE MISMATCH! We entered: $_receivedPairingCode, They sent: $theirCode',
      );
      _logger.severe('This means they entered wrong code!');
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(false);
      }
      return;
    }

    _logger.info(
      'Codes match! Both devices entered correct codes. Starting verification...',
    );

    // Perform verification since both have entered codes
    _performVerification().then((success) {
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(success);
      }
    });
  }

  Future<bool> _performVerification() async {
    if (_currentPairing == null ||
        _receivedPairingCode == null ||
        _theirReceivedCode == null) {
      _logger.warning('Missing data for verification');
      return false;
    }

    try {
      final myPublicKey = await getMyPersistentId();
      // REFACTORED: Use currentSessionId which may be ephemeral or persistent
      final theirPublicKey = _currentSessionId;

      if (theirPublicKey == null) {
        _logger.warning('No other device public key');
        return false;
      }

      // Now compute shared secret (both devices will get same result)
      final sortedCodes = [_currentPairing!.myCode, _receivedPairingCode!]
        ..sort();
      final sortedKeys = [myPublicKey, theirPublicKey]..sort();

      final combinedData =
          '${sortedCodes[0]}:${sortedCodes[1]}:${sortedKeys[0]}:${sortedKeys[1]}';
      final sharedSecret = sha256.convert(utf8.encode(combinedData)).toString();

      _logger.info('Computed shared secret from codes');
      await _ensureContactExistsAfterHandshake(
        theirPublicKey,
        _otherUserName ?? 'User',
      );

      // Generate and send verification hash
      final secretHash = sha256
          .convert(utf8.encode(sharedSecret))
          .toString()
          .substring(0, 8);
      _logger.info('Sending verification hash: $secretHash');
      await sendPairingVerification(secretHash);

      // Store the conversation key
      _conversationKeys[theirPublicKey] = sharedSecret;
      await _contactRepository.cacheSharedSecret(theirPublicKey, sharedSecret);

      _currentPairing = _currentPairing!.copyWith(
        state: PairingState.completed,
        sharedSecret: sharedSecret,
      );

      _logger.info('✅ Pairing completed successfully!');

      // Initialize crypto with conversation key
      SimpleCrypto.initializeConversation(theirPublicKey, sharedSecret);

      // 🔧 NEW MODEL: Upgrade contact from LOW to MEDIUM security (simple UPDATE)
      if (_theirEphemeralId != null && _theirPersistentKey != null) {
        _logger.info('🔐 Upgrading contact from LOW to MEDIUM security');

        // Get existing contact (indexed by first ephemeral ID)
        final contact = await _contactRepository.getContact(_theirEphemeralId!);

        if (contact != null) {
          // Simple UPDATE - set persistent_public_key and upgrade security level
          await _contactRepository.saveContactWithSecurity(
            contact.publicKey, // Same immutable publicKey
            contact.displayName,
            SecurityLevel.medium, // Upgraded!
            currentEphemeralId: contact.currentEphemeralId,
            persistentPublicKey: _theirPersistentKey!, // NOW set
          );

          _logger.info('✅ Contact upgraded to MEDIUM');
          _logger.info(
            '   publicKey (unchanged): ${contact.publicKey.substring(0, 16)}...',
          );
          _logger.info(
            '   persistentPublicKey (now set): ${_theirPersistentKey!.substring(0, 16)}...',
          );

          // 🔑 CRITICAL: Register identity mapping for Noise session lookup
          // This enables encryption/decryption with persistent keys while Noise session
          // remains keyed by ephemeral ID
          SecurityManager.registerIdentityMapping(
            persistentPublicKey: _theirPersistentKey!,
            ephemeralID: _theirEphemeralId!,
          );
          _logger.info(
            '🔑 Registered Noise identity mapping: ${_theirPersistentKey!.substring(0, 8)}... → ${_theirEphemeralId!.substring(0, 8)}...',
          );

          // Trigger chat migration from ephemeral to persistent ID
          await _triggerChatMigration(
            ephemeralId: contact.publicKey,
            persistentKey: _theirPersistentKey!,
            contactName: _otherUserName,
          );
        } else {
          _logger.warning('⚠️ Cannot upgrade - contact not found');
        }
      }

      // STEP 4: Trigger persistent key exchange after verification succeeds
      await _exchangePersistentKeys();

      return true;
    } catch (e) {
      _logger.severe('Verification failed: $e');
      _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
      return false;
    }
  }

  // Method to handle verification
  void handlePairingVerification(String theirSecretHash) {
    _logger.info(
      'Received verification hash from other device: $theirSecretHash',
    );

    // Only log for debugging - both devices compute same secret independently
    // No need to compare hashes since we already verified codes match

    if (_currentPairing != null && _currentPairing!.sharedSecret != null) {
      final ourHash = sha256
          .convert(utf8.encode(_currentPairing!.sharedSecret!))
          .toString()
          .substring(0, 8);
      if (ourHash == theirSecretHash) {
        _logger.info('✅ Verification hashes match - pairing confirmed!');
      } else {
        _logger.severe('❌ Hash mismatch - something went wrong!');
      }
    }
  }

  // ============================================================================
  // STEP 3: THREE-PHASE PAIRING REQUEST/ACCEPT FLOW
  // ============================================================================

  /// Store the ephemeral ID received during handshake
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    _logger.info('Storing their ephemeral ID: $ephemeralId ($displayName)');
    _theirEphemeralId = ephemeralId;
    // Note: Display name is already set via setOtherUserName
  }

  /// STEP 3.1: User clicks "Pair" button - initiate pairing request
  Future<void> sendPairingRequest() async {
    if (_theirEphemeralId == null) {
      _logger.warning(
        '❌ Cannot send pairing request - no ephemeral ID (handshake incomplete)',
      );
      return;
    }

    // 🔧 FIX BUG #3: Get ephemeral ID from EphemeralKeyManager (single source of truth)
    final myEphId = myEphemeralId;
    if (myEphId == null) {
      _logger.warning(
        '❌ Cannot send pairing request - my ephemeral ID not set',
      );
      return;
    }

    _logger.info(
      '📤 STEP 3: Sending pairing request to ${_otherUserName ?? "Unknown"}',
    );

    final message = ProtocolMessage.pairingRequest(
      ephemeralId: myEphId,
      displayName: _myUserName ?? 'User',
    );

    // Update state to "waiting for accept"
    _currentPairing = PairingInfo(
      myCode: '', // Will be generated after they accept
      state: PairingState.pairingRequested,
      theirEphemeralId: _theirEphemeralId,
      theirDisplayName: _otherUserName,
    );

    // Send the request
    onSendPairingRequest?.call(message);

    // Start timeout (30 seconds for them to accept/reject)
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 30), () {
      if (_currentPairing?.state == PairingState.pairingRequested) {
        _logger.warning('⏰ Pairing request timeout - no response');
        _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
        onPairingCancelled?.call();
      }
    });

    _logger.info('✅ Pairing request sent, waiting for accept...');
  }

  /// STEP 3.2: Receive pairing request from other device - show accept/reject popup
  void handlePairingRequest(ProtocolMessage message) {
    final theirEphemeralId = message.payload['ephemeralId'] as String;
    final displayName = message.payload['displayName'] as String;

    _logger.info('📥 STEP 3: Received pairing request from $displayName');
    _logger.info('   Their ephemeral ID: $theirEphemeralId');

    // Store their ephemeral ID if we don't have it yet
    _theirEphemeralId ??= theirEphemeralId;

    // Verify it matches what we have from handshake
    if (_theirEphemeralId != theirEphemeralId) {
      _logger.warning(
        '⚠️ Ephemeral ID mismatch! Handshake: $_theirEphemeralId, Request: $theirEphemeralId',
      );
      // Use the one from the request as it's more recent
      _theirEphemeralId = theirEphemeralId;
    }

    // Update state to "request received"
    _currentPairing = PairingInfo(
      myCode: '', // Not generated yet
      state: PairingState.requestReceived,
      theirEphemeralId: theirEphemeralId,
      theirDisplayName: displayName,
    );

    // Trigger UI popup (show accept/reject dialog)
    _logger.info('🔔 Triggering pairing request popup for user');
    onPairingRequestReceived?.call(theirEphemeralId, displayName);
  }

  /// STEP 3.3: User clicks "Accept" on pairing request popup
  Future<void> acceptPairingRequest() async {
    if (_currentPairing?.state != PairingState.requestReceived) {
      _logger.warning('❌ No pending pairing request to accept');
      return;
    }

    // 🔧 FIX BUG #3: Get ephemeral ID from EphemeralKeyManager (single source of truth)
    final myEphId = myEphemeralId;
    if (myEphId == null) {
      _logger.warning('❌ Cannot accept - my ephemeral ID not set');
      return;
    }

    _logger.info('✅ STEP 3: User accepted pairing request');

    // Send accept message
    final message = ProtocolMessage.pairingAccept(
      ephemeralId: myEphId,
      displayName: _myUserName ?? 'User',
    );

    onSendPairingAccept?.call(message);

    // Both devices now proceed to PIN exchange
    // Generate PIN code
    final code = generatePairingCode();
    _logger.info('📱 Generated PIN code after accept: $code');

    // Update state to displaying
    _currentPairing = _currentPairing!.copyWith(state: PairingState.displaying);
  }

  /// STEP 3.4: User clicks "Reject" on pairing request popup
  Future<void> rejectPairingRequest() async {
    _logger.info('❌ STEP 3: User rejected pairing request');

    // Send cancel message
    final message = ProtocolMessage.pairingCancel(
      reason: 'User rejected pairing',
    );
    onSendPairingCancel?.call(message);

    // Reset state
    _currentPairing = null;
    _pairingTimeout?.cancel();
  }

  /// STEP 3.5: Handle pairing accept from other device
  void handlePairingAccept(ProtocolMessage message) {
    final theirEphemeralId = message.payload['ephemeralId'] as String;
    final displayName = message.payload['displayName'] as String;

    _logger.info('📥 STEP 3: Received pairing accept from $displayName');

    // Verify we sent a request
    if (_currentPairing?.state != PairingState.pairingRequested) {
      _logger.warning('⚠️ Received accept but we didn\'t send a request');
      return;
    }

    // Cancel timeout
    _pairingTimeout?.cancel();

    // Both devices now proceed to PIN exchange
    // Generate PIN code
    final code = generatePairingCode();
    _logger.info('📱 Generated PIN code after receiving accept: $code');

    // Update state to displaying
    _currentPairing = _currentPairing!.copyWith(
      state: PairingState.displaying,
      theirEphemeralId: theirEphemeralId,
      theirDisplayName: displayName,
    );

    _logger.info('✅ Pairing accepted, showing PIN dialog');
  }

  /// STEP 3.6: Handle pairing cancel from either device (atomic cancel)
  void handlePairingCancel(ProtocolMessage message) {
    final reason = message.payload['reason'] as String?;
    _logger.info(
      '❌ STEP 3: Pairing cancelled by other device${reason != null ? ": $reason" : ""}',
    );

    // Close any open dialogs/states
    _currentPairing = _currentPairing?.copyWith(state: PairingState.cancelled);
    _pairingTimeout?.cancel();

    // Notify UI to close popups/dialogs
    onPairingCancelled?.call();

    // Reset after a short delay
    Future.delayed(Duration(seconds: 1), () {
      _currentPairing = null;
    });
  }

  /// STEP 3.7: User/system cancels pairing at any stage
  Future<void> cancelPairing({String? reason}) async {
    if (_currentPairing == null) {
      _logger.info('No active pairing to cancel');
      return;
    }

    _logger.info(
      '🚫 STEP 3: Cancelling pairing${reason != null ? ": $reason" : ""}',
    );

    // Send cancel message to other device
    final message = ProtocolMessage.pairingCancel(
      reason: reason ?? 'User cancelled',
    );
    onSendPairingCancel?.call(message);

    // Reset local state
    _currentPairing = _currentPairing!.copyWith(state: PairingState.cancelled);
    _pairingTimeout?.cancel();

    // Reset after short delay
    Future.delayed(Duration(seconds: 1), () {
      _currentPairing = null;
    });
  }

  // ============================================================================
  // END STEP 3
  // ============================================================================

  // ============================================================================
  // STEP 4: PERSISTENT KEY EXCHANGE
  // ============================================================================

  /// STEP 4.1: Exchange persistent public keys after PIN verification succeeds
  /// This happens automatically after _performVerification() completes successfully
  Future<void> _exchangePersistentKeys() async {
    final myPersistentKey = await getMyPersistentId();

    if (_theirEphemeralId == null) {
      _logger.warning('❌ Cannot exchange persistent keys - no ephemeral ID');
      return;
    }

    // 🔧 FIX BUG #3: Use getter to get ephemeral ID from EphemeralKeyManager
    final myEphId = myEphemeralId;
    _logger.info(
      '🔑 STEP 4: Exchanging persistent keys (my ephemeral: $myEphId)',
    );

    // Create and send persistent key exchange message
    final message = ProtocolMessage.persistentKeyExchange(
      persistentPublicKey: myPersistentKey,
    );

    onSendPersistentKeyExchange?.call(message);
    _logger.info('📤 STEP 4: Sent my persistent public key');
  }

  /// STEP 4.2: Handle received persistent key from other device
  Future<void> handlePersistentKeyExchange(String theirPersistentKey) async {
    if (_theirEphemeralId == null) {
      _logger.warning('❌ Cannot process persistent key - no ephemeral ID');
      return;
    }

    // Store mapping: ephemeralId → persistentKey
    _ephemeralToPersistent[_theirEphemeralId!] = theirPersistentKey;

    // 🔧 NEW MODEL: Store persistent key for future pairing
    _theirPersistentKey = theirPersistentKey;

    // 🔧 NEW MODEL: Session ID is always the ephemeral ID
    _currentSessionId = _theirEphemeralId!;

    // 🔧 NEW MODEL: Create contact with immutable publicKey (first ephemeral ID)
    // persistent_public_key will be NULL at LOW security
    await _contactRepository.saveContactWithSecurity(
      _theirEphemeralId!, // publicKey = first ephemeral ID (immutable)
      _otherUserName ?? 'User',
      SecurityLevel.low,
      currentEphemeralId: _theirEphemeralId, // Track current session
      persistentPublicKey: null, // NULL at LOW security
    );

    // 🔑📊 HANDSHAKE COMPLETE - Consolidated key state (search: 🔑📊)
    final myPersistentKey = await getMyPersistentId();
    // 🔧 FIX BUG #3: Use getter to get ephemeral ID from EphemeralKeyManager
    final myEphId = myEphemeralId;
    _logger.info('═══════════════════════════════════════════════════════════');
    _logger.info('🔑📊 HANDSHAKE COMPLETE: ${_otherUserName ?? "Unknown"}');
    _logger.info(
      '🔑📊 My Keys:    Ephemeral=$myEphId | Persistent=${_truncateId(myPersistentKey)}',
    );
    _logger.info(
      '🔑📊 Their Keys: Ephemeral=$_theirEphemeralId | Persistent=${_truncateId(theirPersistentKey)}',
    );
    _logger.info('🔑📊 Security:   LOW (Noise session only - not paired yet)');
    _logger.info(
      '🔑📊 Contact ID: $_theirEphemeralId (ephemeral - will upgrade on pairing)',
    );
    _logger.info('🔑📊 NoiseSession: $_theirEphemeralId');
    _logger.info('═══════════════════════════════════════════════════════════');

    // 🔧 MODEL: Do NOT migrate chat yet - we're still at LOW security
    // Chat migration happens when upgrading to MEDIUM (pairing complete)
    _logger.info(
      '💡 Persistent key stored for future pairing - contact remains at LOW security',
    );
    _logger.info(
      '💡 When pairing completes, contact will upgrade to MEDIUM and migrate to persistent ID',
    );

    // ✅ SPY MODE: Detect if we're chatting with a friend anonymously
    await _detectSpyMode(theirPersistentKey);
  }

  /// Detect spy mode: check if peer is a friend and we have hints disabled
  Future<void> _detectSpyMode(String theirPersistentKey) async {
    try {
      // Check if this persistent key is in our contacts
      final contact = await _contactRepository.getContact(theirPersistentKey);

      if (contact != null) {
        // Friend detected!
        final userPrefs = UserPreferences();
        final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

        if (!hintsEnabled) {
          // Spy mode detected - we're chatting with friend anonymously
          _logger.info(
            '🕵️ SPY MODE: Connected to friend ${contact.displayName} anonymously',
          );
          _logger.info('🕵️   They don\'t know it\'s us!');

          // Trigger UI callback to show reveal prompt
          onSpyModeDetected?.call(
            SpyModeInfo(
              contactName: contact.displayName,
              ephemeralID: _theirEphemeralId!,
              persistentKey: theirPersistentKey,
            ),
          );
        } else {
          // Normal mode - hints are on, friend knows it's us
          _logger.info(
            '👤 NORMAL MODE: Connected to friend ${contact.displayName}',
          );
          _logger.info('👤   They can see it\'s us via hints');
        }
      } else {
        _logger.info('👥 NEW CONTACT: Not in our contact list yet');
      }
    } catch (e) {
      _logger.severe('Failed to detect spy mode: $e');
    }
  }

  /// Reveal identity to friend in spy mode
  /// Call this when user chooses to reveal their identity
  Future<ProtocolMessage?> revealIdentityToFriend() async {
    try {
      if (_theirEphemeralId == null) {
        _logger.warning('🕵️ Cannot reveal identity - no active session');
        return null;
      }

      final userPrefs = UserPreferences();
      final myPersistentKey = await userPrefs.getPublicKey();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Generate cryptographic proof of ownership
      // Sign a challenge that includes peer's ephemeral ID + timestamp
      // This proves we own the private key corresponding to myPersistentKey
      final challenge = '${_theirEphemeralId}_$timestamp';
      final proof = SimpleCrypto.signMessage(challenge) ?? '';

      if (proof.isEmpty) {
        _logger.severe('🕵️ Failed to generate cryptographic proof');
        return null;
      }

      // Create reveal message
      final revealMessage = ProtocolMessage.friendReveal(
        myPersistentKey: myPersistentKey,
        proof: proof,
        timestamp: timestamp,
      );

      _logger.info('🕵️ Created FRIEND_REVEAL message');
      return revealMessage;
    } catch (e) {
      _logger.severe('🕵️ Failed to create reveal message: $e');
      return null;
    }
  }

  /// Helper: Look up persistent key from ephemeral ID
  String? getPersistentKeyFromEphemeral(String ephemeralId) {
    return _ephemeralToPersistent[ephemeralId];
  }

  // ============================================================================
  // STEP 7: MESSAGE ADDRESSING
  // ============================================================================

  /// STEP 7.1: Get the appropriate ID to use when addressing this contact
  /// - Returns persistent public key if paired (after key exchange)
  /// - Returns ephemeral ID if not paired (privacy preserved)
  String? getRecipientId() {
    // 🔑 IDENTITY RESOLUTION: Return persistent key if paired, else ephemeral ID
    // Noise session manager will automatically resolve persistent → ephemeral internally
    if (_theirPersistentKey != null) {
      // Paired: Use persistent key (Noise will resolve to ephemeral session)
      return _theirPersistentKey;
    }
    // Not paired: Use ephemeral ID directly
    return _currentSessionId;
  }

  /// STEP 7.2: Check if we're paired with the current contact
  /// Paired = we've completed persistent key exchange
  bool get isPaired => _theirPersistentKey != null;

  /// STEP 7.3: Get ID type for logging
  String getIdType() {
    return isPaired ? 'persistent' : 'ephemeral';
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

  void handleContactStatus(bool theyHaveUsAsContact, String theirPublicKey) {
    print(
      '📱 PROTOCOL: Received contact status - they have us: $theyHaveUsAsContact',
    );

    // INFINITE LOOP FIX: Check if this is actually a new status
    final previousStatus = _lastReceivedContactStatus[theirPublicKey];
    if (previousStatus == theyHaveUsAsContact) {
      print(
        '📱 PROTOCOL: Same status received again - ignoring to prevent loop',
      );
      return;
    }

    // INFINITE LOOP FIX: Store the received status
    _lastReceivedContactStatus[theirPublicKey] = theyHaveUsAsContact;

    // Update session state (what they told us)
    updateTheirContactClaim(theyHaveUsAsContact);
    _checkForAsymmetricRelationship(theirPublicKey, theyHaveUsAsContact);

    // INFINITE LOOP FIX: Only process if sync isn't complete
    if (!_isBilateralSyncComplete(theirPublicKey)) {
      print('📱 PROTOCOL: Processing new contact status change');
      _performBilateralContactSync(theirPublicKey, theyHaveUsAsContact);
    } else {
      print('📱 PROTOCOL: Bilateral sync already complete - no action needed');
    }
  }

  /// INFINITE LOOP FIX: Check if bilateral sync is complete
  bool _isBilateralSyncComplete(String theirPublicKey) {
    return _bilateralSyncComplete[theirPublicKey] ?? false;
  }

  /// INFINITE LOOP FIX: Mark bilateral sync as complete
  void _markBilateralSyncComplete(String theirPublicKey) {
    _bilateralSyncComplete[theirPublicKey] = true;
    print(
      '[BLEStateManager] 📱 SYNC COMPLETE: Marked bilateral sync complete for ${_truncateId(theirPublicKey)}',
    );
  }

  /// INFINITE LOOP FIX: Reset sync completion (for new connections)
  void _resetBilateralSyncStatus(String theirPublicKey) {
    _bilateralSyncComplete[theirPublicKey] = false;
    _lastSentContactStatus.remove(theirPublicKey);
    _lastStatusSentTime.remove(theirPublicKey);
    _lastReceivedContactStatus.remove(theirPublicKey);
    print(
      '[BLEStateManager] 📱 SYNC RESET: Reset bilateral sync status for ${_truncateId(theirPublicKey)}',
    );
  }

  /// INFINITE LOOP FIX: Send contact status only if changed or cooldown expired
  Future<void> _sendContactStatusIfChanged(
    bool weHaveThem,
    String theirPublicKey,
  ) async {
    // Check if status changed
    final lastSentStatus = _lastSentContactStatus[theirPublicKey];
    final statusChanged = lastSentStatus != weHaveThem;

    // Check cooldown period
    final lastSentTime = _lastStatusSentTime[theirPublicKey];
    final cooldownExpired =
        lastSentTime == null ||
        DateTime.now().difference(lastSentTime) > _statusCooldownDuration;

    if (statusChanged || (lastSentStatus == null && cooldownExpired)) {
      print(
        '📱 EXCHANGE: Sending our contact status: $weHaveThem (changed: $statusChanged, cooldown: $cooldownExpired)',
      );

      // Update tracking
      _lastSentContactStatus[theirPublicKey] = weHaveThem;
      _lastStatusSentTime[theirPublicKey] = DateTime.now();

      // Send the actual status
      await _doSendContactStatus(weHaveThem, theirPublicKey);
    } else {
      print(
        '📱 EXCHANGE: Skipping contact status send - no change and still in cooldown',
      );
    }
  }

  /// INFINITE LOOP FIX: Check if sync is complete and mark it
  bool _checkAndMarkSyncComplete(
    String theirPublicKey,
    bool weHaveThem,
    bool theyHaveUs,
  ) {
    // Sync is complete when both statuses are known and mutual
    if (weHaveThem && theyHaveUs) {
      print('🔒 MUTUAL: Both have each other - perfect!');
      _markBilateralSyncComplete(theirPublicKey);
      return true;
    }

    // Also consider sync complete if neither has the other (stable state)
    if (!weHaveThem && !theyHaveUs) {
      final receivedStatus = _lastReceivedContactStatus[theirPublicKey];
      final sentStatus = _lastSentContactStatus[theirPublicKey];

      // If both sides have communicated their "no" status, sync is complete
      if (receivedStatus == false && sentStatus == false) {
        print(
          '📱 NO RELATIONSHIP: Both confirmed no relationship - sync complete',
        );
        _markBilateralSyncComplete(theirPublicKey);
        return true;
      }
    }

    return false;
  }

  /// INFINITE LOOP FIX: Internal method to send contact status without checks
  Future<void> _doSendContactStatus(
    bool weHaveThem,
    String theirPublicKey,
  ) async {
    try {
      final myPublicKey = await getMyPersistentId();
      final statusMessage = ProtocolMessage.contactStatus(
        hasAsContact: weHaveThem,
        publicKey: myPublicKey,
      );

      onSendContactStatus?.call(statusMessage);
    } catch (e) {
      _logger.warning('Failed to send contact status: $e');
    }
  }

  Future<void> _performBilateralContactSync(
    String theirPublicKey,
    bool theyHaveUs,
  ) async {
    try {
      // Check our repository state (source of truth)
      final weHaveThem = await weHaveThemAsContact;

      _logger.info(
        '[BLEStateManager] 📱 BILATERAL SYNC (${_truncateId(theirPublicKey)}):',
      );
      _logger.info('  - They have us: $theyHaveUs');
      _logger.info('  - We have them: $weHaveThem');

      // INFINITE LOOP FIX: Only send our status if it changed or hasn't been sent
      await _sendContactStatusIfChanged(weHaveThem, theirPublicKey);

      // INFINITE LOOP FIX: Check if sync is now complete
      if (_checkAndMarkSyncComplete(theirPublicKey, weHaveThem, theyHaveUs)) {
        return; // Sync complete, no further action needed
      }

      // Handle asymmetric relationships with mutual consent
      if (theyHaveUs && !weHaveThem) {
        // They have us but we don't have them - trigger mutual consent prompt
        _logger.info(
          '📱 ASYMMETRIC: They have us, requiring mutual consent to add them',
        );
        _triggerMutualConsentPrompt(theirPublicKey);
      } else if (weHaveThem && !theyHaveUs) {
        // We have them but they don't have us - wait for them to add us
        _logger.info('📱 ASYMMETRIC: We have them, waiting for them to add us');
        // Could show a different UI state here
      } else if (weHaveThem && theyHaveUs) {
        _logger.info('📱 MUTUAL: Both have each other - perfect!');

        // Ensure both sides have ECDH keys
        await _ensureMutualECDH(theirPublicKey);

        // Mark sync as complete
        _markBilateralSyncComplete(theirPublicKey);
      } else {
        _logger.info('📱 NO RELATIONSHIP: Neither has the other');
      }
    } catch (e) {
      _logger.warning('Bilateral contact sync failed: $e');
    }
  }

  Future<void> _ensureMutualECDH(String theirPublicKey) async {
    try {
      // Check if we have ECDH secret
      final existingSecret = await _contactRepository.getCachedSharedSecret(
        theirPublicKey,
      );

      if (existingSecret == null) {
        // Compute and cache ECDH
        final sharedSecret = SimpleCrypto.computeSharedSecret(theirPublicKey);
        if (sharedSecret != null) {
          await _contactRepository.cacheSharedSecret(
            theirPublicKey,
            sharedSecret,
          );
          await SimpleCrypto.restoreConversationKey(
            theirPublicKey,
            sharedSecret,
          );
          _logger.info('📱 ECDH secret computed for mutual contact');
        }
      }

      // Upgrade security level if needed
      final currentLevel = await _contactRepository.getContactSecurityLevel(
        theirPublicKey,
      );
      if (currentLevel != SecurityLevel.high) {
        await _contactRepository.updateContactSecurityLevel(
          theirPublicKey,
          SecurityLevel.high,
        );
        _logger.info('📱 Upgraded to high security for mutual contact');
      }

      // Trigger UI refresh
      onContactRequestCompleted?.call(true);
    } catch (e) {
      _logger.warning('Failed to ensure mutual ECDH: $e');
    }
  }

  Future<void> _checkForAsymmetricRelationship(
    String theirPublicKey,
    bool theyHaveUs,
  ) async {
    final weHaveThem = await weHaveThemAsContact;

    if (theyHaveUs && !weHaveThem) {
      // They have us but we don't have them - prompt to add
      print('🔒 ASYMMETRIC: They have us, we should add them');
      onAsymmetricContactDetected?.call(
        theirPublicKey,
        _otherUserName ?? 'Unknown',
      );
    } else if (weHaveThem && !theyHaveUs) {
      // We have them but they don't have us - they need to add us
      print('🔒 ASYMMETRIC: We have them, they should add us');
      // Could trigger a "contact sync" UI state
    } else if (weHaveThem && theyHaveUs) {
      print('🔒 MUTUAL: Both have each other - perfect!');
    } else {
      print('🔒 NO RELATIONSHIP: Neither has the other');
    }
  }

  Future<void> initializeContactFlags() async {
    if (_currentSessionId == null) return;

    _logger.info('🔄 Initializing contact flags from repository...');

    // Send our status and wait for response
    await requestContactStatusExchange();

    // ENHANCED RETRY LOGIC: Set up retry timer for better asymmetric handling
    _contactSyncRetryTimer?.cancel();
    _contactSyncRetryTimer = Timer(Duration(seconds: 2), () async {
      _retryContactStatusExchange();
    });

    _logger.info('✅ Contact flags initialization requested');
  }

  /// ENHANCED RETRY LOGIC: Handle asymmetric processing scenarios
  Future<void> _retryContactStatusExchange() async {
    try {
      // Enhanced: retry if we have no status OR if asymmetric state detected
      final shouldRetry =
          _lastSyncedTheirStatus == null || await _isContactStateAsymmetric();

      if (shouldRetry) {
        _logger.info('🔄 Retrying contact status exchange...');
        await requestContactStatusExchange();
      } else {
        _logger.info('🔄 Contact state appears synchronized, no retry needed');
      }
    } catch (e) {
      _logger.warning('Failed to retry contact status exchange: $e');
    }
  }

  /// Check if contact state is asymmetric and needs resolution
  Future<bool> _isContactStateAsymmetric() async {
    if (_currentSessionId == null || _lastSyncedTheirStatus == null) {
      return true; // Unknown state needs resolution
    }

    final weHaveThem = await weHaveThemAsContact;
    final theyHaveUs = _lastSyncedTheirStatus == 'yes';

    // Asymmetric if one has the other but not vice versa
    final isAsymmetric =
        (weHaveThem && !theyHaveUs) || (!weHaveThem && theyHaveUs);

    if (isAsymmetric) {
      _logger.info(
        '🔄 ASYMMETRIC STATE: We have them: $weHaveThem, They have us: $theyHaveUs',
      );
    }

    return isAsymmetric;
  }

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
        _lastSyncedTheirStatus = theyHaveUs ? 'yes' : 'no';
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
    if (_currentSessionId == null || _otherUserName == null) {
      _logger.warning('Cannot initiate contact request - missing device info');
      return false;
    }

    try {
      final myPublicKey = await getMyPersistentId();
      final myName = _myUserName ?? 'User';

      _logger.info('📱 CONTACT REQUEST: Initiating request to $_otherUserName');

      // Set up timeout for response
      final completer = Completer<bool>();
      _outgoingRequestCompleters[_currentSessionId!] = completer;

      final timer = Timer(_contactRequestTimeout, () {
        if (!completer.isCompleted) {
          _logger.warning('📱 CONTACT REQUEST: Timeout waiting for response');
          completer.complete(false);
        }
      });
      _pendingOutgoingRequests[_currentSessionId!] = timer;

      // Send the request
      onSendContactRequest?.call(myPublicKey, myName);

      // Wait for response
      final accepted = await completer.future;

      // Cleanup
      _cleanupOutgoingRequest(_currentSessionId!);

      return accepted;
    } catch (e) {
      _logger.severe('Failed to initiate contact request: $e');
      return false;
    }
  }

  /// Clean up tracking for outgoing requests
  void _cleanupOutgoingRequest(String publicKey) {
    _pendingOutgoingRequests[publicKey]?.cancel();
    _pendingOutgoingRequests.remove(publicKey);
    _outgoingRequestCompleters.remove(publicKey);
  }

  /// Handle contact request acceptance response
  void handleContactRequestAcceptResponse(
    String publicKey,
    String displayName,
  ) {
    _logger.info('📱 CONTACT REQUEST: Accepted by $displayName');

    // Complete any pending request
    final completer = _outgoingRequestCompleters[publicKey];
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }

    // Add them as a contact now that we have mutual consent
    _finalizeContactAddition(publicKey, displayName, true);
  }

  /// Handle contact request rejection response
  void handleContactRequestRejectResponse() {
    if (_currentSessionId != null) {
      _logger.info('📱 CONTACT REQUEST: Rejected by $_otherUserName');

      // Complete any pending request
      final completer = _outgoingRequestCompleters[_currentSessionId!];
      if (completer != null && !completer.isCompleted) {
        completer.complete(false);
      }

      _cleanupOutgoingRequest(_currentSessionId!);
    }
  }

  /// Finalize contact addition after mutual consent
  Future<void> _finalizeContactAddition(
    String publicKey,
    String displayName,
    bool mutualConsent,
  ) async {
    try {
      _logger.info(
        '📱 FINALIZE: Adding contact with mutual consent: $displayName',
      );

      // Create verified contact with high security (mutual consent achieved)
      await _contactRepository.saveContactWithSecurity(
        publicKey,
        displayName,
        SecurityLevel.high,
      );
      await _contactRepository.markContactVerified(publicKey);

      // Compute ECDH shared secret
      final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
      if (sharedSecret != null) {
        await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
        await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
        _logger.info('📱 FINALIZE: ECDH secret computed and cached');
      }

      // OBSOLETE: Hints are now deterministic from public key, no seed needed
      // // Generate and store shared seed for hint system
      // final sharedSeed = SensitiveContactHint.generateSharedSeed();
      // await _contactRepository.cacheSharedSeedBytes(publicKey, sharedSeed);
      // _logger.info('📱 FINALIZE: Shared seed generated for hint system');

      // Mark bilateral sync as complete since we have mutual consent
      _markBilateralSyncComplete(publicKey);

      // Notify completion
      onContactRequestCompleted?.call(true);
    } catch (e) {
      _logger.severe('Failed to finalize contact addition: $e');
      onContactRequestCompleted?.call(false);
    }
  }

  // Add this method (it exists but may be missing the exact signature expected):
  Future<bool> sendContactRequest() async {
    try {
      final myPublicKey = await getMyPersistentId();
      final myName = _myUserName ?? 'User';

      _logger.info('Sending contact request');
      onSendContactRequest?.call(myPublicKey, myName);

      _contactRequestCompleter = Completer<bool>();

      // Wait for response (timeout after 30 seconds)
      final accepted = await _contactRequestCompleter!.future.timeout(
        Duration(seconds: 30),
        onTimeout: () {
          _logger.warning('Contact request timeout');
          return false;
        },
      );

      return accepted;
    } catch (e) {
      _logger.severe('Failed to send contact request: $e');
      return false;
    }
  }

  Future<bool> get weHaveThemAsContact async {
    if (_currentSessionId == null) return false;
    final contact = await _contactRepository.getContact(_currentSessionId!);
    return contact != null && contact.trustStatus == TrustStatus.verified;
  }

  void updateTheirContactStatus(bool theyHaveUs) {
    _lastSyncedTheirStatus = theyHaveUs ? 'yes' : 'no';
    print('🔒 SYNC: They ${theyHaveUs ? "have" : "don't have"} us as contact');
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
        _logger.info('Found cached pairing/ECDH secret for $publicKey');

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

  Future<void> handleContactRequest(
    String publicKey,
    String displayName,
  ) async {
    _logger.info('📱 CONTACT REQUEST: Received from $displayName');

    // Check if user allows new contacts
    final prefs = await SharedPreferences.getInstance();
    final allowNewContacts = prefs.getBool('allow_new_contacts') ?? true;

    if (!allowNewContacts) {
      _logger.info('📱 CONTACT REQUEST: Auto-rejected (new contacts disabled)');

      // Auto-reject the request
      onSendContactReject?.call();

      // Don't show UI dialog
      return;
    }

    // User allows new contacts - show the request dialog
    _contactRequestPending = true;
    _pendingContactPublicKey = publicKey;
    _pendingContactName = displayName;

    // Notify UI to show dialog
    onContactRequestReceived?.call(publicKey, displayName);
  }

  Future<void> acceptContactRequest() async {
    if (!_contactRequestPending || _pendingContactPublicKey == null) {
      _logger.warning('No pending contact request');
      return;
    }

    try {
      _logger.info(
        '📱 MUTUAL CONSENT: Accepting contact request from $_pendingContactName',
      );

      // Send acceptance first
      final myPublicKey = await getMyPersistentId();
      final myName = _myUserName ?? 'User';
      onSendContactAccept?.call(myPublicKey, myName);

      // Finalize the contact addition with mutual consent
      await _finalizeContactAddition(
        _pendingContactPublicKey!,
        _pendingContactName!,
        true,
      );

      // Clear pending request
      _contactRequestPending = false;
      _pendingContactPublicKey = null;
      _pendingContactName = null;
    } catch (e) {
      _logger.severe('Failed to accept contact request: $e');
      onContactRequestCompleted?.call(false);
    }
  }

  void rejectContactRequest() {
    if (!_contactRequestPending) return;

    onSendContactReject?.call();

    _contactRequestPending = false;
    _pendingContactPublicKey = null;
    _pendingContactName = null;

    onContactRequestCompleted?.call(false);
  }

  void handleContactAccept(String publicKey, String displayName) {
    _logger.info('📱 MUTUAL CONSENT: Contact request accepted by $displayName');

    // Use the new mutual consent finalization
    handleContactRequestAcceptResponse(publicKey, displayName);
  }

  /// Ensure contact has both ECDH and pairing keys for maximum security
  Future<void> ensureContactMaximumSecurity(String contactPublicKey) async {
    // 1. Ensure ECDH secret exists (already handled)

    // 2. Ensure pairing/conversation key exists for this contact
    if (!SimpleCrypto.hasConversationKey(contactPublicKey)) {
      _logger.info(
        '🔐 Creating pairing key for contact to enable enhanced security',
      );

      // Use the cached ECDH secret as basis for conversation key too
      final cachedSecret = await _contactRepository.getCachedSharedSecret(
        contactPublicKey,
      );
      if (cachedSecret != null) {
        // Initialize conversation key based on ECDH secret + device IDs
        final myId = await getMyPersistentId();
        final conversationSeed = cachedSecret + myId + contactPublicKey;

        SimpleCrypto.initializeConversation(contactPublicKey, conversationSeed);
        _conversationKeys[contactPublicKey] = conversationSeed;

        _logger.info('✅ Enhanced security initialized for contact');
      }
    } else {
      _logger.info('✅ Contact already has maximum security (ECDH + Pairing)');
    }
  }

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

  /// 🔒 Handle received security level sync
  Future<void> handleSecurityLevelSync(Map<String, dynamic> payload) async {
    final theirSecurityLevel =
        SecurityLevel.values[payload['securityLevel'] as int];

    print('🔒 SECURITY SYNC: They have us at ${theirSecurityLevel.name} level');

    if (_currentSessionId != null) {
      final ourSecurityLevel = await _contactRepository.getContactSecurityLevel(
        _currentSessionId!,
      );

      print('🔒 SECURITY SYNC: We have them at ${ourSecurityLevel.name} level');

      // Determine the actual mutual security level (take the lower one)
      final mutualLevel = ourSecurityLevel.index < theirSecurityLevel.index
          ? ourSecurityLevel
          : theirSecurityLevel;

      print('🔒 SECURITY SYNC: Mutual level determined: ${mutualLevel.name}');

      // Update our stored level to match reality
      if (ourSecurityLevel != mutualLevel) {
        await _contactRepository.updateContactSecurityLevel(
          _currentSessionId!,
          mutualLevel,
        );
        print(
          '🔒 SECURITY SYNC: Updated our level to match mutual: ${mutualLevel.name}',
        );

        // Trigger UI refresh
        onContactRequestCompleted?.call(true);
      }
    }
  }

  Future<void> _ensureContactExistsAfterHandshake(
    String publicKey,
    String displayName, {
    String? ephemeralId,
  }) async {
    final existingContact = await _contactRepository.getContact(publicKey);

    if (existingContact == null) {
      // Create contact with LOW security (just completed Noise handshake)
      await _contactRepository.saveContactWithSecurity(
        publicKey,
        displayName,
        SecurityLevel.low,
        currentEphemeralId: ephemeralId,
      );
      _logger.info(
        '🔒 HANDSHAKE: Created contact with LOW security (Noise session): $displayName',
      );

      // 🔐 PRIVACY FIX: Delete intro hint after LOW security connection
      // Intro hints are temporary discovery aids - delete after first use to prevent
      // identity linkage across ephemeral sessions
      await _deleteIntroHintAfterConnection(displayName, publicKey);
    } else {
      // Update existing contact - ensure at least LOW security
      if (existingContact.securityLevel.index < SecurityLevel.low.index) {
        await _contactRepository.updateContactSecurityLevel(
          publicKey,
          SecurityLevel.low,
        );
        _logger.info(
          '🔒 HANDSHAKE: Updated contact to LOW security (Noise session): $displayName',
        );
      }
      // Update ephemeral ID if provided
      if (ephemeralId != null) {
        await _contactRepository.updateContactEphemeralId(
          publicKey,
          ephemeralId,
        );
        _logger.info(
          '🔒 HANDSHAKE: Updated ephemeral ID for contact: $displayName',
        );
      }
    }
  }

  /// 🔐 PRIVACY: Delete intro hint after successful connection
  ///
  /// Intro hints are temporary discovery aids for initial QR-based connections.
  /// After first successful connection, they must be deleted to prevent identity
  /// linkage across ephemeral sessions (LOW security contacts).
  ///
  /// For MEDIUM+ security, persistent hints are generated from shared secrets,
  /// so intro hints are no longer needed.
  Future<void> _deleteIntroHintAfterConnection(
    String displayName,
    String publicKey,
  ) async {
    try {
      final introHintRepo = IntroHintRepository();
      final scannedHints = await introHintRepo.getScannedHints();

      // Find matching hint by display name
      for (final hint in scannedHints.values) {
        if (hint.displayName == displayName) {
          await introHintRepo.removeScannedHint(hint.hintHex);
          _logger.info(
            '🗑️ PRIVACY: Deleted intro hint after connection: ${hint.hintHex} ($displayName)',
          );
          _logger.info(
            '   Reason: Intro hints are temporary - prevents identity linkage across sessions',
          );
          return;
        }
      }

      _logger.fine(
        'ℹ️ No intro hint found to delete for $displayName (may not be QR-based connection)',
      );
    } catch (e, stackTrace) {
      _logger.warning('⚠️ Failed to delete intro hint for $displayName: $e');
      _logger.fine('Stack trace: $stackTrace');
    }
  }

  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    print(
      '[BLEStateManager] 🔧 DEBUG: confirmSecurityUpgrade called for ${_truncateId(publicKey)} to ${newLevel.name}',
    );

    try {
      final existingContact = await _contactRepository.getContact(publicKey);

      if (existingContact == null) {
        print(
          '[BLEStateManager] 🔧 DEBUG: No existing contact - creating new with ${newLevel.name} level',
        );
        await _contactRepository.saveContactWithSecurity(
          publicKey,
          'Unknown',
          newLevel,
        );
        onContactRequestCompleted?.call(true);
        return true;
      }

      print(
        '🔧 DEBUG: Current level: ${existingContact.securityLevel.name}, Target: ${newLevel.name}',
      );

      // Check if we're trying to downgrade from high security
      if (existingContact.securityLevel == SecurityLevel.high) {
        if (newLevel == SecurityLevel.medium) {
          print(
            '🔧 DEBUG: Contact already has ECDH (high security) - pairing unnecessary',
          );

          // Instead of downgrading, just refresh the pairing key at high level
          await _initializeCryptoForLevel(publicKey, SecurityLevel.high);

          // Trigger UI refresh to show current state
          onContactRequestCompleted?.call(true);
          return true;
        }
      }

      // Check if we're already at the target level
      if (existingContact.securityLevel == newLevel) {
        print(
          '🔧 DEBUG: Already at ${newLevel.name} level - re-initializing crypto',
        );
        await _initializeCryptoForLevel(publicKey, newLevel);
        onContactRequestCompleted?.call(true);
        return true;
      }

      // Only allow valid upgrades
      if (newLevel.index > existingContact.securityLevel.index) {
        print(
          '🔧 DEBUG: Valid upgrade from ${existingContact.securityLevel.name} to ${newLevel.name}',
        );
        final success = await _contactRepository.upgradeContactSecurity(
          publicKey,
          newLevel,
        );
        if (success) {
          await _initializeCryptoForLevel(publicKey, newLevel);
          onContactRequestCompleted?.call(true);
        }
        return success;
      } else {
        print('🔧 DEBUG: Invalid downgrade attempt blocked');
        // Still trigger UI refresh to show current state
        onContactRequestCompleted?.call(true);
        return false;
      }
    } catch (e) {
      print('🔧 DEBUG: confirmSecurityUpgrade failed: $e');
      return false;
    }
  }

  // Add method to handle legitimate security resets
  Future<bool> resetContactSecurity(String publicKey, String reason) async {
    print('🔧 SECURITY RESET: Resetting $publicKey due to: $reason');

    try {
      // Use the new explicit reset method
      final success = await _contactRepository.resetContactSecurity(
        publicKey,
        reason,
      );

      if (success) {
        // Clear crypto keys
        SimpleCrypto.clearConversationKey(publicKey);

        // Trigger UI refresh
        onContactRequestCompleted?.call(true);
      }

      return success;
    } catch (e) {
      print('🔧 SECURITY RESET FAILED: $e');
      return false;
    }
  }

  Future<void> _initializeCryptoForLevel(
    String publicKey,
    SecurityLevel level,
  ) async {
    switch (level) {
      case SecurityLevel.medium:
        if (!SimpleCrypto.hasConversationKey(publicKey)) {
          final secret = _conversationKeys[publicKey];
          if (secret != null) {
            SimpleCrypto.initializeConversation(publicKey, secret);
          }
        }
        break;

      case SecurityLevel.high:
        final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
        if (sharedSecret != null) {
          await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
          await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
        }
        break;

      case SecurityLevel.low:
        break;
    }
  }

  void updateTheirContactClaim(bool theyClaimUs) {
    final previousState = _lastSyncedTheirStatus;
    _lastSyncedTheirStatus = theyClaimUs ? 'yes' : 'no';

    print(
      '🔒 SESSION: They ${theyClaimUs ? "claim to have" : "don't have"} us as contact',
    );

    // Only trigger UI refresh if this is a meaningful change
    if (previousState != _lastSyncedTheirStatus) {
      print('🔒 SESSION: Contact claim changed - triggering UI refresh');
      onContactRequestCompleted?.call(true);
    }
  }

  void clearPairing() {
    _currentPairing = null;
    _receivedPairingCode = null;
    _theirReceivedCode = null;
    _weEnteredCode = false;
    _pairingCompleter = null;
    _pairingTimeout?.cancel();
    _logger.info('Pairing state cleared');
  }

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

  Future<void> requestContactStatusExchange() async {
    if (_currentSessionId == null) return;

    try {
      // Get OUR status from repository (persistent truth)
      final weHaveThem = await weHaveThemAsContact;

      // INFINITE LOOP FIX: Use the new debounced sending method
      await _sendContactStatusIfChanged(weHaveThem, _currentSessionId!);
    } catch (e) {
      _logger.warning('Failed to send contact status: $e');
    }
  }

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
    if (!preservePersistentId) {
      // Actual disconnection - clear everything
      _otherUserName = null;
      _logger.warning(
        '  - ⚠️  CLEARED otherUserName: "$previousName" -> null (disconnection)',
      );

      final previousId = _currentSessionId;
      _currentSessionId = null;
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
    }

    _lastSyncedTheirStatus = null;
    _processedContactMessages.clear();
    _contactSyncRetryTimer?.cancel();

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
      // Try to recover display name from contact repository
      final contact = await _contactRepository.getContact(_currentSessionId!);

      if (contact != null && contact.displayName.isNotEmpty) {
        _logger.info(
          '[BLEStateManager] 🔄 RECOVERY: Restored identity from contacts',
        );
        _logger.info('  - Public key: ${_truncateId(_currentSessionId)}');
        _logger.info('  - Display name: ${contact.displayName}');

        // Restore session identity without triggering full connection flow
        _otherUserName = contact.displayName;
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
    _contactSyncRetryTimer?.cancel();
  }
}

// ========== SPY MODE DATA CLASSES ==========

/// Information about detected spy mode session
class SpyModeInfo {
  final String contactName;
  final String ephemeralID;
  final String? persistentKey;

  SpyModeInfo({
    required this.contactName,
    required this.ephemeralID,
    this.persistentKey,
  });
}
