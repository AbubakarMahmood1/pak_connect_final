import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/primitives/dh_state.dart';
import 'package:pak_connect/core/security/sealed/sealed_encryption_service.dart';

void main() {
  group('SealedEncryptionService', () {
    late SealedEncryptionService service;
    late _KeyPair recipient;

    setUp(() {
      service = SealedEncryptionService();
      recipient = _generateKeyPair();
    });

    test('roundtrip succeeds with matching recipient key and aad', () async {
      final plaintext = Uint8List.fromList('hello sealed lane'.codeUnits);
      final aad = Uint8List.fromList('v2|msg-1|alice|bob|sealed_v1'.codeUnits);

      final sealed = await service.encrypt(
        plaintext: plaintext,
        recipientPublicKey: recipient.publicKey,
        aad: aad,
      );

      final decrypted = await service.decrypt(
        ciphertext: sealed.ciphertext,
        recipientPrivateKey: recipient.privateKey,
        ephemeralPublicKey: sealed.ephemeralPublicKey,
        nonce: sealed.nonce,
        aad: aad,
      );

      expect(decrypted, orderedEquals(plaintext));
      expect(
        sealed.keyId,
        equals(service.computeKeyId(recipient.publicKey)),
      );
      expect(sealed.ephemeralPublicKey.length, equals(32));
      expect(sealed.nonce.length, equals(12));
    });

    test('wrong recipient private key cannot decrypt', () async {
      final wrongRecipient = _generateKeyPair();
      final plaintext = Uint8List.fromList('recipient mismatch'.codeUnits);
      final aad = Uint8List.fromList('v2|msg-2|alice|bob|sealed_v1'.codeUnits);

      final sealed = await service.encrypt(
        plaintext: plaintext,
        recipientPublicKey: recipient.publicKey,
        aad: aad,
      );

      expect(
        () => service.decrypt(
          ciphertext: sealed.ciphertext,
          recipientPrivateKey: wrongRecipient.privateKey,
          ephemeralPublicKey: sealed.ephemeralPublicKey,
          nonce: sealed.nonce,
          aad: aad,
        ),
        throwsException,
      );
    });

    test('ciphertext tampering fails authentication', () async {
      final plaintext = Uint8List.fromList('tamper me'.codeUnits);
      final aad = Uint8List.fromList('v2|msg-3|alice|bob|sealed_v1'.codeUnits);

      final sealed = await service.encrypt(
        plaintext: plaintext,
        recipientPublicKey: recipient.publicKey,
        aad: aad,
      );

      final tamperedCiphertext = Uint8List.fromList(sealed.ciphertext);
      tamperedCiphertext[0] ^= 0x01;

      expect(
        () => service.decrypt(
          ciphertext: tamperedCiphertext,
          recipientPrivateKey: recipient.privateKey,
          ephemeralPublicKey: sealed.ephemeralPublicKey,
          nonce: sealed.nonce,
          aad: aad,
        ),
        throwsException,
      );
    });

    test('aad mismatch fails authentication', () async {
      final plaintext = Uint8List.fromList('aad bind'.codeUnits);
      final aad = Uint8List.fromList('v2|msg-4|alice|bob|sealed_v1'.codeUnits);
      final wrongAad = Uint8List.fromList(
        'v2|msg-4|alice|charlie|sealed_v1'.codeUnits,
      );

      final sealed = await service.encrypt(
        plaintext: plaintext,
        recipientPublicKey: recipient.publicKey,
        aad: aad,
      );

      expect(
        () => service.decrypt(
          ciphertext: sealed.ciphertext,
          recipientPrivateKey: recipient.privateKey,
          ephemeralPublicKey: sealed.ephemeralPublicKey,
          nonce: sealed.nonce,
          aad: wrongAad,
        ),
        throwsException,
      );
    });
  });
}

class _KeyPair {
  const _KeyPair({required this.privateKey, required this.publicKey});

  final Uint8List privateKey;
  final Uint8List publicKey;
}

_KeyPair _generateKeyPair() {
  final state = DHState()..generateKeyPair();
  final privateKey = state.getPrivateKey();
  final publicKey = state.getPublicKey();
  state.destroy();
  if (privateKey == null || publicKey == null) {
    throw StateError('Unable to generate test X25519 keypair');
  }
  return _KeyPair(
    privateKey: Uint8List.fromList(privateKey),
    publicKey: Uint8List.fromList(publicKey),
  );
}
