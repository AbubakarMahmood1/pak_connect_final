// Encryption utilities for export/import
// PBKDF2 key derivation, AES-256-GCM encryption/decryption

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:logging/logging.dart';
import '../models/export_bundle.dart';

class EncryptionUtils {
  static final _logger = Logger('EncryptionUtils');

  // Encryption constants
  static const int _saltLength = 32; // 256 bits
  static const int _pbkdf2Iterations = 100000; // 100k iterations
  static const int _keyLength = 32; // 256 bits for AES-256
  static const int _ivLength = 16; // 128 bits for AES

  /// Generate cryptographically secure random salt
  static Uint8List generateSalt() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_saltLength, (_) => random.nextInt(256)),
    );
  }

  /// Derive encryption key from passphrase using PBKDF2
  ///
  /// Uses PBKDF2-HMAC-SHA256 with 100,000 iterations
  /// Returns 256-bit key for AES-256 encryption
  static Uint8List deriveKey(String passphrase, Uint8List salt) {
    _logger.fine('Deriving key with PBKDF2 (100k iterations)...');

    final passphraseBytes = utf8.encode(passphrase);

    // PBKDF2 implementation using HMAC-SHA256
    final key = _pbkdf2(passphraseBytes, salt, _pbkdf2Iterations, _keyLength);

    _logger.fine('Key derivation complete');
    return key;
  }

  /// PBKDF2 implementation using HMAC-SHA256
  static Uint8List _pbkdf2(
    List<int> password,
    Uint8List salt,
    int iterations,
    int keyLength,
  ) {
    final hmac = Hmac(sha256, password);
    final blocks = <int>[];

    final blockCount = (keyLength / 32).ceil();

    for (var i = 1; i <= blockCount; i++) {
      final block = _pbkdf2Block(hmac, salt, iterations, i);
      blocks.addAll(block);
    }

    return Uint8List.fromList(blocks.sublist(0, keyLength));
  }

  static Uint8List _pbkdf2Block(
    Hmac hmac,
    Uint8List salt,
    int iterations,
    int blockNumber,
  ) {
    final blockBytes = Uint8List(4);
    blockBytes.buffer.asByteData().setUint32(0, blockNumber, Endian.big);

    var u = hmac.convert([...salt, ...blockBytes]).bytes;
    var result = List<int>.from(u);

    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }

    return Uint8List.fromList(result);
  }

  /// Encrypt data using AES-256-GCM
  ///
  /// Returns base64-encoded encrypted data with IV prepended
  /// Format: [IV (16 bytes)][Encrypted Data][Auth Tag]
  static String encrypt(String plaintext, Uint8List key) {
    try {
      // Generate random IV
      final iv = _generateIV();

      // Create encrypter with AES-256
      final aesKey = encrypt_lib.Key(key);
      final aesIV = encrypt_lib.IV(iv);
      final encrypter = encrypt_lib.Encrypter(
        encrypt_lib.AES(aesKey, mode: encrypt_lib.AESMode.gcm),
      );

      // Encrypt
      final encrypted = encrypter.encrypt(plaintext, iv: aesIV);

      // Combine IV + encrypted data (IV is needed for decryption)
      final combined = Uint8List.fromList([...iv, ...encrypted.bytes]);

      // Return as base64
      return base64Encode(combined);
    } catch (e) {
      _logger.severe('Encryption failed: $e');
      rethrow;
    }
  }

  /// Decrypt data using AES-256-GCM
  ///
  /// Expects base64-encoded data with IV prepended
  /// Returns null if decryption fails (wrong key/corrupted data)
  static String? decrypt(String encryptedBase64, Uint8List key) {
    try {
      // Decode from base64
      final combined = base64Decode(encryptedBase64);

      if (combined.length < _ivLength) {
        _logger.warning('Invalid encrypted data: too short');
        return null;
      }

      // Extract IV and encrypted data
      final iv = combined.sublist(0, _ivLength);
      final encryptedData = combined.sublist(_ivLength);

      // Create encrypter
      final aesKey = encrypt_lib.Key(key);
      final aesIV = encrypt_lib.IV(iv);
      final encrypter = encrypt_lib.Encrypter(
        encrypt_lib.AES(aesKey, mode: encrypt_lib.AESMode.gcm),
      );

      // Decrypt
      final encrypted = encrypt_lib.Encrypted(encryptedData);
      final decrypted = encrypter.decrypt(encrypted, iv: aesIV);

      return decrypted;
    } catch (e) {
      _logger.fine(
        'Decryption failed (wrong passphrase or corrupted data): $e',
      );
      return null;
    }
  }

  /// Generate random IV for AES
  static Uint8List _generateIV() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_ivLength, (_) => random.nextInt(256)),
    );
  }

  /// Calculate SHA-256 checksum of data
  static String calculateChecksum(List<String> dataList) {
    final combined = dataList.join('|');
    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Validate passphrase strength
  ///
  /// Requirements:
  /// - Minimum 12 characters (no maximum to prevent password length attacks)
  /// - Must contain at least 3 of: lowercase, uppercase, numbers, symbols
  /// - Recommended: 20+ characters with all character types
  ///
  /// Security note: Variable length prevents attackers from knowing password
  /// constraints, making brute-force attacks significantly harder
  static PassphraseValidation validatePassphrase(String passphrase) {
    final warnings = <String>[];
    double strength = 0.0;

    // Minimum length check (no maximum - variable length for security)
    if (passphrase.length < 12) {
      warnings.add('Passphrase must be at least 12 characters');
      return PassphraseValidation(
        isValid: false,
        strength: 0.0,
        warnings: warnings,
      );
    }

    // Character variety checks with comprehensive symbol support
    final hasLowercase = passphrase.contains(RegExp(r'[a-z]'));
    final hasUppercase = passphrase.contains(RegExp(r'[A-Z]'));
    final hasDigits = passphrase.contains(RegExp(r'[0-9]'));
    // Expanded symbol set: common keyboard symbols + Unicode special chars
    final hasSymbols = passphrase.contains(
      RegExp(
        r'''[!@#$%^&*()_+\-=\[\]{};:'",.<>?/\\|`~¡¢£¤¥¦§¨©ª«¬®¯°±²³´µ¶·¸¹º»¼½¾¿×÷]''',
      ),
    );

    // Count character variety types present
    final varietyCount = [
      hasLowercase,
      hasUppercase,
      hasDigits,
      hasSymbols,
    ].where((has) => has).length;

    // Require at least 3 out of 4 character types
    if (varietyCount < 3) {
      final missing = <String>[];
      if (!hasLowercase) missing.add('lowercase letters');
      if (!hasUppercase) missing.add('uppercase letters');
      if (!hasDigits) missing.add('numbers');
      if (!hasSymbols) missing.add('symbols');

      warnings.add(
        'Passphrase must contain at least 3 of: lowercase, uppercase, numbers, symbols',
      );
      warnings.add('Missing: ${missing.take(2).join(", ")}');
      return PassphraseValidation(
        isValid: false,
        strength: 0.0,
        warnings: warnings,
      );
    }

    // Calculate strength score (0.0 - 1.0)
    // Base strength for meeting minimum requirements
    strength += 0.15;

    // Length scoring with diminishing returns (encourages longer passphrases)
    if (passphrase.length >= 20) {
      strength += 0.25; // Excellent length
    } else if (passphrase.length >= 16) {
      strength += 0.20; // Good length
    } else {
      strength += (passphrase.length / 16) * 0.15; // Proportional
    }

    // Character variety bonuses
    if (hasLowercase) strength += 0.15;
    if (hasUppercase) strength += 0.15;
    if (hasDigits) strength += 0.15;
    if (hasSymbols) strength += 0.20; // Extra bonus for symbols

    // Perfect score bonus (all 4 types present)
    if (varietyCount == 4) {
      strength += 0.10;
    }

    // Entropy bonus for very long passphrases (discourages length guessing)
    if (passphrase.length > 24) {
      strength += 0.05;
    }

    // Warnings for improvement (non-blocking)
    if (!hasUppercase && varietyCount == 3) {
      warnings.add('Consider adding uppercase letters for maximum security');
    }
    if (!hasLowercase && varietyCount == 3) {
      warnings.add('Consider adding lowercase letters for maximum security');
    }
    if (!hasDigits && varietyCount == 3) {
      warnings.add('Consider adding numbers for maximum security');
    }
    if (!hasSymbols && varietyCount == 3) {
      warnings.add('Consider adding symbols for maximum security');
    }
    if (passphrase.length < 20) {
      warnings.add('Consider using 20+ characters for optimal security');
    }

    // Check for common patterns (reduces strength)
    if (_containsCommonPatterns(passphrase)) {
      warnings.add('Avoid common patterns and dictionary words');
      strength *= 0.6; // Significant penalty
    }

    return PassphraseValidation(
      isValid: true,
      strength: strength.clamp(0.0, 1.0),
      warnings: warnings,
    );
  }

  /// Check for common weak patterns
  static bool _containsCommonPatterns(String passphrase) {
    final lower = passphrase.toLowerCase();

    // Common patterns
    final patterns = [
      'password',
      '123456',
      'qwerty',
      'abc123',
      'letmein',
      '111111',
      'admin',
    ];

    for (final pattern in patterns) {
      if (lower.contains(pattern)) {
        return true;
      }
    }

    // Sequential numbers or letters
    if (RegExp(r'(012|123|234|345|456|567|678|789)').hasMatch(lower)) {
      return true;
    }
    if (RegExp(
      r'(abc|bcd|cde|def|efg|fgh|ghi|hij|ijk|jkl|klm|lmn|mno|nop|opq|pqr|qrs|rst|stu|tuv|uvw|vwx|wxy|xyz)',
    ).hasMatch(lower)) {
      return true;
    }

    return false;
  }
}
