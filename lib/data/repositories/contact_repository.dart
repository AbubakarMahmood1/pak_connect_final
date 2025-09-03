import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

enum TrustStatus { 
  new_contact,
  verified,
  key_changed,
}

class Contact {
  final String publicKey;
  final String displayName;
  final TrustStatus trustStatus;
  final DateTime firstSeen;
  final DateTime lastSeen;
  
  Contact({
    required this.publicKey,
    required this.displayName,
    required this.trustStatus,
    required this.firstSeen,
    required this.lastSeen,
  });
  
  Map<String, dynamic> toJson() => {
    'publicKey': publicKey,
    'displayName': displayName,
    'trustStatus': trustStatus.index,
    'firstSeen': firstSeen.millisecondsSinceEpoch,
    'lastSeen': lastSeen.millisecondsSinceEpoch,
  };
  
  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    publicKey: json['publicKey'],
    displayName: json['displayName'],
    trustStatus: TrustStatus.values[json['trustStatus']],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(json['firstSeen']),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen']),
  );
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
        trustStatus: TrustStatus.new_contact,
        firstSeen: now,
        lastSeen: now,
      );
      await _storeContact(contact);
    } else {
      final updated = Contact(
        publicKey: publicKey,
        displayName: displayName,
        trustStatus: existing.trustStatus,
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
        firstSeen: contact.firstSeen,
        lastSeen: contact.lastSeen,
      );
      await _storeContact(verified);
    }
  }
  
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    final key = _sharedSecretPrefix + publicKey.substring(0, 16);
    await _secureStorage.write(key: key, value: sharedSecret);
  }
  
  Future<String?> getCachedSharedSecret(String publicKey) async {
    final key = _sharedSecretPrefix + publicKey.substring(0, 16);
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
}