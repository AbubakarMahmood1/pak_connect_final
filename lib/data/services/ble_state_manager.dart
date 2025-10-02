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
import '../../core/services/simple_crypto.dart';
import '../../core/models/protocol_message.dart';
import '../../core/services/security_manager.dart';
import 'ble_service.dart';

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
  String? _otherDevicePersistentId;
  String? _theirReceivedCode;
  bool _weEnteredCode = false;
  String? _lastSyncedTheirStatus;
  
  // Peripheral mode tracking
  bool _isPeripheralMode = false;
  
  Timer? _contactSyncRetryTimer;
  final Set<String> _processedContactMessages = {};

  // INFINITE LOOP FIX: Add status tracking and debouncing
  final Map<String, bool> _lastSentContactStatus = {}; // Track last sent status per contact
  final Map<String, DateTime> _lastStatusSentTime = {}; // Debouncing timestamps
  final Map<String, bool> _lastReceivedContactStatus = {}; // Track last received status
  final Map<String, bool> _bilateralSyncComplete = {}; // Track sync completion per contact
  static const Duration _statusCooldownDuration = Duration(seconds: 2); // Minimum time between status sends

  // Getters
  String? get myUserName => _myUserName;
  String? get otherUserName => _otherUserName;
  String? get otherDevicePersistentId => _otherDevicePersistentId;
  bool get isPeripheralMode => _isPeripheralMode;
  String? get myPersistentId => _myPersistentId;
  PairingInfo? get currentPairing => _currentPairing;
  bool get hasContactRequest => _contactRequestPending;
  String? get pendingContactName => _pendingContactName;
  bool get theyHaveUsAsContact => _lastSyncedTheirStatus == 'yes';

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

   BLEStateManager() {
    // Any synchronous initialization here
  }
  
  Future<void> initialize() async {
   _logger.info('🚀 Starting BLEStateManager initialization...');
   final startTime = DateTime.now();

   _logger.info('👤 Loading user name...');
   final nameStart = DateTime.now();
   await loadUserName();
   _logger.info('✅ User name loaded in ${DateTime.now().difference(nameStart).inMilliseconds}ms: "$_myUserName"');

   _logger.info('🔑 Getting or creating key pair...');
   final keyStart = DateTime.now();
   await _userPreferences.getOrCreateKeyPair();
   _logger.info('✅ Key pair ready in ${DateTime.now().difference(keyStart).inMilliseconds}ms');

   _logger.info('🆔 Getting public key...');
   final pubKeyStart = DateTime.now();
   _myPersistentId = await _userPreferences.getPublicKey();
   _logger.info('✅ Public key retrieved in ${DateTime.now().difference(pubKeyStart).inMilliseconds}ms: "${_myPersistentId?.substring(0, 16)}..."');

   _logger.info('🔐 Initializing crypto...');
   final cryptoStart = DateTime.now();
   await _initializeCrypto();
   _logger.info('✅ Crypto initialized in ${DateTime.now().difference(cryptoStart).inMilliseconds}ms');

   _logger.info('✍️ Initializing signing...');
   final signStart = DateTime.now();
   await _initializeSigning();
   _logger.info('✅ Signing initialized in ${DateTime.now().difference(signStart).inMilliseconds}ms');

   final totalTime = DateTime.now().difference(startTime);
   _logger.info('🎉 BLEStateManager initialization complete in ${totalTime.inMilliseconds}ms');
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
    
    print('🔧 NAME DEBUG: setMyUserName completed, _myUserName is now: "$_myUserName"');
  }
  
  /// ENHANCED: Set username with immediate cache invalidation and callback trigger
  Future<void> setMyUserNameWithCallbacks(String name) async {
    await setMyUserName(name);
    
    // Force reload from storage to ensure consistency
    await loadUserName();
    
    // If connected, the identity re-exchange should be handled by the caller
    print('🔧 NAME DEBUG: Username set with enhanced callbacks and cache invalidation');
  }
  
