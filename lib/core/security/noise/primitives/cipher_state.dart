/// Cipher state wrapper for ChaCha20-Poly1305 AEAD operations
/// 
/// Ports the CipherState interface from bitchat-android's noise-java library.
/// Uses cryptography package for ChaCha20-Poly1305 authenticated encryption.
/// 
/// Reference: bitchat-android/noise/southernstorm/protocol/CipherState.java
library;

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// CipherState abstraction for Noise Protocol encryption operations
/// 
/// Provides ChaCha20-Poly1305 AEAD encryption/decryption with nonce management.
class CipherState {
  /// Cipher algorithm (ChaCha20-Poly1305)
  final Chacha20 _cipher = Chacha20.poly1305Aead();
  
  /// Encryption key (32 bytes for ChaCha20)
  Uint8List? _key;
  
  /// Current nonce value (8 bytes, increments per encryption)
  int _nonce = 0;
  
  /// Algorithm name
  static const String algorithmName = 'ChaChaPoly';
  
  /// Key length in bytes (32 for ChaCha20)
  static const int keyLength = 32;
  
  /// MAC length in bytes (16 for Poly1305)
  static const int macLength = 16;
  
  /// Maximum nonce value before rekey required
  /// Noise spec: rekey after 2^64-1 messages, but we use a safe limit
  static const int maxNonce = (1 << 63) - 1; // Max safe positive int64

  CipherState();

  /// Initialize cipher with key
  /// 
  /// [key] 32-byte ChaCha20 key
  /// Resets nonce to 0.
  /// Matches CipherState.initializeKey() from noise-java.
  void initializeKey(Uint8List key) {
    if (key.length != keyLength) {
      throw ArgumentError('Key must be $keyLength bytes');
    }
    
    _key = Uint8List.fromList(key);
    _nonce = 0;
  }

  /// Check if cipher has a key
  /// 
  /// Returns true if key is set, false otherwise.
  /// Matches CipherState.hasKey() from noise-java.
  bool hasKey() {
    return _key != null;
  }

  /// Set nonce value
  /// 
  /// [nonce] 8-byte nonce value
  /// Matches CipherState.setNonce() from noise-java.
  void setNonce(int nonce) {
    _nonce = nonce;
  }

  /// Get current nonce value
  /// 
  /// Returns current 8-byte nonce.
  /// Matches CipherState.getNonce() from noise-java.
  int getNonce() {
    return _nonce;
  }

  /// Encrypt plaintext with associated data
  /// 
  /// Performs ChaCha20-Poly1305 AEAD encryption.
  /// Increments nonce after encryption.
  /// 
  /// [plaintext] Data to encrypt
  /// [associatedData] Additional authenticated data (AAD)
  /// Returns ciphertext with 16-byte MAC appended
  /// 
  /// Matches CipherState.encryptWithAd() from noise-java.
  Future<Uint8List> encryptWithAd(
    Uint8List? associatedData,
    Uint8List plaintext,
  ) async {
    if (_key == null) {
      throw StateError('Cannot encrypt without key');
    }

    if (_nonce >= maxNonce) {
      throw StateError('Nonce overflow - rekey required');
    }

    // Convert nonce to 12-byte format for ChaCha20-Poly1305
    final nonceBytes = _nonceToBytes(_nonce);

    // Create secret key
    final secretKey = SecretKey(_key!);

    // Encrypt with AEAD
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonceBytes,
      aad: associatedData ?? Uint8List(0),
    );

    // Increment nonce
    _nonce++;

    // Combine ciphertext + MAC
    final result = Uint8List(secretBox.cipherText.length + macLength);
    result.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
    result.setRange(
      secretBox.cipherText.length,
      result.length,
      secretBox.mac.bytes,
    );

    return result;
  }

  /// Decrypt ciphertext with associated data
  /// 
  /// Performs ChaCha20-Poly1305 AEAD decryption and MAC verification.
  /// Increments nonce after successful decryption.
  /// 
  /// [ciphertext] Encrypted data with 16-byte MAC appended
  /// [associatedData] Additional authenticated data (AAD)
  /// Returns plaintext on success
  /// Throws exception on MAC verification failure
  /// 
  /// Matches CipherState.decryptWithAd() from noise-java.
  Future<Uint8List> decryptWithAd(
    Uint8List? associatedData,
    Uint8List ciphertext,
  ) async {
    if (_key == null) {
      throw StateError('Cannot decrypt without key');
    }

    if (ciphertext.length < macLength) {
      throw ArgumentError('Ciphertext too short (must include MAC)');
    }

    if (_nonce >= maxNonce) {
      throw StateError('Nonce overflow - rekey required');
    }

    // Split ciphertext and MAC
    final actualCiphertext = ciphertext.sublist(0, ciphertext.length - macLength);
    final mac = ciphertext.sublist(ciphertext.length - macLength);

    // Convert nonce to 12-byte format
    final nonceBytes = _nonceToBytes(_nonce);

    // Create secret key
    final secretKey = SecretKey(_key!);

    // Create SecretBox for decryption
    final secretBox = SecretBox(
      actualCiphertext,
      nonce: nonceBytes,
      mac: Mac(mac),
    );

    // Decrypt and verify MAC
    try {
      final plaintext = await _cipher.decrypt(
        secretBox,
        secretKey: secretKey,
        aad: associatedData ?? Uint8List(0),
      );

      // Increment nonce only on successful decryption
      _nonce++;

      return Uint8List.fromList(plaintext);
    } catch (e) {
      throw Exception('Decryption failed: MAC verification error - $e');
    }
  }

  /// Convert 8-byte nonce to 12-byte format for ChaCha20-Poly1305
  /// 
  /// ChaCha20 uses 12-byte nonces, Noise uses 8-byte.
  /// Prepends 4 zero bytes to 8-byte nonce.
  List<int> _nonceToBytes(int nonce) {
    final bytes = Uint8List(12);
    
    // Write nonce as little-endian 64-bit integer in last 8 bytes
    for (int i = 0; i < 8; i++) {
      bytes[4 + i] = (nonce >> (i * 8)) & 0xFF;
    }

    return bytes;
  }

  /// Clear sensitive key material from memory
  /// 
  /// Overwrites key with zeros for forward secrecy.
  /// Matches CipherState.destroy() from noise-java.
  void destroy() {
    if (_key != null) {
      _key!.fillRange(0, _key!.length, 0);
      _key = null;
    }
    _nonce = 0;
  }

  /// Create a copy of this cipher state
  /// 
  /// Deep copies key and nonce.
  /// Matches CipherState.fork() from noise-java.
  CipherState fork() {
    final newState = CipherState();
    if (_key != null) {
      newState._key = Uint8List.fromList(_key!);
    }
    newState._nonce = _nonce;
    return newState;
  }
}
