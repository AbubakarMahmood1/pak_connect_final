import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/primitives/symmetric_state.dart';

void main() {
  group('SymmetricState', () {
    test('initialization', () {
      final state = SymmetricState('Noise_XX_25519_ChaChaPoly_SHA256');
      expect(state.getHandshakeHash().length, 32);
      state.destroy();
    });

    test('mixHash changes hash', () {
      final state = SymmetricState('Noise_XX_25519_ChaChaPoly_SHA256');
      final h1 = Uint8List.fromList(state.getHandshakeHash());
      state.mixHash(Uint8List.fromList([1, 2, 3]));
      final h2 = Uint8List.fromList(state.getHandshakeHash());
      expect(h1, isNot(equals(h2)));
      state.destroy();
    });

    test('mixKey enables encryption', () async {
      final state = SymmetricState('Noise_XX_25519_ChaChaPoly_SHA256');
      state.mixKey(Uint8List(32));
      final ct = await state.encryptAndHash(Uint8List.fromList([1, 2, 3]));
      expect(ct.length, 19); // 3 + 16 MAC
      state.destroy();
    });

    test('split produces two ciphers', () {
      final state = SymmetricState('Noise_XX_25519_ChaChaPoly_SHA256');
      state.mixKey(Uint8List(32));
      final (c1, c2) = state.split();
      expect(c1.hasKey(), isTrue);
      expect(c2.hasKey(), isTrue);
      c1.destroy();
      c2.destroy();
      state.destroy();
    });

    test('roundtrip encrypt-decrypt', () async {
      final s1 = SymmetricState('Noise_XX_25519_ChaChaPoly_SHA256');
      final s2 = SymmetricState('Noise_XX_25519_ChaChaPoly_SHA256');
      final key = Uint8List(32);
      s1.mixKey(key);
      s2.mixKey(key);
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final ct = await s1.encryptAndHash(plaintext);
      final pt = await s2.decryptAndHash(ct);
      expect(pt, equals(plaintext));
      s1.destroy();
      s2.destroy();
    });
  });
}
