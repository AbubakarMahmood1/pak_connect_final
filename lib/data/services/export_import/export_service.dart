// Export service for creating encrypted data bundles
// Creates self-contained .pakconnect files (v2) with all user data,
// encryption keys, and embedded encrypted database.

import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database_helper.dart';
import '../../database/database_backup_service.dart';
import '../../repositories/preferences_repository.dart';
import '../../repositories/user_preferences.dart';
import 'export_bundle.dart';
import 'encryption_utils.dart';
import 'selective_backup_service.dart';

class ExportService {
  static final _logger = Logger('ExportService');
  static const String _bundleExtension = '.pakconnect';
  static const String _bundleVersion = '2.1.0';
  static const String _lastExportTimestampKey = 'last_export_timestamp';

  /// Create encrypted, self-contained export bundle.
  ///
  /// The v2.1.0 bundle embeds the encrypted database bytes so the
  /// .pakconnect file is fully portable across devices. Integrity is
  /// protected by HMAC-SHA256 keyed with the passphrase-derived key.
  ///
  /// When [incremental] is true, only records modified since the last
  /// successful export are included. The bundle's [baseTimestamp] records
  /// the cutoff and the import side uses upsert (INSERT OR REPLACE) to
  /// merge changes without clearing existing data.
  static Future<ExportResult> createExport({
    required String userPassphrase,
    String? customPath,
    ExportType exportType = ExportType.full,
    bool incremental = false,
  }) async {
    String? tempBackupPath;
    try {
      _logger.info('🔐 Starting export process (${exportType.name})...');

      // 1. Validate passphrase strength
      _logger.info('Validating passphrase...');
      final validation = EncryptionUtils.validatePassphrase(userPassphrase);
      if (!validation.isValid) {
        return ExportResult.failure(
          'Weak passphrase: ${validation.warnings.join(", ")}',
        );
      }

      if (validation.isWeak) {
        _logger.warning('Passphrase is weak but acceptable');
      }

      // 2. Create database backup (selective or full) to temp file
      _logger.info('Creating database backup (${exportType.name})...');
      await DatabaseHelper.close();

      int recordCount = 0;

      // Resolve incremental cutoff timestamp
      int? sinceMsEpoch;
      DateTime? baseTimestamp;
      if (incremental && exportType != ExportType.full) {
        final prefs = await SharedPreferences.getInstance();
        final lastExport = prefs.getInt(_lastExportTimestampKey);
        if (lastExport != null) {
          sinceMsEpoch = lastExport;
          baseTimestamp = DateTime.fromMillisecondsSinceEpoch(lastExport);
          _logger.info('Incremental export since $baseTimestamp');
        } else {
          _logger.info('No previous export found — performing full export');
        }
      }

      if (exportType == ExportType.full) {
        final dbBackup = await DatabaseBackupService.createBackup(
          includeMetadata: true,
        );

        if (!dbBackup.success || dbBackup.backupPath == null) {
          await DatabaseHelper.database;
          return ExportResult.failure(
            'Database backup failed: ${dbBackup.errorMessage}',
          );
        }

        tempBackupPath = dbBackup.backupPath;
        final stats = await DatabaseHelper.getStatistics();
        recordCount = stats['total_records'] as int? ?? 0;
      } else {
        final selectiveBackup =
            await SelectiveBackupService.createSelectiveBackup(
              exportType: exportType,
              since: sinceMsEpoch,
            );

        if (!selectiveBackup.success || selectiveBackup.backupPath == null) {
          await DatabaseHelper.database;
          return ExportResult.failure(
            'Selective backup failed: ${selectiveBackup.errorMessage}',
          );
        }

        tempBackupPath = selectiveBackup.backupPath;
        recordCount = selectiveBackup.recordCount;
      }

      _logger.info(
        'Database backup created: $tempBackupPath ($recordCount records)',
      );

      // 3. Read database bytes for embedding
      _logger.info('Reading database bytes for embedding...');
      final dbBytes = await File(tempBackupPath!).readAsBytes();

      // 4. Collect encryption keys
      _logger.info('Collecting encryption keys...');
      final keys = await _collectKeys();

      // 5. Collect preferences
      _logger.info('Collecting preferences...');
      final preferences = await _collectPreferences();

      // 6. Collect metadata
      _logger.info('Collecting metadata...');
      final metadata = await _collectMetadata();

      // 7. Generate salt and derive encryption key
      _logger.info('Deriving encryption key...');
      final salt = EncryptionUtils.generateSalt();
      final encryptionKey = EncryptionUtils.deriveKey(userPassphrase, salt);

      // 8. Encrypt each component (including database)
      _logger.info('Encrypting data...');
      final encryptedMetadata = EncryptionUtils.encrypt(
        jsonEncode(metadata),
        encryptionKey,
      );

      final encryptedKeys = EncryptionUtils.encrypt(
        jsonEncode(keys),
        encryptionKey,
      );

      final encryptedPreferences = EncryptionUtils.encrypt(
        jsonEncode(preferences),
        encryptionKey,
      );

      final encryptedDatabase = EncryptionUtils.encrypt(
        base64Encode(dbBytes),
        encryptionKey,
      );

      // 9. Calculate HMAC-SHA256 over all encrypted payloads + restore mode.
      _logger.info('Calculating HMAC...');
      final hmac = EncryptionUtils.calculateHmac([
        encryptedMetadata,
        encryptedKeys,
        encryptedPreferences,
        encryptedDatabase,
        exportType.name,
        baseTimestamp?.toIso8601String() ?? '',
      ], encryptionKey);

      // 10. Create bundle
      final bundle = ExportBundle(
        version: _bundleVersion,
        timestamp: DateTime.now(),
        deviceId: metadata['device_id'] as String,
        username: metadata['username'] as String,
        exportType: exportType,
        baseTimestamp: baseTimestamp,
        encryptedMetadata: encryptedMetadata,
        encryptedKeys: encryptedKeys,
        encryptedPreferences: encryptedPreferences,
        encryptedDatabase: encryptedDatabase,
        salt: salt,
        hmac: hmac,
      );

      // 11. Write bundle file
      _logger.info('Writing bundle file...');
      final bundlePath = await _writeBundleFile(bundle, customPath);

      // 12. Get bundle size
      final bundleFile = File(bundlePath);
      final bundleSize = await bundleFile.length();

      // 13. Clean up temp backup file
      try {
        await File(tempBackupPath).delete();
        // Also clean up sidecar .meta.json if it exists
        final metaFile = File('$tempBackupPath.meta.json');
        if (await metaFile.exists()) await metaFile.delete();
      } catch (_) {
        // Non-critical
      }
      tempBackupPath = null;

      // 14. Reopen database
      await DatabaseHelper.database;

      // 15. Record export timestamp for future incremental exports
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _lastExportTimestampKey,
        bundle.timestamp.millisecondsSinceEpoch,
      );

      final incrementalLabel = baseTimestamp != null ? ', incremental' : '';
      _logger.info(
        '✅ Export complete (${exportType.name}$incrementalLabel): $bundlePath '
        '($recordCount records, ${bundleSize / 1024}KB)',
      );

      return ExportResult.success(
        bundlePath: bundlePath,
        bundleSize: bundleSize,
        exportType: exportType,
        recordCount: recordCount,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Export failed', e, stackTrace);

      // Clean up temp backup on failure
      if (tempBackupPath != null) {
        try {
          await File(tempBackupPath).delete();
        } catch (_) {}
      }

      // Ensure database is reopened even if export fails
      try {
        await DatabaseHelper.database;
      } catch (_) {}

      return ExportResult.failure('Export failed: $e');
    }
  }

