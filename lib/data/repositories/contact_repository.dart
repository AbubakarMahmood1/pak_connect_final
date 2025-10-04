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

enum TrustStatus {
  newContact,     // 👤 Identity: Never verified this person
  verified,       // 👤 Identity: Confirmed this is really them
  keyChanged,     // 👤 Identity: Their key changed (security warning)
}

class Contact {
  final String publicKey;
  final String displayName;
  final TrustStatus trustStatus;
  final SecurityLevel securityLevel;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final DateTime? lastSecuritySync;

  Contact({
    required this.publicKey,
    required this.displayName,
    required this.trustStatus,
    required this.securityLevel,
    required this.firstSeen,
    required this.lastSeen,
    this.lastSecuritySync,
  });

  Map<String, dynamic> toJson() => {
    'publicKey': publicKey,
    'displayName': displayName,
    'trustStatus': trustStatus.index,
    'securityLevel': securityLevel.index,
    'firstSeen': firstSeen.millisecondsSinceEpoch,
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'lastSecuritySync': lastSecuritySync?.millisecondsSinceEpoch,
  };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    publicKey: json['publicKey'] ?? json['public_key'],
    displayName: json['displayName'] ?? json['display_name'],
    trustStatus: TrustStatus.values[json['trustStatus'] ?? json['trust_status'] ?? 0],
    securityLevel: SecurityLevel.values[json['securityLevel'] ?? json['security_level'] ?? 0],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(json['firstSeen'] ?? json['first_seen']),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] ?? json['last_seen']),
    lastSecuritySync: json['lastSecuritySync'] != null
      ? DateTime.fromMillisecondsSinceEpoch(json['lastSecuritySync'])
      : (json['last_security_sync'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['last_security_sync'])
        : null),
  );

  /// Convert to database row format
  Map<String, dynamic> toDatabase() => {
    'public_key': publicKey,
    'display_name': displayName,
    'trust_status': trustStatus.index,
    'security_level': securityLevel.index,
    'first_seen': firstSeen.millisecondsSinceEpoch,
    'last_seen': lastSeen.millisecondsSinceEpoch,
    'last_security_sync': lastSecuritySync?.millisecondsSinceEpoch,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  };

  /// Create from database row
  factory Contact.fromDatabase(Map<String, dynamic> row) => Contact(
    publicKey: row['public_key'] as String,
    displayName: row['display_name'] as String,
    trustStatus: TrustStatus.values[row['trust_status'] as int],
    securityLevel: SecurityLevel.values[row['security_level'] as int],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(row['first_seen'] as int),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(row['last_seen'] as int),
    lastSecuritySync: row['last_security_sync'] != null
      ? DateTime.fromMillisecondsSinceEpoch(row['last_security_sync'] as int)
      : null,
  );

  Contact copyWithSecurityLevel(SecurityLevel newLevel) => Contact(
    publicKey: publicKey,
    displayName: displayName,
    trustStatus: trustStatus,
    securityLevel: newLevel,
    firstSeen: firstSeen,
    lastSeen: DateTime.now(),
    lastSecuritySync: DateTime.now(),
  );

  bool get isSecurityStale => lastSecuritySync == null ||
    DateTime.now().difference(lastSecuritySync!).inHours > 24;
}

class ContactRepository {
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

