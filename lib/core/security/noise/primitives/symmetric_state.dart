/// Symmetric state for Noise Protocol key derivation
/// 
/// Ports the SymmetricState interface from bitchat-android's noise-java library.
/// Manages hashing and key derivation during handshake.
/// 
/// Reference: bitchat-android/noise/southernstorm/protocol/SymmetricState.java
library;

import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'cipher_state.dart';

/// SymmetricState for Noise Protocol handshake operations
/// 
/// Maintains chaining key and handshake hash during protocol execution.
/// Uses HMAC-SHA256 for key derivation (HKDF pattern).
class SymmetricState {
  /// Current chaining key (32 bytes)
  Uint8List _chainingKey;
  
  /// Current handshake hash (32 bytes)
  final Uint8List _handshakeHash;
  
  /// Cipher state for encrypted payloads during handshake
  final CipherState _cipherState;
  
  /// Hash algorithm name
  static const String hashName = 'SHA256';
  
  /// Hash length in bytes
  static const int hashLength = 32;
  
  /// Block length for HMAC
  static const int blockLength = 64;

  /// Initialize symmetric state with protocol name
  /// 
  /// [protocolName] Full Noise protocol string (e.g., "Noise_XX_25519_ChaChaPoly_SHA256")
  /// 
  /// Matches SymmetricState constructor from noise-java.
  SymmetricState(String protocolName) 
      : _chainingKey = Uint8List(hashLength),
        _handshakeHash = Uint8List(hashLength),
        _cipherState = CipherState() {
    
    // Initialize h = HASH(protocolName)
    final protocolBytes = Uint8List.fromList(protocolName.codeUnits);
    
    if (protocolBytes.length <= hashLength) {
      // If protocol name fits in hash length, pad with zeros
      _handshakeHash.setRange(0, protocolBytes.length, protocolBytes);
    } else {
      // Otherwise, hash it
      final digest = sha256.convert(protocolBytes);
      _handshakeHash.setAll(0, digest.bytes);
    }
    
    // Initialize ck = h
    _chainingKey.setAll(0, _handshakeHash);
  }

  /// Mix key material into chaining key
  /// 
  /// Performs HKDF to update chaining key and potentially cipher key.
  /// 
  /// [inputKeyMaterial] Key material to mix (e.g., DH output)
  /// 
  /// Matches SymmetricState.mixKey() from noise-java.
  void mixKey(Uint8List inputKeyMaterial) {
    // HKDF with two outputs: (ck, k)
    final outputs = _hkdf(_chainingKey, inputKeyMaterial, 2);
    
    _chainingKey = outputs[0];
    
    // Initialize cipher with new key if appropriate
    if (outputs[1].isNotEmpty) {
      _cipherState.initializeKey(outputs[1]);
    }
  }

  /// Mix arbitrary data into handshake hash
  /// 
  /// Updates h = HASH(h || data)
  /// 
  /// [data] Data to mix into hash
  /// 
  /// Matches SymmetricState.mixHash() from noise-java.
  void mixHash(Uint8List data) {
    final combined = Uint8List(_handshakeHash.length + data.length);
    combined.setRange(0, _handshakeHash.length, _handshakeHash);
    combined.setRange(_handshakeHash.length, combined.length, data);
    
    final digest = sha256.convert(combined);
    _handshakeHash.setAll(0, digest.bytes);
  }

  /// Mix key and hash together
  /// 
  /// Combines mixKey and mixHash operations.
  /// Used when processing DH outputs.
  /// 
  /// [inputKeyMaterial] Key material to mix
  /// 
  /// Matches SymmetricState.mixKeyAndHash() from noise-java.
  void mixKeyAndHash(Uint8List inputKeyMaterial) {
    // HKDF with three outputs: (ck, temp_h, temp_k)
    final outputs = _hkdf(_chainingKey, inputKeyMaterial, 3);
    
    _chainingKey = outputs[0];
    mixHash(outputs[1]);
    
    if (outputs[2].isNotEmpty) {
      _cipherState.initializeKey(outputs[2]);
    }
  }

