import 'dart:typed_data';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/services/security_manager.dart';

/// Interface for contact repository operations
///
/// Abstracts contact storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations (e.g., in-memory for tests)
///
/// **Phase 1 Note**: Interface defines all public methods from ContactRepository
abstract class IContactRepository {
  // =========================
  // BASIC CRUD OPERATIONS
  // =========================

  /// Save or update a contact
  Future<void> saveContact(String publicKey, String displayName);

  /// Get a specific contact by public key
  Future<Contact?> getContact(String publicKey);

  /// Get contact by persistent public key (MEDIUM+ identity)
  Future<Contact?> getContactByPersistentKey(String persistentPublicKey);

  /// Get contact by current ephemeral ID (session-specific identifier)
  Future<Contact?> getContactByCurrentEphemeralId(String ephemeralId);

  /// Get contact by ANY identifier (publicKey, persistentPublicKey, OR currentEphemeralId)
  Future<Contact?> getContactByAnyId(String identifier);

  /// Get all contacts as a map (public key → contact)
  Future<Map<String, Contact>> getAllContacts();

  /// Delete contact completely from storage
  Future<bool> deleteContact(String publicKey);

  // =========================
  // SECURITY OPERATIONS
  // =========================

  /// Mark contact as verified
  Future<void> markContactVerified(String publicKey);

  /// Update Noise session data for a contact
  Future<void> updateNoiseSession({
    required String publicKey,
    required String noisePublicKey,
    required String sessionState,
  });

  /// Update contact security level
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel newLevel,
  );

  /// Update contact's current ephemeral ID (session tracking)
  Future<void> updateContactEphemeralId(
    String publicKey,
    String newEphemeralId,
  );

  /// Get contact's current security level
  Future<SecurityLevel> getContactSecurityLevel(String publicKey);

  /// Downgrade security for deleted contact
  Future<void> downgradeSecurityForDeletedContact(
    String publicKey,
    String reason,
  );

  /// Upgrade security level (with validation)
  Future<bool> upgradeContactSecurity(String publicKey, SecurityLevel newLevel);

  /// Reset contact security
  Future<bool> resetContactSecurity(String publicKey, String reason);

  /// Create new contact with explicit security level
  Future<void> saveContactWithSecurity(
    String publicKey,
    String displayName,
    SecurityLevel securityLevel, {
    String? currentEphemeralId,
    String? persistentPublicKey,
  });

  // =========================
  // SECRET CACHING
  // =========================

  /// Cache shared secret (uses FlutterSecureStorage)
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret);

  /// Get cached shared secret
  Future<String?> getCachedSharedSecret(String publicKey);

  /// Cache shared seed as bytes (for hint system)
  Future<void> cacheSharedSeedBytes(String publicKey, Uint8List seedBytes);

  /// Get cached shared seed as bytes
  Future<Uint8List?> getCachedSharedSeedBytes(String publicKey);

  /// Clear cached secrets
  Future<void> clearCachedSecrets(String publicKey);

  // =========================
  // QUERY OPERATIONS
  // =========================

  /// Get contact name by public key
  Future<String?> getContactName(String publicKey);

  // =========================
  // STATISTICS
  // =========================

  /// Get total contact count
  Future<int> getContactCount();

  /// Get verified contact count
  Future<int> getVerifiedContactCount();

  /// Get contact count by security level
  Future<Map<SecurityLevel, int>> getContactsBySecurityLevel();

  /// Get recently active contacts (last 7 days)
  Future<int> getRecentlyActiveContactCount();

  // =========================
  // FAVORITES MANAGEMENT
  // =========================

  /// Mark a contact as favorite
  Future<void> markContactFavorite(String publicKey);

  /// Remove favorite status from a contact
  Future<void> unmarkContactFavorite(String publicKey);

  /// Toggle favorite status for a contact
  Future<bool> toggleContactFavorite(String publicKey);

  /// Get all favorite contacts
  Future<List<Contact>> getFavoriteContacts();

  /// Get count of favorite contacts
  Future<int> getFavoriteContactCount();

  /// Check if a contact is marked as favorite
  Future<bool> isContactFavorite(String publicKey);
}
