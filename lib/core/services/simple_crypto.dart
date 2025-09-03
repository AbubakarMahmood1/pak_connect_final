import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:pointycastle/export.dart';

class SimpleCrypto {
  static Encrypter? _encrypter;
  static IV? _iv;
  static ECPrivateKey? _privateKey;
  static ECPublicKey? _verifyingKey;
  
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

  // === MESSAGE SIGNING (Direct Constructor Approach) ===
  
static void initializeSigning(String privateKeyHex, String publicKeyHex) {
  try {
    print('🔵 INIT STEP 1: Starting signing initialization');
    print('🔵 INIT STEP 1.1: Private key hex length: ${privateKeyHex.length} chars');
    print('🔵 INIT STEP 1.2: Public key hex length: ${publicKeyHex.length} chars');
    
    // Parse private key
    print('🔵 INIT STEP 2: Parsing private key...');
    final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
    print('🔵 INIT STEP 2.1: Private key BigInt parsed successfully');
    print('🔵 INIT STEP 2.2: Private key bit length: ${privateKeyInt.bitLength}');
    
    print('🔵 INIT STEP 2.3: Creating ECPrivateKey...');
    _privateKey = ECPrivateKey(privateKeyInt, ECCurve_secp256r1());
    print('🔵 INIT STEP 2.4: ECPrivateKey created successfully');
    
    // Parse public key
    print('🔵 INIT STEP 3: Parsing public key...');
    final publicKeyBytes = _hexToBytes(publicKeyHex);
    print('🔵 INIT STEP 3.1: Public key bytes length: ${publicKeyBytes.length}');
    
    final curve = ECCurve_secp256r1();
    print('🔵 INIT STEP 3.2: Curve created');
    
    final point = curve.curve.decodePoint(publicKeyBytes);
    print('🔵 INIT STEP 3.3: Point decoded successfully');
    
    _verifyingKey = ECPublicKey(point, curve);
    print('🔵 INIT STEP 3.4: ECPublicKey created successfully');
    
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
    print('🔵 SIGN STEP 1: Starting message signing process');
    print('🔵 SIGN STEP 1.1: Content length: ${content.length} chars');
    
    // Step 2: Create signer
    print('🔵 SIGN STEP 2: Creating ECDSASigner...');
    final signer = ECDSASigner(SHA256Digest());
    print('🔵 SIGN STEP 2.1: ECDSASigner created successfully');
    
    // Step 3: Create our own SecureRandom (bypass registry)
    print('🔵 SIGN STEP 3: Creating manual SecureRandom...');
    final secureRandom = FortunaRandom();
    
    // Seed it properly
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => 
      DateTime.now().microsecondsSinceEpoch ~/ (i + 1)));
    secureRandom.seed(KeyParameter(seed));
    print('🔵 SIGN STEP 3.1: SecureRandom created and seeded');
    
    // Step 4: Initialize with both private key AND SecureRandom
    print('🔵 SIGN STEP 4: Initializing signer with private key + SecureRandom...');
    final privateKeyParam = PrivateKeyParameter(_privateKey!);
    final params = ParametersWithRandom(privateKeyParam, secureRandom);
    
    signer.init(true, params);  // Use ParametersWithRandom instead
    print('🔵 SIGN STEP 4.1: Signer initialized with manual SecureRandom');
    
    // Step 5: Prepare message
    print('🔵 SIGN STEP 5: Converting message to bytes...');
    final messageBytes = utf8.encode(content);
    print('🔵 SIGN STEP 5.1: Message bytes length: ${messageBytes.length}');
    
    // Step 6: Generate signature
    print('🔵 SIGN STEP 6: Generating signature...');
    final signature = signer.generateSignature(messageBytes) as ECSignature;
    print('🔵 SIGN STEP 6.1: Signature generated successfully');
    
    // Step 7: Encode signature
    final rHex = signature.r.toRadixString(16);
    final sHex = signature.s.toRadixString(16);
    final result = '$rHex:$sHex';
    print('🟢 SIGN SUCCESS: Signature generated: ${result.substring(0, 32)}...');
    
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
    print('🔵 ECDH DEBUG: Computing shared secret');
    print('🔵 ECDH DEBUG: Their public key: ${theirPublicKeyHex.substring(0, 32)}...');
    print('🔵 ECDH DEBUG: My private key: ${_privateKey!.d!.toRadixString(16).substring(0, 16)}...');
    
