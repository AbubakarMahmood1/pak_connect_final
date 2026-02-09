import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:logging/logging.dart';
import '../../domain/entities/enhanced_message.dart';

/// Archive data encryption is now handled at the database level by SQLCipher.
/// 
/// 🔒 SECURITY FIX: Removed field-level encryption using hardcoded keys.
/// All archive data is now stored in plaintext within the SQLCipher-encrypted database.
/// This provides proper at-rest encryption without the security vulnerabilities
/// of the previous hardcoded-key approach.
/// 
/// Legacy decryption is maintained for backward compatibility (read-only).
/// 
/// See: DATABASE_ENCRYPTION_FIX.md and P0.1 (SQLCipher database encryption)
class ArchiveCrypto {
  static final _logger = Logger('ArchiveCrypto');
  static const _legacyPrefix = 'enc::archive::v1::';
  
  // Legacy key material for backward-compatible decryption only
  static Encrypter? _legacyEncrypter;
  static IV? _legacyIV;

  /// Store field as-is (database encryption handles at-rest security)
  static String encryptField(String value) {
    // No field-level encryption - SQLCipher handles at-rest encryption
    return value;
  }

  /// Retrieve field, decrypting legacy format if needed
  static String decryptField(String value) {
    // Check for legacy encrypted format
    if (value.startsWith(_legacyPrefix)) {
      final ciphertext = value.substring(_legacyPrefix.length);
      
      // Handle P0.2 transition window: PLAINTEXT: marker inside legacy prefix
      if (ciphertext.startsWith('PLAINTEXT:')) {
        return ciphertext.substring('PLAINTEXT:'.length);
      }
      
      try {
        _ensureLegacyKeyInitialized();
        final encrypted = Encrypted.fromBase64(ciphertext);
        final decrypted = _legacyEncrypter!.decrypt(encrypted, iv: _legacyIV!);
        
        _logger.info(
          'Decrypted legacy archive field (will be stored as plaintext on next update)',
        );
        return decrypted;
      } catch (e) {
        _logger.severe(
          'Failed to decrypt legacy archive field: $e. '
          'Returning encrypted value as-is.',
        );
        // Return encrypted value if decryption fails
        return value;
      }
    }
    
    // Return plaintext value
    return value;
  }

  /// Initialize legacy decryption keys (for backward compatibility only)
  /// @deprecated This is only for reading old encrypted data
  static void _ensureLegacyKeyInitialized() {
    if (_legacyEncrypter != null) return;
    
    // Use the old hardcoded passphrase for legacy decryption only
    const String legacyPassphrase = "PakConnect2024_SecureBase_v1";
    
    final keyBytes = sha256
        .convert(utf8.encode('${legacyPassphrase}BLE_CHAT_SALT'))
        .bytes;
    final key = Key(Uint8List.fromList(keyBytes));
    
    final ivBytes = sha256
        .convert(utf8.encode('${legacyPassphrase}BLE_CHAT_IV'))
        .bytes
        .sublist(0, 16);
    _legacyIV = IV(Uint8List.fromList(ivBytes));
    
    _legacyEncrypter = Encrypter(AES(key));
  }

  static MessageEncryptionInfo resolveEncryptionInfo(
    MessageEncryptionInfo? provided,
  ) =>
      provided ??
      MessageEncryptionInfo(
        algorithm: 'SQLCipher',
        keyId: 'database_encryption',
        isEndToEndEncrypted: false,
        encryptedAt: DateTime.now(),
      );
}
