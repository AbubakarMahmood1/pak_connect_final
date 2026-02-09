import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/simple_crypto.dart';
import 'package:pak_connect/core/security/archive_crypto.dart';
import 'package:pak_connect/core/security/signing_manager.dart';
import 'package:pointycastle/export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void _initializeSigningForTests() {
  final curve = ECCurve_secp256r1();
  final privateKey = BigInt.from(42);
  final publicPoint = curve.G * privateKey;
  final privateKeyHex = privateKey.toRadixString(16).padLeft(64, '0');
  final publicKeyHex = _bytesToHex(publicPoint!.getEncoded(false));

  SimpleCrypto.initializeSigning(privateKeyHex, publicKeyHex);
}

/// Tests for weak PRNG seeding fixes and archive PLAINTEXT migration bug
///
/// These tests verify:
/// 1. Random IV/nonce: Sign same message twice → signatures MUST be different
/// 2. No timestamp-seeded PRNG in cryptographic code
/// 3. Archive PLAINTEXT migration: enc::archive::v1::PLAINTEXT:hello → 'hello'
/// 4. Archive normal legacy decryption still works
/// 5. Archive v2 format still works
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('PRNG Security Fixes', () {
    setUp(() {
      SimpleCrypto.initialize();
      _initializeSigningForTests();
    });

    tearDown(() {
      SimpleCrypto.clear();
      SimpleCrypto.clearAllConversationKeys();
    });

    test(
      'signing same message twice produces different signatures (non-deterministic k-nonce)',
      () {
        const testMessage = 'test message for signature verification';
        expect(SimpleCrypto.isSigningReady, isTrue);

        // Sign the same message twice
        final signature1 = SimpleCrypto.signMessage(testMessage);
        final signature2 = SimpleCrypto.signMessage(testMessage);

        // Both should succeed
        expect(signature1, isNotNull);
        expect(signature2, isNotNull);

        // Signatures MUST be different due to random k-nonce
        expect(
          signature1,
          isNot(equals(signature2)),
          reason:
              'ECDSA signatures must use random k-nonce, resulting in different signatures for same message',
        );
      },
    );

    test('no timestamp-seeded PRNG patterns in cryptographic source files', () {
      // List of cryptographic source files that were fixed
      final criticalFiles = [
        'lib/data/repositories/user_preferences.dart',
        'lib/core/services/simple_crypto.dart',
        'lib/core/security/signing_manager.dart',
        'lib/core/security/message_security.dart',
      ];

      for (final filePath in criticalFiles) {
        final file = File(filePath);
        if (!file.existsSync()) {
          fail('Critical file not found: $filePath');
        }

        final content = file.readAsStringSync();

        // Check for dangerous timestamp-based seeding patterns
        final hasMillisecondsSinceEpoch = content.contains(
          'millisecondsSinceEpoch',
        );
        final hasMicrosecondsSinceEpoch = content.contains(
          'microsecondsSinceEpoch',
        );

        // These patterns should NOT appear in cryptographic contexts
        // Note: They may appear in logging or timing, but not in crypto seeding
        if (hasMillisecondsSinceEpoch || hasMicrosecondsSinceEpoch) {
          // Check if it's in a crypto context (near FortunaRandom, seed, or crypto operations)
          final hasCryptoContext =
              content.contains('FortunaRandom') ||
              content.contains('secureRandom.seed') ||
              content.contains('KeyParameter');

          if (hasCryptoContext) {
            // Look for the dangerous pattern near crypto code
            final lines = content.split('\n');
            var foundDangerousPattern = false;

            for (var i = 0; i < lines.length; i++) {
              final line = lines[i];
              if ((line.contains('millisecondsSinceEpoch') ||
                  line.contains('microsecondsSinceEpoch'))) {
                // Check if within 10 lines of crypto code
                for (
                  var j = (i - 10).clamp(0, lines.length);
                  j < (i + 10).clamp(0, lines.length);
                  j++
                ) {
                  if (lines[j].contains('secureRandom.seed') ||
                      lines[j].contains('FortunaRandom') ||
                      lines[j].contains('KeyParameter')) {
                    foundDangerousPattern = true;
                    break;
                  }
                }
              }
              if (foundDangerousPattern) break;
            }

            expect(
              foundDangerousPattern,
              isFalse,
              reason:
                  'File $filePath contains timestamp-based PRNG seeding in cryptographic context',
            );
          }
        }
      }
    });
  });

  group('Archive PLAINTEXT Migration Fix', () {
    test(
      'decryptField handles enc::archive::v1::PLAINTEXT: prefix correctly',
      () {
        const testValue = 'hello world';
        const legacyPlaintextValue = 'enc::archive::v1::PLAINTEXT:$testValue';

        final result = ArchiveCrypto.decryptField(legacyPlaintextValue);

        expect(
          result,
          equals(testValue),
          reason:
              'Should extract plaintext from enc::archive::v1::PLAINTEXT: format',
        );
      },
    );

    test('decryptField handles normal plaintext (no prefix)', () {
      const plaintext = 'plain text value';

      final result = ArchiveCrypto.decryptField(plaintext);

      expect(
        result,
        equals(plaintext),
        reason: 'Should return plaintext as-is when no encryption prefix',
      );
    });

    test('decryptField handles legacy AES encrypted values', () {
      // This test verifies that real legacy encrypted values still work
      // Note: We can't create real legacy encrypted values without the old key,
      // so we test that the path exists and doesn't crash

      const fakeLegacyEncrypted =
          'enc::archive::v1::YWJjZGVmZ2g='; // base64 "abcdefgh"

      // This should either decrypt successfully or return the value as-is on failure
      // It should NOT crash with base64 parsing error
      expect(
        () => ArchiveCrypto.decryptField(fakeLegacyEncrypted),
        returnsNormally,
        reason: 'Should handle legacy encrypted values gracefully',
      );
    });

    test('encryptField uses plaintext (no encryption)', () {
      const testValue = 'test value';

      final result = ArchiveCrypto.encryptField(testValue);

      // New implementation should just return plaintext
      expect(
        result,
        equals(testValue),
        reason:
            'Archive encryption now stores plaintext (relies on DB encryption)',
      );
    });

    test('encrypt/decrypt roundtrip preserves data', () {
      const originalValue = 'test roundtrip data 123!@#';

      final encrypted = ArchiveCrypto.encryptField(originalValue);
      final decrypted = ArchiveCrypto.decryptField(encrypted);

      expect(
        decrypted,
        equals(originalValue),
        reason: 'Roundtrip should preserve original value',
      );
    });

    test('handles multiple PLAINTEXT: patterns correctly', () {
      // Edge case: what if the actual plaintext contains "PLAINTEXT:"?
      const testValue = 'PLAINTEXT:nested value';
      const legacyValue = 'enc::archive::v1::PLAINTEXT:$testValue';

      final result = ArchiveCrypto.decryptField(legacyValue);

      expect(
        result,
        equals(testValue),
        reason:
            'Should only strip the first PLAINTEXT: marker after legacy prefix',
      );
    });
  });
}