  /// Get current handshake hash
  /// 
  /// Returns the current 32-byte handshake hash.
  /// Used for channel binding and session identification.
  /// 
  /// Matches SymmetricState.getHandshakeHash() from noise-java.
  Uint8List getHandshakeHash() {
    return Uint8List.fromList(_handshakeHash);
  }

  /// Encrypt plaintext during handshake
  /// 
  /// Encrypts and mixes hash in one operation.
  /// 
  /// [plaintext] Data to encrypt
  /// Returns ciphertext with MAC
  /// 
  /// Matches SymmetricState.encryptAndHash() from noise-java.
  Future<Uint8List> encryptAndHash(Uint8List plaintext) async {
    final ciphertext = await _cipherState.encryptWithAd(_handshakeHash, plaintext);
    mixHash(ciphertext);
    return ciphertext;
  }

  /// Decrypt ciphertext during handshake
  /// 
  /// Decrypts and mixes hash in one operation.
  /// 
  /// [ciphertext] Encrypted data with MAC
  /// Returns plaintext
  /// Throws on decryption/MAC failure
  /// 
  /// Matches SymmetricState.decryptAndHash() from noise-java.
  Future<Uint8List> decryptAndHash(Uint8List ciphertext) async {
    final plaintext = await _cipherState.decryptWithAd(_handshakeHash, ciphertext);
    mixHash(ciphertext);
    return plaintext;
  }

  /// Split into two cipher states for transport
  /// 
  /// Called after handshake completion to derive send/receive keys.
  /// 
  /// Returns (sendCipher, receiveCipher) tuple
  /// 
  /// Matches SymmetricState.split() from noise-java.
  (CipherState, CipherState) split() {
    // HKDF with two outputs for send and receive keys
    final outputs = _hkdf(_chainingKey, Uint8List(0), 2);
    
    final sendCipher = CipherState();
    final receiveCipher = CipherState();
    
    sendCipher.initializeKey(outputs[0]);
    receiveCipher.initializeKey(outputs[1]);
    
    return (sendCipher, receiveCipher);
  }

  /// HKDF implementation for key derivation
  /// 
  /// Derives multiple output keys from input key material.
  /// Uses HMAC-SHA256 as PRF.
  /// 
  /// [chainingKey] Current chaining key (acts as salt)
  /// [inputKeyMaterial] Input key material
  /// [numOutputs] Number of 32-byte outputs to generate (1-3)
  /// 
  /// Returns list of output keys
  List<Uint8List> _hkdf(
    Uint8List chainingKey,
    Uint8List inputKeyMaterial,
    int numOutputs,
  ) {
    // HKDF-Extract: temp_key = HMAC-HASH(chaining_key, input_key_material)
    final tempKey = _hmacSha256(chainingKey, inputKeyMaterial);
    
    final outputs = <Uint8List>[];
    Uint8List previousOutput = Uint8List(0);
    
    // HKDF-Expand: Generate outputs
    for (int i = 1; i <= numOutputs; i++) {
      final data = Uint8List(previousOutput.length + 1);
      data.setRange(0, previousOutput.length, previousOutput);
      data[previousOutput.length] = i;
      
      final output = _hmacSha256(tempKey, data);
      outputs.add(output);
      previousOutput = output;
    }
    
    return outputs;
  }

  /// HMAC-SHA256 implementation
  /// 
  /// [key] HMAC key
  /// [data] Data to authenticate
  /// 
  /// Returns 32-byte HMAC output
  Uint8List _hmacSha256(Uint8List key, Uint8List data) {
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(data);
    return Uint8List.fromList(digest.bytes);
  }

  /// Clear sensitive data from memory
  /// 
  /// Overwrites keys and hashes for forward secrecy.
  /// Matches SymmetricState.destroy() from noise-java.
  void destroy() {
    _chainingKey.fillRange(0, _chainingKey.length, 0);
    _handshakeHash.fillRange(0, _handshakeHash.length, 0);
    _cipherState.destroy();
  }
}
