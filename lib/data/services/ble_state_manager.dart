import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:crypto/crypto.dart';
import '../../core/models/pairing_state.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/services/simple_crypto.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/models/protocol_message.dart';

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
  bool _theyEnteredCode = false;
  bool _theyHaveUsAsContact = false;
  bool _weHaveThemAsContact = false;
  
  // Peripheral mode tracking
  bool _isPeripheralMode = false;
  
  // Getters
  String? get myUserName => _myUserName;
  String? get otherUserName => _otherUserName;
  String? get otherDevicePersistentId => _otherDevicePersistentId;
  bool get isPeripheralMode => _isPeripheralMode;
  String? get myPersistentId => _myPersistentId;
  PairingInfo? get currentPairing => _currentPairing;
  bool get hasContactRequest => _contactRequestPending;
  String? get pendingContactName => _pendingContactName;
  bool get theyHaveUsAsContact => _theyHaveUsAsContact;
  bool get weHaveThemAsContact => _weHaveThemAsContact;

  bool _contactRequestPending = false;
  String? _pendingContactPublicKey;
  String? _pendingContactName;
  Completer<bool>? _contactRequestCompleter;
  Completer<bool>? _pairingCompleter;
  Timer? _pairingTimeout;
  String? _receivedPairingCode;

  ContactRepository get contactRepository => _contactRepository;
  
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
  
  Future<void> initialize() async {
  await loadUserName();
  
  // Ensure key pair exists
  await _userPreferences.getOrCreateKeyPair();
  _myPersistentId = await _userPreferences.getPublicKey();
  
  await _initializeCrypto();
  await _initializeSigning();
}
  
Future<void> loadUserName() async {
  _myUserName = await _userPreferences.getUserName();
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
    _myUserName = name;
    await _userPreferences.setUserName(name);
  }
  
  void setOtherUserName(String? name) {
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
  _logger.info('Setting other device identity: "$displayName" (ID: $deviceId)');
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
  return contact?.trustStatus ?? TrustStatus.new_contact;
}

Future<bool> hasContactKeyChanged(String publicKey, String currentDisplayName) async {
  final existingContact = await _contactRepository.getContact(publicKey);
  
  if (existingContact == null) {
    return false; // New contact, not a key change
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
  _theyEnteredCode = true;
  
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

Future<void> exchangeContactStatus() async {
  if (_otherDevicePersistentId == null) return;
  
  // Check if we have them as contact
  final contact = await _contactRepository.getContact(_otherDevicePersistentId!);
  _weHaveThemAsContact = contact != null && contact.trustStatus == TrustStatus.verified;
  
  // Send our status
  final myPublicKey = await getMyPersistentId();
  final statusMessage = ProtocolMessage.contactStatus(
    hasAsContact: _weHaveThemAsContact,
    publicKey: myPublicKey,
  );
  
  onSendContactStatus?.call(statusMessage);
}

void handleContactStatus(bool theyHaveUsAsContact, String theirPublicKey) {
  _logger.info('Contact status: They ${theyHaveUsAsContact ? "have" : "don't have"} us as contact');
  
  // Check our status
  final weHaveThem = _contactRepository.getContact(theirPublicKey) != null;
  
  if (theyHaveUsAsContact && !weHaveThem) {
    // They have us but we don't have them - prompt to add
    onAsymmetricContactDetected?.call(theirPublicKey, _otherUserName ?? 'Unknown');
  } else if (weHaveThem && !theyHaveUsAsContact) {
    // We have them but they don't have us - notify them
    _logger.info('Asymmetric contact - we have them, they need to add us');
  }
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
    // Save as verified contact
    await _contactRepository.saveContact(_pendingContactPublicKey!, _pendingContactName!);
    await _contactRepository.markContactVerified(_pendingContactPublicKey!);
    
    // Compute ECDH shared secret
    final sharedSecret = SimpleCrypto.computeSharedSecret(_pendingContactPublicKey!);
    if (sharedSecret != null) {
      await _contactRepository.cacheSharedSecret(_pendingContactPublicKey!, sharedSecret);
      _logger.info('ECDH shared secret computed and cached');
    }
    
    // Send acceptance
    final myPublicKey = await getMyPersistentId();
    final myName = _myUserName ?? 'User';
    onSendContactAccept?.call(myPublicKey, myName);
    
    _contactRequestPending = false;
    _pendingContactPublicKey = null;
    _pendingContactName = null;
    
    onContactRequestCompleted?.call(true);
    
  } catch (e) {
    _logger.severe('Failed to accept contact: $e');
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
  _logger.info('Contact request accepted by $displayName');
  
  // Save as verified contact
  _contactRepository.saveContact(publicKey, displayName);
  _contactRepository.markContactVerified(publicKey);
  
  // Compute ECDH shared secret
  final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
  if (sharedSecret != null) {
    _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
    _logger.info('ECDH shared secret computed and cached for accepted contact');
  }
  
  // Complete the request
  if (_contactRequestCompleter != null && !_contactRequestCompleter!.isCompleted) {
    _contactRequestCompleter!.complete(true);
  }
  
  onContactRequestCompleted?.call(true);
}

void handleContactReject() {
  _logger.info('Contact request rejected');
  
  if (_contactRequestCompleter != null && !_contactRequestCompleter!.isCompleted) {
    _contactRequestCompleter!.complete(false);
  }
  
  onContactRequestCompleted?.call(false);
}

void clearPairing() {
  _currentPairing = null;
  _receivedPairingCode = null;
  _theirReceivedCode = null;
  _weEnteredCode = false;
  _theyEnteredCode = false;
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
  
 void clearOtherUserName() {
  _otherUserName = null;
  _otherDevicePersistentId = null;
  onNameChanged?.call(null);
}
  
  Future<void> _initializeCrypto() async {
    try {
      final passphrase = await _userPreferences.getPassphrase();
      SimpleCrypto.initialize(passphrase);
      _logger.info('Encryption initialized with passphrase: ${passphrase.substring(0, 3)}***');
    } catch (e) {
      _logger.warning('Failed to initialize encryption: $e');
    }
  }
  
  Future<String> getCurrentPassphrase() async {
    return await _userPreferences.getPassphrase();
  }
  
  Future<void> setCustomPassphrase(String passphrase) async {
    await _userPreferences.setPassphrase(passphrase);
    SimpleCrypto.initialize(passphrase);
    _logger.info('Custom passphrase set and crypto reinitialized');
  }
  
  Future<void> generateNewPassphrase() async {
    await _userPreferences.setPassphrase('');
    final generated = await _userPreferences.getPassphrase();
    SimpleCrypto.initialize(generated);
    _logger.info('New passphrase generated and crypto reinitialized');
  }
  
  void dispose() {
    // Cleanup if needed
  }
}