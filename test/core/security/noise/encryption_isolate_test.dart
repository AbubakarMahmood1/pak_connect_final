import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/security/noise/encryption_isolate.dart';

/// Unit tests for encryption/decryption isolate functions
///
/// Tests correctness, nonce handling, MAC verification, and error cases.
void main() {
  group('EncryptionIsolate', () {
    test('encryptInIsolate produces ciphertext with MAC', () async {
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final nonce = 0;

      final task = EncryptionTask(plaintext: plaintext, key: key, nonce: nonce);

      final ciphertext = await encryptInIsolate(task);

      // Ciphertext should include MAC (16 bytes)
      expect(
        ciphertext.length,
        equals(plaintext.length + 16),
        reason: 'Ciphertext should include 16-byte MAC',
      );
    });

    test('decryptInIsolate recovers original plaintext', () async {
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final nonce = 0;

      // Encrypt
      final encryptTask = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: nonce,
      );
      final ciphertext = await encryptInIsolate(encryptTask);

      // Decrypt
      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: nonce,
      );
      final decrypted = await decryptInIsolate(decryptTask);

      expect(
        decrypted,
        equals(plaintext),
        reason: 'Decrypted plaintext should match original',
      );
    });

    test('different nonces produce different ciphertexts', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);

      final task1 = EncryptionTask(plaintext: plaintext, key: key, nonce: 0);
      final ct1 = await encryptInIsolate(task1);

      final task2 = EncryptionTask(plaintext: plaintext, key: key, nonce: 1);
      final ct2 = await encryptInIsolate(task2);

      expect(
        ct1,
        isNot(equals(ct2)),
        reason: 'Different nonces should produce different ciphertexts',
      );
    });

    test('same nonce produces same ciphertext (deterministic)', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final nonce = 42;

      final task1 = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: nonce,
      );
      final ct1 = await encryptInIsolate(task1);

      final task2 = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: nonce,
      );
      final ct2 = await encryptInIsolate(task2);

      expect(
        ct1,
        equals(ct2),
        reason: 'Same nonce should produce same ciphertext (for testing)',
      );
    });

    test('wrong key fails MAC verification', () async {
      final key1 = Uint8List(32);
      final key2 = Uint8List(32);
      key2[0] = 1; // Different key

      final plaintext = Uint8List.fromList([1, 2, 3]);

      // Encrypt with key1
      final encryptTask = EncryptionTask(
        plaintext: plaintext,
        key: key1,
        nonce: 0,
      );
      final ciphertext = await encryptInIsolate(encryptTask);

      // Try to decrypt with key2
      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key2,
        nonce: 0,
      );

      expect(
        () async => await decryptInIsolate(decryptTask),
        throwsA(isA<Exception>()),
        reason: 'Decryption with wrong key should throw',
      );
    });

    test('wrong nonce fails MAC verification', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);

      // Encrypt with nonce=0
      final encryptTask = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: 0,
      );
      final ciphertext = await encryptInIsolate(encryptTask);

      // Try to decrypt with nonce=1
      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: 1,
      );

      expect(
        () async => await decryptInIsolate(decryptTask),
        throwsA(isA<Exception>()),
        reason: 'Decryption with wrong nonce should throw',
      );
    });

    test('associated data is authenticated', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final ad1 = Uint8List.fromList([4, 5, 6]);
      final ad2 = Uint8List.fromList([7, 8, 9]);

      // Encrypt with ad1
      final encryptTask = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: 0,
        associatedData: ad1,
      );
      final ciphertext = await encryptInIsolate(encryptTask);

      // Try to decrypt with ad2
      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: 0,
        associatedData: ad2,
      );

      expect(
        () async => await decryptInIsolate(decryptTask),
        throwsA(isA<Exception>()),
        reason: 'Decryption with wrong AD should throw',
      );

      // Decrypt with correct ad1 should succeed
      final decryptTaskCorrect = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: 0,
        associatedData: ad1,
      );
      final decrypted = await decryptInIsolate(decryptTaskCorrect);

      expect(decrypted, equals(plaintext));
    });

    test('empty plaintext works correctly', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List(0);

      final encryptTask = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: 0,
      );
      final ciphertext = await encryptInIsolate(encryptTask);

      // Should still have MAC (16 bytes)
      expect(ciphertext.length, equals(16));

      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: 0,
      );
      final decrypted = await decryptInIsolate(decryptTask);

      expect(decrypted.length, equals(0));
    });

    test('large plaintext (10KB) works correctly', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List(10000);
      for (var i = 0; i < plaintext.length; i++) {
        plaintext[i] = i % 256;
      }

      final encryptTask = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: 0,
      );
      final ciphertext = await encryptInIsolate(encryptTask);

      expect(ciphertext.length, equals(plaintext.length + 16));

      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: 0,
      );
      final decrypted = await decryptInIsolate(decryptTask);

      expect(decrypted, equals(plaintext));
    });

    test('ciphertext too short throws ArgumentError', () async {
      final key = Uint8List(32);
      final ciphertext = Uint8List(10); // <16 bytes (MAC size)

      final decryptTask = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: 0,
      );

      expect(
        () async => await decryptInIsolate(decryptTask),
        throwsA(isA<ArgumentError>()),
        reason: 'Ciphertext shorter than MAC should throw ArgumentError',
      );
    });

    test('nonce conversion to 12-byte format is consistent', () async {
      // Test that nonce conversion produces consistent results
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);

      // Test with various nonce values
      final nonces = [0, 1, 255, 256, 65535, 16777215, 0xFFFFFFFF];

      for (final nonce in nonces) {
        final task = EncryptionTask(
          plaintext: plaintext,
          key: key,
          nonce: nonce,
        );
        final ciphertext = await encryptInIsolate(task);

        final decryptTask = DecryptionTask(
          ciphertext: ciphertext,
          key: key,
          nonce: nonce,
        );
        final decrypted = await decryptInIsolate(decryptTask);

        expect(
          decrypted,
          equals(plaintext),
          reason: 'Nonce $nonce should roundtrip correctly',
        );
      }
    });
  });
}
