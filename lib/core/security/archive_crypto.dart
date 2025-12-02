import 'package:logging/logging.dart';
import '../services/simple_crypto.dart';
import '../../domain/entities/enhanced_message.dart';

/// Thin wrapper to encrypt/decrypt archive fields with a stable prefix for
/// backward compatibility. Falls back to plaintext on failure to avoid data loss.
class ArchiveCrypto {
  static const _prefix = 'enc::archive::v1::';
  static final _logger = Logger('ArchiveCrypto');

  static String encryptField(String value) {
    if (value.isEmpty) return value;
    _ensureInitialized();
    try {
      return '$_prefix${SimpleCrypto.encrypt(value)}';
    } catch (e) {
      _logger.warning('Archive encryption failed, storing plaintext: $e');
      return value;
    }
  }

  static String decryptField(String value) {
    if (!value.startsWith(_prefix)) return value;
    _ensureInitialized();
    try {
      final cipher = value.substring(_prefix.length);
      return SimpleCrypto.decrypt(cipher);
    } catch (e) {
      _logger.warning('Archive decryption failed, returning ciphertext: $e');
      return value;
    }
  }

  static MessageEncryptionInfo resolveEncryptionInfo(
    MessageEncryptionInfo? provided,
  ) =>
      provided ??
      MessageEncryptionInfo(
        algorithm: 'AES-256-CBC',
        keyId: 'archive_simple_crypto_v1',
        isEndToEndEncrypted: false,
        encryptedAt: DateTime.now(),
      );

  static void _ensureInitialized() {
    if (!SimpleCrypto.isInitialized) {
      SimpleCrypto.initialize();
    }
  }
}
