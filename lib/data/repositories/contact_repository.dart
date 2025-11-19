// SQLite-based contact repository with security levels and trust management
// Replaces SharedPreferences with efficient database queries

import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import '../../core/services/security_manager.dart';
import '../database/database_helper.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../core/interfaces/i_contact_repository.dart';

enum TrustStatus {
  newContact, // 👤 Identity: Never verified this person
  verified, // 👤 Identity: Confirmed this is really them
  keyChanged, // 👤 Identity: Their key changed (security warning)
}

class Contact {
  final String
  publicKey; // IMMUTABLE: First contact ID (never changes, primary key)
  final String?
  persistentPublicKey; // Persistent identity (NULL at LOW, set at MEDIUM+)
  final String?
  currentEphemeralId; // Active Noise session ID (updates on reconnect)

  final String displayName;
  final TrustStatus trustStatus;
  final SecurityLevel securityLevel;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final DateTime? lastSecuritySync;

  // Noise Protocol fields (Phase 2 integration)
  final String?
  noisePublicKey; // Base64-encoded peer Noise static public key (44 chars)
  final String?
  noiseSessionState; // Session lifecycle state (uninitialized/handshaking/established/expired)
  final DateTime? lastHandshakeTime; // When Noise session was last established

  // Favorites support (Phase 2.5)
  final bool isFavorite; // True if user marked this contact as favorite

  Contact({
    required this.publicKey,
    this.persistentPublicKey,
    this.currentEphemeralId,
    required this.displayName,
    required this.trustStatus,
    required this.securityLevel,
    required this.firstSeen,
    required this.lastSeen,
    this.lastSecuritySync,
    this.noisePublicKey,
    this.noiseSessionState,
    this.lastHandshakeTime,
    this.isFavorite = false,
  });

  /// 🔧 MODEL: Get the chat ID for this contact
  /// - At LOW: Use publicKey (first ephemeral ID, temporary chat)
  /// - At MEDIUM+: Use persistentPublicKey (permanent chat identity)
  String get chatId => persistentPublicKey ?? publicKey;

  /// 🔧 MODEL: Get the session ID for Noise Protocol lookup
  /// Noise sessions are ALWAYS indexed by currentEphemeralId
  String? get sessionIdForNoise => currentEphemeralId ?? publicKey;

