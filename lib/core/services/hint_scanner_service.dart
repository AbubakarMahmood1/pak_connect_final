// File: lib/core/services/hint_scanner_service.dart

import 'dart:typed_data';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../../data/repositories/contact_repository.dart';
import '../interfaces/i_repository_provider.dart';
import '../utils/app_logger.dart';
import 'hint_advertisement_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:get_it/get_it.dart';

/// Result of hint matching
class HintMatchResult {
  final HintMatchType type;
  final String? contactPublicKey;
  final String? contactName;
  final EphemeralDiscoveryHint? introHint;

  HintMatchResult._({
    required this.type,
    this.contactPublicKey,
    this.contactName,
    this.introHint,
  });

  factory HintMatchResult.contact({
    required String publicKey,
    required String name,
  }) {
    return HintMatchResult._(
      type: HintMatchType.contact,
      contactPublicKey: publicKey,
      contactName: name,
    );
  }

  factory HintMatchResult.intro({required EphemeralDiscoveryHint hint}) {
    return HintMatchResult._(type: HintMatchType.intro, introHint: hint);
  }

  factory HintMatchResult.stranger() {
    return HintMatchResult._(type: HintMatchType.stranger);
  }

  bool get isContact => type == HintMatchType.contact;
  bool get isIntro => type == HintMatchType.intro;
  bool get isStranger => type == HintMatchType.stranger;

  @override
  String toString() {
    switch (type) {
      case HintMatchType.contact:
        return 'Contact: $contactName';
      case HintMatchType.intro:
        return 'Intro: ${introHint?.displayName ?? "unknown"}';
      case HintMatchType.stranger:
        return 'Stranger';
    }
  }
}

enum HintMatchType {
  contact, // Matched against cached contact hints (Level 2)
  intro, // Matched against active intro hints (Level 1)
  stranger, // No match
}

/// Service for scanning and matching discovered hints
class HintScannerService {
  final _logger = AppLogger.getLogger(LoggerNames.hintSystem);

  /// Cache of contacts keyed by identifier (public key)
  final Map<String, Contact> _contactCache = {};

  /// Active intro hints (from QR scans we did)
  final Map<String, EphemeralDiscoveryHint> _activeIntroHints = {};

  /// Provider for accessing repositories
  final IRepositoryProvider _repositoryProvider;

  HintScannerService({IRepositoryProvider? repositoryProvider})
    : _repositoryProvider =
          repositoryProvider ?? GetIt.instance<IRepositoryProvider>();

  /// Initialize scanner by precomputing all contact hints
  Future<void> initialize() async {
    await _rebuildContactCache();
    _logger.info(
      '✅ HintScannerService initialized with ${_contactCache.length} contacts',
    );
  }

  /// Rebuild contact hint cache (call after new pairing)
  Future<void> _rebuildContactCache() async {
    _contactCache.clear();

    final contacts = await _repositoryProvider.contactRepository
        .getAllContacts();
    for (final entry in contacts.entries) {
      _contactCache[entry.key] = entry.value;
    }

    _logger.info('🔄 Contact cache rebuilt: ${_contactCache.length} entries');
  }

  /// Add active intro hint (from QR scan)
  void addActiveIntroHint(EphemeralDiscoveryHint hint) {
    if (hint.isUsable) {
      _activeIntroHints[hint.hintHex] = hint;
      _logger.info(
        '📝 Added active intro hint: ${hint.hintHex} (${hint.displayName})',
      );
    }
  }

  /// Remove intro hint (after successful pairing or expiration)
  void removeIntroHint(String hintHex) {
    _activeIntroHints.remove(hintHex);
    _logger.info('🗑️ Removed intro hint: $hintHex');
  }

  /// Clean up expired intro hints
  void cleanupExpiredIntros() {
    final expired = _activeIntroHints.entries
        .where((e) => e.value.isExpired)
        .map((e) => e.key)
        .toList();

    for (final key in expired) {
      _activeIntroHints.remove(key);
    }

    if (expired.isNotEmpty) {
      _logger.info('🧹 Cleaned up ${expired.length} expired intro hints');
    }
  }

  /// Check discovered device against all hints
  ///
  /// Returns match result indicating contact, intro, or stranger
  Future<HintMatchResult> checkDevice(Uint8List advertisementData) async {
    // Parse advertisement
    final parsed = HintAdvertisementService.parseAdvertisement(
      advertisementData,
    );

    if (parsed == null) {
      return HintMatchResult.stranger();
    }

    if (parsed.isIntro) {
      final introMatch = _matchIntroHint(parsed);
      if (introMatch != null) {
        return introMatch;
      }
    } else {
      final contactMatch = await _matchContactHint(parsed);
      if (contactMatch != null) {
        return contactMatch;
      }
    }

    return HintMatchResult.stranger();
  }

  Future<HintMatchResult?> _matchContactHint(ParsedHint parsed) async {
    if (_contactCache.isEmpty) {
      await _rebuildContactCache();
    }

    for (final contact in _contactCache.values) {
      final identifier = contact.persistentPublicKey ?? contact.publicKey;
      final expected = HintAdvertisementService.computeHintBytes(
        identifier: identifier,
        nonce: parsed.nonce,
      );

      if (_bytesEqual(expected, parsed.hintBytes)) {
        _logger.info(
          '✅ CONTACT MATCH: ${contact.displayName} (${identifier.shortId()}...)',
        );
        return HintMatchResult.contact(
          publicKey: contact.publicKey,
          name: contact.displayName,
        );
      }
    }

    return null;
  }

  HintMatchResult? _matchIntroHint(ParsedHint parsed) {
    for (final intro in _activeIntroHints.values) {
      if (!intro.isUsable) continue;

      final expected = HintAdvertisementService.computeHintBytes(
        identifier: intro.hintHex,
        nonce: parsed.nonce,
      );

      if (_bytesEqual(expected, parsed.hintBytes)) {
        _logger.info('✅ INTRO MATCH: ${intro.displayName} (${intro.hintHex})');
        return HintMatchResult.intro(hint: intro);
      }
    }
    return null;
  }

  /// Get cache statistics
  Map<String, int> getStatistics() {
    return {
      'cached_contacts': _contactCache.length,
      'active_intros': _activeIntroHints.length,
    };
  }

  /// Clear all caches (for testing)
  void clearCaches() {
    _contactCache.clear();
    _activeIntroHints.clear();
    _logger.info('🧹 All hint caches cleared');
  }

  /// Dispose scanner
  void dispose() {
    _contactCache.clear();
    _activeIntroHints.clear();
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
