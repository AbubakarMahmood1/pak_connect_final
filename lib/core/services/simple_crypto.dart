import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

class SimpleCrypto {
  static Encrypter? _encrypter;
  static IV? _iv;
  
  // Initialize with shared passphrase
  static void initialize(String passphrase) {
    // Generate key from passphrase using PBKDF2-like approach
    final keyBytes = sha256.convert(utf8.encode(passphrase + 'BLE_CHAT_SALT')).bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    
    // Use fixed IV for simplicity (in production, should be random per message)
    //_iv = IV.fromSecureRandom(16);
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
  }
}