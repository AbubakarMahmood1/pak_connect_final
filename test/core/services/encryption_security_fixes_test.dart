import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/archive_crypto.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Active Crypto Security Fixes', () {
    const sharedSecret = 'test_shared_secret_123';
    const publicKey = 'test_public_key_abc';

    setUp(() {
      SimpleCrypto.initialize();
      SimpleCrypto.clearAllConversationKeys();
      SimpleCrypto.initializeConversation(publicKey, sharedSecret);
    });

    tearDown(() {
      SimpleCrypto.clear();
      SimpleCrypto.clearAllConversationKeys();
    });

    test('encrypting the same plaintext twice produces different ciphertexts', () {
      const plaintext = 'test message';

      final encrypted1 = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );
      final encrypted2 = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );

      expect(encrypted1, startsWith('v2:'));
      expect(encrypted2, startsWith('v2:'));
      expect(encrypted1, isNot(equals(encrypted2)));
      expect(encrypted1, isNot(startsWith('PLAINTEXT:')));
      expect(encrypted2, isNot(startsWith('PLAINTEXT:')));
    });

    test('IV length is exactly 16 bytes in encrypted output', () {
      const plaintext = 'test message';

      final encrypted = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );
      final ciphertext = encrypted.substring('v2:'.length);
      final combined = base64.decode(ciphertext);
      final iv = combined.sublist(0, 16);

      expect(combined.length, greaterThanOrEqualTo(16));
      expect(iv.length, equals(16));
    });

    test('invalid v2 ciphertext (too short) throws error', () {
      final tooShort = 'v2:${base64.encode([1, 2, 3, 4, 5])}';

      expect(
        () => SimpleCrypto.decryptFromConversation(tooShort, publicKey),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('conversation encryption/decryption roundtrip works correctly', () {
      const plaintext = 'test message with special chars: 🔒🔐';

      final encrypted = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );
      final decrypted = SimpleCrypto.decryptFromConversation(
        encrypted,
        publicKey,
      );

      expect(decrypted, equals(plaintext));
    });

    test('wire format includes v2: prefix', () {
      const plaintext = 'test message';

      final encrypted = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );

      expect(encrypted, startsWith('v2:'));
    });

    test('same plaintext produces different ciphertexts across repeated sends', () {
      const plaintext = 'same message';

      final ciphertexts = List.generate(
        10,
        (_) => SimpleCrypto.encryptForConversation(plaintext, publicKey),
      );

      expect(ciphertexts.toSet().length, equals(ciphertexts.length));
      for (final ciphertext in ciphertexts) {
        final decrypted = SimpleCrypto.decryptFromConversation(
          ciphertext,
          publicKey,
        );
        expect(decrypted, equals(plaintext));
      }
    });

    test('empty plaintext encryption/decryption works', () {
      const plaintext = '';

      final encrypted = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );
      final decrypted = SimpleCrypto.decryptFromConversation(
        encrypted,
        publicKey,
      );

      expect(decrypted, equals(plaintext));
    });

    test('long plaintext encryption/decryption works', () {
      final plaintext = 'a' * 10000;

      final encrypted = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );
      final decrypted = SimpleCrypto.decryptFromConversation(
        encrypted,
        publicKey,
      );

      expect(decrypted, equals(plaintext));
    });

    test('special characters and unicode round-trip correctly', () {
      const plaintext = '🔒🔐 محمد 中文 日本語 한글 😊👍🎉';

      final encrypted = SimpleCrypto.encryptForConversation(
        plaintext,
        publicKey,
      );
      final decrypted = SimpleCrypto.decryptFromConversation(
        encrypted,
        publicKey,
      );

      expect(decrypted, equals(plaintext));
    });

    test('deprecated wrapper telemetry stays at zero', () {
      expect(
        SimpleCrypto.getDeprecatedWrapperUsageCounts(),
        equals(const {'encrypt': 0, 'decrypt': 0, 'total': 0}),
      );
    });
  });

  group('ArchiveCrypto Security Fixes', () {
    test('encryptField returns plaintext (SQLCipher handles encryption)', () {
      const plaintext = 'test archive data';

      final result = ArchiveCrypto.encryptField(plaintext);

      expect(result, equals(plaintext));
    });

    test('decryptField returns plaintext when field is not legacy formatted', () {
      const plaintext = 'test archive data';

      final result = ArchiveCrypto.decryptField(plaintext);

      expect(result, equals(plaintext));
    });

    test('legacy formatted archive payloads are handled gracefully', () {
      final simulatedLegacy =
          'enc::archive::v1::${base64.encode('legacy test data'.codeUnits)}';

      final result = ArchiveCrypto.decryptField(simulatedLegacy);

      expect(result, isNotNull);
      expect(result, isA<String>());
    });

    test('malformed legacy encrypted format is handled gracefully', () {
      const malformedLegacy = 'enc::archive::v1::invalid_base64!!!';

      final result = ArchiveCrypto.decryptField(malformedLegacy);

      expect(result, equals(malformedLegacy));
    });

    test('empty values are handled correctly', () {
      const empty = '';

      expect(ArchiveCrypto.encryptField(empty), equals(empty));
      expect(ArchiveCrypto.decryptField(empty), equals(empty));
    });

    test('encryption info indicates SQLCipher', () {
      final info = ArchiveCrypto.resolveEncryptionInfo(null);

      expect(info.algorithm, equals('SQLCipher'));
      expect(info.keyId, equals('database_encryption'));
      expect(info.isEndToEndEncrypted, isFalse);
    });
  });
}
