import 'package:meta/meta.dart';

/// Encryption method used for a particular message.
///
/// `global` remains only as an explicit unsupported sentinel for old fixtures
/// and fail-closed paths. It must not be selected for new outbound messages.
@immutable
class EncryptionMethod {
  final EncryptionType type;
  final String? publicKey;

  const EncryptionMethod._(this.type, [this.publicKey]);

  factory EncryptionMethod.ecdh(String publicKey) =>
      EncryptionMethod._(EncryptionType.ecdh, publicKey);

  factory EncryptionMethod.noise(String publicKey) =>
      EncryptionMethod._(EncryptionType.noise, publicKey);

  factory EncryptionMethod.pairing(String publicKey) =>
      EncryptionMethod._(EncryptionType.pairing, publicKey);

  /// Unsupported sentinel for removed legacy/global payload handling.
  factory EncryptionMethod.global() =>
      const EncryptionMethod._(EncryptionType.global);

  @override
  String toString() => 'EncryptionMethod(${type.name}, key: $publicKey)';
}

enum EncryptionType {
  ecdh,
  noise,
  pairing,

  /// Unsupported sentinel for removed legacy/global payload handling.
  global,
}
