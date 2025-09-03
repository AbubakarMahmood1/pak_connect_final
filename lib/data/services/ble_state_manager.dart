import 'dart:async';
import 'package:logging/logging.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/services/simple_crypto.dart';

class BLEStateManager {
  final _logger = Logger('BLEStateManager');
  
  // User and contact management
  final ContactRepository _contactRepository = ContactRepository();
  final UserPreferences _userPreferences = UserPreferences();
  
  String? _myUserName;
  String? _otherUserName;
  String? _myPersistentId;
  String? _otherDevicePersistentId;
  
  // Peripheral mode tracking
  bool _isPeripheralMode = false;
  
  // Getters
  String? get myUserName => _myUserName;
  String? get otherUserName => _otherUserName;
  String? get otherDevicePersistentId => _otherDevicePersistentId;
  bool get isPeripheralMode => _isPeripheralMode;
  String? get myPersistentId => _myPersistentId;
  
  // Callbacks
  Function(String?)? onNameChanged;
  
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
  
  Future<void> saveContact(String deviceId, String userName) async {
    await _contactRepository.saveContact(deviceId, userName);
  }
  
  Future<String?> getContactName(String deviceId) async {
    return await _contactRepository.getContactName(deviceId);
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