void setOtherUserName(String? name) {
  print('🐛 NAV DEBUG: setOtherUserName called with: "$name" (was: "$_otherUserName")');
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
  print('🐛 NAV DEBUG: - deviceId: ${deviceId.substring(0, 16)}...');
  print('🐛 NAV DEBUG: - displayName: "$displayName"');
  print('🐛 NAV DEBUG: - previous _otherDevicePersistentId: ${_otherDevicePersistentId?.substring(0, 16)}...');
  
  _logger.info('Setting other device identity: "$displayName" (ID: $deviceId)');
  
  // INFINITE LOOP FIX: Reset sync state for new connection
  if (_otherDevicePersistentId != deviceId) {
    // This is a new contact, reset sync state
    _resetBilateralSyncStatus(deviceId);
  }
  
  _otherUserName = displayName;
  _otherDevicePersistentId = deviceId;
  onNameChanged?.call(_otherUserName);
  
  if (displayName.isNotEmpty) {
    _logger.info('✅ Identity exchange complete - UI should show connected now');
  } else {
    _logger.warning('⚠️ Identity cleared - UI will show disconnected');
  }
}
  
  Future<void> saveContact(String publicKey, String userName) async {
  await _contactRepository.saveContact(publicKey, userName);
  _logger.info('Contact saved: $userName (${publicKey.substring(0, 16)}...)');
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

Future<bool> hasContactKeyChanged(String publicKey, String currentDisplayName) async {
  final existingContact = await _contactRepository.getContact(publicKey);
  
  if (existingContact == null) {
    return false;
  }
  
  // Check if we've seen this display name with a different public key
  final allContacts = await _contactRepository.getAllContacts();
  final sameNameContacts = allContacts.values.where((c) => 
    c.displayName == currentDisplayName && c.publicKey != publicKey).toList();
  
  return sameNameContacts.isNotEmpty;
}

// In ble_state_manager.dart, update generatePairingCode method
String generatePairingCode() {
  if (_currentPairing != null && _currentPairing!.state == PairingState.displaying) {
    _logger.info('Returning existing pairing code: ${_currentPairing!.myCode}');
    return _currentPairing!.myCode;
  }
  
  final random = Random();
  final code = (random.nextInt(9000) + 1000).toString();
  _currentPairing = PairingInfo(
    myCode: code,
    state: PairingState.displaying,
  );
  
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
    _logger.info('Sending our code to other device: ${_currentPairing!.myCode}');
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
      print('🔒 PAIRING DEBUG: Verification result - success=$success, sharedSecret=${_currentPairing?.sharedSecret?.substring(0,8)}...');
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
    _logger.severe('CODE MISMATCH! We entered: $_receivedPairingCode, They sent: $theirCode');
    _logger.severe('This means they entered wrong code!');
    if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
      _pairingCompleter!.complete(false);
    }
    return;
  }
  
  _logger.info('Codes match! Both devices entered correct codes. Starting verification...');
  
  // Perform verification since both have entered codes
  _performVerification().then((success) {
    if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
      _pairingCompleter!.complete(success);
    }
  });
}

Future<bool> _performVerification() async {
  if (_currentPairing == null || _receivedPairingCode == null || _theirReceivedCode == null) {
    _logger.warning('Missing data for verification');
    return false;
  }
  
  try {
    final myPublicKey = await getMyPersistentId();
    final theirPublicKey = _otherDevicePersistentId;
    
    if (theirPublicKey == null) {
      _logger.warning('No other device public key');
      return false;
    }
    
    // Now compute shared secret (both devices will get same result)
    final sortedCodes = [_currentPairing!.myCode, _receivedPairingCode!]..sort();
    final sortedKeys = [myPublicKey, theirPublicKey]..sort();
    
    final combinedData = '${sortedCodes[0]}:${sortedCodes[1]}:${sortedKeys[0]}:${sortedKeys[1]}';
    final sharedSecret = sha256.convert(utf8.encode(combinedData)).toString();
    
    _logger.info('Computed shared secret from codes');
    await _ensureContactExistsAfterPairing(theirPublicKey, _otherUserName ?? 'User');
    
    // Generate and send verification hash
    final secretHash = sha256.convert(utf8.encode(sharedSecret)).toString().substring(0, 8);
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
    
    return true;
    
  } catch (e) {
    _logger.severe('Verification failed: $e');
    _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
    return false;
  }
}

