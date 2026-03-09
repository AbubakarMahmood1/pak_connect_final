import 'dart:convert';
import 'dart:typed_data';

/// The triple sent in relay metadata instead of plaintext finalRecipient.
class StealthEnvelope {
  /// Ephemeral public key R = r·G (32 bytes, hex-encoded for JSON).
  final Uint8List ephemeralPublicKey;

  /// 1-byte view tag for fast rejection.
  final int viewTag;

  /// 32-byte stealth address (full verification).
  final Uint8List stealthAddress;

  const StealthEnvelope({
    required this.ephemeralPublicKey,
    required this.viewTag,
    required this.stealthAddress,
  });

  Map<String, dynamic> toJson() => {
        'R': base64Encode(ephemeralPublicKey),
        'vt': viewTag,
        'sa': base64Encode(stealthAddress),
      };

  factory StealthEnvelope.fromJson(Map<String, dynamic> json) {
    return StealthEnvelope(
      ephemeralPublicKey: base64Decode(json['R'] as String),
      viewTag: json['vt'] as int,
      stealthAddress: base64Decode(json['sa'] as String),
    );
  }
}

/// Result of checking a stealth envelope against our scan key.
class StealthCheckResult {
  /// Whether the message is addressed to us.
  final bool isForMe;

  /// Whether the fast view-tag check passed (useful for stats).
  final bool passedViewTag;

  const StealthCheckResult({
    required this.isForMe,
    required this.passedViewTag,
  });
}
