import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

import 'noise/primitives/dh_state.dart';

/// ECDH-based stealth addressing for anonymous mesh relay.
///
/// **Protocol (EIP-5564 simplified for BLE mesh)**:
///
/// Sender:
///   1. Pick random ephemeral key r (X25519).
///   2. R = r·G  (ephemeral public key, 32 bytes).
///   3. sharedSecret = X25519(r, recipientScanKey).
///   4. viewTag = HMAC-SHA256(sharedSecret, "pakconnect/stealth/view")[0]  (1 byte).
///   5. stealthAddr = HMAC-SHA256(sharedSecret, "pakconnect/stealth/addr") (32 bytes).
///   6. Send (R, viewTag, stealthAddr) in RelayMetadata instead of finalRecipient.
///
/// Recipient scanning (per incoming relay):
///   1. sharedSecret = X25519(scanPrivateKey, R).
///   2. computedViewTag = HMAC-SHA256(sharedSecret, "pakconnect/stealth/view")[0].
///   3. If computedViewTag ≠ viewTag → SKIP (fast reject, filters 255/256 ≈ 99.6%).
///   4. computedAddr = HMAC-SHA256(sharedSecret, "pakconnect/stealth/addr").
///   5. If computedAddr == stealthAddr → MESSAGE IS FOR ME.
class StealthAddress {
  static final _logger = Logger('StealthAddress');

  static const int viewTagLength = 1;
  static const int stealthAddrLength = 32;
  static const int ephemeralKeyLength = 32;

  static final _viewTagInfo =
      Uint8List.fromList(utf8.encode('pakconnect/stealth/view'));
  static final _addrInfo =
      Uint8List.fromList(utf8.encode('pakconnect/stealth/addr'));

  /// Generate a stealth envelope for a recipient's scan key.
  ///
  /// Returns [StealthEnvelope] containing (R, viewTag, stealthAddr).
  static StealthEnvelope generate({
    required Uint8List recipientScanKey,
  }) {
    // 1. Generate ephemeral keypair
    final ephemeral = DHState()..generateKeyPair();
    final ephemeralPublic = ephemeral.getPublicKey()!;
    final ephemeralPrivate = ephemeral.getPrivateKey()!;

    try {
      // 2. ECDH: sharedSecret = X25519(r, recipientScanKey)
      final sharedSecret =
          DHState.calculate(ephemeralPrivate, recipientScanKey);

      // 3. Derive view tag and stealth address
      final viewTag = _deriveViewTag(sharedSecret);
      final stealthAddr = _deriveStealthAddr(sharedSecret);

      _logger.fine('Generated stealth envelope: viewTag=0x${viewTag.toRadixString(16)}');

      return StealthEnvelope(
        ephemeralPublicKey: Uint8List.fromList(ephemeralPublic),
        viewTag: viewTag,
        stealthAddress: stealthAddr,
      );
    } finally {
      ephemeral.destroy();
    }
  }

  /// Check if a stealth envelope is addressed to us.
  ///
  /// [scanPrivateKey] is the recipient's X25519 private key (scan key).
  /// Returns true if the message is destined for us.
  static StealthCheckResult check({
    required Uint8List scanPrivateKey,
    required StealthEnvelope envelope,
  }) {
    // 1. ECDH: sharedSecret = X25519(scanPrivateKey, R)
    final sharedSecret = DHState.calculate(
      scanPrivateKey,
      envelope.ephemeralPublicKey,
    );

    // 2. Fast-reject via view tag (filters 255/256 ≈ 99.6% of non-matches)
    final computedViewTag = _deriveViewTag(sharedSecret);
    if (computedViewTag != envelope.viewTag) {
      return const StealthCheckResult(
        isForMe: false,
        passedViewTag: false,
      );
    }

    // 3. Full verification via stealth address (256-bit match)
    final computedAddr = _deriveStealthAddr(sharedSecret);
    final isMatch = _constantTimeEquals(computedAddr, envelope.stealthAddress);

    return StealthCheckResult(
      isForMe: isMatch,
      passedViewTag: true,
    );
  }

  /// Derive the 1-byte view tag from the shared secret.
  static int _deriveViewTag(Uint8List sharedSecret) {
    final hmacResult = Hmac(sha256, sharedSecret).convert(_viewTagInfo);
    return hmacResult.bytes[0];
  }

  /// Derive the 32-byte stealth address from the shared secret.
  static Uint8List _deriveStealthAddr(Uint8List sharedSecret) {
    final hmacResult = Hmac(sha256, sharedSecret).convert(_addrInfo);
    return Uint8List.fromList(hmacResult.bytes);
  }

  /// Constant-time comparison to prevent timing attacks.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

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