    // Parse their public key
    final theirPublicKeyBytes = _hexToBytes(theirPublicKeyHex);
    final curve = ECCurve_secp256r1();
    final theirPoint = curve.curve.decodePoint(theirPublicKeyBytes);
    final theirPublicKey = ECPublicKey(theirPoint, curve);
    
    print('🔵 ECDH DEBUG: Parsed their public key successfully');
    
    // ECDH computation: myPrivateKey * theirPublicKey
    final sharedPoint = theirPublicKey.Q! * _privateKey!.d!;
    final sharedSecret = sharedPoint!.x!.toBigInteger()!.toRadixString(16);
    
    print('🔵 ECDH DEBUG: Shared secret: ${sharedSecret.substring(0, 32)}...');
    print('🔵 ECDH DEBUG: Shared secret length: ${sharedSecret.length} hex chars');
    
    return sharedSecret;
    
  } catch (e) {
    print('🔴 ECDH computation failed: $e');
    return null;
  }
}

static String? encryptForContact(String plaintext, String contactPublicKey) {
  final sharedSecret = computeSharedSecret(contactPublicKey);
  if (sharedSecret == null) return null;
  
  try {
    print('🔵 ECDH ENCRYPT: Using shared secret: ${sharedSecret.substring(0, 16)}...');
    
    // Derive AES key from shared secret
    final saltedSecret = sharedSecret + 'ECDH_AES_SALT';
    print('🔵 ECDH ENCRYPT: Salted secret: ${saltedSecret.substring(0, 32)}...');
    
    final keyBytes = sha256.convert(utf8.encode(saltedSecret)).bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    print('🔵 ECDH ENCRYPT: AES key: ${keyBytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...');
    
    final ivInput = sharedSecret + 'ECDH_AES_IV';
    final ivBytes = sha256.convert(utf8.encode(ivInput)).bytes.sublist(0, 16);
    final iv = IV(Uint8List.fromList(ivBytes));
    print('🔵 ECDH ENCRYPT: IV: ${ivBytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...');
    
    final encrypter = Encrypter(AES(key));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    
    print('🟢 ECDH ENCRYPT: Success, encrypted: ${encrypted.base64.substring(0, 16)}...');
    return encrypted.base64;
    
  } catch (e) {
    print('🔴 ECDH encryption failed: $e');
    return null;
  }
}

static String? decryptFromContact(String encryptedBase64, String contactPublicKey) {
  final sharedSecret = computeSharedSecret(contactPublicKey);
  if (sharedSecret == null) return null;
  
  try {
    print('🔵 ECDH DECRYPT: Using shared secret: ${sharedSecret.substring(0, 16)}...');
    print('🔵 ECDH DECRYPT: Encrypted data: ${encryptedBase64.substring(0, 16)}...');
    
    final saltedSecret = sharedSecret + 'ECDH_AES_SALT';
    print('🔵 ECDH DECRYPT: Salted secret: ${saltedSecret.substring(0, 32)}...');
    
    final keyBytes = sha256.convert(utf8.encode(saltedSecret)).bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    print('🔵 ECDH DECRYPT: AES key: ${keyBytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...');
    
    final ivInput = sharedSecret + 'ECDH_AES_IV';
    final ivBytes = sha256.convert(utf8.encode(ivInput)).bytes.sublist(0, 16);
    final iv = IV(Uint8List.fromList(ivBytes));
    print('🔵 ECDH DECRYPT: IV: ${ivBytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...');
    
    final encrypter = Encrypter(AES(key));
    final encrypted = Encrypted.fromBase64(encryptedBase64);
    
    print('🔵 ECDH DECRYPT: Attempting decryption...');
    final decrypted = encrypter.decrypt(encrypted, iv: iv);
    print('🟢 ECDH DECRYPT: Success, decrypted: "$decrypted"');
    return decrypted;
    
  } catch (e) {
    print('🔴 ECDH decryption failed: $e');
    return null;
  }
}
}