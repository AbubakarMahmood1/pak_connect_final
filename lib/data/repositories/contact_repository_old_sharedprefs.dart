// ignore_for_file: avoid_print, constant_identifier_names

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import '../../core/services/security_manager.dart';

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
    publicKey: json['publicKey'],
    displayName: json['displayName'],
    trustStatus: TrustStatus.values[json['trustStatus']],
    securityLevel: SecurityLevel.values[json['securityLevel'] ?? 0],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(json['firstSeen']),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen']),
    lastSecuritySync: json['lastSecuritySync'] != null 
      ? DateTime.fromMillisecondsSinceEpoch(json['lastSecuritySync']) 
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
  static const String _contactsKey = 'enhanced_contacts_v2';
  static const String _sharedSecretPrefix = 'shared_secret_';
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();

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
      );
      await _storeContact(updated);
    }
  }
  
  Future<Contact?> getContact(String publicKey) async {
    final contacts = await getAllContacts();
    return contacts[publicKey];
  }

  Future<Map<String, Contact>> getAllContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getStringList(_contactsKey) ?? [];
    
    final contacts = <String, Contact>{};
    for (final json in contactsJson) {
      try {
        final contact = Contact.fromJson(jsonDecode(json));
        contacts[contact.publicKey] = contact;
      } catch (e) {
        print('Failed to parse contact: $e');
      }
    }
    return contacts;
  }

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
      );
      await _storeContact(verified);
    }
  }
  
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.substring(0, 16);
    await _secureStorage.write(key: key, value: sharedSecret);
  }
  
  Future<String?> getCachedSharedSecret(String publicKey) async {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.substring(0, 16);
    return await _secureStorage.read(key: key);
  }

  Future<String?> getContactName(String publicKey) async {
    final contact = await getContact(publicKey);
    return contact?.displayName;
  }

  Future<void> _storeContact(Contact contact) async {
    final prefs = await SharedPreferences.getInstance();
    final contacts = await getAllContacts();
    
    contacts[contact.publicKey] = contact;
    
    final contactsJson = contacts.values
        .map((contact) => jsonEncode(contact.toJson()))
        .toList();
    
    await prefs.setStringList(_contactsKey, contactsJson);
  }

  /// 🔒 Update contact security level
Future<void> updateContactSecurityLevel(String publicKey, SecurityLevel newLevel) async {
  final contact = await getContact(publicKey);
  if (contact != null) {
    print('🔧 REPO DEBUG: Updating ${publicKey.substring(0,8)}... from ${contact.securityLevel.name} to ${newLevel.name}');
    print('🔧 REPO DEBUG: Contact trust status: ${contact.trustStatus.name}');
    
    final updatedContact = contact.copyWithSecurityLevel(newLevel);
    await _storeContact(updatedContact);
    print('🔧 SECURITY: Updated $publicKey to ${newLevel.name} level');
  } else {
    print('🔧 REPO DEBUG: Cannot update security level - contact not found');
  }
}

/// 🔒 Get contact's current security level
Future<SecurityLevel> getContactSecurityLevel(String publicKey) async {
  final contact = await getContact(publicKey);
  return contact?.securityLevel ?? SecurityLevel.low;
}

/// 🔒 Drop all contacts with this device back to low security (when they delete us)
Future<void> downgradeSecurityForDeletedContact(String publicKey, String reason) async {
  final contact = await getContact(publicKey);
  if (contact != null && contact.securityLevel != SecurityLevel.low) {
    print('🔒 SECURITY DOWNGRADE: $publicKey due to $reason');
    await updateContactSecurityLevel(publicKey, SecurityLevel.low);
    
    // Also clear any cached secrets
    await _clearCachedSecrets(publicKey);
  }
}

/// 🔒 Upgrade security level (with validation)
Future<bool> upgradeContactSecurity(String publicKey, SecurityLevel newLevel) async {
  final contact = await getContact(publicKey);
  if (contact == null) {
    print('🔧 SECURITY: Cannot upgrade non-existent contact');
    return false;
  }

  // Validate upgrade path using secure validation
  if (!_isValidUpgrade(contact.securityLevel, newLevel)) {
    print('🔧 SECURITY: Invalid upgrade blocked');
    return false;
  }

  // Perform the upgrade
  await updateContactSecurityLevel(publicKey, newLevel);
  return true;
}

/// 🔒 Validate security upgrade path
bool _isValidUpgrade(SecurityLevel current, SecurityLevel target) {
  // Allow same level (for re-initialization of keys)
  if (current == target) {
    print('🔧 SECURITY: Same level re-initialization: ${current.name}');
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
  print('🔧 SECURITY: BLOCKED downgrade attempt from ${current.name} to ${target.name}');
  return false;
}

Future<bool> resetContactSecurity(String publicKey, String reason) async {
  print('🔧 SECURITY RESET: $publicKey due to: $reason');
  
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
    print('🔧 SECURITY: Contact reset to low security');
    return true;
  }
  
  return false;
}

/// 🔒 Clear cached secrets when downgrading
Future<void> _clearCachedSecrets(String publicKey) async {
  await clearCachedSecrets(publicKey);
}

Future<void> clearCachedSecrets(String publicKey) async {
  try {
    // Use SHA256 hash of full public key for consistent cache key generation
    final keyHash = sha256.convert(utf8.encode(publicKey)).toString();
    final key = _sharedSecretPrefix + keyHash.substring(0, 16);
    await _secureStorage.delete(key: key);
    print('🔒 SECURITY: Cleared cached secrets for $publicKey');
  } catch (e) {
    print('🔒 SECURITY WARNING: Failed to clear secrets: $e');
  }
}

/// 🔒 Create new contact with explicit security level
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
    print('🔒 SECURITY: New contact created with ${initialLevel.name} level');
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
    final contacts = await getAllContacts();
    if (contacts.containsKey(publicKey)) {
      contacts.remove(publicKey);
      
      final prefs = await SharedPreferences.getInstance();
      final contactsJson = contacts.values
          .map((contact) => jsonEncode(contact.toJson()))
          .toList();
      
      await prefs.setStringList(_contactsKey, contactsJson);
      
      // Also clear any cached secrets
      await clearCachedSecrets(publicKey);
      
      print('🗑️ Contact deleted: ${publicKey.substring(0, 16)}...');
      return true;
    }
    return false;
  } catch (e) {
    print('❌ Failed to delete contact: $e');
    return false;
  }
}
}