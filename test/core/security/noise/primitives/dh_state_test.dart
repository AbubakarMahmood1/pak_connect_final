import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/api.dart';
import 'package:pak_connect/core/security/noise/primitives/dh_state.dart';

/// Unit tests for DHState (X25519 Diffie-Hellman wrapper)
void main() {
  group('DHState', () {
    late DHState alice;
    late DHState bob;

    setUp(() {
      alice = DHState();
      bob = DHState();
    });

    tearDown(() {
      alice.destroy();
      bob.destroy();
    });

    test('generateKeyPair produces valid 32-byte keys', () {
      alice.generateKeyPair();
      final publicKey = alice.getPublicKey()!;
      final privateKey = alice.getPrivateKey()!;

      expect(publicKey.length, 32);
      expect(privateKey.length, 32);
      expect(publicKey.any((byte) => byte != 0), isTrue);
      expect(privateKey.any((byte) => byte != 0), isTrue);
    });

    test('generateKeyPair produces different keys each time', () {
      alice.generateKeyPair();
      final pub1 = Uint8List.fromList(alice.getPublicKey()!);

      bob.generateKeyPair();
      final pub2 = Uint8List.fromList(bob.getPublicKey()!);

      expect(pub1, isNot(equals(pub2)));
    });

    test('DH calculation produces 32-byte shared secret', () {
      alice.generateKeyPair();
      bob.generateKeyPair();

      final shared = DHState.calculate(
        alice.getPrivateKey()!,
        bob.getPublicKey()!,
      );

      expect(shared.length, 32);
      expect(shared.any((byte) => byte != 0), isTrue);
    });

    test('DH is symmetric', () {
      alice.generateKeyPair();
      bob.generateKeyPair();

      final aliceToBob = DHState.calculate(
        alice.getPrivateKey()!,
        bob.getPublicKey()!,
      );
      final bobToAlice = DHState.calculate(
        bob.getPrivateKey()!,
        alice.getPublicKey()!,
      );

      expect(aliceToBob, equals(bobToAlice));
    });

    test('destroy wipes keys', () {
      alice.generateKeyPair();
      expect(alice.getPublicKey(), isNotNull);
      expect(alice.getPrivateKey(), isNotNull);

      alice.destroy();
      expect(alice.getPublicKey(), isNull);
      expect(alice.getPrivateKey(), isNull);
    });

    test('invalid key length throws', () {
      final badKey = Uint8List(16);
      final goodKey = Uint8List(32);

      expect(
        () => DHState.calculate(badKey, goodKey),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => DHState.calculate(goodKey, badKey),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RFC 7748 test vector', () {
      final alicePriv = Uint8List.fromList([
        0x77,
        0x07,
        0x6d,
        0x0a,
        0x73,
        0x18,
        0xa5,
        0x7d,
        0x3c,
        0x16,
        0xc1,
        0x72,
        0x51,
        0xb2,
        0x66,
        0x45,
        0xdf,
        0x4c,
        0x2f,
        0x87,
        0xeb,
        0xc0,
        0x99,
        0x2a,
        0xb1,
        0x77,
        0xfb,
        0xa5,
        0x1d,
        0xb9,
        0x2c,
        0x2a,
      ]);
      final bobPub = Uint8List.fromList([
        0xde,
        0x9e,
        0xdb,
        0x7d,
        0x7b,
        0x7d,
        0xc1,
        0xb4,
        0xd3,
        0x5b,
        0x61,
        0xc2,
        0xec,
        0xe4,
        0x35,
        0x37,
        0x3f,
        0x83,
        0x43,
        0xc8,
        0x5b,
        0x78,
        0x67,
        0x4d,
        0xad,
        0xfc,
        0x7e,
        0x14,
        0x6f,
        0x88,
        0x2b,
        0x4f,
      ]);
      final expected = Uint8List.fromList([
        0x4a,
        0x5d,
        0x9d,
        0x5b,
        0xa4,
        0xce,
        0x2d,
        0xe1,
        0x72,
        0x8e,
        0x3b,
        0xf4,
        0x80,
        0x35,
        0x0f,
        0x25,
        0xe0,
        0x7e,
        0x21,
        0xc9,
        0x47,
        0xd1,
        0x9e,
        0x33,
        0x76,
        0xf0,
        0x9b,
        0x3c,
        0x1e,
        0x16,
        0x17,
        0x42,
      ]);

      final actual = DHState.calculate(alicePriv, bobPub);
      expect(actual, equals(expected));
    });

    test('setPrivateKey derives public key', () {
      final privKey = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        privKey[i] = i;
      }

      alice.setPrivateKey(privKey);
      final pubKey = alice.getPublicKey()!;

      expect(pubKey.length, 32);
      expect(pubKey.any((byte) => byte != 0), isTrue);
    });

    test('copy creates independent instance', () {
      alice.generateKeyPair();
      final copy = alice.copy();

      expect(copy.getPublicKey(), equals(alice.getPublicKey()));
      expect(copy.getPrivateKey(), equals(alice.getPrivateKey()));

      alice.destroy();
      expect(copy.getPublicKey(), isNotNull);
      copy.destroy();
    });
  });
}
