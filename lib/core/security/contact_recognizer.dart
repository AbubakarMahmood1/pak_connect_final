// File: lib/core/security/contact_recognizer.dart
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import '../../domain/entities/contact.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';

class ContactRecognizer {
  static Future<bool> isKnownContact(String ephemeralHint) async {
    final contactRepo = GetIt.instance<IContactRepository>();
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
    final contactRepo = GetIt.instance<IContactRepository>();
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
