import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

class ChatUtils {
  static final _logger = Logger('ChatUtils');

  /// Generate chat ID from other device's ID
  ///
  /// 🔧 FIX BUG #4: Session-specific chat ID generation
  ///
  /// Uses their session ID (ephemeral pre-pairing, persistent post-pairing)
  /// This ensures:
  /// - Pre-pairing: Each Noise session gets unique chat (session isolation)
  /// - Post-pairing: Persistent chat history across sessions
  ///
  /// Implementation:
  /// - Pre-pairing: theirId = ephemeral ID (unique per session)
  /// - Post-pairing: theirId = persistent key (same across sessions)
  /// - Chat ID = theirId (simple and elegant)
  ///
  /// Result: Different sessions → different chats (session isolation achieved)
  static String generateChatId(String theirId) {
    final preview = theirId.length > 16
        ? '${theirId.substring(0, 16)}...'
        : theirId;
    _logger.info('🆔 CHAT ID GENERATED: $preview (session-specific)');
    _logger.info(
      '✅ Session isolation: ephemeral ID (pre-pairing) or persistent key (post-pairing)',
    );

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
