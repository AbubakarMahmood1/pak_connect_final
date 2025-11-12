/// Isolate worker functions for CPU-intensive encryption operations
///
/// These top-level functions are compatible with Flutter's compute() function
/// for offloading crypto operations to background isolates on slow devices.
library;

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Parameters for isolate-based encryption
class EncryptionTask {
  final Uint8List plaintext;
  final Uint8List key;
  final int nonce;
  final Uint8List? associatedData;

  EncryptionTask({
    required this.plaintext,
    required this.key,
    required this.nonce,
    this.associatedData,
  });
}

/// Parameters for isolate-based decryption
class DecryptionTask {
  final Uint8List ciphertext;
  final Uint8List key;
  final int nonce;
  final Uint8List? associatedData;

  DecryptionTask({
    required this.ciphertext,
    required this.key,
    required this.nonce,
    this.associatedData,
  });
}

/// Perform ChaCha20-Poly1305 encryption in isolate
///
/// This is a top-level function compatible with compute().
/// Performs the same operation as CipherState.encryptWithAd() but in background.
Future<Uint8List> encryptInIsolate(EncryptionTask task) async {
  final cipher = Chacha20.poly1305Aead();

  // Convert nonce to 12-byte format for ChaCha20-Poly1305
  final nonceBytes = _nonceToBytes(task.nonce);

  // Create secret key
  final secretKey = SecretKey(task.key);

  // Encrypt with AEAD
  final secretBox = await cipher.encrypt(
    task.plaintext,
    secretKey: secretKey,
    nonce: nonceBytes,
    aad: task.associatedData ?? Uint8List(0),
  );

  // Combine ciphertext + MAC (16 bytes)
  const macLength = 16;
  final result = Uint8List(secretBox.cipherText.length + macLength);
  result.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
  result.setRange(
    secretBox.cipherText.length,
    result.length,
    secretBox.mac.bytes,
  );

  return result;
}

/// Perform ChaCha20-Poly1305 decryption in isolate
///
/// This is a top-level function compatible with compute().
/// Performs the same operation as CipherState.decryptWithAd() but in background.
Future<Uint8List> decryptInIsolate(DecryptionTask task) async {
  final cipher = Chacha20.poly1305Aead();
  const macLength = 16;

  if (task.ciphertext.length < macLength) {
    throw ArgumentError('Ciphertext too short (must include MAC)');
  }

  // Split ciphertext and MAC
  final actualCiphertext = task.ciphertext.sublist(
    0,
    task.ciphertext.length - macLength,
  );
  final mac = task.ciphertext.sublist(task.ciphertext.length - macLength);

  // Convert nonce to 12-byte format
  final nonceBytes = _nonceToBytes(task.nonce);

  // Create secret key
  final secretKey = SecretKey(task.key);

  // Create SecretBox for decryption
  final secretBox = SecretBox(
    actualCiphertext,
    nonce: nonceBytes,
    mac: Mac(mac),
  );

  // Decrypt and verify MAC
  try {
    final plaintext = await cipher.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: task.associatedData ?? Uint8List(0),
    );

    return Uint8List.fromList(plaintext);
  } catch (e) {
    throw Exception('Decryption failed: MAC verification error - $e');
  }
}

/// Convert 8-byte nonce to 12-byte format for ChaCha20-Poly1305
///
/// ChaCha20 uses 12-byte nonces, Noise uses 8-byte.
/// Prepends 4 zero bytes to 8-byte nonce.
List<int> _nonceToBytes(int nonce) {
  final bytes = Uint8List(12);

  // Write nonce as little-endian 64-bit integer in last 8 bytes
  for (int i = 0; i < 8; i++) {
    bytes[4 + i] = (nonce >> (i * 8)) & 0xFF;
  }

  return bytes;
}
