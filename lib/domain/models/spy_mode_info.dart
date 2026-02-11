/// Model for spy mode detection information.
/// Represents a contact discovered in spy mode (anonymous/ephemeral session).
class SpyModeInfo {
  final String contactName;
  final String ephemeralID;
  final String? persistentKey;

  SpyModeInfo({
    required this.contactName,
    required this.ephemeralID,
    this.persistentKey,
  });
}
