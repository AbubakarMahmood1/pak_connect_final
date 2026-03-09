import 'dart:convert';

/// Utilities for packing/unpacking sealed sender identity in encrypted payloads.
///
/// When sealed sender is active:
/// - RelayMetadata.originalSender = "sealed" (relay nodes see this)
/// - The real sender identity is embedded inside the encrypted content
///
/// Payload format (JSON inside encrypted blob):
/// ```json
/// { "s": "<real_sender_public_key>", "c": "<original_content>" }
/// ```
class SealedSenderPayload {
  /// Pack the real sender and content into a single JSON string
  /// that will be encrypted before transmission.
  static String pack({
    required String senderPublicKey,
    required String content,
  }) {
    return jsonEncode({'s': senderPublicKey, 'c': content});
  }

  /// Unpack the real sender and content from a decrypted payload.
  /// Returns null if the payload doesn't have sealed sender format.
  static SealedSenderData? unpack(String decryptedPayload) {
    try {
      final json = jsonDecode(decryptedPayload) as Map<String, dynamic>;
      if (json.containsKey('s') && json.containsKey('c')) {
        return SealedSenderData(
          senderPublicKey: json['s'] as String,
          content: json['c'] as String,
        );
      }
    } catch (_) {
      // Not sealed sender format — return null
    }
    return null;
  }
}

/// Extracted sender identity + content from a sealed sender payload.
class SealedSenderData {
  final String senderPublicKey;
  final String content;

  const SealedSenderData({
    required this.senderPublicKey,
    required this.content,
  });
}