  Map<String, dynamic> toJson() => {
    'publicKey': publicKey,
    'persistentPublicKey': persistentPublicKey,
    'currentEphemeralId': currentEphemeralId,
    'displayName': displayName,
    'trustStatus': trustStatus.index,
    'securityLevel': securityLevel.index,
    'firstSeen': firstSeen.millisecondsSinceEpoch,
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'lastSecuritySync': lastSecuritySync?.millisecondsSinceEpoch,
    'noisePublicKey': noisePublicKey,
    'noiseSessionState': noiseSessionState,
    'lastHandshakeTime': lastHandshakeTime?.millisecondsSinceEpoch,
    'isFavorite': isFavorite,
  };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    publicKey: json['publicKey'] ?? json['public_key'],
    persistentPublicKey:
        json['persistentPublicKey'] ?? json['persistent_public_key'],
    currentEphemeralId:
        json['currentEphemeralId'] ?? json['current_ephemeral_id'],
    displayName: json['displayName'] ?? json['display_name'],
    trustStatus:
        TrustStatus.values[json['trustStatus'] ?? json['trust_status'] ?? 0],
    securityLevel: SecurityLevel
        .values[json['securityLevel'] ?? json['security_level'] ?? 0],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(
      json['firstSeen'] ?? json['first_seen'],
    ),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(
      json['lastSeen'] ?? json['last_seen'],
    ),
    lastSecuritySync: json['lastSecuritySync'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastSecuritySync'])
        : (json['last_security_sync'] != null
              ? DateTime.fromMillisecondsSinceEpoch(json['last_security_sync'])
              : null),
    noisePublicKey: json['noisePublicKey'] ?? json['noise_public_key'],
    noiseSessionState: json['noiseSessionState'] ?? json['noise_session_state'],
    lastHandshakeTime: json['lastHandshakeTime'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastHandshakeTime'])
        : (json['last_handshake_time'] != null
              ? DateTime.fromMillisecondsSinceEpoch(json['last_handshake_time'])
              : null),
    isFavorite: (json['isFavorite'] ?? json['is_favorite'] ?? 0) == 1,
  );

  /// Convert to database row format
  Map<String, dynamic> toDatabase() => {
    'public_key': publicKey,
    'persistent_public_key': persistentPublicKey,
    'current_ephemeral_id': currentEphemeralId,
    'display_name': displayName,
    'trust_status': trustStatus.index,
    'security_level': securityLevel.index,
    'first_seen': firstSeen.millisecondsSinceEpoch,
    'last_seen': lastSeen.millisecondsSinceEpoch,
    'last_security_sync': lastSecuritySync?.millisecondsSinceEpoch,
    'noise_public_key': noisePublicKey,
    'noise_session_state': noiseSessionState,
    'last_handshake_time': lastHandshakeTime?.millisecondsSinceEpoch,
    'is_favorite': isFavorite ? 1 : 0,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  };

  /// Create from database row
  factory Contact.fromDatabase(Map<String, dynamic> row) => Contact(
    publicKey: row['public_key'] as String,
    persistentPublicKey: row['persistent_public_key'] as String?,
    currentEphemeralId: row['current_ephemeral_id'] as String?,
    displayName: row['display_name'] as String,
    trustStatus: TrustStatus.values[row['trust_status'] as int],
    securityLevel: SecurityLevel.values[row['security_level'] as int],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(row['first_seen'] as int),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(row['last_seen'] as int),
    lastSecuritySync: row['last_security_sync'] != null
        ? DateTime.fromMillisecondsSinceEpoch(row['last_security_sync'] as int)
        : null,
    noisePublicKey: row['noise_public_key'] as String?,
    noiseSessionState: row['noise_session_state'] as String?,
    lastHandshakeTime: row['last_handshake_time'] != null
        ? DateTime.fromMillisecondsSinceEpoch(row['last_handshake_time'] as int)
        : null,
    isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
  );

  Contact copyWithSecurityLevel(SecurityLevel newLevel) => Contact(
    publicKey: publicKey,
    persistentPublicKey: persistentPublicKey,
    currentEphemeralId: currentEphemeralId,
    displayName: displayName,
    trustStatus: trustStatus,
    securityLevel: newLevel,
    firstSeen: firstSeen,
    lastSeen: DateTime.now(),
    lastSecuritySync: DateTime.now(),
    noisePublicKey: noisePublicKey,
    noiseSessionState: noiseSessionState,
    lastHandshakeTime: lastHandshakeTime,
    isFavorite: isFavorite,
  );

  bool get isSecurityStale =>
      lastSecuritySync == null ||
      DateTime.now().difference(lastSecuritySync!).inHours > 24;
}

class ContactRepository implements IContactRepository {
  static final _logger = Logger('ContactRepository');
  static const String _sharedSecretPrefix = 'shared_secret_';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Get database instance
  Future<Database> get _db async => await DatabaseHelper.database;

  /// Save or update a contact
  Future<void> saveContact(String publicKey, String displayName) async {
    final existing = await getContact(publicKey);
    final now = DateTime.now();

    if (existing == null) {
      final contact = Contact(
        publicKey: publicKey,
        displayName: displayName,
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: now,
        lastSeen: now,
      );
      await _storeContact(contact);
    } else {
      final updated = Contact(
        publicKey: publicKey,
        displayName: displayName,
        trustStatus: existing.trustStatus,
        securityLevel: existing.securityLevel,
        firstSeen: existing.firstSeen,
        lastSeen: now,
        lastSecuritySync: existing.lastSecuritySync,
        noisePublicKey: existing.noisePublicKey,
        noiseSessionState: existing.noiseSessionState,
        lastHandshakeTime: existing.lastHandshakeTime,
        isFavorite: existing.isFavorite,
      );
      await _storeContact(updated);
    }
  }

