import '../../domain/entities/ephemeral_discovery_hint.dart';

/// Abstract interface for managing intro hints (Level 1 - QR-based discovery)
///
/// Implementations:
/// - IntroHintRepository: SharedPreferences-backed implementation
abstract interface class IIntroHintRepository {
  /// Get our currently active intro hints
  Future<List<EphemeralDiscoveryHint>> getMyActiveHints();

  /// Save our active intro hint (when generating QR)
  Future<void> saveMyActiveHint(EphemeralDiscoveryHint hint);

  /// Get all scanned intro hints (from other people)
  Future<Map<String, EphemeralDiscoveryHint>> getScannedHints();

  /// Save a scanned intro hint
  Future<void> saveScannedHint(String key, EphemeralDiscoveryHint hint);

  /// Remove a scanned hint
  Future<void> removeScannedHint(String key);

  /// Clean up expired hints from storage
  Future<void> cleanupExpiredHints();

  /// Get the most recent active hint we've generated
  Future<EphemeralDiscoveryHint?> getMostRecentActiveHint();

  /// Clear all hints (for testing)
  Future<void> clearAll();
}
