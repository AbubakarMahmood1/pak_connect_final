import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:logging/logging.dart';
import 'dart:typed_data';
import 'dart:async';

class UserPreferences {
  static final _logger = Logger('UserPreferences');
  static const String _userNameKey = 'user_display_name';
  static const String _deviceIdKey = 'my_persistent_device_id';
  static const String _publicKeyKey = 'ecdh_public_key_v2';
  static const String _privateKeyKey = 'ecdh_private_key_v2';
  static const String _hintBroadcastKey =
      'hint_broadcast_enabled'; // Spy mode control

  // USERNAME PROPAGATION FIX: Stream controller for reactive updates
  static StreamController<String>? _usernameStreamController;

  /// Get username change stream for reactive updates
  static Stream<String> get usernameStream {
    _usernameStreamController ??= StreamController<String>.broadcast();
    return _usernameStreamController!.stream;
  }

  Future<String> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_userNameKey) ?? 'User';
    _logger.fine('🔧 NAME DEBUG: Retrieved from SharedPreferences: "$name"');
    return name;
  }

  Future<void> setUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmedName = name.trim();
    await prefs.setString(_userNameKey, trimmedName);
    _logger.fine('🔧 NAME DEBUG: Saved to SharedPreferences: "$trimmedName"');

    // USERNAME PROPAGATION FIX: Notify reactive listeners
    _usernameStreamController?.add(trimmedName);
  }

  /// Clean up stream controller
  static void dispose() {
    _usernameStreamController?.close();
    _usernameStreamController = null;
  }

  // Get or create persistent device ID
  Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_deviceIdKey);

    if (deviceId == null || deviceId.isEmpty) {
      // Generate unique device ID
      deviceId = 'dev_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString(_deviceIdKey, deviceId);
    }

    return deviceId;
  }

  // Get existing device ID (returns null if not set)
  Future<String?> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceIdKey);
  }

  Future<Map<String, String>> getOrCreateKeyPair() async {
    _logger.info('🔑 Checking for existing key pair...');
    final pubStart = DateTime.now();
    final publicKey = await getPublicKey();
    _logger.info(
      '✅ Public key check complete in ${DateTime.now().difference(pubStart).inMilliseconds}ms',
    );

    final privStart = DateTime.now();
    final privateKey = await getPrivateKey();
    _logger.info(
      '✅ Private key check complete in ${DateTime.now().difference(privStart).inMilliseconds}ms',
    );

    if (publicKey.isNotEmpty && privateKey.isNotEmpty) {
      _logger.info('🔑 Existing key pair found');
      return {'public': publicKey, 'private': privateKey};
    }

    // Generate new key pair
    _logger.info('🔑 No existing key pair found, generating new one...');
    return await _generateNewKeyPair();
  }

  Future<String> getPublicKey() async {
    _logger.info('🔑 Reading public key from secure storage...');
    final start = DateTime.now();
    final storage = FlutterSecureStorage();
    final publicKey = await storage.read(key: _publicKeyKey);
    _logger.info(
      '✅ Public key read in ${DateTime.now().difference(start).inMilliseconds}ms',
    );
    return publicKey ?? '';
  }

  Future<String> getPrivateKey() async {
    _logger.info('🔑 Reading private key from secure storage...');
    final start = DateTime.now();
    final storage = FlutterSecureStorage();
    final privateKey = await storage.read(key: _privateKeyKey);
    _logger.info(
      '✅ Private key read in ${DateTime.now().difference(start).inMilliseconds}ms',
    );
    return privateKey ?? '';
  }

  Future<bool> hasKeyPair() async {
    final publicKey = await getPublicKey();
    final privateKey = await getPrivateKey();
    return publicKey.isNotEmpty && privateKey.isNotEmpty;
  }

  Future<Map<String, String>> _generateNewKeyPair() async {
    _logger.info('🔑 Generating new ECDH key pair...');
    final genStart = DateTime.now();

    final keyGen = ECKeyGenerator();
    final secureRandom = FortunaRandom();

    // Seed the random number generator
    final seed = List<int>.generate(
      32,
      (i) => DateTime.now().millisecondsSinceEpoch ~/ (i + 1),
    );
    secureRandom.seed(KeyParameter(Uint8List.fromList(seed)));

    // Generate P-256 key pair
    final keyParams = ECKeyGeneratorParameters(ECCurve_secp256r1());
    keyGen.init(ParametersWithRandom(keyParams, secureRandom));

    _logger.info('🔑 Generating key pair...');
    final keyGenStart = DateTime.now();
    final keyPair = keyGen.generateKeyPair();
    _logger.info(
      '✅ Key pair generated in ${DateTime.now().difference(keyGenStart).inMilliseconds}ms',
    );

    final publicKey = keyPair.publicKey as ECPublicKey;
    final privateKey = keyPair.privateKey as ECPrivateKey;

    // Encode keys as hex strings
    final publicKeyHex = publicKey.Q!
        .getEncoded(false)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final privateKeyHex = privateKey.d!.toRadixString(16);

    // Store securely
    _logger.info('🔑 Storing keys in secure storage...');
    final storeStart = DateTime.now();
    final storage = FlutterSecureStorage();
    await storage.write(key: _publicKeyKey, value: publicKeyHex);
    await storage.write(key: _privateKeyKey, value: privateKeyHex);
    _logger.info(
      '✅ Keys stored in ${DateTime.now().difference(storeStart).inMilliseconds}ms',
    );

    final totalTime = DateTime.now().difference(genStart);
    _logger.info(
      '🎉 Key pair generation complete in ${totalTime.inMilliseconds}ms',
    );

    return {'public': publicKeyHex, 'private': privateKeyHex};
  }

  Future<void> regenerateKeyPair() async {
    final storage = FlutterSecureStorage();
    await storage.delete(key: _publicKeyKey);
    await storage.delete(key: _privateKeyKey);
    await _generateNewKeyPair();
  }

  // ========== SPY MODE (Hint Broadcast Control) ==========

  /// Get hint broadcast status (default: true/enabled)
  /// When false = SPY MODE (anonymous ephemeral-only chat)
  Future<bool> getHintBroadcastEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hintBroadcastKey) ?? true; // Default: hints ON
  }

  /// Set hint broadcast status
  /// false = Enable SPY MODE (chat anonymously with friends)
  Future<void> setHintBroadcastEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hintBroadcastKey, enabled);
    _logger.info(
      enabled
          ? '🕵️ Spy mode DISABLED - hints will be broadcast'
          : '🕵️ Spy mode ENABLED - chatting anonymously',
    );
  }
}
