// File: lib/data/repositories/intro_hint_repository.dart

import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../../core/utils/app_logger.dart';

/// Repository for managing intro hints (Level 1 - QR-based discovery)
///
/// Stores:
/// - Our own active intro hints (from generated QR codes)
/// - Scanned intro hints (from other people's QR codes)
class IntroHintRepository {
  final _logger = AppLogger.getLogger(LoggerNames.hintSystem);

  static const String _myActiveHintsKey = 'my_active_intro_hints';
  static const String _scannedHintsKey = 'scanned_intro_hints';

  /// Get our currently active intro hints
  Future<List<EphemeralDiscoveryHint>> getMyActiveHints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_myActiveHintsKey);

    if (json == null) return [];

    try {
      final List<dynamic> list = jsonDecode(json);
      final hints = list
          .map((data) => EphemeralDiscoveryHint.fromMap(data))
          .toList();

      // Filter out expired hints
      final activeHints = hints.where((h) => h.isUsable).toList();

      // Clean up if any were expired
      if (activeHints.length != hints.length) {
        await _saveMyActiveHints(activeHints);
      }

      return activeHints;
    } catch (e) {
      _logger.severe('Failed to load active hints: $e');
      return [];
    }
  }

  /// Save our active intro hint (when generating QR)
  Future<void> saveMyActiveHint(EphemeralDiscoveryHint hint) async {
    final hints = await getMyActiveHints();

    // Add new hint (keep max 3 active hints)
    hints.insert(0, hint);
    if (hints.length > 3) {
      hints.removeRange(3, hints.length);
    }

    await _saveMyActiveHints(hints);
    _logger.info('💾 Saved active intro hint: ${hint.hintHex}');
  }

  /// Get all scanned intro hints (from other people)
  Future<Map<String, EphemeralDiscoveryHint>> getScannedHints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_scannedHintsKey);

    if (json == null) return {};

    try {
      final Map<String, dynamic> map = jsonDecode(json);
      final hints = <String, EphemeralDiscoveryHint>{};

      for (final entry in map.entries) {
        try {
          final hint = EphemeralDiscoveryHint.fromMap(entry.value);

          // Only include non-expired hints
          if (hint.isUsable) {
            hints[entry.key] = hint;
          }
        } catch (e) {
          _logger.warning('Failed to parse scanned hint ${entry.key}: $e');
        }
      }

      // Clean up if any were expired
      if (hints.length != map.length) {
        await _saveScannedHints(hints);
      }

      return hints;
    } catch (e) {
      _logger.severe('Failed to load scanned hints: $e');
      return {};
    }
  }

  /// Save a scanned intro hint (from someone's QR code)
  Future<void> saveScannedHint(EphemeralDiscoveryHint hint) async {
    final hints = await getScannedHints();

    hints[hint.hintHex] = hint;

    await _saveScannedHints(hints);
    _logger.info(
      '💾 Saved scanned intro hint: ${hint.hintHex} (${hint.displayName})',
    );
  }

  /// Remove a scanned hint (after successful pairing)
  Future<void> removeScannedHint(String hintHex) async {
    final hints = await getScannedHints();

    if (hints.remove(hintHex) != null) {
      await _saveScannedHints(hints);
      _logger.info('🗑️ Removed scanned hint: $hintHex');
    }
  }

  /// Clean up all expired hints
  Future<void> cleanupExpiredHints() async {
    // Clean up our active hints
    final myHints = await getMyActiveHints();
    final activeMyHints = myHints.where((h) => h.isUsable).toList();
    if (activeMyHints.length != myHints.length) {
      await _saveMyActiveHints(activeMyHints);
      _logger.info(
        '🧹 Cleaned up ${myHints.length - activeMyHints.length} expired active hints',
      );
    }

    // Clean up scanned hints
    final scannedHints = await getScannedHints();
    final activeScanned = Map<String, EphemeralDiscoveryHint>.fromEntries(
      scannedHints.entries.where((e) => e.value.isUsable),
    );
    if (activeScanned.length != scannedHints.length) {
      await _saveScannedHints(activeScanned);
      _logger.info(
        '🧹 Cleaned up ${scannedHints.length - activeScanned.length} expired scanned hints',
      );
    }
  }

  /// Get most recent active hint for advertising
  Future<EphemeralDiscoveryHint?> getMostRecentActiveHint() async {
    final hints = await getMyActiveHints();
    return hints.isEmpty ? null : hints.first;
  }

  /// Clear all hints (for testing)
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_myActiveHintsKey);
    await prefs.remove(_scannedHintsKey);
    _logger.info('🧹 Cleared all intro hints');
  }

  // Private helpers

  Future<void> _saveMyActiveHints(List<EphemeralDiscoveryHint> hints) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(hints.map((h) => h.toMap()).toList());
    await prefs.setString(_myActiveHintsKey, json);
  }

  Future<void> _saveScannedHints(
    Map<String, EphemeralDiscoveryHint> hints,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final map = hints.map((key, hint) => MapEntry(key, hint.toMap()));
    final json = jsonEncode(map);
    await prefs.setString(_scannedHintsKey, json);
  }
}
