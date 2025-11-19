import 'package:flutter/foundation.dart';

import '../interfaces/i_contact_repository.dart';
import 'package:get_it/get_it.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../services/hint_advertisement_service.dart';

class HintCacheManager {
  static final Map<String, ContactHint> _contactCache = {};
  static DateTime? _lastCacheUpdate;
  static int _cacheValidityMinutes = 30;

  static int get cacheSize => _contactCache.length;

  static Future<void> updateCache() async {
    final now = DateTime.now();
    if (_lastCacheUpdate != null &&
        now.difference(_lastCacheUpdate!).inMinutes < _cacheValidityMinutes) {
      return;
    }

    _contactCache.clear();
    final contactRepo = GetIt.instance<IContactRepository>();
    final contacts = await contactRepo.getAllContacts();

    for (final contact in contacts.values) {
      final enhancedContact = EnhancedContact(
        contact: contact,
        lastSeenAgo: DateTime.now().difference(contact.lastSeen),
        isRecentlyActive:
            DateTime.now().difference(contact.lastSeen).inHours < 24,
        interactionCount: 0,
        averageResponseTime: const Duration(minutes: 5),
        groupMemberships: const [],
      );
      _contactCache[contact.publicKey] = ContactHint(enhancedContact);
    }

    _lastCacheUpdate = now;
    if (kDebugMode) {
      print('✅ Hint contact cache refreshed: ${_contactCache.length} entries');
    }
  }

  static Future<ContactHint?> matchBlindedHint({
    required Uint8List nonce,
    required Uint8List hintBytes,
  }) async {
    await updateCache();
    return _matchFromCache(nonce, hintBytes);
  }

  static ContactHint? matchBlindedHintSync({
    required Uint8List nonce,
    required Uint8List hintBytes,
  }) {
    if (_contactCache.isEmpty) {
      return null;
    }
    return _matchFromCache(nonce, hintBytes);
  }

  static ContactHint? _matchFromCache(Uint8List nonce, Uint8List hintBytes) {
    for (final entry in _contactCache.values) {
      final identifier = entry.contact.contact.chatId;
      final expected = HintAdvertisementService.computeHintBytes(
        identifier: identifier,
        nonce: nonce,
      );

      if (_bytesEqual(expected, hintBytes)) {
        return entry;
      }
    }

    return null;
  }

  static void clearCache() {
    _contactCache.clear();
    _lastCacheUpdate = null;
  }

  static void dispose() {
    clearCache();
  }

  static void onSessionRotated() {
    clearCache();
    if (kDebugMode) {
      print('♻️ Hint cache invalidated after session rotation');
    }
  }

  static void setCacheValidity(int minutes) {
    _cacheValidityMinutes = minutes;
    clearCache();
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class ContactHint {
  final EnhancedContact contact;

  ContactHint(this.contact);
}
