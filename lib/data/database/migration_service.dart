import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Migration result with detailed statistics.
class MigrationResult {
  final bool success;
  final String message;
  final Map<String, int> migrationCounts;
  final Map<String, String> checksums;
  final Duration duration;
  final String? backupPath;
  final List<String> errors;
  final List<String> warnings;

  const MigrationResult({
    required this.success,
    required this.message,
    required this.migrationCounts,
    required this.checksums,
    required this.duration,
    this.backupPath,
    this.errors = const [],
    this.warnings = const [],
  });

  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
    'migrationCounts': migrationCounts,
    'checksums': checksums,
    'durationMs': duration.inMilliseconds,
    'backupPath': backupPath,
    'errors': errors,
    'warnings': warnings,
  };
}

/// Final-state migration shim for historical SharedPreferences data.
///
/// PakConnect now relies on SQLite-native state only. Older plaintext
/// SharedPreferences payloads are no longer interpreted or migrated.
class MigrationService {
  static final _logger = Logger('MigrationService');

  static const String _migrationCompletedKey = 'sqlite_migration_completed';
  static const String _backupPrefix = 'migration_backup_';
  static const Set<String> _obsoleteKeys = <String>{
    'enhanced_contacts_v2',
    'chat_messages',
    'offline_message_queue_v2',
    'deleted_message_ids_v1',
    'device_public_key_mapping',
    'chat_unread_counts',
    'contact_last_seen',
  };

  /// Legacy SharedPreferences migration has been retired.
  ///
  /// The method remains for startup/test compatibility and now reports that no
  /// migration path is available.
  static Future<bool> needsMigration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final migrated = prefs.getBool(_migrationCompletedKey) ?? false;
      final obsoleteKeys = _findObsoleteKeys(prefs);

      if (migrated) {
        _logger.info('Migration already completed');
        return false;
      }

      if (obsoleteKeys.isNotEmpty) {
        _logger.warning(
          'Legacy SharedPreferences migration support has been removed. '
          'Obsolete keys will be ignored until cleanup is requested.',
        );
        return false;
      }

      _logger.info('No data to migrate');
      return false;
    } catch (e) {
      _logger.severe('Failed to check migration status: $e');
      return false;
    }
  }

  /// Clears obsolete plaintext SharedPreferences data and marks migration as complete.
  static Future<MigrationResult> migrate() async {
    final startTime = DateTime.now();

    try {
      final prefs = await SharedPreferences.getInstance();
      final obsoleteKeys = _findObsoleteKeys(prefs);
      var removedCount = 0;

      for (final key in obsoleteKeys) {
        await prefs.remove(key);
        removedCount++;
      }

      for (final key in prefs.getKeys().toList()) {
        if (!key.startsWith(_backupPrefix)) {
          continue;
        }
        await prefs.remove(key);
        removedCount++;
      }

      await prefs.setBool(_migrationCompletedKey, true);

      final duration = DateTime.now().difference(startTime);
      final warnings = obsoleteKeys.isEmpty
          ? const <String>[]
          : const <String>[
              'Legacy SharedPreferences migration support has been removed. '
                  'Obsolete plaintext keys were discarded instead of migrated.',
            ];

      if (removedCount > 0) {
        _logger.info(
          '🧹 Removed $removedCount obsolete SharedPreferences keys and marked migration complete',
        );
      } else {
        _logger.info(
          '✅ Migration marked complete (no obsolete SharedPreferences keys found)',
        );
      }

      return MigrationResult(
        success: true,
        message: removedCount > 0
            ? 'Legacy SharedPreferences support is retired. '
                  'Removed $removedCount obsolete plaintext keys.'
            : 'Migration already obsolete. SQLite-native state is authoritative.',
        migrationCounts: <String, int>{'obsolete_keys_removed': removedCount},
        checksums: const <String, String>{},
        duration: duration,
        warnings: warnings,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Migration cleanup failed: $e', e, stackTrace);
      return MigrationResult(
        success: false,
        message: 'Migration cleanup failed: $e',
        migrationCounts: const <String, int>{},
        checksums: const <String, String>{},
        duration: DateTime.now().difference(startTime),
        errors: <String>[e.toString()],
      );
    }
  }

  static List<String> _findObsoleteKeys(SharedPreferences prefs) {
    final found = <String>[];
    for (final key in _obsoleteKeys) {
      if (prefs.containsKey(key)) {
        found.add(key);
      }
    }
    return found;
  }
}
