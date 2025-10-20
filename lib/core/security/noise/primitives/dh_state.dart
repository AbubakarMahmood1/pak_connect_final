/// Diffie-Hellman state wrapper for X25519 operations
/// 
/// Ports the DHState interface from bitchat-android's noise-java library.
/// Uses pinenacl package for X25519 elliptic curve operations.
/// 
/// Reference: bitchat-android/noise/southernstorm/protocol/DHState.java
library;

import 'package:pinenacl/api.dart';
import 'package:pinenacl/x25519.dart' as x25519;
import 'package:pinenacl/tweetnacl.dart' as nacl;

/// DHState abstraction for Noise Protocol Diffie-Hellman operations
/// 
/// Provides X25519 key generation and shared secret calculation.
class DHState {
  /// Private key (32 bytes)
  Uint8List? _privateKey;
  
  /// Public key (32 bytes)
  Uint8List? _publicKey;
  
  /// Algorithm name (always "25519" for X25519)
  static const String algorithmName = '25519';
  
  /// Key length in bytes (32 for X25519)
  static const int keyLength = 32;
  
  /// Shared secret length in bytes (32 for X25519)
  static const int sharedKeyLength = 32;

  DHState();

  /// Generate a new X25519 key pair
  /// 
  /// Creates random private key and derives public key.
  /// Matches DHState.generateKeyPair() from noise-java.
  void generateKeyPair() {
    final keyPair = x25519.PrivateKey.generate();
    _privateKey = Uint8List.fromList(keyPair.asTypedList);
    _publicKey = Uint8List.fromList(keyPair.publicKey.asTypedList);
  }

  /// Set private key and derive public key
  /// 
  /// [privateKey] 32-byte X25519 private key
  /// Matches DHState.setPrivateKey() from noise-java.
  void setPrivateKey(Uint8List privateKey) {
    if (privateKey.length != keyLength) {
      throw ArgumentError('Private key must be $keyLength bytes');
    }
    
    _privateKey = Uint8List.fromList(privateKey);
    
    // Derive public key from private key
    final privKey = x25519.PrivateKey(privateKey);
    _publicKey = Uint8List.fromList(privKey.publicKey.asTypedList);
  }

  /// Set public key (for remote peer)
  /// 
  /// [publicKey] 32-byte X25519 public key
  /// Matches DHState.setPublicKey() from noise-java.
  void setPublicKey(Uint8List publicKey) {
    if (publicKey.length != keyLength) {
      throw ArgumentError('Public key must be $keyLength bytes');
    }
    
    _publicKey = Uint8List.fromList(publicKey);
  }

  /// Get current public key
  /// 
  /// Returns 32-byte public key or null if not set.
  /// Matches DHState.getPublicKey() from noise-java.
  Uint8List? getPublicKey() {
    return _publicKey != null ? Uint8List.fromList(_publicKey!) : null;
  }

  /// Get current private key
  /// 
  /// Returns 32-byte private key or null if not set.
  /// Matches DHState.getPrivateKey() from noise-java.
  Uint8List? getPrivateKey() {
    return _privateKey != null ? Uint8List.fromList(_privateKey!) : null;
  }

  /// Calculate shared secret using X25519
  /// 
  /// Performs Diffie-Hellman operation: sharedSecret = DH(privateKey, publicKey)
  /// 
  /// [privateKey] Our 32-byte private key
  /// [publicKey] Their 32-byte public key
  /// Returns 32-byte shared secret
  /// 
  /// Matches DHState.calculate() from noise-java.
  static Uint8List calculate(Uint8List privateKey, Uint8List publicKey) {
    if (privateKey.length != keyLength) {
      throw ArgumentError('Private key must be $keyLength bytes');
    }
    if (publicKey.length != keyLength) {
      throw ArgumentError('Public key must be $keyLength bytes');
    }

    // Perform raw X25519 scalar multiplication using TweetNaCl
    // IMPORTANT: We use crypto_scalarmult directly, NOT Box.sharedKey
    // Box.sharedKey computes HSalsa20(X25519 result) for NaCl encryption,
    // but Noise Protocol requires raw X25519 output (RFC 7748 compliant)
    final result = Uint8List(keyLength);
    final returnValue = nacl.TweetNaCl.crypto_scalarmult(result, privateKey, publicKey);
    
    // crypto_scalarmult returns the result in the first parameter
    // and also returns it as the return value
    return returnValue;
  }

  /// Clear sensitive key material from memory
  /// 
  /// Overwrites keys with zeros for forward secrecy.
  /// Matches DHState.destroy() from noise-java.
  void destroy() {
    if (_privateKey != null) {
      _privateKey!.fillRange(0, _privateKey!.length, 0);
      _privateKey = null;
    }
    if (_publicKey != null) {
      _publicKey!.fillRange(0, _publicKey!.length, 0);
      _publicKey = null;
    }
  }

  /// Copy this DH state
  /// 
  /// Creates a deep copy with same key material.
  /// Matches DHState.copy() from noise-java.
  DHState copy() {
    final newState = DHState();
    if (_privateKey != null) {
      newState._privateKey = Uint8List.fromList(_privateKey!);
    }
    if (_publicKey != null) {
      newState._publicKey = Uint8List.fromList(_publicKey!);
    }
    return newState;
  }
}
