import '../entities/ephemeral_discovery_hint.dart';

/// Domain contract for intro hint persistence (QR-based discovery).
abstract interface class IIntroHintRepository {
  Future<List<EphemeralDiscoveryHint>> getMyActiveHints();

  Future<void> saveMyActiveHint(EphemeralDiscoveryHint hint);

  Future<Map<String, EphemeralDiscoveryHint>> getScannedHints();

  Future<void> saveScannedHint(String key, EphemeralDiscoveryHint hint);

  Future<void> removeScannedHint(String key);

  Future<void> cleanupExpiredHints();

  Future<EphemeralDiscoveryHint?> getMostRecentActiveHint();

  Future<void> clearAll();
}
