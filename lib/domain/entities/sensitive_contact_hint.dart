// File: lib/domain/entities/sensitive_contact_hint.dart

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Level 2 Hint: Sensitive hint for paired contact recognition
///
/// Use case: "We're already paired, I recognize you nearby"
/// Lifetime: Permanent (until contact deleted)
/// Security: Private (only paired contacts can compute)
class SensitiveContactHint {
  /// The contact's public key
  final String contactPublicKey;

  /// Shared seed exchanged during pairing
  final Uint8List sharedSeed;

  /// Computed 4-byte hint
  final Uint8List hintBytes;

  /// Contact display name (for debugging/UI)
  final String? displayName;

  /// When this hint was established (pairing time)
  final DateTime establishedAt;

  SensitiveContactHint({
    required this.contactPublicKey,
    required this.sharedSeed,
    required this.hintBytes,
    this.displayName,
    required this.establishedAt,
  });

  /// Compute sensitive hint from public key and shared seed
  ///
  /// Formula: SHA256(publicKey + sharedSeed)[0:4]
  /// This is deterministic - both parties compute the same value
  factory SensitiveContactHint.compute({
    required String contactPublicKey,
    required Uint8List sharedSeed,
    String? displayName,
    DateTime? establishedAt,
  }) {
    final hintBytes = _computeHint(contactPublicKey, sharedSeed);

    return SensitiveContactHint(
      contactPublicKey: contactPublicKey,
      sharedSeed: sharedSeed,
      hintBytes: hintBytes,
      displayName: displayName,
      establishedAt: establishedAt ?? DateTime.now(),
    );
  }

  /// Generate new shared seed (during pairing) using cryptographic RNG
  static Uint8List generateSharedSeed() {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  /// Compute hint bytes from public key and seed
  static Uint8List _computeHint(String publicKey, Uint8List sharedSeed) {
    // Combine public key and shared seed
    final combined = utf8.encode(publicKey) + sharedSeed;

    // Hash and take first 4 bytes
    final hash = sha256.convert(combined);
    return Uint8List.fromList(hash.bytes.sublist(0, 4));
  }

  /// Get hint as hex string
  String get hintHex => hintBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

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
      'shared_seed': sharedSeed,
      'hint_bytes': hintBytes,
      'display_name': displayName,
      'established_at': establishedAt.millisecondsSinceEpoch,
    };
  }

  /// Create from database map
  factory SensitiveContactHint.fromMap(Map<String, dynamic> map) {
    return SensitiveContactHint(
      contactPublicKey: map['contact_public_key'] as String,
      sharedSeed: map['shared_seed'] as Uint8List,
      hintBytes: map['hint_bytes'] as Uint8List,
      displayName: map['display_name'] as String?,
      establishedAt: DateTime.fromMillisecondsSinceEpoch(map['established_at'] as int),
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
