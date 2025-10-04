// File: lib/core/services/hint_scanner_service.dart

import 'dart:typed_data';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../../domain/entities/sensitive_contact_hint.dart';
import '../../data/repositories/contact_repository.dart';
import '../utils/app_logger.dart';
import 'hint_advertisement_service.dart';

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

  factory HintMatchResult.intro({
    required EphemeralDiscoveryHint hint,
  }) {
    return HintMatchResult._(
      type: HintMatchType.intro,
      introHint: hint,
    );
  }

  factory HintMatchResult.stranger() {
    return HintMatchResult._(
      type: HintMatchType.stranger,
    );
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
  contact,   // Matched against cached contact hints (Level 2)
  intro,     // Matched against active intro hints (Level 1)
  stranger,  // No match
}

/// Service for scanning and matching discovered hints
class HintScannerService {
  final _logger = AppLogger.getLogger(LoggerNames.hintSystem);

  /// Cache of contact hints for O(1) lookup
  final Map<String, SensitiveContactHint> _contactHintCache = {};

  /// Active intro hints (from QR scans we did)
  final Map<String, EphemeralDiscoveryHint> _activeIntroHints = {};

  /// Repository for accessing contact data
  final ContactRepository _contactRepository;

  HintScannerService({
    required ContactRepository contactRepository,
  }) : _contactRepository = contactRepository;

  /// Initialize scanner by precomputing all contact hints
  Future<void> initialize() async {
    await _rebuildContactCache();
    _logger.info('✅ HintScannerService initialized with ${_contactHintCache.length} contacts');
  }

  /// Rebuild contact hint cache (call after new pairing)
  Future<void> _rebuildContactCache() async {
    _contactHintCache.clear();

    final contacts = await _contactRepository.getAllContacts();

    for (final contact in contacts.values) {
      // Get shared seed for this contact
      final sharedSeed = await _contactRepository.getCachedSharedSecret(contact.publicKey);

      if (sharedSeed != null) {
        // Compute sensitive hint
        final sensitiveHint = SensitiveContactHint.compute(
          contactPublicKey: contact.publicKey,
          sharedSeed: Uint8List.fromList(sharedSeed.codeUnits),
          displayName: contact.displayName,
        );

        // Cache by hint hex string for fast lookup
        _contactHintCache[sensitiveHint.hintHex] = sensitiveHint;
      }
    }

    _logger.info('🔄 Contact hint cache rebuilt: ${_contactHintCache.length} entries');
  }

  /// Add active intro hint (from QR scan)
  void addActiveIntroHint(EphemeralDiscoveryHint hint) {
    if (hint.isUsable) {
      _activeIntroHints[hint.hintHex] = hint;
      _logger.info('📝 Added active intro hint: ${hint.hintHex} (${hint.displayName})');
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
    final parsed = HintAdvertisementService.parseAdvertisement(advertisementData);

    if (parsed == null) {
      return HintMatchResult.stranger();
    }

    // Check Level 2: Sensitive contact hints (priority)
    if (parsed.hasEphemeralHint) {
      final match = _checkContactHint(parsed.ephemeralHintBytes!);
      if (match != null) {
        return match;
      }
    }

    // Check Level 1: Intro hints
    if (parsed.hasIntroHint) {
      final match = _checkIntroHint(parsed.introHintBytes!);
      if (match != null) {
        return match;
      }
    }

    // No match
    return HintMatchResult.stranger();
  }

  /// Check ephemeral hint against contact cache
  HintMatchResult? _checkContactHint(Uint8List hintBytes) {
    final hintHex = hintBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

    final contact = _contactHintCache[hintHex];

    if (contact != null) {
      _logger.info('✅ CONTACT MATCH: ${contact.displayName} (${contact.contactPublicKey.substring(0, 16)}...)');

      return HintMatchResult.contact(
        publicKey: contact.contactPublicKey,
        name: contact.displayName ?? 'Unknown',
      );
    }

    return null;
  }

  /// Check intro hint against active intros
  HintMatchResult? _checkIntroHint(Uint8List hintBytes) {
    final hintHex = hintBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

    final intro = _activeIntroHints[hintHex];

    if (intro != null && intro.isUsable) {
      _logger.info('✅ INTRO MATCH: ${intro.displayName} (${intro.hintHex})');

      return HintMatchResult.intro(hint: intro);
    }

    return null;
  }

  /// Get cache statistics
  Map<String, int> getStatistics() {
    return {
      'cached_contacts': _contactHintCache.length,
      'active_intros': _activeIntroHints.length,
    };
  }

  /// Clear all caches (for testing)
  void clearCaches() {
    _contactHintCache.clear();
    _activeIntroHints.clear();
    _logger.info('🧹 All hint caches cleared');
  }

  /// Dispose scanner
  void dispose() {
    _contactHintCache.clear();
    _activeIntroHints.clear();
  }
}
