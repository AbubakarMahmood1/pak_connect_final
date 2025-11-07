import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/primitives/cipher_state.dart';

/// Unit tests for CipherState (ChaCha20-Poly1305 AEAD wrapper)
void main() {
  group('CipherState', () {
    late CipherState cipher;

    setUp(() {
      cipher = CipherState();
    });

    tearDown() {
      cipher.destroy();
    }

    test('initialization with key', () {
      final key = Uint8List(32);
      cipher.initializeKey(key);
      expect(cipher.hasKey(), isTrue);
    });

    test('encrypt-decrypt roundtrip', () async {
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final ad = Uint8List.fromList([6, 7, 8]);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(ad, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(ad, ciphertext);

      expect(decrypted, equals(plaintext));
      cipher2.destroy();
    });

    test('ciphertext includes MAC tag', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final ad = Uint8List(0);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(ad, plaintext);

      expect(ciphertext.length, plaintext.length + 16);
    });

    test('nonce increments produce different ciphertexts', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final ad = Uint8List(0);

      cipher.initializeKey(key);

      final ct1 = await cipher.encryptWithAd(ad, plaintext);
      final ct2 = await cipher.encryptWithAd(ad, plaintext);

      expect(ct1, isNot(equals(ct2)));
    });

    test('manual nonce control', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final ad = Uint8List(0);

      cipher.initializeKey(key);
      cipher.setNonce(100);

      final ct1 = await cipher.encryptWithAd(ad, plaintext);

      cipher.setNonce(100);
      final ct2 = await cipher.encryptWithAd(ad, plaintext);

      expect(ct1, equals(ct2));
    });

    test('wrong key fails decryption', () async {
      final key1 = Uint8List(32);
      final key2 = Uint8List(32);
      key2[0] = 1;

      final plaintext = Uint8List.fromList([1, 2, 3]);
      final ad = Uint8List(0);

      cipher.initializeKey(key1);
      final ciphertext = await cipher.encryptWithAd(ad, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key2);

      // AEAD should throw on MAC verification failure
      bool threw = false;
      try {
        await cipher2.decryptWithAd(ad, ciphertext);
      } catch (e) {
        threw = true;
      }

      // Cryptography package throws SecretBoxAuthenticationError
      expect(threw, isTrue, reason: 'Should throw on MAC auth failure');
      cipher2.destroy();
    });

    test('wrong AD fails authentication', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final ad1 = Uint8List.fromList([1, 2, 3]);
      final ad2 = Uint8List.fromList([4, 5, 6]);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(ad1, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);

      // AEAD should throw on MAC verification failure with wrong AD
      bool threw = false;
      try {
        await cipher2.decryptWithAd(ad2, ciphertext);
      } catch (e) {
        threw = true;
      }

      expect(threw, isTrue, reason: 'Should throw on wrong AD');
      cipher2.destroy();
    });

    test('destroy wipes key', () {
      final key = Uint8List(32);
      cipher.initializeKey(key);
      expect(cipher.hasKey(), isTrue);

      cipher.destroy();
      expect(cipher.hasKey(), isFalse);
    });

    test('empty plaintext works', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List(0);
      final ad = Uint8List(0);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(ad, plaintext);

      expect(ciphertext.length, 16);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(ad, ciphertext);

      expect(decrypted.length, 0);
      cipher2.destroy();
    });
  });
}
