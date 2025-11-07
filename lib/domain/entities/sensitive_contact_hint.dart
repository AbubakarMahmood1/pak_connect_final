// File: lib/domain/entities/sensitive_contact_hint.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Level 2 Hint: Persistent hint for paired contact recognition
///
/// Use case: "We're already paired, I recognize you nearby"
/// Lifetime: Permanent (deterministic from public key, never changes)
/// Security: Privacy-preserving (hint reveals nothing without knowing the public key)
///
/// Design: Each device computes a persistent hint from their own public key and broadcasts it.
/// During pairing, devices exchange public keys and compute each other's hints for recognition.
class SensitiveContactHint {
  /// The contact's public key
  final String contactPublicKey;

  /// Computed 4-byte hint (deterministic from public key)
  final Uint8List hintBytes;

  /// Contact display name (for debugging/UI)
  final String? displayName;

  /// When this hint was established (pairing time)
  final DateTime establishedAt;

  SensitiveContactHint({
    required this.contactPublicKey,
    required this.hintBytes,
    this.displayName,
    required this.establishedAt,
  });

  /// Compute persistent hint from public key only
  ///
  /// Formula: SHA256(publicKey)[0:4]
  /// This is deterministic - same public key always produces same hint
  factory SensitiveContactHint.compute({
    required String contactPublicKey,
    String? displayName,
    DateTime? establishedAt,
  }) {
    final hintBytes = _computeHint(contactPublicKey);

    return SensitiveContactHint(
      contactPublicKey: contactPublicKey,
      hintBytes: hintBytes,
      displayName: displayName,
      establishedAt: establishedAt ?? DateTime.now(),
    );
  }

  /// Compute hint bytes from public key only (deterministic)
  static Uint8List _computeHint(String publicKey) {
    // Hash public key and take first 4 bytes
    final hash = sha256.convert(utf8.encode(publicKey));
    return Uint8List.fromList(hash.bytes.sublist(0, 4));
  }

  /// Get hint as hex string
  String get hintHex => hintBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  /// Verify if a discovered hint matches this contact
  bool matches(Uint8List discoveredHint) {
    if (discoveredHint.length != hintBytes.length) return false;

    for (int i = 0; i < hintBytes.length; i++) {
      if (hintBytes[i] != discoveredHint[i]) return false;
    }
    return true;
  }

  /// Convert to database map
  Map<String, dynamic> toMap() {
    return {
      'contact_public_key': contactPublicKey,
      'hint_bytes': hintBytes,
      'display_name': displayName,
      'established_at': establishedAt.millisecondsSinceEpoch,
    };
  }

  /// Create from database map
  factory SensitiveContactHint.fromMap(Map<String, dynamic> map) {
    return SensitiveContactHint(
      contactPublicKey: map['contact_public_key'] as String,
      hintBytes: map['hint_bytes'] as Uint8List,
      displayName: map['display_name'] as String?,
      establishedAt: DateTime.fromMillisecondsSinceEpoch(
        map['established_at'] as int,
      ),
    );
  }

  @override
  String toString() {
    return 'SensitiveContactHint(contact: ${contactPublicKey.substring(0, 16)}..., '
        'hint: $hintHex, name: $displayName)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SensitiveContactHint) return false;

    return contactPublicKey == other.contactPublicKey;
  }

  @override
  int get hashCode => contactPublicKey.hashCode;
}
