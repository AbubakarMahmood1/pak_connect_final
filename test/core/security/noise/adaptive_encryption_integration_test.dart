import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/core/security/noise/primitives/cipher_state.dart';
import 'package:pak_connect/core/security/noise/adaptive_encryption_strategy.dart';
import 'package:pak_connect/core/monitoring/performance_metrics.dart';

/// Integration tests for adaptive encryption
///
/// Tests end-to-end flows: sync mode, isolate mode, and cross-mode roundtrips.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Adaptive Encryption Integration', () {
    late CipherState cipher;
    late AdaptiveEncryptionStrategy strategy;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await PerformanceMonitor.reset();

      cipher = CipherState();
      strategy = AdaptiveEncryptionStrategy();
      await strategy.initialize();
    });

    tearDown(() async {
      cipher.destroy();
      strategy.setDebugOverride(null);
      await PerformanceMonitor.reset();
    });

    test('CipherState uses sync path when debug override is false', () async {
      strategy.setDebugOverride(false); // Force sync

      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(null, plaintext);

      expect(ciphertext.length, equals(plaintext.length + 16));
      expect(strategy.isUsingIsolate, isFalse);
    });

    test('CipherState uses isolate path when debug override is true', () async {
      strategy.setDebugOverride(true); // Force isolate

      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(null, plaintext);

      expect(ciphertext.length, equals(plaintext.length + 16));
      expect(strategy.isUsingIsolate, isTrue);
    });

    test('encrypt-decrypt roundtrip works in sync mode', () async {
      strategy.setDebugOverride(false);

      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(null, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(null, ciphertext);

      expect(decrypted, equals(plaintext));

      cipher2.destroy();
    });

    test('encrypt-decrypt roundtrip works in isolate mode', () async {
      strategy.setDebugOverride(true);

      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(null, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(null, ciphertext);

      expect(decrypted, equals(plaintext));

      cipher2.destroy();
    });

    test('cross-mode: encrypt in sync, decrypt in isolate', () async {
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Encrypt in sync mode
      strategy.setDebugOverride(false);
      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(null, plaintext);

      // Decrypt in isolate mode
      strategy.setDebugOverride(true);
      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(null, ciphertext);

      expect(decrypted, equals(plaintext));

      cipher2.destroy();
    });

    test('cross-mode: encrypt in isolate, decrypt in sync', () async {
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Encrypt in isolate mode
      strategy.setDebugOverride(true);
      cipher.initializeKey(key);
      final ciphertext = await cipher.encryptWithAd(null, plaintext);

      // Decrypt in sync mode
      strategy.setDebugOverride(false);
      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(null, ciphertext);

      expect(decrypted, equals(plaintext));

      cipher2.destroy();
    });

    test('nonce increments correctly in sync mode', () async {
      strategy.setDebugOverride(false);

      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);

      cipher.initializeKey(key);

      expect(cipher.getNonce(), equals(0));

      await cipher.encryptWithAd(null, plaintext);
      expect(cipher.getNonce(), equals(1));

      await cipher.encryptWithAd(null, plaintext);
      expect(cipher.getNonce(), equals(2));
    });

    test('nonce increments correctly in isolate mode', () async {
      strategy.setDebugOverride(true);

      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);

      cipher.initializeKey(key);

      expect(cipher.getNonce(), equals(0));

      await cipher.encryptWithAd(null, plaintext);
      expect(cipher.getNonce(), equals(1));

      await cipher.encryptWithAd(null, plaintext);
      expect(cipher.getNonce(), equals(2));
    });

    test('large message (10KB) works in both modes', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List(10000);
      for (var i = 0; i < plaintext.length; i++) {
        plaintext[i] = i % 256;
      }

      // Test sync mode
      strategy.setDebugOverride(false);
      cipher.initializeKey(key);
      final ciphertextSync = await cipher.encryptWithAd(null, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decryptedSync = await cipher2.decryptWithAd(null, ciphertextSync);
      expect(decryptedSync, equals(plaintext));

      // Test isolate mode
      strategy.setDebugOverride(true);
      cipher.setNonce(0); // Reset nonce
      final ciphertextIsolate = await cipher.encryptWithAd(null, plaintext);

      cipher2.setNonce(0); // Reset nonce
      final decryptedIsolate = await cipher2.decryptWithAd(
        null,
        ciphertextIsolate,
      );
      expect(decryptedIsolate, equals(plaintext));

      cipher2.destroy();
    });

    test('associated data works in both modes', () async {
      final key = Uint8List(32);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final ad = Uint8List.fromList([4, 5, 6]);

      // Sync mode
      strategy.setDebugOverride(false);
      cipher.initializeKey(key);
      final ciphertextSync = await cipher.encryptWithAd(ad, plaintext);

      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decryptedSync = await cipher2.decryptWithAd(ad, ciphertextSync);
      expect(decryptedSync, equals(plaintext));

      // Isolate mode
      strategy.setDebugOverride(true);
      cipher.setNonce(0);
      final ciphertextIsolate = await cipher.encryptWithAd(ad, plaintext);

      cipher2.setNonce(0);
      final decryptedIsolate = await cipher2.decryptWithAd(
        ad,
        ciphertextIsolate,
      );
      expect(decryptedIsolate, equals(plaintext));

      cipher2.destroy();
    });

    test('mode switches automatically based on metrics', () async {
      // Start with auto mode (no override)
      strategy.setDebugOverride(null);
      await strategy.initialize();

      expect(
        strategy.isUsingIsolate,
        isFalse,
        reason: 'Should start in sync mode (no metrics)',
      );

      // Simulate high jank
      for (int i = 0; i < 20; i++) {
        await PerformanceMonitor.recordEncryption(
          durationMs: 25,
          messageSize: 1000,
        );
      }

      await strategy.recheckMetrics();

      expect(
        strategy.isUsingIsolate,
        isTrue,
        reason: 'Should switch to isolate mode after detecting high jank',
      );
    });

    test('small messages bypass isolate even when forced', () async {
      strategy.setDebugOverride(true); // Try to force isolate

      final key = Uint8List(32);
      final plaintext = Uint8List(500); // <1KB

      cipher.initializeKey(key);

      // Small message should still work (strategy handles this internally)
      final ciphertext = await cipher.encryptWithAd(null, plaintext);
      expect(ciphertext.length, equals(plaintext.length + 16));

      // Decrypt to verify correctness
      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      final decrypted = await cipher2.decryptWithAd(null, ciphertext);
      expect(decrypted, equals(plaintext));

      cipher2.destroy();
    });

    test('multiple sequential operations maintain nonce order', () async {
      final key = Uint8List(32);
      final plaintexts = [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
        Uint8List.fromList([3]),
      ];

      // Test in sync mode
      strategy.setDebugOverride(false);
      cipher.initializeKey(key);

      final ciphertexts = <Uint8List>[];
      for (final pt in plaintexts) {
        ciphertexts.add(await cipher.encryptWithAd(null, pt));
      }

      expect(cipher.getNonce(), equals(3));

      // Decrypt in order
      final cipher2 = CipherState();
      cipher2.initializeKey(key);
      for (int i = 0; i < plaintexts.length; i++) {
        final decrypted = await cipher2.decryptWithAd(null, ciphertexts[i]);
        expect(decrypted, equals(plaintexts[i]));
      }

      cipher2.destroy();
    });
  });
}