  /// Get a specific contact by public key
  Future<Contact?> getContact(String publicKey) async {
    final db = await _db;

    final results = await db.query(
      'contacts',
      where: 'public_key = ?',
      whereArgs: [publicKey],
      limit: 1,
    );

    if (results.isEmpty) return null;

    return Contact.fromDatabase(results.first);
  }

  /// 🔧 NEW MODEL: Get contact by persistent public key (MEDIUM+ identity)
  Future<Contact?> getContactByPersistentKey(String persistentPublicKey) async {
    final db = await _db;

    final results = await db.query(
      'contacts',
      where: 'persistent_public_key = ?',
      whereArgs: [persistentPublicKey],
      limit: 1,
    );

    if (results.isEmpty) return null;

    return Contact.fromDatabase(results.first);
  }

  /// 🔧 NEW MODEL: Get contact by current ephemeral ID (session-specific identifier)
  /// Used when looking up contacts by their active session ID
  Future<Contact?> getContactByCurrentEphemeralId(String ephemeralId) async {
    final db = await _db;

    final results = await db.query(
      'contacts',
      where: 'current_ephemeral_id = ?',
      whereArgs: [ephemeralId],
      limit: 1,
    );

    if (results.isEmpty) return null;

    return Contact.fromDatabase(results.first);
  }

  /// 🔧 ENHANCED: Get contact by ANY identifier (publicKey, persistentPublicKey, OR currentEphemeralId)
  /// This is the most comprehensive lookup and should be used when identifier type is unknown.
  ///
  /// Tries lookups in order of performance:
  /// 1. publicKey (primary key - fastest, O(1))
  /// 2. persistentPublicKey (indexed - fast, O(log n))
  /// 3. currentEphemeralId (indexed - fast, O(log n))
  ///
  /// Real-world scenarios handled:
  /// - First connection: identifier = ephemeralId (matches publicKey)
  /// - Reconnection with new ephemeral: identifier = new ephemeralId (matches currentEphemeralId)
  /// - After MEDIUM+ pairing: identifier = persistentKey (matches persistentPublicKey)
  /// - Repository mode with "repo_" prefix: identifier could be any of the above
  Future<Contact?> getContactByAnyId(String identifier) async {
    // Try by publicKey first (primary key - fastest)
    var contact = await getContact(identifier);
    if (contact != null) return contact;

    // Try by persistentPublicKey (indexed - still fast)
    contact = await getContactByPersistentKey(identifier);
    if (contact != null) return contact;

    // Try by currentEphemeralId (handles reconnections with new ephemeral IDs)
    contact = await getContactByCurrentEphemeralId(identifier);
    return contact;
  }

  /// Get all contacts as a map (public key → contact)
  Future<Map<String, Contact>> getAllContacts() async {
    final db = await _db;

    final results = await db.query('contacts', orderBy: 'last_seen DESC');

    final contacts = <String, Contact>{};
    for (final row in results) {
      try {
        final contact = Contact.fromDatabase(row);
        contacts[contact.publicKey] = contact;
      } catch (e) {
        _logger.warning('Failed to parse contact from database: $e');
      }
    }

    return contacts;
  }

  /// Mark contact as verified
  Future<void> markContactVerified(String publicKey) async {
    final contact = await getContact(publicKey);
    if (contact != null) {
      final verified = Contact(
        publicKey: contact.publicKey,
        displayName: contact.displayName,
        trustStatus: TrustStatus.verified,
        securityLevel: contact.securityLevel,
        firstSeen: contact.firstSeen,
        lastSeen: contact.lastSeen,
        lastSecuritySync: contact.lastSecuritySync,
        noisePublicKey: contact.noisePublicKey,
        noiseSessionState: contact.noiseSessionState,
        lastHandshakeTime: contact.lastHandshakeTime,
        isFavorite: contact.isFavorite,
      );
      await _storeContact(verified);
    }
  }

