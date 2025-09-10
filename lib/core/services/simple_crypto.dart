import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:pointycastle/export.dart';
import '../../data/repositories/contact_repository.dart';

class SimpleCrypto {
  static Encrypter? _encrypter;
  static IV? _iv;
  static ECPrivateKey? _privateKey;
  static ECPublicKey? _verifyingKey;
  static Map<String, String> _sharedSecretCache = {};
  static final Map<String, Encrypter> _conversationEncrypters = {};
  static final Map<String, IV> _conversationIVs = {};
  
  // Initialize with shared passphrase
  static void initialize(String passphrase) {
    // Generate key from passphrase using PBKDF2-like approach
    final keyBytes = sha256.convert(utf8.encode(passphrase + 'BLE_CHAT_SALT')).bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    
    // Use fixed IV for simplicity (in production, should be random per message)
    final ivBytes = sha256.convert(utf8.encode(passphrase + 'BLE_CHAT_IV')).bytes.sublist(0, 16);
    _iv = IV(Uint8List.fromList(ivBytes));
    
    _encrypter = Encrypter(AES(key));
  }
  
  // Encrypt message content
  static String encrypt(String plaintext) {
    if (_encrypter == null) {
      throw StateError('Crypto not initialized. Call initialize() first.');
    }
    
    final encrypted = _encrypter!.encrypt(plaintext, iv: _iv!);
    return encrypted.base64;
  }
  
  // Decrypt message content
  static String decrypt(String encryptedBase64) {
    if (_encrypter == null) {
      throw StateError('Crypto not initialized. Call initialize() first.');
    }
    
    final encrypted = Encrypted.fromBase64(encryptedBase64);
    return _encrypter!.decrypt(encrypted, iv: _iv!);
  }
  
  // Check if crypto is ready
  static bool get isInitialized => _encrypter != null;
  
  // Clear crypto (for logout/reset)
  static void clear() {
    _encrypter = null;
    _iv = null;
    _privateKey = null;
    _verifyingKey = null;
  }

static void initializeConversation(String publicKey, String sharedSecret) {
  // Generate conversation-specific key and IV
  final keyBytes = sha256.convert(utf8.encode(sharedSecret + 'CONVERSATION_KEY')).bytes;
  final key = Key(Uint8List.fromList(keyBytes));
  
  final ivBytes = sha256.convert(utf8.encode(sharedSecret + 'CONVERSATION_IV')).bytes.sublist(0, 16);
  final iv = IV(Uint8List.fromList(ivBytes));
  
  _conversationEncrypters[publicKey] = Encrypter(AES(key));
  _conversationIVs[publicKey] = iv;
  
  print('Initialized conversation crypto for ${publicKey.substring(0, 8)}...');
}

// Add conversation-aware encrypt method
static String encryptForConversation(String plaintext, String publicKey) {
  final encrypter = _conversationEncrypters[publicKey];
  final iv = _conversationIVs[publicKey];
  
  if (encrypter == null || iv == null) {
    throw StateError('No conversation key for $publicKey');
  }
  
  final encrypted = encrypter.encrypt(plaintext, iv: iv);
  return encrypted.base64;
}

// Add conversation-aware decrypt method  
static String decryptFromConversation(String encryptedBase64, String publicKey) {
  final encrypter = _conversationEncrypters[publicKey];
  final iv = _conversationIVs[publicKey];
  
  if (encrypter == null || iv == null) {
    throw StateError('No conversation key for $publicKey');
  }
  
  final encrypted = Encrypted.fromBase64(encryptedBase64);
  return encrypter.decrypt(encrypted, iv: iv);
}

static bool hasConversationKey(String publicKey) {
  return _conversationEncrypters.containsKey(publicKey);
}

