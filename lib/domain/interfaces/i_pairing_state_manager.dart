import '../models/security_level.dart';

/// Abstraction for pairing-code flows used by chat presentation controllers.
abstract interface class IPairingStateManager {
  /// Clears in-progress pairing state.
  void clearPairing();

  /// Generates the local verification code shown to the user.
  String generatePairingCode();

  /// Completes pairing using the peer-provided verification code.
  Future<bool> completePairing(String theirCode);

  /// Applies a contact security upgrade after successful pairing.
  Future<bool> confirmSecurityUpgrade(String publicKey, SecurityLevel newLevel);
}
