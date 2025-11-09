// File: lib/domain/entities/ephemeral_discovery_hint.dart

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Level 1 Hint: Temporary discovery hint for QR-based pairing
///
/// Use case: "I met you at a party, scan my QR, find me later"
/// Lifetime: 14 days (configurable)
/// Security: Public (anyone with QR can find you for limited time)
class EphemeralDiscoveryHint {
  /// Unique random 8-byte hint identifier
  /// Advertised in BLE for device discovery
  final Uint8List hintBytes;

  /// When this hint was generated
  final DateTime createdAt;

  /// When this hint expires and becomes invalid
  final DateTime expiresAt;

  /// Optional display name for UX
  final String? displayName;

  /// Whether this hint is currently being advertised
  final bool isActive;

  /// Unique identifier for this hint instance
  final String hintId;

  EphemeralDiscoveryHint({
    required this.hintBytes,
    required this.createdAt,
    required this.expiresAt,
    this.displayName,
    this.isActive = true,
  }) : hintId = _generateHintId(hintBytes);

  /// Generate a new random discovery hint
  factory EphemeralDiscoveryHint.generate({
    String? displayName,
    Duration validityPeriod = const Duration(days: 14),
  }) {
    final now = DateTime.now();
    final hintBytes = _generateSecureRandomBytes(8);

    return EphemeralDiscoveryHint(
      hintBytes: hintBytes,
      createdAt: now,
      expiresAt: now.add(validityPeriod),
      displayName: displayName,
      isActive: true,
    );
  }

  /// Check if hint is still valid
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Check if hint is usable
  bool get isUsable => isActive && !isExpired;

  /// Get hint as hex string
  String get hintHex => hintBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  /// Generate QR code data
  Map<String, dynamic> toQRData() {
    return {
      'version': 1,
      'type': 'pak_connect_intro',
      'hint': hintHex,
      'expires': expiresAt.millisecondsSinceEpoch,
      'name': displayName,
    };
  }

  /// Get QR code string (base64 encoded JSON)
  String toQRString() {
    final json = jsonEncode(toQRData());
    return base64Encode(utf8.encode(json));
  }

  /// Parse hint from QR code data
  static EphemeralDiscoveryHint? fromQRString(String qrData) {
    try {
      final decoded = utf8.decode(base64Decode(qrData));
      final data = jsonDecode(decoded) as Map<String, dynamic>;

      if (data['type'] != 'pak_connect_intro') return null;
      if (data['version'] != 1) return null;

      final hintHex = data['hint'] as String;
      final hintBytes = _hexToBytes(hintHex);
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        data['expires'] as int,
      );

      return EphemeralDiscoveryHint(
        hintBytes: hintBytes,
        createdAt: DateTime.now(), // Scanner's timestamp
        expiresAt: expiresAt,
        displayName: data['name'] as String?,
        isActive: true,
      );
    } catch (e) {
      return null;
    }
  }

  /// Convert to database map
  Map<String, dynamic> toMap() {
    return {
      'hint_id': hintId,
      'hint_bytes': hintBytes,
      'created_at': createdAt.millisecondsSinceEpoch,
      'expires_at': expiresAt.millisecondsSinceEpoch,
      'display_name': displayName,
      'is_active': isActive ? 1 : 0,
    };
  }

  /// Create from database map
  factory EphemeralDiscoveryHint.fromMap(Map<String, dynamic> map) {
    // Handle both database (Uint8List) and JSON (List<dynamic>) formats
    final hintBytesRaw = map['hint_bytes'];
    final Uint8List hintBytes = hintBytesRaw is Uint8List
        ? hintBytesRaw
        : Uint8List.fromList(List<int>.from(hintBytesRaw as List));

    return EphemeralDiscoveryHint(
      hintBytes: hintBytes,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(map['expires_at'] as int),
      displayName: map['display_name'] as String?,
      isActive: (map['is_active'] as int) == 1,
    );
  }

  /// Generate secure random bytes using cryptographic RNG
  static Uint8List _generateSecureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Generate unique hint ID from bytes
  static String _generateHintId(Uint8List bytes) {
    return 'hint_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// Convert hex string to bytes
  static Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  @override
  String toString() {
    return 'EphemeralDiscoveryHint(id: $hintId, hex: $hintHex, '
        'expires: $expiresAt, active: $isActive)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! EphemeralDiscoveryHint) return false;

    if (hintBytes.length != other.hintBytes.length) return false;
    for (int i = 0; i < hintBytes.length; i++) {
      if (hintBytes[i] != other.hintBytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => hintId.hashCode;
}
