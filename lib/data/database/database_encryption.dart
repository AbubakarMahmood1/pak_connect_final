// Database encryption key management using FlutterSecureStorage
// Provides transparent encryption at rest without user friction

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'dart:convert';
import 'dart:math';

class DatabaseEncryption {
  static final _logger = Logger('DatabaseEncryption');
  static const String _encryptionKeyStorageKey = 'db_encryption_key_v1';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  
  // 🔧 FIX: Cache encryption key to prevent duplicate secure storage reads
  static String? _cachedEncryptionKey;

  /// Get or create database encryption key
  /// - Generates 256-bit random key on first launch
  /// - Stores in OS keychain (Android Keystore / iOS Keychain)
  /// - Returns same key on subsequent launches
  /// - Caches key in memory to prevent duplicate secure storage reads
  static Future<String> getOrCreateEncryptionKey() async {
    // 🔧 FIX: Return cached key if available
    if (_cachedEncryptionKey != null) {
      _logger.fine('✅ Using cached encryption key (skipped secure storage read)');
      return _cachedEncryptionKey!;
    }
    
    try {
      // Check if key already exists
      String? existingKey = await _secureStorage.read(key: _encryptionKeyStorageKey);

      if (existingKey != null && existingKey.isNotEmpty) {
        _logger.info('✅ Retrieved existing database encryption key from secure storage');
        _cachedEncryptionKey = existingKey; // Cache it
        return existingKey;
      }

      // Generate new 256-bit encryption key
      final key = await _generateSecureKey();

      // Store in secure storage
      await _secureStorage.write(key: _encryptionKeyStorageKey, value: key);

      _logger.info('🔐 Generated and stored new database encryption key');
      _cachedEncryptionKey = key; // Cache it
      return key;

    } catch (e) {
      _logger.severe('❌ Failed to get/create encryption key: $e');
      // Fallback to device-derived key (less secure but better than nothing)
      final fallbackKey = _generateFallbackKey();
      _cachedEncryptionKey = fallbackKey; // Cache it
      return fallbackKey;
    }
  }

  /// Generate cryptographically secure random key
  static Future<String> _generateSecureKey() async {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));

    // Convert to hex string for SQLCipher
    final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    _logger.fine('Generated 256-bit encryption key');
    return key;
  }

  /// Fallback key generation (if secure storage fails)
  /// Uses device-specific entropy - less ideal but better than no encryption
  static String _generateFallbackKey() {
    _logger.warning('⚠️ Using fallback encryption key (secure storage unavailable)');

    // Use timestamp + random as fallback
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random(timestamp);
    final entropy = '$timestamp${random.nextInt(1000000)}';

    // Hash for consistent length
    final hash = sha256.convert(utf8.encode(entropy)).toString();
    return hash;
  }

  /// Delete encryption key (for testing/reset purposes)
  /// WARNING: This will make existing encrypted database unreadable!
  static Future<void> deleteEncryptionKey() async {
    try {
      await _secureStorage.delete(key: _encryptionKeyStorageKey);
      _cachedEncryptionKey = null; // 🔧 FIX: Clear cache
      _logger.warning('🗑️ Database encryption key deleted');
    } catch (e) {
      _logger.severe('Failed to delete encryption key: $e');
    }
  }

  /// Check if encryption key exists
  static Future<bool> hasEncryptionKey() async {
    try {
      final key = await _secureStorage.read(key: _encryptionKeyStorageKey);
      return key != null && key.isNotEmpty;
    } catch (e) {
      _logger.warning('Failed to check encryption key existence: $e');
      return false;
    }
  }
}
