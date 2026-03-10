import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';

class HintCacheManager {
  static final _logger = Logger('HintCacheManager');
  static final Map<String, ContactHint> _contactCache = {};
  static DateTime? _lastCacheUpdate;
  static int _cacheValidityMinutes = 30;
  static IContactRepository? _contactRepository;

  static int get cacheSize => _contactCache.length;

  static void configureContactRepository({
    required IContactRepository contactRepository,
  }) {
    _contactRepository = contactRepository;
  }

  static void clearContactRepository() {
    _contactRepository = null;
  }

  static Future<void> updateCache() async {
    final now = DateTime.now();
    if (_lastCacheUpdate != null &&
        now.difference(_lastCacheUpdate!).inMinutes < _cacheValidityMinutes) {
      return;
    }

    _contactCache.clear();
    final contactRepo = _contactRepository;
    if (contactRepo == null) {
      if (kDebugMode) {
        _logger.warning(
          '⚠️ Hint cache skipped: contact repository is not configured',
        );
      }
      return;
    }
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
      _logger.info(
        '✅ Hint contact cache refreshed: ${_contactCache.length} entries',
      );
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
    // Privacy hardening: deterministic hint matching using public chatId is
    // disabled. Contact IDs are public, so deriving hints from them allows
    // eavesdroppers to recompute and link advertisements. Only intro-hint
    // based matching (handled by the intro hint repository) is safe.
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
      _logger.info('♻️ Hint cache invalidated after session rotation');
    }
  }

  static void setCacheValidity(int minutes) {
    _cacheValidityMinutes = minutes;
    clearCache();
  }
}

class ContactHint {
  final EnhancedContact contact;

  ContactHint(this.contact);
}