  // === MESSAGE SIGNING (Direct Constructor Approach) ===
  
static void initializeSigning(String privateKeyHex, String publicKeyHex) {
  try {
    // Parse private key
    final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
    
    _privateKey = ECPrivateKey(privateKeyInt, ECCurve_secp256r1());
    
    // Parse public key
    final publicKeyBytes = _hexToBytes(publicKeyHex);
    
    final curve = ECCurve_secp256r1();
    
    final point = curve.curve.decodePoint(publicKeyBytes);
    
    _verifyingKey = ECPublicKey(point, curve);
    
    print('🟢 INIT SUCCESS: Message signing initialized completely');
  } catch (e, stackTrace) {
    print('🔴 INIT FAIL: Exception during initialization');
    print('🔴 INIT FAIL: Error type: ${e.runtimeType}');
    print('🔴 INIT FAIL: Error message: $e');
    print('🔴 INIT FAIL: Stack trace first 3 lines:');
    final stackLines = stackTrace.toString().split('\n');
    for (int i = 0; i < 3 && i < stackLines.length; i++) {
      print('🔴 INIT STACK $i: ${stackLines[i]}');
    }
    _privateKey = null;
    _verifyingKey = null;
  }
}

  // Direct constructor approach (NO registry)
static String? signMessage(String content) {
  if (_privateKey == null) {
    print('🔴 SIGN FAIL: No private key available');
    return null;
  }
  
  try {    
    // Step 2: Create signer
    final signer = ECDSASigner(SHA256Digest());
    
    // Step 3: Create our own SecureRandom (bypass registry)
    final secureRandom = FortunaRandom();
    
    // Seed it properly
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => 
      DateTime.now().microsecondsSinceEpoch ~/ (i + 1)));
    secureRandom.seed(KeyParameter(seed));
    
    // Step 4: Initialize with both private key AND SecureRandom
    final privateKeyParam = PrivateKeyParameter(_privateKey!);
    final params = ParametersWithRandom(privateKeyParam, secureRandom);
    
    signer.init(true, params);
    
    // Step 5: Prepare message
    final messageBytes = utf8.encode(content);
    
    // Step 6: Generate signature
    final signature = signer.generateSignature(messageBytes) as ECSignature;
    
    // Step 7: Encode signature
    final rHex = signature.r.toRadixString(16);
    final sHex = signature.s.toRadixString(16);
    final result = '$rHex:$sHex';
    
    return result;
    
  } catch (e, stackTrace) {
    print('🔴 SIGN FAIL: Exception caught');
    print('🔴 SIGN FAIL: Error type: ${e.runtimeType}');
    print('🔴 SIGN FAIL: Error message: $e');
    print('🔴 SIGN FAIL: Stack trace first 3 lines:');
    final stackLines = stackTrace.toString().split('\n');
    for (int i = 0; i < 3 && i < stackLines.length; i++) {
      print('🔴 STACK $i: ${stackLines[i]}');
    }
    return null;
  }
}

  // Direct constructor verification
  static bool verifySignature(String content, String signatureHex, String senderPublicKeyHex) {
    try {
      // Parse sender's public key
      final publicKeyBytes = _hexToBytes(senderPublicKeyHex);
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(publicKeyBytes);
      final publicKey = ECPublicKey(point, curve);
      
      // Parse signature
      final sigParts = signatureHex.split(':');
      final r = BigInt.parse(sigParts[0], radix: 16);
      final s = BigInt.parse(sigParts[1], radix: 16);
      final signature = ECSignature(r, s);
      
      // Direct instantiation - no registry
      final verifier = ECDSASigner(SHA256Digest());
      verifier.init(false, PublicKeyParameter(publicKey));
      
      final messageBytes = utf8.encode(content);
      return verifier.verifySignature(messageBytes, signature);
      
    } catch (e) {
      print('Signature verification failed: $e');
      return false;
    }
  }

  // Helper method
  static Uint8List _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(result);
  }

  // Check if signing is ready
  static bool get isSigningReady => _privateKey != null;

