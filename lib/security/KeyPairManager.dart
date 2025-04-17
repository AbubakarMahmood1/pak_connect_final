import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'dart:math';

class KeyPairManager {
  static final KeyPairManager _instance = KeyPairManager._internal();
  factory KeyPairManager() => _instance;
  KeyPairManager._internal();

  // Generate an ECC key pair
  AsymmetricKeyPair<PublicKey, PrivateKey> generateKeyPair() {
    // Use P-256 curve (also known as secp256r1 or prime256v1)
    final domainParams = ECDomainParameters('prime256v1');
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)))));

    final keyGenerator = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(domainParams),
        secureRandom,
      ));

    return keyGenerator.generateKeyPair();
  }

  // Encode public key for transmission
  Uint8List encodePublicKey(ECPublicKey publicKey) {
    final q = publicKey.Q!;
    final qEncoded = q.getEncoded(false);
    return Uint8List.fromList(qEncoded);
  }

  // Decode received public key
  ECPublicKey decodePublicKey(Uint8List encodedKey) {
    final domainParams = ECDomainParameters('prime256v1');
    final point = domainParams.curve.decodePoint(encodedKey);
    return ECPublicKey(point, domainParams);
  }

  // Compute shared secret using ECDH
  Uint8List computeSharedSecret(ECPrivateKey privateKey, ECPublicKey publicKey) {
    final agreement = ECDHBasicAgreement()
      ..init(privateKey);

    final sharedSecret = agreement.calculateAgreement(publicKey);

    // Convert BigInt to bytes
    final sharedSecretBytes = _bigIntToBytes(sharedSecret);

    // Apply a KDF (HKDF) to derive a suitable encryption key
    final kdf = HKDFKeyDerivator(SHA256Digest());
    final params = HkdfParameters(
      sharedSecretBytes,
      32, // Output key length
      Uint8List(0), // No salt needed
      Uint8List(0), // No info needed
    );

    kdf.init(params);
    return kdf.process(Uint8List(0));
  }

  // Helper to convert BigInt to bytes
  Uint8List _bigIntToBytes(BigInt bigInt) {
    String hexString = bigInt.toRadixString(16);
    if (hexString.length % 2 != 0) {
      hexString = '0$hexString';
    }

    final result = Uint8List(hexString.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      final byteString = hexString.substring(i * 2, i * 2 + 2);
      result[i] = int.parse(byteString, radix: 16);
    }

    return result;
  }
}