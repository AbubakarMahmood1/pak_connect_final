import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class ChatUtils {
  /// Generate chat ID from other device's ID
  ///
  /// Uses their persistent public key if known (after pairing),
  /// otherwise uses their ephemeral ID (before pairing)
  ///
  /// Simple and elegant: chatId = theirId
  static String generateChatId(String theirId) {
    return theirId;
  }

/// Generate 8-character hash from public key for BLE advertising
  static String generatePublicKeyHash(String publicKey) {
    final bytes = utf8.encode(publicKey);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 8); // First 8 hex chars = 4 bytes
  }
  
  /// Convert hash back to bytes for BLE advertising
  static Uint8List hashToBytes(String hash) {
    final bytes = <int>[];
    for (int i = 0; i < hash.length; i += 2) {
      bytes.add(int.parse(hash.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

}