  /// Get all contacts as a map (public key → contact)
  Future<Map<String, Contact>> getAllContacts() async {
    final db = await _db;

    final results = await db.query(
      'contacts',
      orderBy: 'last_seen DESC',
    );

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
      );
      await _storeContact(verified);
    }
  }

  /// Cache shared secret (uses FlutterSecureStorage - NOT database)
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.substring(0, 16);
    await _secureStorage.write(key: key, value: sharedSecret);
  }

  /// Get cached shared secret (from FlutterSecureStorage)
  Future<String?> getCachedSharedSecret(String publicKey) async {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.substring(0, 16);
    return await _secureStorage.read(key: key);
  }

  /// Cache shared seed as bytes (for hint system)
  Future<void> cacheSharedSeedBytes(String publicKey, Uint8List seedBytes) async {
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = '$_sharedSecretPrefix${keyHash.substring(0, 16)}_seed';

    // Convert bytes to base64 for storage
    final base64Seed = base64Encode(seedBytes);
    await _secureStorage.write(key: key, value: base64Seed);
  }

  /// Get cached shared seed as bytes (for hint system)
  Future<Uint8List?> getCachedSharedSeedBytes(String publicKey) async {
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = '$_sharedSecretPrefix${keyHash.substring(0, 16)}_seed';

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
  Future<void> updateContactSecurityLevel(String publicKey, SecurityLevel newLevel) async {
    final contact = await getContact(publicKey);
    if (contact != null) {
      _logger.info('🔧 REPO DEBUG: Updating ${publicKey.substring(0, 8)}... from ${contact.securityLevel.name} to ${newLevel.name}');
      _logger.info('🔧 REPO DEBUG: Contact trust status: ${contact.trustStatus.name}');

      final updatedContact = contact.copyWithSecurityLevel(newLevel);
      await _storeContact(updatedContact);
      _logger.info('🔧 SECURITY: Updated $publicKey to ${newLevel.name} level');
    } else {
      _logger.warning('🔧 REPO DEBUG: Cannot update security level - contact not found');
    }
  }

  /// Get contact's current security level
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async {
    final contact = await getContact(publicKey);
    return contact?.securityLevel ?? SecurityLevel.low;
  }

  /// Downgrade security for deleted contact
  Future<void> downgradeSecurityForDeletedContact(String publicKey, String reason) async {
    final contact = await getContact(publicKey);
    if (contact != null && contact.securityLevel != SecurityLevel.low) {
      _logger.info('🔒 SECURITY DOWNGRADE: $publicKey due to $reason');
      await updateContactSecurityLevel(publicKey, SecurityLevel.low);

      // Also clear any cached secrets
      await _clearCachedSecrets(publicKey);
    }
  }

  /// Upgrade security level (with validation)
  Future<bool> upgradeContactSecurity(String publicKey, SecurityLevel newLevel) async {
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
      _logger.info('🔧 SECURITY: Same level re-initialization: ${current.name}');
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
    _logger.warning('🔧 SECURITY: BLOCKED downgrade attempt from ${current.name} to ${target.name}');
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
        securityLevel: SecurityLevel.low,      // Reset to low
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
      final key = _sharedSecretPrefix + keyHash.substring(0, 16);
      await _secureStorage.delete(key: key);
      _logger.info('🔒 SECURITY: Cleared cached secrets for $publicKey');
    } catch (e) {
      _logger.warning('🔒 SECURITY WARNING: Failed to clear secrets: $e');
    }
  }

  /// Create new contact with explicit security level
  Future<void> saveContactWithSecurity(String publicKey, String displayName, SecurityLevel initialLevel) async {
    final existing = await getContact(publicKey);
    final now = DateTime.now();

    if (existing == null) {
      final contact = Contact(
        publicKey: publicKey,
        displayName: displayName,
        trustStatus: TrustStatus.newContact,
        securityLevel: initialLevel,
        firstSeen: now,
        lastSeen: now,
        lastSecuritySync: now,
      );
      await _storeContact(contact);
      _logger.info('🔒 SECURITY: New contact created with ${initialLevel.name} level');
    } else {
      final updated = Contact(
        publicKey: publicKey,
        displayName: displayName,
        trustStatus: existing.trustStatus,
        securityLevel: existing.securityLevel,
        firstSeen: existing.firstSeen,
        lastSeen: now,
        lastSecuritySync: existing.lastSecuritySync,
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
          _logger.warning('Failed to clear secrets during delete (non-fatal): $e');
        }

        _logger.info('🗑️ Contact deleted: ${publicKey.substring(0, 16)}...');
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
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM contacts');
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
      final sevenDaysAgo = DateTime.now().subtract(Duration(days: 7)).millisecondsSinceEpoch;

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
}
