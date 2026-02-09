import 'package:logging/logging.dart';
import '../../domain/entities/enhanced_message.dart';

/// Archive data encryption is now handled at the database level by SQLCipher.
/// 
/// 🔒 SECURITY FIX: Removed field-level encryption using hardcoded keys.
/// All archive data is now stored in plaintext within the SQLCipher-encrypted database.
/// This provides proper at-rest encryption without the security vulnerabilities
/// of the previous hardcoded-key approach.
/// 
/// See: DATABASE_ENCRYPTION_FIX.md and P0.1 (SQLCipher database encryption)
class ArchiveCrypto {
  static final _logger = Logger('ArchiveCrypto');

  /// Store field as-is (database encryption handles at-rest security)
  static String encryptField(String value) {
    // No field-level encryption - SQLCipher handles at-rest encryption
    return value;
  }

  /// Retrieve field as-is (database encryption handles at-rest security)
  static String decryptField(String value) {
    // Check for legacy encrypted format and warn
    if (value.startsWith('enc::archive::v1::')) {
      _logger.warning(
        'Found legacy encrypted archive field - unable to decrypt. '
        'Field will be stored in plaintext on next update.',
      );
      // Return the encrypted value as-is - cannot decrypt without the hardcoded key
      // This will be replaced with plaintext on next update
      return value;
    }
    
    // Return plaintext value
    return value;
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
