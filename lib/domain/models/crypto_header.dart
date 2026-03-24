import 'package:meta/meta.dart';

/// Canonical crypto metadata for protocol message payloads.
///
/// For protocol version >= 2, encrypted messages are expected to include this
/// header so decryption can route deterministically by declared mode.
@immutable
class CryptoHeader {
  const CryptoHeader({
    required this.mode,
    this.modeVersion = 1,
    this.keyId,
    this.sessionId,
    this.ephemeralPublicKey,
    this.nonce,
  });

  final CryptoMode mode;
  final int modeVersion;
  final String? keyId;
  final String? sessionId;
  final String? ephemeralPublicKey;
  final String? nonce;

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.wireValue,
      'modeVersion': modeVersion,
      if (keyId != null && keyId!.isNotEmpty) 'kid': keyId,
      if (sessionId != null && sessionId!.isNotEmpty) 'sessionId': sessionId,
      if (ephemeralPublicKey != null && ephemeralPublicKey!.isNotEmpty)
        'epk': ephemeralPublicKey,
      if (nonce != null && nonce!.isNotEmpty) 'nonce': nonce,
    };
  }

  static CryptoHeader? fromJson(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(raw);
    final mode = CryptoMode.tryParse(map['mode'] as String?);
    if (mode == null) {
      return null;
    }
    return CryptoHeader(
      mode: mode,
      modeVersion: (map['modeVersion'] as num?)?.toInt() ?? 1,
      keyId: map['kid'] as String?,
      sessionId: map['sessionId'] as String?,
      ephemeralPublicKey: map['epk'] as String?,
      nonce: map['nonce'] as String?,
    );
  }
}

enum CryptoMode {
  none,
  noiseV1,
  sealedV1,

  ;

  static CryptoMode? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    switch (raw) {
      case 'none':
        return CryptoMode.none;
      case 'noise_v1':
        return CryptoMode.noiseV1;
      case 'sealed_v1':
        return CryptoMode.sealedV1;
      default:
        return null;
    }
  }
}

extension CryptoModeWire on CryptoMode {
  String get wireValue {
    switch (this) {
      case CryptoMode.none:
        return 'none';
      case CryptoMode.noiseV1:
        return 'noise_v1';
      case CryptoMode.sealedV1:
        return 'sealed_v1';
    }
  }
}
