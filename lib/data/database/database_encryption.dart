// Database encryption key management using FlutterSecureStorage
// Provides transparent encryption at rest without user friction

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'dart:math';

/// Exception thrown when database encryption setup fails
/// FIX-002: Custom exception for secure storage failures
class DatabaseEncryptionException implements Exception {
  final String message;
  DatabaseEncryptionException(this.message);

  @override
  String toString() => 'DatabaseEncryptionException: $message';
}

class DatabaseEncryption {
  static final _logger = Logger('DatabaseEncryption');
  static const String _encryptionKeyStorageKey = 'db_encryption_key_v1';
  static FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // 🔧 FIX: Cache encryption key to prevent duplicate secure storage reads
  static String? _cachedEncryptionKey;

  /// Get or create database encryption key
  /// - Generates 256-bit random key on first launch
  /// - Stores in OS keychain (Android Keystore / iOS Keychain)
  /// - Returns same key on subsequent launches
  /// - Caches key in memory to prevent duplicate secure storage reads
  ///
  /// FIX-002: Removed weak fallback - fails closed for security
  static Future<String> getOrCreateEncryptionKey() async {
    // 🔧 FIX: Return cached key if available
    if (_cachedEncryptionKey != null) {
      _logger.fine(
        '✅ Using cached encryption key (skipped secure storage read)',
      );
      return _cachedEncryptionKey!;
    }

    try {
      // Check if key already exists
      String? existingKey = await _secureStorage.read(
        key: _encryptionKeyStorageKey,
      );

      if (existingKey != null && existingKey.isNotEmpty) {
        _logger.info(
          '✅ Retrieved existing database encryption key from secure storage',
        );
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
    } catch (e, stackTrace) {
      _logger.severe('❌ Failed to access secure storage: $e', e, stackTrace);

      // FIX-002: FAIL CLOSED - Do not use weak fallback
      // Throw exception to force user to enable secure storage
      throw DatabaseEncryptionException(
        'Cannot initialize database: Secure storage unavailable.\n\n'
        'PakConnect requires secure storage for encryption keys.\n'
        'Please ensure:\n'
        '  • Android: Device lock screen is set\n'
        '  • iOS: Passcode is enabled\n\n'
        'Error details: $e',
      );
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

  // FIX-002: Removed _generateFallbackKey() method
  // Weak fallback removed for security - fail closed instead

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

  /// Allow tests to override secure storage with an in-memory implementation.
  @visibleForTesting
  static void overrideSecureStorage(FlutterSecureStorage storage) {
    _secureStorage = storage;
    _cachedEncryptionKey = null;
    _logger.warning(
      '⚠️ DatabaseEncryption secure storage overridden for tests',
    );
  }

  /// Reset secure storage override (restores real plugin usage).
  @visibleForTesting
  static void resetSecureStorageOverride() {
    _secureStorage = const FlutterSecureStorage();
    _cachedEncryptionKey = null;
  }
}