// === ECDH KEY EXCHANGE ===
static String? computeSharedSecret(String theirPublicKeyHex) {
  if (_privateKey == null) {
    print('Cannot compute shared secret - no private key');
    return null;
  }
  
  try {
    
    // Parse their public key
    final theirPublicKeyBytes = _hexToBytes(theirPublicKeyHex);
    final curve = ECCurve_secp256r1();
    final theirPoint = curve.curve.decodePoint(theirPublicKeyBytes);
    final theirPublicKey = ECPublicKey(theirPoint, curve);
    
    // ECDH computation: myPrivateKey * theirPublicKey
    final sharedPoint = theirPublicKey.Q! * _privateKey!.d!;
    final sharedSecret = sharedPoint!.x!.toBigInteger()!.toRadixString(16);
    
    return sharedSecret;
    
  } catch (e) {
    print('🔴 ECDH computation failed: $e');
    return null;
  }
}

static Future<String?> encryptForContact(String plaintext, String contactPublicKey, ContactRepository contactRepo) async {
  // Get cached or compute shared secret
  final sharedSecret = await getCachedOrComputeSharedSecret(contactPublicKey, contactRepo);
  if (sharedSecret == null) return null;
  
  try {
    print('ECDH ENCRYPT: Using cached shared secret: ${sharedSecret.substring(0, 16)}...');
    
    final saltedSecret = sharedSecret + 'ECDH_AES_SALT';
    final keyBytes = sha256.convert(utf8.encode(saltedSecret)).bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    
    final ivInput = sharedSecret + 'ECDH_AES_IV';
    final ivBytes = sha256.convert(utf8.encode(ivInput)).bytes.sublist(0, 16);
    final iv = IV(Uint8List.fromList(ivBytes));
    
    final encrypter = Encrypter(AES(key));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    
    print('ECDH encryption with cached secret successful');
    return encrypted.base64;
    
  } catch (e) {
    print('ECDH encryption failed: $e');
    return null;
  }
}


static Future<String?> decryptFromContact(String encryptedBase64, String contactPublicKey, ContactRepository contactRepo) async {
  final sharedSecret = await getCachedOrComputeSharedSecret(contactPublicKey, contactRepo);
  if (sharedSecret == null) return null;
  
  try {
    print('ECDH DECRYPT: Using cached shared secret: ${sharedSecret.substring(0, 16)}...');
    
    final saltedSecret = sharedSecret + 'ECDH_AES_SALT';
    final keyBytes = sha256.convert(utf8.encode(saltedSecret)).bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    
    final ivInput = sharedSecret + 'ECDH_AES_IV';
    final ivBytes = sha256.convert(utf8.encode(ivInput)).bytes.sublist(0, 16);
    final iv = IV(Uint8List.fromList(ivBytes));
    
    final encrypter = Encrypter(AES(key));
    final encrypted = Encrypted.fromBase64(encryptedBase64);
    
    final decrypted = encrypter.decrypt(encrypted, iv: iv);
    print('ECDH decryption with cached secret successful');
    return decrypted;
    
  } catch (e) {
    print('ECDH decryption failed: $e');
    return null;
  }
}

static Future<String?> getCachedOrComputeSharedSecret(String contactPublicKey, ContactRepository contactRepo) async {
  // Check memory cache first (fastest)
  if (_sharedSecretCache.containsKey(contactPublicKey)) {
    return _sharedSecretCache[contactPublicKey];
  }
  
  // Check secure storage cache
  final cachedSecret = await contactRepo.getCachedSharedSecret(contactPublicKey);
  if (cachedSecret != null) {
    print('Loaded shared secret from secure storage');
    _sharedSecretCache[contactPublicKey] = cachedSecret;
    return cachedSecret;
  }
  
  // Compute new shared secret (expensive)
  print('Computing new ECDH shared secret - will cache for future use');
  final newSecret = computeSharedSecret(contactPublicKey);
  if (newSecret != null) {
    _sharedSecretCache[contactPublicKey] = newSecret;
    await contactRepo.cacheSharedSecret(contactPublicKey, newSecret);
    print('ECDH shared secret computed and cached');
  }
  
  return newSecret;
}
}