  /// Collect encryption keys from secure storage
  static Future<Map<String, String>> _collectKeys() async {
    final storage = const FlutterSecureStorage();

    final dbKey = await storage.read(key: 'db_encryption_key_v1') ?? '';
    final publicKey = await storage.read(key: 'ecdh_public_key_v2') ?? '';
    final privateKey = await storage.read(key: 'ecdh_private_key_v2') ?? '';

    if (dbKey.isEmpty || publicKey.isEmpty || privateKey.isEmpty) {
      throw Exception('Missing encryption keys in secure storage');
    }

    return {
      'database_encryption_key': dbKey,
      'ecdh_public_key': publicKey,
      'ecdh_private_key': privateKey,
      'key_version': 'v2',
    };
  }

  /// Collect preferences from both repositories
  static Future<Map<String, dynamic>> _collectPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsRepo = PreferencesRepository();

    return {
      'app_preferences': await prefsRepo.getAll(),
      'username': prefs.getString('user_display_name'),
      'device_id': prefs.getString('my_persistent_device_id'),
      'theme_mode': prefs.getString('theme_mode'),
    };
  }

  /// Collect metadata about the export
  static Future<Map<String, dynamic>> _collectMetadata() async {
    final userPrefs = UserPreferences();

    final username = await userPrefs.getUserName();
    final deviceId = await userPrefs.getOrCreateDeviceId();
    final dbStats = await DatabaseHelper.getStatistics();

    return {
      'version': '1.0.0',
      'timestamp': DateTime.now().toIso8601String(),
      'username': username,
      'device_id': deviceId,
      'database_version': dbStats['database_version'],
      'total_records': dbStats['total_records'],
      'table_counts': dbStats['table_counts'],
    };
  }

  /// Write bundle to file
  static Future<String> _writeBundleFile(
    ExportBundle bundle,
    String? customPath,
  ) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filename = 'pakconnect_backup_$timestamp$_bundleExtension';

    String bundlePath;
    if (customPath != null) {
      bundlePath = join(customPath, filename);
    } else {
      // Use default backup directory
      final dbPath = await DatabaseHelper.getDatabasePath();
      final backupDir = join(dirname(dbPath), 'exports');
      await Directory(backupDir).create(recursive: true);
      bundlePath = join(backupDir, filename);
    }

    // Write bundle JSON
    final bundleFile = File(bundlePath);
    await bundleFile.writeAsString(jsonEncode(bundle.toJson()));

    _logger.info('Bundle written to: $bundlePath');
    return bundlePath;
  }

  /// Get default export directory
  static Future<String> getDefaultExportDirectory() async {
    final dbPath = await DatabaseHelper.getDatabasePath();
    return join(dirname(dbPath), 'exports');
  }

  /// List available exports
  static Future<List<ExportBundle>> listAvailableExports() async {
    try {
      final exports = await _listAvailableExportEntries();
      return exports.map((entry) => entry.bundle).toList(growable: false);
    } catch (e) {
      _logger.warning('Failed to list exports: $e');
      return [];
    }
  }

  /// Delete old exports, keeping only the most recent N
  static Future<int> cleanupOldExports({int keepCount = 3}) async {
    try {
      final exports = await _listAvailableExportEntries();

      if (exports.length <= keepCount) {
        return 0;
      }

      final exportsToDelete = exports.skip(keepCount).toList();
      int deletedCount = 0;

      for (final export in exportsToDelete) {
        try {
          if (await export.file.exists()) {
            await export.file.delete();
            deletedCount++;
          }
        } catch (e) {
          _logger.warning('Failed to delete export: $e');
        }
      }

      _logger.info('Cleaned up $deletedCount old exports');
      return deletedCount;
    } catch (e) {
      _logger.warning('Failed to cleanup exports: $e');
      return 0;
    }
  }

  static Future<List<_ExportFileEntry>> _listAvailableExportEntries() async {
    final exportDir = await getDefaultExportDirectory();
    final dir = Directory(exportDir);

    if (!await dir.exists()) {
      return [];
    }

    final exports = <_ExportFileEntry>[];

    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith(_bundleExtension)) {
        continue;
      }

      try {
        final contents = await entity.readAsString();
        final json = jsonDecode(contents) as Map<String, dynamic>;
        exports.add(_ExportFileEntry(entity, ExportBundle.fromJson(json)));
      } catch (e) {
        _logger.warning('Failed to parse export: ${entity.path}', e);
      }
    }

    exports.sort((a, b) => b.bundle.timestamp.compareTo(a.bundle.timestamp));
    return exports;
  }
}

class _ExportFileEntry {
  final File file;
  final ExportBundle bundle;

  const _ExportFileEntry(this.file, this.bundle);
}
