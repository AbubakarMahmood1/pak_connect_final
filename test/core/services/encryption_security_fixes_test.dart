import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/simple_crypto.dart';
import 'package:pak_connect/core/security/archive_crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Comprehensive tests for encryption security vulnerability fixes
/// 
/// Tests verify:
/// 1. No hardcoded passphrase is used for real encryption
/// 2. Random IVs are used (same plaintext → different ciphertext)
/// 3. Wire format versioning works correctly
/// 4. Global fallback returns plaintext markers
/// 5. Backward compatibility with old ciphertexts
/// 6. ArchiveCrypto uses database encryption, not hardcoded keys
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('SimpleCrypto Security Fixes', () {
    setUp(() {
      SimpleCrypto.initialize();
    });

    tearDown(() {
      SimpleCrypto.clear();
      SimpleCrypto.clearAllConversationKeys();
    });

    group('Global Encryption Deprecation', () {
      test('encrypt() returns plaintext with PLAINTEXT: marker', () {
        const plaintext = 'test message';
        
        // ignore: deprecated_member_use
        final result = SimpleCrypto.encrypt(plaintext);
        
        expect(result, startsWith('PLAINTEXT:'));
        expect(result, equals('PLAINTEXT:$plaintext'));
      });

      test('decrypt() handles PLAINTEXT: marker', () {
        const plaintext = 'test message';
        const markedPlaintext = 'PLAINTEXT:$plaintext';
        
        // ignore: deprecated_member_use
        final result = SimpleCrypto.decrypt(markedPlaintext);
        
        expect(result, equals(plaintext));
      });

      test('encrypt/decrypt roundtrip returns plaintext', () {
        const plaintext = 'test message';
        
        // ignore: deprecated_member_use
        final encrypted = SimpleCrypto.encrypt(plaintext);
        // ignore: deprecated_member_use
        final decrypted = SimpleCrypto.decrypt(encrypted);
        
        expect(decrypted, equals(plaintext));
      });
    });

    group('Conversation Encryption - Random IVs', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';

      setUp(() {
        SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      });

      test('encrypting same plaintext twice produces different ciphertexts', () {
        const plaintext = 'test message';
        
        final encrypted1 = SimpleCrypto.encryptForConversation(plaintext, publicKey);
        final encrypted2 = SimpleCrypto.encryptForConversation(plaintext, publicKey);
        
        // Both should start with v2: prefix
        expect(encrypted1, startsWith('v2:'));
        expect(encrypted2, startsWith('v2:'));
        
        // But the ciphertexts should be different (due to random IVs)
        expect(encrypted1, isNot(equals(encrypted2)));
      });

      test('encryption/decryption roundtrip works correctly', () {
        const plaintext = 'test message with special chars: 🔒🔐';
        
        final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
        final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
        
        expect(decrypted, equals(plaintext));
      });

      test('wire format includes v2: prefix', () {
        const plaintext = 'test message';
        
        final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
        
        expect(encrypted, startsWith('v2:'));
      });

      test('multiple messages can be decrypted correctly', () {
        const messages = [
          'message 1',
          'message 2',
          'message 3 with emoji 😊',
          'message 4 with numbers 12345',
        ];
        
        for (final msg in messages) {
          final encrypted = SimpleCrypto.encryptForConversation(msg, publicKey);
          final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
          expect(decrypted, equals(msg));
        }
      });
    });

    group('Wire Format Versioning', () {
      test('v2 format prefix is correctly applied and parsed', () {
        const sharedSecret = 'test_shared_secret_123';
        const publicKey = 'test_public_key_abc';
        SimpleCrypto.initializeConversation(publicKey, sharedSecret);
        
        const plaintext = 'test message';
        final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
        
        // Should have v2: prefix
        expect(encrypted, startsWith('v2:'));
        
        // Should be able to decrypt
        final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
        expect(decrypted, equals(plaintext));
      });
    });

    group('No Hardcoded Passphrase in Codebase', () {
      test('SimpleCrypto does not expose hardcoded passphrase', () {
        // The hardcoded passphrase "PakConnect2024_SecureBase_v1" should not be
        // used in any active encryption paths.
        // This test verifies that encrypt() returns PLAINTEXT: marker instead.
        
        const plaintext = 'test message';
        
        // ignore: deprecated_member_use
        final result = SimpleCrypto.encrypt(plaintext);
        
        // Should return plaintext marker, not encrypted data
        expect(result, startsWith('PLAINTEXT:'));
        expect(result, isNot(contains('base64')));
      });
    });
  });

  group('ArchiveCrypto Security Fixes', () {
    test('encryptField returns plaintext (no encryption)', () {
      const plaintext = 'test archive data';
      
      final result = ArchiveCrypto.encryptField(plaintext);
      
      // Should return plaintext as-is (SQLCipher handles encryption)
      expect(result, equals(plaintext));
    });

    test('decryptField returns plaintext (no decryption)', () {
      const plaintext = 'test archive data';
      
      final result = ArchiveCrypto.decryptField(plaintext);
      
      // Should return plaintext as-is
      expect(result, equals(plaintext));
    });

    test('legacy encrypted format is handled gracefully', () {
      const legacyEncrypted = 'enc::archive::v1::some_encrypted_data';
      
      final result = ArchiveCrypto.decryptField(legacyEncrypted);
      
      // Should return the encrypted value as-is (cannot decrypt without key)
      expect(result, equals(legacyEncrypted));
    });

    test('empty values are handled correctly', () {
      const empty = '';
      
      final encrypted = ArchiveCrypto.encryptField(empty);
      final decrypted = ArchiveCrypto.decryptField(empty);
      
      expect(encrypted, equals(empty));
      expect(decrypted, equals(empty));
    });

    test('encryption info indicates SQLCipher', () {
      final info = ArchiveCrypto.resolveEncryptionInfo(null);
      
      expect(info.algorithm, equals('SQLCipher'));
      expect(info.keyId, equals('database_encryption'));
      expect(info.isEndToEndEncrypted, isFalse);
    });
  });

  group('Security Regression Tests', () {
    test('hardcoded passphrase is not used in active code paths', () {
      // Verify that the hardcoded passphrase "PakConnect2024_SecureBase_v1"
      // is not being used for any real encryption
      
      const plaintext = 'sensitive data';
      
      // Global encryption should return plaintext marker
      // ignore: deprecated_member_use
      final globalEncrypted = SimpleCrypto.encrypt(plaintext);
      expect(globalEncrypted, startsWith('PLAINTEXT:'));
      
      // Archive encryption should return plaintext
      final archiveEncrypted = ArchiveCrypto.encryptField(plaintext);
      expect(archiveEncrypted, equals(plaintext));
    });

    test('same plaintext produces different ciphertexts (random IV test)', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      
      const plaintext = 'same message';
      
      // Encrypt the same message multiple times
      final ciphertexts = List.generate(
        10,
        (_) => SimpleCrypto.encryptForConversation(plaintext, publicKey),
      );
      
      // All ciphertexts should be different
      final uniqueCiphertexts = ciphertexts.toSet();
      expect(uniqueCiphertexts.length, equals(ciphertexts.length));
      
      // But all should decrypt to the same plaintext
      for (final ciphertext in ciphertexts) {
        final decrypted = SimpleCrypto.decryptFromConversation(ciphertext, publicKey);
        expect(decrypted, equals(plaintext));
      }
    });

    test('no fixed IVs are used in conversation encryption', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      
      // Encrypt the same message twice
      const plaintext = 'test message';
      final encrypted1 = SimpleCrypto.encryptForConversation(plaintext, publicKey);
      final encrypted2 = SimpleCrypto.encryptForConversation(plaintext, publicKey);
      
      // Remove v2: prefix
      final cipher1 = encrypted1.substring('v2:'.length);
      final cipher2 = encrypted2.substring('v2:'.length);
      
      // The ciphertexts should be different (proof of random IVs)
      expect(cipher1, isNot(equals(cipher2)));
    });
  });

  group('Edge Cases', () {
    test('empty plaintext encryption/decryption', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      
      const plaintext = '';
      
      final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
      final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
      
      expect(decrypted, equals(plaintext));
    });

    test('long plaintext encryption/decryption', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      
      final plaintext = 'a' * 10000; // 10KB message
      
      final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
      final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
      
      expect(decrypted, equals(plaintext));
    });

    test('special characters encryption/decryption', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      
      const plaintext = r'!@#$%^&*()_+-={}[]|\\:";\'<>?,./~`';
      
      final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
      final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
      
      expect(decrypted, equals(plaintext));
    });

    test('unicode and emoji encryption/decryption', () {
      const sharedSecret = 'test_shared_secret_123';
      const publicKey = 'test_public_key_abc';
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
      
      const plaintext = '🔒🔐 محمد 中文 日本語 한글 😊👍🎉';
      
      final encrypted = SimpleCrypto.encryptForConversation(plaintext, publicKey);
      final decrypted = SimpleCrypto.decryptFromConversation(encrypted, publicKey);
      
      expect(decrypted, equals(plaintext));
    });
  });
}
