import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

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
    final preview = theirId.length > 16 ? '${theirId.shortId()}...' : theirId;
    _logger.fine('🆔 CHAT ID GENERATED: $preview (session-specific)');
    _logger.fine(
      '✅ Session isolation: ephemeral ID (pre-pairing) or persistent key (post-pairing)',
    );

    return theirId;
  }

  /// Resolve the best identifier for chat/security state:
  /// persistentPublicKey → currentSessionId → currentEphemeralId.
  static String? resolveChatKey({
    String? persistentPublicKey,
    String? currentSessionId,
    String? currentEphemeralId,
  }) {
    if (persistentPublicKey != null && persistentPublicKey.isNotEmpty) {
      return persistentPublicKey;
    }
    if (currentSessionId != null && currentSessionId.isNotEmpty) {
      return currentSessionId;
    }
    if (currentEphemeralId != null && currentEphemeralId.isNotEmpty) {
      return currentEphemeralId;
    }
    return null;
  }

  /// Generate 8-character hash from public key for BLE advertising
  static String generatePublicKeyHash(String publicKey) {
    final bytes = utf8.encode(publicKey);
    final digest = sha256.convert(bytes);
    return digest.toString().shortId(8); // First 8 hex chars = 4 bytes
  }

  /// Convert hash back to bytes for BLE advertising
  static Uint8List hashToBytes(String hash) {
    final bytes = <int>[];
    for (int i = 0; i < hash.length; i += 2) {
      bytes.add(int.parse(hash.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  /// Extract contact public key from chat ID (handles multiple formats)
  ///
  /// Supports:
  /// 1. Production format: `contactKey` (returns as-is)
  /// 2. Test format: `persistent_chat_{KEY1}_{KEY2}` (extracts non-myKey)
  /// 3. Temp format: `temp_{deviceId}` (returns null - not a contact)
  ///
  /// **Important**: When myPublicKey is provided, searches for it explicitly
  /// to handle keys with underscores correctly.
  ///
  /// Examples:
  /// - `persistent_chat_testuser0_key_mykey` + myPublicKey='mykey' → `testuser0_key`
  /// - `persistent_chat_alice_bob_charlie` + myPublicKey='charlie' → `alice_bob`
  /// - `persistent_chat_alice_bob` + myPublicKey='' → `alice` (backwards compat)
  ///
  /// Returns:
  /// - Contact's public key if found
  /// - null if chatId is invalid or temp format
  static String? extractContactKey(String chatId, String myPublicKey) {
    // Temp chats are not persistent contacts
    if (chatId.startsWith('temp_')) {
      return null;
    }

    // Legacy test format: persistent_chat_{KEY1}_{KEY2}
    if (chatId.startsWith('persistent_chat_')) {
      final withoutPrefix = chatId.substring('persistent_chat_'.length);

      // Handle empty or malformed IDs
      if (withoutPrefix.isEmpty) {
        return null;
      }

      // If myPublicKey is provided and found in the string, extract the other part
      if (myPublicKey.isNotEmpty) {
        // Try to find myPublicKey as a suffix (most common: contact_mykey)
        if (withoutPrefix.endsWith('_$myPublicKey')) {
          final contactKey = withoutPrefix.substring(
            0,
            withoutPrefix.length - myPublicKey.length - 1,
          );
          return contactKey.isNotEmpty ? contactKey : null;
        }

        // Try to find myPublicKey as a prefix (less common: mykey_contact)
        if (withoutPrefix.startsWith('${myPublicKey}_')) {
          final contactKey = withoutPrefix.substring(myPublicKey.length + 1);
          return contactKey.isNotEmpty ? contactKey : null;
        }
      }

      // Fallback: Use lastIndexOf for backwards compatibility
      // This handles cases where myPublicKey is empty or not found
      final lastUnderscoreIndex = withoutPrefix.lastIndexOf('_');

      if (lastUnderscoreIndex != -1) {
        // Check if underscore is at the end (trailing underscore)
        if (lastUnderscoreIndex == withoutPrefix.length - 1) {
          // Strip trailing underscore and return
          final key = withoutPrefix.substring(0, lastUnderscoreIndex);
          return key.isNotEmpty ? key : null;
        }

        // Normal case: underscore in the middle
        final key1 = withoutPrefix.substring(0, lastUnderscoreIndex);
        final key2 = withoutPrefix.substring(lastUnderscoreIndex + 1);

        // Return the key that isn't mine (if we can determine it)
        if (myPublicKey.isNotEmpty) {
          if (key1 == myPublicKey) {
            return key2.isNotEmpty ? key2 : null;
          } else if (key2 == myPublicKey) {
            return key1.isNotEmpty ? key1 : null;
          }
        }

        // If neither matches, assume first key is contact's
        // (backwards compatibility for tests without myPublicKey)
        return key1.isNotEmpty ? key1 : null;
      }

      // No underscore found - return the whole key
      return withoutPrefix;
    }

    // Production format: chatId = contactPublicKey (simple)
    return chatId;
  }
}
