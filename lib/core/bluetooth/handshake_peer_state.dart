import 'package:pak_connect/core/security/noise/models/noise_models.dart';

/// Holds peer-scoped identity and handshake metadata for the BLE handshake.
class HandshakePeerState {
  String? theirEphemeralId;
  String? theirDisplayName;
  String? theirNoisePublicKey; // base64
  bool? theyHaveUsAsContact;
  NoisePattern? attemptedPattern;
  bool patternMismatchDetected = false;
  String? rejectionReason;

  void setIdentity({required String ephemeralId, String? displayName}) {
    theirEphemeralId = ephemeralId;
    theirDisplayName = displayName;
  }

  void setNoisePublicKey(String publicKeyBase64) {
    theirNoisePublicKey = publicKeyBase64;
  }

  void setContactStatus(bool value) {
    theyHaveUsAsContact = value;
  }

  void markAttemptedPattern(NoisePattern pattern) {
    attemptedPattern = pattern;
  }

  void markRejection(String? reason) {
    rejectionReason = reason;
  }

  void markPatternMismatch() {
    patternMismatchDetected = true;
  }
}
