import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';

class SigningCryptoService {
  static final _logger = Logger('SigningCryptoService');

  static ECPrivateKey? _privateKey;

  static bool get isSigningReady => _privateKey != null;
  static bool get hasPrivateKey => _privateKey != null;

  static void clear() {
    _privateKey = null;
  }

  static void initializeSigning(String privateKeyHex, String publicKeyHex) {
    try {
      final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
      _privateKey = ECPrivateKey(privateKeyInt, ECCurve_secp256r1());

      final publicKeyBytes = _hexToBytes(publicKeyHex);
      final curve = ECCurve_secp256r1();
      curve.curve.decodePoint(publicKeyBytes);

      _logger.fine('🟢 INIT SUCCESS: Message signing initialized completely');
    } catch (e, stackTrace) {
      _logger.fine('🔴 INIT FAIL: Exception during initialization');
      _logger.fine('🔴 INIT FAIL: Error type: ${e.runtimeType}');
      _logger.fine('🔴 INIT FAIL: Error message: $e');
      final stackLines = stackTrace.toString().split('\n');
      for (var i = 0; i < 3 && i < stackLines.length; i++) {
        _logger.fine('🔴 INIT STACK $i: ${stackLines[i]}');
      }
      _privateKey = null;
    }
  }

  static String? signMessage(String content) {
    if (_privateKey == null) {
      _logger.fine('🔴 SIGN FAIL: No private key available');
      return null;
    }

    try {
      final signer = ECDSASigner(SHA256Digest());
      final secureRandom = FortunaRandom();
      final random = Random.secure();
      final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      secureRandom.seed(KeyParameter(seed));

      final privateKeyParam = PrivateKeyParameter(_privateKey!);
      final params = ParametersWithRandom(privateKeyParam, secureRandom);
      signer.init(true, params);

      final messageBytes = utf8.encode(content);
      final signature = signer.generateSignature(messageBytes) as ECSignature;
      final rHex = signature.r.toRadixString(16);
      final sHex = signature.s.toRadixString(16);
      return '$rHex:$sHex';
    } catch (e, stackTrace) {
      _logger.fine('🔴 SIGN FAIL: Exception caught');
      _logger.fine('🔴 SIGN FAIL: Error type: ${e.runtimeType}');
      _logger.fine('🔴 SIGN FAIL: Error message: $e');
      final stackLines = stackTrace.toString().split('\n');
      for (var i = 0; i < 3 && i < stackLines.length; i++) {
        _logger.fine('🔴 STACK $i: ${stackLines[i]}');
      }
      return null;
    }
  }

  static bool verifySignature(
    String content,
    String signatureHex,
    String senderPublicKeyHex,
  ) {
    try {
      final publicKeyBytes = _hexToBytes(senderPublicKeyHex);
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(publicKeyBytes);
      final publicKey = ECPublicKey(point, curve);

      final sigParts = signatureHex.split(':');
      final r = BigInt.parse(sigParts[0], radix: 16);
      final s = BigInt.parse(sigParts[1], radix: 16);
      final signature = ECSignature(r, s);

      final verifier = ECDSASigner(SHA256Digest());
      verifier.init(false, PublicKeyParameter(publicKey));

      final messageBytes = utf8.encode(content);
      return verifier.verifySignature(messageBytes, signature);
    } catch (e) {
      _logger.fine('Signature verification failed: $e');
      return false;
    }
  }

  static String? computeSharedSecret(String theirPublicKeyHex) {
    if (_privateKey == null) {
      _logger.fine('Cannot compute shared secret - no private key');
      return null;
    }

    try {
      final theirPublicKeyBytes = _hexToBytes(theirPublicKeyHex);
      final curve = ECCurve_secp256r1();
      final theirPoint = curve.curve.decodePoint(theirPublicKeyBytes);
      final theirPublicKey = ECPublicKey(theirPoint, curve);

      final sharedPoint = theirPublicKey.Q! * _privateKey!.d!;
      return sharedPoint!.x!.toBigInteger()!.toRadixString(16);
    } catch (e) {
      _logger.fine('🔴 ECDH computation failed: $e');
      return null;
    }
  }

  static Uint8List hexToBytes(String hex) => _hexToBytes(hex);

  static Uint8List _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(result);
  }
}
