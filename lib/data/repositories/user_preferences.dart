import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'dart:typed_data';

class UserPreferences {
  static const String _userNameKey = 'user_display_name';
  static const String _passphraseKey = 'chat_passphrase';
  static const String _deviceIdKey = 'my_persistent_device_id';
  static const String _publicKeyKey = 'ecdh_public_key_v2';
  static const String _privateKeyKey = 'ecdh_private_key_v2';
  
  Future<String> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userNameKey) ?? 'User';
  }
  
  Future<void> setUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, name.trim());
  }
  
  // Add passphrase methods
  Future<String> getPassphrase() async {
    final prefs = await SharedPreferences.getInstance();
    String? stored = prefs.getString(_passphraseKey);
    
    if (stored == null || stored.isEmpty) {
      // Auto-generate secure passphrase
      final generated = _generatePassphrase();
      await setPassphrase(generated);
      return generated;
    }
    
    return stored;
  }
  
  Future<void> setPassphrase(String passphrase) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_passphraseKey, passphrase.trim());
  }
  
  // Generate random passphrase
  String _generatePassphrase() {
    final words = ['blue', 'red', 'cat', 'dog', 'sun', 'moon', 'fire', 'water', 'tree', 'rock'];
    final random = DateTime.now().millisecondsSinceEpoch;
    final word1 = words[random % words.length];
    final word2 = words[(random ~/ 1000) % words.length];
    final number = (random % 999) + 100; // 3 digit number
    return '$word1$number$word2';
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
  final publicKey = await getPublicKey();
  final privateKey = await getPrivateKey();
  
  if (publicKey.isNotEmpty && privateKey.isNotEmpty) {
    return {'public': publicKey, 'private': privateKey};
  }
  
  // Generate new key pair
  return await _generateNewKeyPair();
}

Future<String> getPublicKey() async {
  final storage = FlutterSecureStorage();
  final publicKey = await storage.read(key: _publicKeyKey);
  return publicKey ?? '';
}

Future<String> getPrivateKey() async {
  final storage = FlutterSecureStorage();
  final privateKey = await storage.read(key: _privateKeyKey);
  return privateKey ?? '';
}

Future<bool> hasKeyPair() async {
  final publicKey = await getPublicKey();
  final privateKey = await getPrivateKey();
  return publicKey.isNotEmpty && privateKey.isNotEmpty;
}

Future<Map<String, String>> _generateNewKeyPair() async {
  final keyGen = ECKeyGenerator();
  final secureRandom = FortunaRandom();
  
  // Seed the random number generator
  final seed = List<int>.generate(32, (i) => 
    DateTime.now().millisecondsSinceEpoch ~/ (i + 1));
  secureRandom.seed(KeyParameter(Uint8List.fromList(seed)));
  
  // Generate P-256 key pair
  final keyParams = ECKeyGeneratorParameters(ECCurve_secp256r1());
  keyGen.init(ParametersWithRandom(keyParams, secureRandom));
  
  final keyPair = keyGen.generateKeyPair();
  final publicKey = keyPair.publicKey as ECPublicKey;
  final privateKey = keyPair.privateKey as ECPrivateKey;
  
  // Encode keys as hex strings
  final publicKeyHex = publicKey.Q!.getEncoded(false).map((b) => 
    b.toRadixString(16).padLeft(2, '0')).join();
  final privateKeyHex = privateKey.d!.toRadixString(16);
  
  // Store securely
  final storage = FlutterSecureStorage();
  await storage.write(key: _publicKeyKey, value: publicKeyHex);
  await storage.write(key: _privateKeyKey, value: privateKeyHex);
  
  return {'public': publicKeyHex, 'private': privateKeyHex};
}

Future<void> regenerateKeyPair() async {
  final storage = FlutterSecureStorage();
  await storage.delete(key: _publicKeyKey);
  await storage.delete(key: _privateKeyKey);
  await _generateNewKeyPair();
}

}