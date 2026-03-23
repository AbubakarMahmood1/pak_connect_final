import '../../domain/entities/enhanced_message.dart';

/// Archive data encryption is now handled at the database level by SQLCipher.
///
/// All archive data is stored in plaintext within the SQLCipher-encrypted
/// database. Legacy field-level archive decrypt support has been removed.
class ArchiveCrypto {
  /// Store field as-is (database encryption handles at-rest security).
  static String encryptField(String value) {
    return value;
  }

  /// Retrieve field as-is. Unsupported legacy archive prefixes are not decoded.
  static String decryptField(String value) {
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
