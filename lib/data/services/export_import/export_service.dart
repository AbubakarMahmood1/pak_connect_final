// Export service for creating encrypted data bundles
// Creates .pakconnect files with all user data and encryption keys

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

  /// Create encrypted export bundle
  ///
  /// [exportType] determines what data to export:
  /// - ExportType.full: Everything (default)
  /// - ExportType.contactsOnly: Only contacts
  /// - ExportType.messagesOnly: Messages + chats
  ///
  /// Returns path to created .pakconnect file
  /// Throws exception if export fails
  static Future<ExportResult> createExport({
    required String userPassphrase,
    String? customPath,
    ExportType exportType = ExportType.full,
  }) async {
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

      // 2. Create database backup (selective or full)
      _logger.info('Creating database backup (${exportType.name})...');
      await DatabaseHelper.close();

      String? backupPath;
      int recordCount = 0;

      if (exportType == ExportType.full) {
        // Full database backup
        final dbBackup = await DatabaseBackupService.createBackup(
          includeMetadata: true,
        );

        if (!dbBackup.success || dbBackup.backupPath == null) {
          await DatabaseHelper.database; // Reopen
          return ExportResult.failure(
            'Database backup failed: ${dbBackup.errorMessage}',
          );
        }

        backupPath = dbBackup.backupPath;
        final stats = await DatabaseHelper.getStatistics();
        recordCount = stats['total_records'] as int? ?? 0;
      } else {
        // Selective backup
        final selectiveBackup =
            await SelectiveBackupService.createSelectiveBackup(
              exportType: exportType,
            );

        if (!selectiveBackup.success || selectiveBackup.backupPath == null) {
          await DatabaseHelper.database; // Reopen
          return ExportResult.failure(
            'Selective backup failed: ${selectiveBackup.errorMessage}',
          );
        }

        backupPath = selectiveBackup.backupPath;
        recordCount = selectiveBackup.recordCount;
      }

      _logger.info(
        'Database backup created: $backupPath ($recordCount records)',
      );

      // 3. Collect encryption keys
      _logger.info('Collecting encryption keys...');
      final keys = await _collectKeys();

      // 4. Collect preferences
      _logger.info('Collecting preferences...');
      final preferences = await _collectPreferences();

      // 5. Collect metadata
      _logger.info('Collecting metadata...');
      final metadata = await _collectMetadata();

      // 6. Generate salt and derive encryption key
      _logger.info('Deriving encryption key...');
      final salt = EncryptionUtils.generateSalt();
      final encryptionKey = EncryptionUtils.deriveKey(userPassphrase, salt);

      // 7. Encrypt each component
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

      // 8. Calculate checksum
      _logger.info('Calculating checksum...');
      final checksum = EncryptionUtils.calculateChecksum([
        encryptedMetadata,
        encryptedKeys,
        encryptedPreferences,
        backupPath!, // backupPath is guaranteed non-null at this point
      ]);

      // 9. Create bundle
      final bundle = ExportBundle(
        version: '1.0.0',
        timestamp: DateTime.now(),
        deviceId: metadata['device_id'] as String,
        username: metadata['username'] as String,
        exportType: exportType,
        encryptedMetadata: encryptedMetadata,
        encryptedKeys: encryptedKeys,
        encryptedPreferences: encryptedPreferences,
        databasePath: backupPath,
        salt: salt,
        checksum: checksum,
      );

      // 10. Write bundle file
      _logger.info('Writing bundle file...');
      final bundlePath = await _writeBundleFile(bundle, customPath);

      // 11. Get bundle size
      final bundleFile = File(bundlePath);
      final bundleSize = await bundleFile.length();

      // 12. Reopen database
      await DatabaseHelper.database;

      _logger.info(
        '✅ Export complete (${exportType.name}): $bundlePath ($recordCount records, ${bundleSize / 1024}KB)',
      );

      return ExportResult.success(
        bundlePath: bundlePath,
        bundleSize: bundleSize,
        exportType: exportType,
        recordCount: recordCount,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Export failed', e, stackTrace);

      // Ensure database is reopened even if export fails
      try {
        await DatabaseHelper.database;
      } catch (_) {
        // Ignore errors during recovery
      }

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
      final exportDir = await getDefaultExportDirectory();
      final dir = Directory(exportDir);

      if (!await dir.exists()) {
        return [];
      }

      final exports = <ExportBundle>[];

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith(_bundleExtension)) {
          try {
            final contents = await entity.readAsString();
            final json = jsonDecode(contents) as Map<String, dynamic>;
            exports.add(ExportBundle.fromJson(json));
          } catch (e) {
            _logger.warning('Failed to parse export: ${entity.path}', e);
          }
        }
      }

      // Sort by timestamp descending (newest first)
      exports.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return exports;
    } catch (e) {
      _logger.warning('Failed to list exports: $e');
      return [];
    }
  }

  /// Delete old exports, keeping only the most recent N
  static Future<int> cleanupOldExports({int keepCount = 3}) async {
    try {
      final exports = await listAvailableExports();

      if (exports.length <= keepCount) {
        return 0;
      }

      final exportsToDelete = exports.skip(keepCount).toList();
      int deletedCount = 0;

      final exportDir = await getDefaultExportDirectory();

      for (final export in exportsToDelete) {
        try {
          final timestamp = export.timestamp.millisecondsSinceEpoch;
          final filename = 'pakconnect_backup_$timestamp$_bundleExtension';
          final file = File(join(exportDir, filename));

          if (await file.exists()) {
            await file.delete();
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
}
