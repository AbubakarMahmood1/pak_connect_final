// Import service for restoring encrypted data bundles
// Restores .pakconnect files with all user data and encryption keys.
// Supports v2.0.0 (self-contained, HMAC) and v1.0.0 (legacy path-based).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database_helper.dart';
import '../../database/database_backup_service.dart';
import '../../repositories/preferences_repository.dart';
import 'export_bundle.dart';
import 'encryption_utils.dart';
import 'selective_restore_service.dart';

class ImportService {
  static final _logger = Logger('ImportService');

  /// Import and restore from encrypted bundle.
  ///
  /// v2.0.0 bundles are self-contained (database embedded, HMAC-verified).
  /// v1.0.0 bundles reference an external DB path (legacy, still supported).
  ///
  /// WARNING: This will REPLACE all existing data!
  static Future<ImportResult> importBundle({
    required String bundlePath,
    required String userPassphrase,
    bool clearExistingData = true,
  }) async {
    try {
      _logger.info('🔐 Starting import process...');
      _logger.info('Bundle: $bundlePath');

      // ── 1. Read and parse bundle file ──
      _logger.info('Reading bundle file...');
      final bundleFile = File(bundlePath);

      if (!await bundleFile.exists()) {
        return ImportResult.failure('Bundle file not found: $bundlePath');
      }

      final bundleJson = await bundleFile.readAsString();
      final bundle = ExportBundle.fromJson(
        jsonDecode(bundleJson) as Map<String, dynamic>,
      );

      _logger.info('Bundle version: ${bundle.version}');
      _logger.info('Bundle timestamp: ${bundle.timestamp}');
      _logger.info('Original username: ${bundle.username}');
      _logger.info('Original device: ${bundle.deviceId}');

      // ── 2. Validate version compatibility ──
      _logger.info('Validating version compatibility...');
      if (!_isCompatibleVersion(bundle.version)) {
        return ImportResult.failure(
          'Incompatible bundle version: ${bundle.version}. '
          'Expected: 1.0.0 or 2.0.0',
        );
      }

      // ── 3. Derive decryption key ──
      _logger.info('Deriving decryption key...');
      final decryptionKey = EncryptionUtils.deriveKey(
        userPassphrase,
        bundle.salt,
      );

      // ── 4. Decrypt metadata first (validates passphrase) ──
      _logger.info('Decrypting metadata...');
      final metadataJson = EncryptionUtils.decrypt(
        bundle.encryptedMetadata,
        decryptionKey,
      );

      if (metadataJson == null) {
        return ImportResult.failure(
          'Invalid passphrase or corrupted metadata. '
          'Please check your passphrase and try again.',
        );
      }

      final metadata = jsonDecode(metadataJson) as Map<String, dynamic>;
      _logger.info('Metadata decrypted successfully');
      _logger.fine(
        'Bundle contains ${metadata['total_records']} total records',
      );

      // ── 5. Verify integrity (HMAC for v2, SHA-256 for v1) ──
      _logger.info('Verifying bundle integrity...');
      final integrityOk = _verifyIntegrity(bundle, decryptionKey);
      if (!integrityOk) {
        return ImportResult.failure(
          'Bundle integrity check failed. '
          'File may be corrupted or tampered with.',
        );
      }
      _logger.info('Bundle integrity verified');

      // ── 6. Decrypt keys and preferences ──
      _logger.info('Decrypting keys...');
      final keysJson = EncryptionUtils.decrypt(
        bundle.encryptedKeys,
        decryptionKey,
      );

      if (keysJson == null) {
        return ImportResult.failure(
          'Failed to decrypt keys. Invalid passphrase.',
        );
      }

      _logger.info('Decrypting preferences...');
      final preferencesJson = EncryptionUtils.decrypt(
        bundle.encryptedPreferences,
        decryptionKey,
      );

      if (preferencesJson == null) {
        return ImportResult.failure(
          'Failed to decrypt preferences. Invalid passphrase.',
        );
      }

      final keys = jsonDecode(keysJson) as Map<String, dynamic>;
      final preferences = jsonDecode(preferencesJson) as Map<String, dynamic>;

      // Validate keys before doing anything destructive
      if (!keys.containsKey('database_encryption_key') ||
          !keys.containsKey('ecdh_public_key') ||
          !keys.containsKey('ecdh_private_key')) {
        return ImportResult.failure('Missing required keys in bundle');
      }

      _logger.info('All data decrypted successfully');

      // ── 7. PREFLIGHT: Resolve database file BEFORE any destructive ops ──
      String dbRestorePath;

      if (bundle.isSelfContained) {
        // v2: decrypt embedded database to a temp file
        _logger.info('Extracting embedded database...');
        final dbBase64 = EncryptionUtils.decrypt(
          bundle.encryptedDatabase!,
          decryptionKey,
        );

        if (dbBase64 == null) {
          return ImportResult.failure(
            'Failed to decrypt embedded database.',
          );
        }

        final dbBytes = base64Decode(dbBase64);
        final mainDbPath = await DatabaseHelper.getDatabasePath();
        dbRestorePath = '${mainDbPath}_import_temp_${DateTime.now().millisecondsSinceEpoch}.db';
        await File(dbRestorePath).writeAsBytes(dbBytes);
        _logger.info('Embedded database extracted to temp file');
      } else {
        // v1 legacy: reference external path
        _logger.warning('⚠️ Importing legacy v1.0.0 bundle (external DB path)');
        dbRestorePath = bundle.databasePath;
      }

      // Verify the DB file actually exists BEFORE clearing anything
      final dbFile = File(dbRestorePath);
      if (!await dbFile.exists()) {
        return ImportResult.failure(
          'Database file not found: $dbRestorePath',
        );
      }

      // ── 8. Clear existing data (AFTER all preflight checks pass) ──
      if (clearExistingData) {
        _logger.warning('⚠️ Clearing all existing data...');
        await _clearExistingData();
        _logger.info('Existing data cleared');
      }

      // ── 9. Restore encryption keys to secure storage ──
      _logger.info('Restoring encryption keys...');
      await _restoreKeys(keys);
      _logger.info('Keys restored to secure storage');

      // ── 10. Restore database (selective or full) ──
      _logger.info('Restoring database (${bundle.exportType.name})...');

      int recordsRestored = 0;

      if (bundle.exportType == ExportType.full) {
        final restoreResult = await DatabaseBackupService.restoreBackup(
          backupPath: dbRestorePath,
          validateChecksum: !bundle.isSelfContained, // v2 already HMAC-verified
        );

        if (!restoreResult.success) {
          return ImportResult.failure(
            'Database restore failed: ${restoreResult.errorMessage}',
          );
        }

        recordsRestored = restoreResult.recordsRestored ?? 0;
      } else {
        final selectiveRestore =
            await SelectiveRestoreService.restoreSelectiveBackup(
              backupPath: dbRestorePath,
              exportType: bundle.exportType,
              clearExistingData: clearExistingData,
            );

        if (!selectiveRestore.success) {
          return ImportResult.failure(
            'Selective restore failed: ${selectiveRestore.errorMessage}',
          );
        }

        recordsRestored = selectiveRestore.recordsRestored;
      }

      _logger.info('Database restored: $recordsRestored records');

      // ── 11. Clean up temp extracted DB ──
      if (bundle.isSelfContained) {
        try {
          await File(dbRestorePath).delete();
        } catch (_) {}
      }

      // ── 12. Restore preferences ──
      _logger.info('Restoring preferences...');
      await _restorePreferences(preferences);
      _logger.info('Preferences restored');

      // ── 13. Success! ──
      _logger.info('✅ Import complete (${bundle.exportType.name})!');

      return ImportResult.success(
        recordsRestored: recordsRestored,
        originalDeviceId: bundle.deviceId,
        originalUsername: bundle.username,
        backupTimestamp: bundle.timestamp,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Import failed', e, stackTrace);

      try {
        await DatabaseHelper.database;
      } catch (_) {}

      return ImportResult.failure('Import failed: $e');
    }
  }

  /// Validate bundle without importing.
  ///
  /// Useful for previewing what will be imported.
  static Future<Map<String, dynamic>> validateBundle({
    required String bundlePath,
    required String userPassphrase,
  }) async {
    try {
      final bundleFile = File(bundlePath);
      if (!await bundleFile.exists()) {
        return {'valid': false, 'error': 'Bundle file not found'};
      }

      final bundleJson = await bundleFile.readAsString();
      final bundle = ExportBundle.fromJson(
        jsonDecode(bundleJson) as Map<String, dynamic>,
      );

      if (!_isCompatibleVersion(bundle.version)) {
        return {
          'valid': false,
          'error': 'Incompatible version: ${bundle.version}',
        };
      }

      final decryptionKey = EncryptionUtils.deriveKey(
        userPassphrase,
        bundle.salt,
      );

      final metadataJson = EncryptionUtils.decrypt(
        bundle.encryptedMetadata,
        decryptionKey,
      );

      if (metadataJson == null) {
        return {'valid': false, 'error': 'Invalid passphrase'};
      }

      final metadata = jsonDecode(metadataJson) as Map<String, dynamic>;

      // Verify integrity
      if (!_verifyIntegrity(bundle, decryptionKey)) {
        return {
          'valid': false,
          'error': 'Integrity check failed - file may be corrupted or tampered',
        };
      }

      return {
        'valid': true,
        'version': bundle.version,
        'export_type': bundle.exportType.name,
        'timestamp': bundle.timestamp.toIso8601String(),
        'username': bundle.username,
        'device_id': bundle.deviceId,
        'database_version': metadata['database_version'],
        'total_records': metadata['total_records'],
        'table_counts': metadata['table_counts'],
        'self_contained': bundle.isSelfContained,
      };
    } catch (e) {
      return {'valid': false, 'error': 'Validation failed: $e'};
    }
  }

  // ──────────────────────── Private helpers ────────────────────────

  /// Verify bundle integrity using the appropriate mechanism.
  static bool _verifyIntegrity(ExportBundle bundle, Uint8List key) {
    if (bundle.isSelfContained && bundle.hmac != null) {
      // v2: HMAC-SHA256 keyed verification
      return EncryptionUtils.verifyHmac([
        bundle.encryptedMetadata,
        bundle.encryptedKeys,
        bundle.encryptedPreferences,
        bundle.encryptedDatabase!,
      ], key, bundle.hmac!);
    } else if (bundle.checksum != null) {
      // v1 legacy: unkeyed SHA-256 (backward compat only)
      final calculated = EncryptionUtils.calculateChecksum([
        bundle.encryptedMetadata,
        bundle.encryptedKeys,
        bundle.encryptedPreferences,
        bundle.databasePath,
      ]);
      return calculated == bundle.checksum;
    }
    // No integrity field at all — reject
    return false;
  }

  /// Clear all existing data.
  ///
  /// WARNING: This is destructive!
  static Future<void> _clearExistingData() async {
    await DatabaseHelper.close();
    await DatabaseHelper.clearAllData();

    final prefs = await SharedPreferences.getInstance();
    final keysToKeep = [
      'sqlite_migration_completed',
      'first_launch_complete',
    ];

    final allKeys = prefs.getKeys();
    for (final key in allKeys) {
      if (!keysToKeep.contains(key)) {
        await prefs.remove(key);
      }
    }

    const storage = FlutterSecureStorage();
    await storage.deleteAll();
  }

  /// Restore encryption keys to secure storage.
  static Future<void> _restoreKeys(Map<String, dynamic> keys) async {
    const storage = FlutterSecureStorage();

    await storage.write(
      key: 'db_encryption_key_v1',
      value: keys['database_encryption_key'] as String,
    );

    await storage.write(
      key: 'ecdh_public_key_v2',
      value: keys['ecdh_public_key'] as String,
    );

    await storage.write(
      key: 'ecdh_private_key_v2',
      value: keys['ecdh_private_key'] as String,
    );

    _logger.info('Restored ${keys.length} encryption keys');
  }

  /// Restore preferences to both repositories.
  static Future<void> _restorePreferences(
    Map<String, dynamic> preferences,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final prefsRepo = PreferencesRepository();

    final appPrefs = preferences['app_preferences'] as Map<String, dynamic>?;
    if (appPrefs != null) {
      for (final entry in appPrefs.entries) {
        try {
          final value = entry.value;
          if (value is String) {
            await prefsRepo.setString(entry.key, value);
          } else if (value is bool) {
            await prefsRepo.setBool(entry.key, value);
          } else if (value is int) {
            await prefsRepo.setInt(entry.key, value);
          } else if (value is double) {
            await prefsRepo.setDouble(entry.key, value);
          }
        } catch (e) {
          _logger.warning('Failed to restore preference ${entry.key}: $e');
        }
      }
      _logger.info('Restored ${appPrefs.length} app preferences');
    }

    if (preferences['username'] != null) {
      await prefs.setString(
        'user_display_name',
        preferences['username'] as String,
      );
    }

    if (preferences['device_id'] != null) {
      await prefs.setString(
        'my_persistent_device_id',
        preferences['device_id'] as String,
      );
    }

    if (preferences['theme_mode'] != null) {
      await prefs.setString('theme_mode', preferences['theme_mode'] as String);
    }
  }

  /// Check if bundle version is compatible.
  static bool _isCompatibleVersion(String version) {
    return version == '1.0.0' || version == '2.0.0';
  }
}
