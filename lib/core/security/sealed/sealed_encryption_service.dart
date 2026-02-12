import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:logging/logging.dart';

import '../noise/primitives/dh_state.dart';

/// Result of a sealed_v1 encryption operation.
class SealedEncryptionResult {
  const SealedEncryptionResult({
    required this.ciphertext,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.keyId,
  });

  /// Ciphertext with Poly1305 tag appended (16 bytes).
  final Uint8List ciphertext;

  /// Sender ephemeral X25519 public key (32 bytes).
  final Uint8List ephemeralPublicKey;

  /// ChaCha20-Poly1305 nonce (12 bytes).
  final Uint8List nonce;

  /// Key identifier derived from recipient static public key.
  final String keyId;
}

/// Stateless sealed-box style encryption for offline/store-forward payloads.
///
/// Construction:
/// - X25519(ephemeral_sender_priv, recipient_static_pub) -> shared secret
/// - HKDF-SHA256(shared secret) -> 32-byte ChaCha20 key
/// - ChaCha20-Poly1305 with caller-supplied AAD
class SealedEncryptionService {
  SealedEncryptionService({Chacha20? cipher})
    : _cipher = cipher ?? Chacha20.poly1305Aead();

  static final _logger = Logger('SealedEncryptionService');
  static const int _x25519KeyLength = 32;
  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static const int _symmetricKeyLength = 32;
  static final Uint8List _hkdfSalt = Uint8List.fromList(
    'pakconnect/sealed_v1/salt'.codeUnits,
  );
  static final Uint8List _hkdfInfo = Uint8List.fromList(
    'pakconnect/sealed_v1/chacha20poly1305'.codeUnits,
  );

  final Chacha20 _cipher;

  Future<SealedEncryptionResult> encrypt({
    required Uint8List plaintext,
    required Uint8List recipientPublicKey,
    Uint8List? aad,
  }) async {
    _validateX25519Key(recipientPublicKey, 'recipientPublicKey');

    final ephemeralState = DHState()..generateKeyPair();
    final ephemeralPrivate = ephemeralState.getPrivateKey();
    final ephemeralPublic = ephemeralState.getPublicKey();

    if (ephemeralPrivate == null || ephemeralPublic == null) {
      ephemeralState.destroy();
      throw StateError('Failed to generate ephemeral X25519 keypair');
    }

    final sharedSecret = DHState.calculate(ephemeralPrivate, recipientPublicKey);
    final keyBytes = _deriveMessageKey(sharedSecret);

    try {
      final nonce = _randomBytes(_nonceLength);
      final secretBox = await _cipher.encrypt(
        plaintext,
        secretKey: SecretKey(keyBytes),
        nonce: nonce,
        aad: aad ?? Uint8List(0),
      );

      final ciphertext = Uint8List(secretBox.cipherText.length + _macLength);
      ciphertext.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
      ciphertext.setRange(
        secretBox.cipherText.length,
        ciphertext.length,
        secretBox.mac.bytes,
      );

      return SealedEncryptionResult(
        ciphertext: ciphertext,
        ephemeralPublicKey: Uint8List.fromList(ephemeralPublic),
        nonce: Uint8List.fromList(nonce),
        keyId: computeKeyId(recipientPublicKey),
      );
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
      sharedSecret.fillRange(0, sharedSecret.length, 0);
      ephemeralPrivate.fillRange(0, ephemeralPrivate.length, 0);
      ephemeralState.destroy();
    }
  }

  Future<Uint8List> decrypt({
    required Uint8List ciphertext,
    required Uint8List recipientPrivateKey,
    required Uint8List ephemeralPublicKey,
    required Uint8List nonce,
    Uint8List? aad,
  }) async {
    _validateX25519Key(recipientPrivateKey, 'recipientPrivateKey');
    _validateX25519Key(ephemeralPublicKey, 'ephemeralPublicKey');

    if (nonce.length != _nonceLength) {
      throw ArgumentError('nonce must be $_nonceLength bytes');
    }
    if (ciphertext.length < _macLength) {
      throw ArgumentError('ciphertext too short (must include MAC)');
    }

    final sharedSecret = DHState.calculate(recipientPrivateKey, ephemeralPublicKey);
    final keyBytes = _deriveMessageKey(sharedSecret);

    try {
      final body = ciphertext.sublist(0, ciphertext.length - _macLength);
      final mac = ciphertext.sublist(ciphertext.length - _macLength);
      final secretBox = SecretBox(body, nonce: nonce, mac: Mac(mac));
      final plaintext = await _cipher.decrypt(
        secretBox,
        secretKey: SecretKey(keyBytes),
        aad: aad ?? Uint8List(0),
      );
      return Uint8List.fromList(plaintext);
    } catch (error) {
      _logger.fine('sealed_v1 decrypt failed: $error');
      rethrow;
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
      sharedSecret.fillRange(0, sharedSecret.length, 0);
    }
  }

  String computeKeyId(Uint8List recipientPublicKey) {
    _validateX25519Key(recipientPublicKey, 'recipientPublicKey');
    final digest = crypto.sha256.convert(recipientPublicKey);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _deriveMessageKey(Uint8List sharedSecret) {
    final prkBytes =
        crypto.Hmac(crypto.sha256, _hkdfSalt).convert(sharedSecret).bytes;
    final prk = Uint8List.fromList(prkBytes);
    final okm = _hkdfExpand(
      pseudoRandomKey: prk,
      info: _hkdfInfo,
      length: _symmetricKeyLength,
    );
    prk.fillRange(0, prk.length, 0);
    return okm;
  }

  Uint8List _hkdfExpand({
    required Uint8List pseudoRandomKey,
    required Uint8List info,
    required int length,
  }) {
    final output = Uint8List(length);
    var previous = Uint8List(0);
    var offset = 0;
    var blockIndex = 1;

    while (offset < length) {
      final input = Uint8List(previous.length + info.length + 1);
      if (previous.isNotEmpty) {
        input.setRange(0, previous.length, previous);
      }
      if (info.isNotEmpty) {
        input.setRange(previous.length, previous.length + info.length, info);
      }
      input[input.length - 1] = blockIndex;

      final blockBytes =
          crypto.Hmac(crypto.sha256, pseudoRandomKey).convert(input).bytes;
      final block = Uint8List.fromList(blockBytes);
      final bytesToCopy = min(length - offset, block.length);
      output.setRange(offset, offset + bytesToCopy, block);

      previous.fillRange(0, previous.length, 0);
      previous = block;
      offset += bytesToCopy;
      blockIndex++;
    }

    previous.fillRange(0, previous.length, 0);
    return output;
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  void _validateX25519Key(Uint8List key, String label) {
    if (key.length != _x25519KeyLength) {
      throw ArgumentError('$label must be $_x25519KeyLength bytes');
    }
  }
}