// Method to handle verification
void handlePairingVerification(String theirSecretHash) {
  _logger.info('Received verification hash from other device: $theirSecretHash');
  
  // Only log for debugging - both devices compute same secret independently
  // No need to compare hashes since we already verified codes match
  
  if (_currentPairing != null && _currentPairing!.sharedSecret != null) {
    final ourHash = sha256.convert(utf8.encode(_currentPairing!.sharedSecret!)).toString().substring(0, 8);
    if (ourHash == theirSecretHash) {
      _logger.info('✅ Verification hashes match - pairing confirmed!');
    } else {
      _logger.severe('❌ Hash mismatch - something went wrong!');
    }
  }
}


void handleContactStatus(bool theyHaveUsAsContact, String theirPublicKey) {
    print('📱 PROTOCOL: Received contact status - they have us: $theyHaveUsAsContact');
    
    // INFINITE LOOP FIX: Check if this is actually a new status
    final previousStatus = _lastReceivedContactStatus[theirPublicKey];
    if (previousStatus == theyHaveUsAsContact) {
      print('📱 PROTOCOL: Same status received again - ignoring to prevent loop');
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
  print('📱 SYNC COMPLETE: Marked bilateral sync complete for ${theirPublicKey.substring(0, 16)}...');
}

/// INFINITE LOOP FIX: Reset sync completion (for new connections)
void _resetBilateralSyncStatus(String theirPublicKey) {
  _bilateralSyncComplete[theirPublicKey] = false;
  _lastSentContactStatus.remove(theirPublicKey);
  _lastStatusSentTime.remove(theirPublicKey);
  _lastReceivedContactStatus.remove(theirPublicKey);
  print('📱 SYNC RESET: Reset bilateral sync status for ${theirPublicKey.substring(0, 16)}...');
}

/// INFINITE LOOP FIX: Send contact status only if changed or cooldown expired
Future<void> _sendContactStatusIfChanged(bool weHaveThem, String theirPublicKey) async {
  // Check if status changed
  final lastSentStatus = _lastSentContactStatus[theirPublicKey];
  final statusChanged = lastSentStatus != weHaveThem;
  
  // Check cooldown period
  final lastSentTime = _lastStatusSentTime[theirPublicKey];
  final cooldownExpired = lastSentTime == null ||
    DateTime.now().difference(lastSentTime) > _statusCooldownDuration;
  
  if (statusChanged || (lastSentStatus == null && cooldownExpired)) {
    print('📱 EXCHANGE: Sending our contact status: $weHaveThem (changed: $statusChanged, cooldown: $cooldownExpired)');
    
    // Update tracking
    _lastSentContactStatus[theirPublicKey] = weHaveThem;
    _lastStatusSentTime[theirPublicKey] = DateTime.now();
    
    // Send the actual status
    await _doSendContactStatus(weHaveThem, theirPublicKey);
  } else {
    print('📱 EXCHANGE: Skipping contact status send - no change and still in cooldown');
  }
}

/// INFINITE LOOP FIX: Check if sync is complete and mark it
bool _checkAndMarkSyncComplete(String theirPublicKey, bool weHaveThem, bool theyHaveUs) {
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
      print('📱 NO RELATIONSHIP: Both confirmed no relationship - sync complete');
      _markBilateralSyncComplete(theirPublicKey);
      return true;
    }
  }
  
  return false;
}