  /// Update Noise session data for a contact (Phase 2 integration)
  Future<void> updateNoiseSession({
    required String publicKey,
    required String noisePublicKey,
    required String sessionState,
  }) async {
    final contact = await getContact(publicKey);
    if (contact != null) {
      final now = DateTime.now();
      final existingHandshake = contact.lastHandshakeTime;
      final shouldRefreshTimestamp = sessionState == 'established';
      final resolvedHandshakeTime = shouldRefreshTimestamp
          ? (existingHandshake == null || now.isAfter(existingHandshake)
                ? now
                : existingHandshake)
          : existingHandshake;

      final updated = Contact(
        publicKey: contact.publicKey,
        displayName: contact.displayName,
        trustStatus: contact.trustStatus,
        securityLevel: contact.securityLevel,
        firstSeen: contact.firstSeen,
        lastSeen: contact.lastSeen,
        lastSecuritySync: contact.lastSecuritySync,
        noisePublicKey: noisePublicKey,
        noiseSessionState: sessionState,
        lastHandshakeTime: resolvedHandshakeTime,
        isFavorite: contact.isFavorite,
      );
      await _storeContact(updated);
      final keyPreview = publicKey.length > 8
          ? publicKey.shortId(8)
          : publicKey;
      _logger.info(
        '🔐 Updated Noise session for $keyPreview... (state: $sessionState)',
      );
    } else {
      final keyPreview = publicKey.length > 8
          ? publicKey.shortId(8)
          : publicKey;
      _logger.warning(
        'Cannot update Noise session - contact not found: $keyPreview...',
      );
    }
  }

  /// Cache shared secret (uses FlutterSecureStorage - NOT database)
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.shortId();
    await _secureStorage.write(key: key, value: sharedSecret);
  }

  /// Get cached shared secret (from FlutterSecureStorage)
  Future<String?> getCachedSharedSecret(String publicKey) async {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.shortId();
    return await _secureStorage.read(key: key);
  }

  /// Cache shared seed as bytes (for hint system)
  Future<void> cacheSharedSeedBytes(
    String publicKey,
    Uint8List seedBytes,
  ) async {
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = '$_sharedSecretPrefix${keyHash.shortId()}_seed';

    // Convert bytes to base64 for storage
    final base64Seed = base64Encode(seedBytes);
    await _secureStorage.write(key: key, value: base64Seed);
  }

  /// Get cached shared seed as bytes (for hint system)
  Future<Uint8List?> getCachedSharedSeedBytes(String publicKey) async {
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = '$_sharedSecretPrefix${keyHash.shortId()}_seed';

    final base64Seed = await _secureStorage.read(key: key);
    if (base64Seed == null) return null;

    try {
      return Uint8List.fromList(base64Decode(base64Seed));
    } catch (e) {
      _logger.warning('Failed to decode shared seed for $publicKey: $e');
      return null;
    }
  }

  /// Get contact name by public key
  Future<String?> getContactName(String publicKey) async {
    final contact = await getContact(publicKey);
    return contact?.displayName;
  }

