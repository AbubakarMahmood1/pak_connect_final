// File: lib/core/security/contact_recognizer.dart
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import '../../domain/entities/contact.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';

class ContactRecognizer {
  static IContactRepository? _contactRepository;

  static void configureContactRepository(IContactRepository contactRepository) {
    _contactRepository = contactRepository;
  }

  static void clearContactRepository() {
    _contactRepository = null;
  }

  static bool get isConfigured => _contactRepository != null;

  static Future<bool> isKnownContact(String ephemeralHint) async {
    final contactRepo = _contactRepository;
    if (contactRepo == null) {
      return false;
    }
    final contacts = await contactRepo.getAllContacts();

    // Check against all contacts (Phase 2 will optimize this)
    for (final contact in contacts.values) {
      final sharedSecret = await contactRepo.getCachedSharedSecret(
        contact.publicKey,
      );
      if (sharedSecret != null) {
        final expectedHint = EphemeralKeyManager.generateContactHint(
          contact.publicKey,
          sharedSecret,
        );
        if (expectedHint == ephemeralHint) {
          return true;
        }
      }
    }
    return false;
  }

  // Get contact info from ephemeral hint
  static Future<Contact?> getContactFromHint(String ephemeralHint) async {
    final contactRepo = _contactRepository;
    if (contactRepo == null) {
      return null;
    }
    final contacts = await contactRepo.getAllContacts();

    for (final contact in contacts.values) {
      final sharedSecret = await contactRepo.getCachedSharedSecret(
        contact.publicKey,
      );
      if (sharedSecret != null) {
        final expectedHint = EphemeralKeyManager.generateContactHint(
          contact.publicKey,
          sharedSecret,
        );
        if (expectedHint == ephemeralHint) {
          return contact;
        }
      }
    }
    return null;
  }
}
