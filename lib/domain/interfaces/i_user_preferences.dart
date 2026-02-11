/// Domain contract for user identity preference storage.
///
/// This abstraction exposes only the key-material operations that higher layers
/// require and keeps concrete storage details in the data layer.
abstract interface class IUserPreferences {
  /// Returns the locally configured display name.
  Future<String> getUserName();

  /// Persists the local display name.
  Future<void> setUserName(String name);

  /// Returns a stable device identifier, creating one if missing.
  Future<String> getOrCreateDeviceId();

  /// Returns the existing device identifier if available.
  Future<String?> getDeviceId();

  /// Returns an existing keypair or creates a new one if absent.
  Future<Map<String, String>> getOrCreateKeyPair();

  /// Returns the persistent public key as a hex string, or empty string.
  Future<String> getPublicKey();

  /// Returns the persistent private key as a hex string, or empty string.
  Future<String> getPrivateKey();

  /// Returns whether discovery hints are broadcast (spy mode off by default).
  Future<bool> getHintBroadcastEnabled();

  /// Enables/disables discovery hint broadcasting.
  Future<void> setHintBroadcastEnabled(bool enabled);

  /// Regenerates local key material used for pairing and encryption identity.
  Future<void> regenerateKeyPair();
}