  /// Update contact security level
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    final contact = await getContact(publicKey);
    if (contact != null) {
      _logger.info(
        '🔧 REPO DEBUG: Updating ${publicKey.shortId(8)}... from ${contact.securityLevel.name} to ${newLevel.name}',
      );
      _logger.info(
        '🔧 REPO DEBUG: Contact trust status: ${contact.trustStatus.name}',
      );

      final updatedContact = contact.copyWithSecurityLevel(newLevel);
      await _storeContact(updatedContact);
      _logger.info('🔧 SECURITY: Updated $publicKey to ${newLevel.name} level');
    } else {
      _logger.warning(
        '🔧 REPO DEBUG: Cannot update security level - contact not found',
      );
    }
  }

  /// Update contact's current ephemeral ID (session tracking)
  Future<void> updateContactEphemeralId(
    String publicKey,
    String newEphemeralId,
  ) async {
    final db = await _db;
    await db.update(
      'contacts',
      {'current_ephemeral_id': newEphemeralId},
      where: 'public_key = ?',
      whereArgs: [publicKey],
    );
    _logger.info(
      '🔧 REPO: Updated current_ephemeral_id for ${publicKey.shortId(8)}... to ${newEphemeralId.shortId(8)}...',
    );
  }

  /// Get contact's current security level
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async {
    final contact = await getContact(publicKey);
    return contact?.securityLevel ?? SecurityLevel.low;
  }

  /// Downgrade security for deleted contact
  Future<void> downgradeSecurityForDeletedContact(
    String publicKey,
    String reason,
  ) async {
    final contact = await getContact(publicKey);
    if (contact != null && contact.securityLevel != SecurityLevel.low) {
      _logger.info('🔒 SECURITY DOWNGRADE: $publicKey due to $reason');
      await updateContactSecurityLevel(publicKey, SecurityLevel.low);

      // Also clear any cached secrets
      await _clearCachedSecrets(publicKey);
    }
  }

  /// Upgrade security level (with validation)
  Future<bool> upgradeContactSecurity(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    final contact = await getContact(publicKey);
    if (contact == null) {
      _logger.warning('🔧 SECURITY: Cannot upgrade non-existent contact');
      return false;
    }

    // Validate upgrade path using secure validation
    if (!_isValidUpgrade(contact.securityLevel, newLevel)) {
      _logger.warning('🔧 SECURITY: Invalid upgrade blocked');
      return false;
    }

    // Perform the upgrade
    await updateContactSecurityLevel(publicKey, newLevel);
    return true;
  }

  /// Validate security upgrade path
  bool _isValidUpgrade(SecurityLevel current, SecurityLevel target) {
    // Allow same level (for re-initialization of keys)
    if (current == target) {
      _logger.info(
        '🔧 SECURITY: Same level re-initialization: ${current.name}',
      );
      return true;
    }

    // Only allow UPGRADES, never downgrades (except through explicit reset)
    if (target.index > current.index) {
      // Validate proper upgrade path
      switch (target) {
        case SecurityLevel.low:
          return true; // This case shouldn't happen (upgrading TO low)
        case SecurityLevel.medium:
          return current == SecurityLevel.low; // low -> medium only
        case SecurityLevel.high:
          return current == SecurityLevel.medium; // medium -> high only
      }
    }

    // BLOCK all downgrades - they must go through explicit security reset
    _logger.warning(
      '🔧 SECURITY: BLOCKED downgrade attempt from ${current.name} to ${target.name}',
    );
    return false;
  }

  /// Reset contact security
  Future<bool> resetContactSecurity(String publicKey, String reason) async {
    _logger.info('🔧 SECURITY RESET: $publicKey due to: $reason');

    // Clear all security artifacts
    await clearCachedSecrets(publicKey);

    // Reset to low security
    final contact = await getContact(publicKey);
    if (contact != null) {
      final resetContact = Contact(
        publicKey: contact.publicKey,
        displayName: contact.displayName,
        trustStatus: TrustStatus.newContact, // Reset trust
        securityLevel: SecurityLevel.low, // Reset to low
        firstSeen: contact.firstSeen,
        lastSeen: DateTime.now(),
        lastSecuritySync: DateTime.now(),
      );

      await _storeContact(resetContact);
      _logger.info('🔧 SECURITY: Contact reset to low security');
      return true;
    }

    return false;
  }

  /// Clear cached secrets (private)
  Future<void> _clearCachedSecrets(String publicKey) async {
    await clearCachedSecrets(publicKey);
  }

  /// Clear cached secrets (public)
  Future<void> clearCachedSecrets(String publicKey) async {
    try {
      // Use SHA256 hash of full public key for consistent cache key generation
      final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
      final key = _sharedSecretPrefix + keyHash.shortId();
      await _secureStorage.delete(key: key);
      _logger.info('🔒 SECURITY: Cleared cached secrets for $publicKey');
    } catch (e) {
      _logger.warning('🔒 SECURITY WARNING: Failed to clear secrets: $e');
    }
  }

  /// Create new contact with explicit security level
  /// 🔧 NEW MODEL: Immutable publicKey, separate persistent identity
  ///
  /// At LOW security:
  ///   - publicKey = first ephemeral ID (never changes, primary key)
  ///   - persistentPublicKey = NULL
  ///   - currentEphemeralId = current session ID (same as publicKey initially)
  ///
  /// At MEDIUM+ security:
  ///   - publicKey = still first ephemeral ID (unchanged)
  ///   - persistentPublicKey = real persistent key (set during upgrade)
  ///   - currentEphemeralId = current session ID (updates on reconnect)
  Future<void> saveContactWithSecurity(
    String publicKey, // Immutable: first ephemeral ID or existing publicKey
    String displayName,
    SecurityLevel securityLevel, {
    String? currentEphemeralId, // Current session ID
    String? persistentPublicKey, // Persistent identity (NULL at LOW)
  }) async {
    final existing = await getContact(publicKey);
    final now = DateTime.now();

    if (existing == null) {
      final contact = Contact(
        publicKey: publicKey, // Immutable primary key
        persistentPublicKey: persistentPublicKey, // NULL at LOW, set at MEDIUM+
        currentEphemeralId: currentEphemeralId ?? publicKey,
        displayName: displayName,
        trustStatus: TrustStatus.newContact,
        securityLevel: securityLevel,
        firstSeen: now,
        lastSeen: now,
        lastSecuritySync: now,
      );
      await _storeContact(contact);

      _logger.info('🔒 SECURITY: New contact (${securityLevel.name})');
      _logger.info('   publicKey (immutable): ${publicKey.shortId()}...');
      _logger.info(
        '   persistentPublicKey: ${persistentPublicKey?.shortId() ?? "NULL"}',
      );
      _logger.info(
        '   currentEphemeralId: ${(currentEphemeralId ?? publicKey).shortId()}...',
      );
    } else {
      // Contact exists - update fields
      final updated = Contact(
        publicKey: publicKey, // Never changes
        persistentPublicKey:
            persistentPublicKey ?? existing.persistentPublicKey,
        currentEphemeralId: currentEphemeralId ?? existing.currentEphemeralId,
        displayName: displayName,
        trustStatus: existing.trustStatus,
        securityLevel: securityLevel,
        firstSeen: existing.firstSeen,
        lastSeen: now,
        lastSecuritySync: existing.lastSecuritySync,
        noisePublicKey: existing.noisePublicKey,
        noiseSessionState: existing.noiseSessionState,
        lastHandshakeTime: existing.lastHandshakeTime,
        isFavorite: existing.isFavorite,
      );
      await _storeContact(updated);
    }
  }

  /// Delete contact completely from storage
  Future<bool> deleteContact(String publicKey) async {
    try {
      final db = await _db;

      final rowsDeleted = await db.delete(
        'contacts',
        where: 'public_key = ?',
        whereArgs: [publicKey],
      );

      if (rowsDeleted > 0) {
        // Try to clear cached secrets (best effort - don't fail if this fails)
        try {
          await clearCachedSecrets(publicKey);
        } catch (e) {
          _logger.warning(
            'Failed to clear secrets during delete (non-fatal): $e',
          );
        }

        _logger.info('🗑️ Contact deleted: ${publicKey.shortId()}...');
        return true;
      }

      return false;
    } catch (e) {
      _logger.severe('❌ Failed to delete contact: $e');
      return false;
    }
  }

  /// Store contact in database (private helper)
  Future<void> _storeContact(Contact contact) async {
    final db = await _db;

    final data = contact.toDatabase();
    data['created_at'] = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'contacts',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // =========================
  // STATISTICS METHODS
  // =========================

  /// Get total contact count
  Future<int> getContactCount() async {
    try {
      final db = await _db;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM contacts',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get contact count: $e');
      return 0;
    }
  }

  /// Get verified contact count
  Future<int> getVerifiedContactCount() async {
    try {
      final db = await _db;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM contacts WHERE trust_status = ?',
        [TrustStatus.verified.index],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get verified contact count: $e');
      return 0;
    }
  }

  /// Get contact count by security level
  Future<Map<SecurityLevel, int>> getContactsBySecurityLevel() async {
    try {
      final db = await _db;
      final Map<SecurityLevel, int> counts = {};

      for (final level in SecurityLevel.values) {
        final result = await db.rawQuery(
          'SELECT COUNT(*) as count FROM contacts WHERE security_level = ?',
          [level.index],
        );
        counts[level] = Sqflite.firstIntValue(result) ?? 0;
      }

      return counts;
    } catch (e) {
      _logger.warning('Failed to get contacts by security level: $e');
      return {};
    }
  }

  /// Get recently active contacts (last 7 days)
  Future<int> getRecentlyActiveContactCount() async {
    try {
      final db = await _db;
      final sevenDaysAgo = DateTime.now()
          .subtract(Duration(days: 7))
          .millisecondsSinceEpoch;

      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM contacts WHERE last_seen >= ?',
        [sevenDaysAgo],
      );

      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get recently active contact count: $e');
      return 0;
    }
  }

  // =========================
  // FAVORITES MANAGEMENT
  // =========================

  /// Mark a contact as favorite
  Future<void> markContactFavorite(String publicKey) async {
    final contact = await getContact(publicKey);
    if (contact == null) {
      _logger.warning(
        'Cannot mark non-existent contact as favorite: ${publicKey.shortId(8)}...',
      );
      return;
    }

    if (contact.isFavorite) {
      _logger.fine(
        'Contact already marked as favorite: ${publicKey.shortId(8)}...',
      );
      return;
    }

    final db = await _db;
    await db.update(
      'contacts',
      {'is_favorite': 1, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'public_key = ?',
      whereArgs: [publicKey],
    );

    _logger.info('⭐ Marked contact as favorite: ${publicKey.shortId(8)}...');
  }

  /// Remove favorite status from a contact
  Future<void> unmarkContactFavorite(String publicKey) async {
    final contact = await getContact(publicKey);
    if (contact == null) {
      _logger.warning(
        'Cannot unmark non-existent contact: ${publicKey.shortId(8)}...',
      );
      return;
    }

    if (!contact.isFavorite) {
      _logger.fine(
        'Contact is not marked as favorite: ${publicKey.shortId(8)}...',
      );
      return;
    }

    final db = await _db;
    await db.update(
      'contacts',
      {'is_favorite': 0, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'public_key = ?',
      whereArgs: [publicKey],
    );

    _logger.info(
      'Removed favorite status from contact: ${publicKey.shortId(8)}...',
    );
  }

  /// Toggle favorite status for a contact
  Future<bool> toggleContactFavorite(String publicKey) async {
    final contact = await getContact(publicKey);
    if (contact == null) {
      _logger.warning(
        'Cannot toggle favorite for non-existent contact: ${publicKey.shortId(8)}...',
      );
      return false;
    }

    if (contact.isFavorite) {
      await unmarkContactFavorite(publicKey);
      return false;
    } else {
      await markContactFavorite(publicKey);
      return true;
    }
  }

  /// Get all favorite contacts
  Future<List<Contact>> getFavoriteContacts() async {
    final db = await _db;

    final results = await db.query(
      'contacts',
      where: 'is_favorite = 1',
      orderBy: 'last_seen DESC',
    );

    final favorites = <Contact>[];
    for (final row in results) {
      try {
        favorites.add(Contact.fromDatabase(row));
      } catch (e) {
        _logger.warning('Failed to parse favorite contact: $e');
      }
    }

    return favorites;
  }

  /// Get count of favorite contacts
  Future<int> getFavoriteContactCount() async {
    try {
      final db = await _db;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM contacts WHERE is_favorite = 1',
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _logger.warning('Failed to get favorite contact count: $e');
      return 0;
    }
  }

  /// Check if a contact is marked as favorite
  Future<bool> isContactFavorite(String publicKey) async {
    final contact = await getContact(publicKey);
    return contact?.isFavorite ?? false;
  }
}