/// INFINITE LOOP FIX: Internal method to send contact status without checks
Future<void> _doSendContactStatus(bool weHaveThem, String theirPublicKey) async {
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

Future<void> _performBilateralContactSync(String theirPublicKey, bool theyHaveUs) async {
    try {
      // Check our repository state (source of truth)
      final weHaveThem = await weHaveThemAsContact;
      
      _logger.info('📱 BILATERAL SYNC (${theirPublicKey.substring(0, 16)}...):');
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
        _logger.info('📱 ASYMMETRIC: They have us, requiring mutual consent to add them');
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
      final existingSecret = await _contactRepository.getCachedSharedSecret(theirPublicKey);
      
      if (existingSecret == null) {
        // Compute and cache ECDH
        final sharedSecret = SimpleCrypto.computeSharedSecret(theirPublicKey);
        if (sharedSecret != null) {
          await _contactRepository.cacheSharedSecret(theirPublicKey, sharedSecret);
          await SimpleCrypto.restoreConversationKey(theirPublicKey, sharedSecret);
          _logger.info('📱 ECDH secret computed for mutual contact');
        }
      }
      
      // Upgrade security level if needed
      final currentLevel = await _contactRepository.getContactSecurityLevel(theirPublicKey);
      if (currentLevel != SecurityLevel.high) {
        await _contactRepository.updateContactSecurityLevel(theirPublicKey, SecurityLevel.high);
        _logger.info('📱 Upgraded to high security for mutual contact');
      }
      
      // Trigger UI refresh
      onContactRequestCompleted?.call(true);
      
    } catch (e) {
      _logger.warning('Failed to ensure mutual ECDH: $e');
    }
  }

Future<void> _checkForAsymmetricRelationship(String theirPublicKey, bool theyHaveUs) async {
  final weHaveThem = await weHaveThemAsContact;
  
  if (theyHaveUs && !weHaveThem) {
    // They have us but we don't have them - prompt to add
    print('🔒 ASYMMETRIC: They have us, we should add them');
    onAsymmetricContactDetected?.call(theirPublicKey, _otherUserName ?? 'Unknown');
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
    if (_otherDevicePersistentId == null) return;
    
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
      final shouldRetry = _lastSyncedTheirStatus == null ||
                         await _isContactStateAsymmetric();
      
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
    if (_otherDevicePersistentId == null || _lastSyncedTheirStatus == null) {
      return true; // Unknown state needs resolution
    }
    
    final weHaveThem = await weHaveThemAsContact;
    final theyHaveUs = _lastSyncedTheirStatus == 'yes';
    
    // Asymmetric if one has the other but not vice versa
    final isAsymmetric = (weHaveThem && !theyHaveUs) || (!weHaveThem && theyHaveUs);
    
    if (isAsymmetric) {
      _logger.info('🔄 ASYMMETRIC STATE: We have them: $weHaveThem, They have us: $theyHaveUs');
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
    _logger.info('🔄 Preserving contact relationship across mode switch:');
    _logger.info('  Other: $otherName (${otherPublicKey.substring(0, 16)}...)');
    
    // Preserve identity
    _otherDevicePersistentId = otherPublicKey;
    _otherUserName = otherName;
    
    // Preserve their claim status if provided
    if (theyHaveUs != null) {
      _lastSyncedTheirStatus = theyHaveUs ? 'yes' : 'no';
    }
  } else {
    _logger.info('🔄 No previous relationship to preserve during mode switch');
    
    // Clear session state for fresh start - don't preserve persistent ID for fresh connections
    clearSessionState(preservePersistentId: false);
  }
}

/// Trigger mutual consent prompt instead of automatic addition
void _triggerMutualConsentPrompt(String theirPublicKey) {
  if (onMutualConsentRequired != null && _otherUserName != null) {
    _logger.info('📱 MUTUAL CONSENT: Prompting user to initiate contact request for $_otherUserName');
    onMutualConsentRequired?.call(theirPublicKey, _otherUserName!);
  }
}

/// User-initiated contact request (replaces automatic addition)
Future<bool> initiateContactRequest() async {
  if (_otherDevicePersistentId == null || _otherUserName == null) {
    _logger.warning('Cannot initiate contact request - missing device info');
    return false;
  }
  
  try {
    final myPublicKey = await getMyPersistentId();
    final myName = _myUserName ?? 'User';
    
    _logger.info('📱 CONTACT REQUEST: Initiating request to $_otherUserName');
    
    // Set up timeout for response
    final completer = Completer<bool>();
    _outgoingRequestCompleters[_otherDevicePersistentId!] = completer;
    
    final timer = Timer(_contactRequestTimeout, () {
      if (!completer.isCompleted) {
        _logger.warning('📱 CONTACT REQUEST: Timeout waiting for response');
        completer.complete(false);
      }
    });
    _pendingOutgoingRequests[_otherDevicePersistentId!] = timer;
    
    // Send the request
    onSendContactRequest?.call(myPublicKey, myName);
    
    // Wait for response
    final accepted = await completer.future;
    
    // Cleanup
    _cleanupOutgoingRequest(_otherDevicePersistentId!);
    
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
void handleContactRequestAcceptResponse(String publicKey, String displayName) {
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
  if (_otherDevicePersistentId != null) {
    _logger.info('📱 CONTACT REQUEST: Rejected by $_otherUserName');
    
    // Complete any pending request
    final completer = _outgoingRequestCompleters[_otherDevicePersistentId!];
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    
    _cleanupOutgoingRequest(_otherDevicePersistentId!);
  }
}

/// Finalize contact addition after mutual consent
Future<void> _finalizeContactAddition(String publicKey, String displayName, bool mutualConsent) async {
  try {
    _logger.info('📱 FINALIZE: Adding contact with mutual consent: $displayName');
    
    // Create verified contact with high security (mutual consent achieved)
    await _contactRepository.saveContactWithSecurity(
      publicKey,
      displayName,
      SecurityLevel.high
    );
    await _contactRepository.markContactVerified(publicKey);
    
    // Compute ECDH shared secret
    final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
    if (sharedSecret != null) {
      await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
      await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
      _logger.info('📱 FINALIZE: ECDH secret computed and cached');
    }
    
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
    if (_otherDevicePersistentId == null) return false;
    final contact = await _contactRepository.getContact(_otherDevicePersistentId!);
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
    final cachedSecret = await _contactRepository.getCachedSharedSecret(publicKey);
    
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

void handleContactRequest(String publicKey, String displayName) {
  _logger.info('Received contact request from $displayName');
  
  _contactRequestPending = true;
  _pendingContactPublicKey = publicKey;
  _pendingContactName = displayName;
  
  // Notify UI
  onContactRequestReceived?.call(publicKey, displayName);
}

Future<void> acceptContactRequest() async {
  if (!_contactRequestPending || _pendingContactPublicKey == null) {
    _logger.warning('No pending contact request');
    return;
  }
  
  try {
    _logger.info('📱 MUTUAL CONSENT: Accepting contact request from $_pendingContactName');
    
    // Send acceptance first
    final myPublicKey = await getMyPersistentId();
    final myName = _myUserName ?? 'User';
    onSendContactAccept?.call(myPublicKey, myName);
    
    // Finalize the contact addition with mutual consent
    await _finalizeContactAddition(_pendingContactPublicKey!, _pendingContactName!, true);
    
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
    _logger.info('🔐 Creating pairing key for contact to enable enhanced security');
    
    // Use the cached ECDH secret as basis for conversation key too
    final cachedSecret = await _contactRepository.getCachedSharedSecret(contactPublicKey);
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

Future<void> checkForQRIntroduction(String otherPublicKey, String otherName) async {
  final prefs = await SharedPreferences.getInstance();
  final introData = prefs.getString('scanned_intro_$otherPublicKey');
  
  if (introData != null) {
    _logger.info('👋 QR introduction found for $otherName - using normal pairing');
    
    // Clean up the introduction data
    await prefs.remove('scanned_intro_$otherPublicKey');
  }
  
  // Always use existing pairing system - QR is just context
  // The existing onPairingRequired callback will be triggered by normal connection flow
}

Future<void> requestSecurityLevelSync() async {
  if (_otherDevicePersistentId == null) return;
  
  try {
    final myPublicKey = await getMyPersistentId();
    final mySecurityLevel = await _contactRepository.getContactSecurityLevel(_otherDevicePersistentId!);
    
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
    print('🔒 SECURITY SYNC: Requested sync with current level: ${mySecurityLevel.name}');
  } catch (e) {
    _logger.warning('🔒 SECURITY SYNC FAILED: $e');
  }
}

/// 🔒 Handle received security level sync
Future<void> handleSecurityLevelSync(Map<String, dynamic> payload) async {
  final theirSecurityLevel = SecurityLevel.values[payload['securityLevel'] as int];
  
  print('🔒 SECURITY SYNC: They have us at ${theirSecurityLevel.name} level');
  
  if (_otherDevicePersistentId != null) {
    final ourSecurityLevel = await _contactRepository.getContactSecurityLevel(_otherDevicePersistentId!);
    
    print('🔒 SECURITY SYNC: We have them at ${ourSecurityLevel.name} level');
    
    // Determine the actual mutual security level (take the lower one)
    final mutualLevel = ourSecurityLevel.index < theirSecurityLevel.index 
      ? ourSecurityLevel 
      : theirSecurityLevel;
    
    print('🔒 SECURITY SYNC: Mutual level determined: ${mutualLevel.name}');
    
    // Update our stored level to match reality
    if (ourSecurityLevel != mutualLevel) {
      await _contactRepository.updateContactSecurityLevel(_otherDevicePersistentId!, mutualLevel);
      print('🔒 SECURITY SYNC: Updated our level to match mutual: ${mutualLevel.name}');
      
      // Trigger UI refresh
      onContactRequestCompleted?.call(true);
    }
  }
}

Future<void> _ensureContactExistsAfterPairing(String publicKey, String displayName) async {
  final existingContact = await _contactRepository.getContact(publicKey);
  
  if (existingContact == null) {
    // Create contact with medium security (pairing level)
    await _contactRepository.saveContactWithSecurity(
      publicKey, 
      displayName, 
      SecurityLevel.medium
    );
    _logger.info('🔒 PAIRING: Created contact with medium security: $displayName');
  } else {
    // Upgrade existing contact to at least medium security
    if (existingContact.securityLevel.index < SecurityLevel.medium.index) {
      await _contactRepository.updateContactSecurityLevel(publicKey, SecurityLevel.medium);
      _logger.info('🔒 PAIRING: Upgraded contact to medium security: $displayName');
    }
  }
}

Future<bool> confirmSecurityUpgrade(String publicKey, SecurityLevel newLevel) async {
  print('🔧 DEBUG: confirmSecurityUpgrade called for ${publicKey.substring(0, 16)}... to ${newLevel.name}');
  
  try {
    final existingContact = await _contactRepository.getContact(publicKey);
    
    if (existingContact == null) {
      print('🔧 DEBUG: No existing contact - creating new with ${newLevel.name} level');
      await _contactRepository.saveContactWithSecurity(publicKey, 'Unknown', newLevel);
      onContactRequestCompleted?.call(true);
      return true;
    }
    
    print('🔧 DEBUG: Current level: ${existingContact.securityLevel.name}, Target: ${newLevel.name}');
    
    // Check if we're trying to downgrade from high security
    if (existingContact.securityLevel == SecurityLevel.high) {
      if (newLevel == SecurityLevel.medium) {
        print('🔧 DEBUG: Contact already has ECDH (high security) - pairing unnecessary');
        
        // Instead of downgrading, just refresh the pairing key at high level
        await _initializeCryptoForLevel(publicKey, SecurityLevel.high);
        
        // Trigger UI refresh to show current state
        onContactRequestCompleted?.call(true);
        return true;
      }
    }
    
    // Check if we're already at the target level
    if (existingContact.securityLevel == newLevel) {
      print('🔧 DEBUG: Already at ${newLevel.name} level - re-initializing crypto');
      await _initializeCryptoForLevel(publicKey, newLevel);
      onContactRequestCompleted?.call(true);
      return true;
    }
    
    // Only allow valid upgrades
    if (newLevel.index > existingContact.securityLevel.index) {
      print('🔧 DEBUG: Valid upgrade from ${existingContact.securityLevel.name} to ${newLevel.name}');
      final success = await _contactRepository.upgradeContactSecurity(publicKey, newLevel);
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
    final success = await _contactRepository.resetContactSecurity(publicKey, reason);
    
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

Future<void> _initializeCryptoForLevel(String publicKey, SecurityLevel level) async {
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
  
  print('🔒 SESSION: They ${theyClaimUs ? "claim to have" : "don't have"} us as contact');
  
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
    _isPeripheralMode = isPeripheral;
  }

Future<void> requestContactStatusExchange() async {
    if (_otherDevicePersistentId == null) return;
    
    try {
      // Get OUR status from repository (persistent truth)
      final weHaveThem = await weHaveThemAsContact;
      
      // INFINITE LOOP FIX: Use the new debounced sending method
      await _sendContactStatusIfChanged(weHaveThem, _otherDevicePersistentId!);
      
    } catch (e) {
      _logger.warning('Failed to send contact status: $e');
    }
  }

void clearSessionState({bool preservePersistentId = false}) {
    _logger.warning('🔍 SESSION STATE CLEARING - CRITICAL NAVIGATION EVENT');
    _logger.warning('  - BEFORE: otherUserName = "$_otherUserName"');
    _logger.warning('  - BEFORE: otherDevicePersistentId = "${_otherDevicePersistentId?.substring(0, 16)}..."');
    _logger.warning('  - preservePersistentId = $preservePersistentId');
    _logger.warning('  - Called from: ${StackTrace.current.toString().split('\n').take(5).join(' -> ')}');
    
    // FIX: Preserve identity during navigation to maintain connection state
    final previousName = _otherUserName;
    if (!preservePersistentId) {
        // Actual disconnection - clear everything
        _otherUserName = null;
        _logger.warning('  - ⚠️  CLEARED otherUserName: "$previousName" -> null (disconnection)');
        
        final previousId = _otherDevicePersistentId;
        _otherDevicePersistentId = null;
        _logger.warning('  - ⚠️  CLEARED persistent ID: "${previousId?.substring(0, 16)}..." -> null (connection loss)');
    } else {
        // Navigation only - preserve identity to maintain connection state
        _logger.warning('  - ✅ PRESERVED otherUserName: "$_otherUserName" (navigation)');
        _logger.warning('  - ✅ PRESERVED persistent ID: "${_otherDevicePersistentId?.substring(0, 16)}..." (navigation)');
    }
    
    _lastSyncedTheirStatus = null;
    _processedContactMessages.clear();
    _contactSyncRetryTimer?.cancel();
    
    // FIX: Only broadcast null name if we're actually clearing it (disconnection)
    if (!preservePersistentId) {
        _logger.warning('  - 🚨 BROADCASTING NULL NAME TO UI (triggers disconnected state)');
        onNameChanged?.call(null);
        _logger.warning('🔍 SESSION CLEAR COMPLETE - UI will now show DISCONNECTED');
    } else {
        _logger.warning('  - ✅ PRESERVING NAME BROADCAST (UI stays connected during navigation)');
        _logger.warning('🔍 SESSION CLEAR COMPLETE - UI connection state preserved');
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
    if (_otherDevicePersistentId == null) {
      _logger.info('🔄 RECOVERY: No persistent ID available for identity recovery');
      return;
    }
    
    try {
      // Try to recover display name from contact repository
      final contact = await _contactRepository.getContact(_otherDevicePersistentId!);
      
      if (contact != null && contact.displayName.isNotEmpty) {
        _logger.info('🔄 RECOVERY: Restored identity from contacts');
        _logger.info('  - Public key: ${_otherDevicePersistentId!.substring(0, 16)}...');
        _logger.info('  - Display name: ${contact.displayName}');
        
        // Restore session identity without triggering full connection flow
        _otherUserName = contact.displayName;
        onNameChanged?.call(_otherUserName);
        
        _logger.info('✅ RECOVERY: Identity successfully recovered from storage');
      } else {
        _logger.warning('🔄 RECOVERY: No contact found in repository for persistent ID');
      }
    } catch (e) {
      _logger.warning('🔄 RECOVERY: Failed to recover identity from storage: $e');
    }
  }
  
  /// Get identity information with fallback to persistent storage
  Future<Map<String, String?>> getIdentityWithFallback() async {
    // Primary: Use session state if available
    if (_otherUserName != null && _otherUserName!.isNotEmpty) {
      return {
        'displayName': _otherUserName,
        'publicKey': _otherDevicePersistentId ?? '',
        'source': 'session'
      };
    }
    
    // Fallback: Try to get from persistent storage
    if (_otherDevicePersistentId != null) {
      try {
        final contact = await _contactRepository.getContact(_otherDevicePersistentId!);
        if (contact != null) {
          return {
            'displayName': contact.displayName,
            'publicKey': _otherDevicePersistentId!,
            'source': 'repository'
          };
        }
      } catch (e) {
        _logger.warning('Failed to get fallback identity: $e');
      }
    }
    
    // Last resort: Return what we have
    return {
      'displayName': _otherUserName ?? 'Connected Device',
      'publicKey': _otherDevicePersistentId ?? '',
      'source': 'fallback'
    };
  }

  void dispose() {
    _contactSyncRetryTimer?.cancel();
  }
  
  // Methods required by integration service
  
  /// Start BLE scanning - delegates to BLE service with burst source
  Future<void> startScanning() async {
    _logger.info('🔧 BURST: Power manager requesting burst scanning');
    // Delegate to actual BLE service with burst scanning source
    try {
      final bleService = _getBleService();
      if (bleService != null) {
        await bleService.startScanning(source: ScanningSource.burst);
      } else {
        _logger.warning('BLE service not available for burst scanning');
      }
    } catch (e) {
      _logger.warning('Burst scanning failed: $e');
    }
  }
  
  /// Stop BLE scanning - delegates to BLE service  
  Future<void> stopScanning() async {
    _logger.info('🔧 BURST: Power manager requesting scan stop');
    // Delegate to actual BLE service
    try {
      final bleService = _getBleService();
      if (bleService != null) {
        await bleService.stopScanning();
      } else {
        _logger.warning('BLE service not available for stopping scan');
      }
    } catch (e) {
      _logger.warning('Stop scanning failed: $e');
    }
  }
  
  /// Get BLE service instance - helper method
  BLEService? _getBleService() {
    // In a real implementation, this would get the BLE service instance
    // For now, we'll log that this needs to be connected
    _logger.fine('BLE service connection needed for power manager integration');
    return null; // Placeholder - needs proper service injection
  }
  
  /// Send message via BLE - placeholder for integration
  Future<void> sendMessage(String content, {String? messageId}) async {
    _logger.info('BLE message send requested: ${messageId?.substring(0, 16) ?? 'unknown'}...');
    
    try {
      // This would typically delegate to the actual BLE service
      // For now, simulate the callback behavior
      await Future.delayed(Duration(milliseconds: 100));
      
      if (messageId != null) {
        // Simulate successful message sending
        onMessageSent?.call(messageId, true);
      }
      
    } catch (e) {
      _logger.severe('Failed to send BLE message: $e');
      if (messageId != null) {
        onMessageSent?.call(messageId, false);
      }
    }
  }
}