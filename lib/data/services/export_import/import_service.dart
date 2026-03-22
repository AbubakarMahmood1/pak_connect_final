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

  // Rate limiting constants
  static const String _attemptTrackerKey = 'import_attempt_tracker';
  static const List<int> _backoffScheduleMs = [0, 2000, 5000, 15000, 30000, 60000];

  // Checkpoint file name (stored alongside DB in app data directory)
  static const String _checkpointFileName = 'import_checkpoint.json';
  // Secure storage key for sensitive checkpoint data (keys/prefs)
  static const String _checkpointSensitiveKey =
      'import_checkpoint_sensitive_v1';

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

      // ── 0. Check rate limit before expensive key derivation ──
      final cooldownRemaining = await _checkCooldown();
      if (cooldownRemaining > Duration.zero) {
        final secs = cooldownRemaining.inSeconds;
        return ImportResult.failure(
          'Too many failed attempts. Please wait $secs seconds before trying again.',
        );
      }

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

      // Reject v2+ bundles that were stripped to look like legacy v1
      if (_requiresSelfContainedBundle(bundle) && !bundle.isSelfContained) {
        return ImportResult.failure(
          'Invalid bundle structure for version ${bundle.version}: '
          'missing embedded encrypted database',
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
        await _recordFailedAttempt();
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

      // ── 7.5. Save checkpoint so import can resume if interrupted ──
      await _saveCheckpoint(
        dbRestorePath: dbRestorePath,
        keys: keys,
        preferences: preferences,
        exportType: bundle.exportType.name,
        clearExistingData: clearExistingData,
        bundleMetadata: {
          'deviceId': bundle.deviceId,
          'username': bundle.username,
          'timestamp': bundle.timestamp.toIso8601String(),
          'isSelfContained': bundle.isSelfContained,
        },
      );

      // ── 8. Clear existing data (AFTER all preflight checks pass) ──
      // Incremental bundles merge via upsert — never clear existing data.
      final shouldClear = clearExistingData && !bundle.isIncremental;
      if (shouldClear) {
        _logger.warning('⚠️ Clearing all existing data...');
        await _clearExistingData();
        _logger.info('Existing data cleared');
      } else if (bundle.isIncremental) {
        _logger.info('Incremental bundle — merging into existing data');
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
              clearExistingData: shouldClear,
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

      // ── 13. Success — clean up checkpoint ──
      await _clearCheckpoint();
      await _resetAttempts();
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

      if (_requiresSelfContainedBundle(bundle) && !bundle.isSelfContained) {
        return {
          'valid': false,
          'error':
              'Invalid bundle structure for version ${bundle.version}: '
              'missing embedded encrypted database',
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
    if (_requiresSelfContainedBundle(bundle)) {
      // v2+: HMAC-SHA256 keyed verification is mandatory
      if (!bundle.isSelfContained || bundle.hmac == null) {
        return false;
      }
      return EncryptionUtils.verifyHmac([
        bundle.encryptedMetadata,
        bundle.encryptedKeys,
        bundle.encryptedPreferences,
        bundle.encryptedDatabase!,
        bundle.exportType.name,
        bundle.baseTimestamp?.toIso8601String() ?? '',
      ], key, bundle.hmac!);
    } else if (bundle.version == '1.0.0' && bundle.checksum != null) {
      // v1 legacy only: unkeyed SHA-256 (backward compat)
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
    return version == '1.0.0' || version == '2.0.0' || version == '2.1.0';
  }

  /// v2+ bundles MUST be self-contained with HMAC — legacy checksum is not
  /// acceptable for these versions.
  static bool _requiresSelfContainedBundle(ExportBundle bundle) {
    return bundle.version == '2.0.0' || bundle.version == '2.1.0';
  }

  // ──────────────────── Resumable import checkpoint ────────────────────

  /// Check whether an interrupted import left a checkpoint to resume.
  static Future<bool> hasPendingCheckpoint() async {
    final path = await _checkpointPath();
    return File(path).existsSync();
  }

  /// Resume an import that was interrupted after data was cleared.
  ///
  /// Returns null if no checkpoint exists.
  static Future<ImportResult?> resumePendingImport() async {
    final checkpoint = await _loadCheckpoint();
    if (checkpoint == null) return null;

    _logger.info('🔄 Resuming interrupted import from checkpoint...');

    try {
      final dbRestorePath = checkpoint['dbRestorePath'] as String;
      final keys = checkpoint['keys'] as Map<String, dynamic>;
      final preferences = checkpoint['preferences'] as Map<String, dynamic>;
      final exportTypeName = checkpoint['exportType'] as String;
      final clearExistingData = checkpoint['clearExistingData'] as bool;
      final meta = checkpoint['bundleMetadata'] as Map<String, dynamic>;

      final exportType = ExportType.values.firstWhere(
        (e) => e.name == exportTypeName,
        orElse: () => ExportType.full,
      );

      // Verify the temp DB file still exists
      if (!File(dbRestorePath).existsSync()) {
        await _clearCheckpoint();
        return ImportResult.failure(
          'Checkpoint recovery failed: temp database file missing. '
          'Please re-import from the original bundle.',
        );
      }

      // Resume from step 9: restore keys
      _logger.info('Restoring encryption keys...');
      await _restoreKeys(keys);
      _logger.info('Keys restored to secure storage');

      // Step 10: restore database
      _logger.info('Restoring database ($exportTypeName)...');
      int recordsRestored = 0;

      if (exportType == ExportType.full) {
        final restoreResult = await DatabaseBackupService.restoreBackup(
          backupPath: dbRestorePath,
          validateChecksum: false, // already verified before checkpoint
        );
        if (!restoreResult.success) {
          return ImportResult.failure(
            'Resume failed at database restore: ${restoreResult.errorMessage}',
          );
        }
        recordsRestored = restoreResult.recordsRestored ?? 0;
      } else {
        final selectiveRestore =
            await SelectiveRestoreService.restoreSelectiveBackup(
              backupPath: dbRestorePath,
              exportType: exportType,
              clearExistingData: clearExistingData,
            );
        if (!selectiveRestore.success) {
          return ImportResult.failure(
            'Resume failed at selective restore: ${selectiveRestore.errorMessage}',
          );
        }
        recordsRestored = selectiveRestore.recordsRestored;
      }

      _logger.info('Database restored: $recordsRestored records');

      // Step 11: clean up temp DB
      if (meta['isSelfContained'] == true) {
        try {
          await File(dbRestorePath).delete();
        } catch (_) {}
      }

      // Step 12: restore preferences
      _logger.info('Restoring preferences...');
      await _restorePreferences(preferences);
      _logger.info('Preferences restored');

      // Step 13: success
      await _clearCheckpoint();
      await _resetAttempts();
      _logger.info('✅ Resumed import complete ($exportTypeName)!');

      return ImportResult.success(
        recordsRestored: recordsRestored,
        originalDeviceId: meta['deviceId'] as String? ?? 'unknown',
        originalUsername: meta['username'] as String? ?? 'unknown',
        backupTimestamp:
            DateTime.tryParse(meta['timestamp'] as String? ?? '') ??
                DateTime.now(),
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Resume from checkpoint failed', e, stackTrace);
      return ImportResult.failure('Resume failed: $e');
    }
  }

  /// Discard a pending checkpoint (e.g. user chooses to start fresh).
  static Future<void> discardCheckpoint() async {
    final checkpoint = await _loadCheckpoint();
    if (checkpoint != null) {
      // Clean up the temp DB file if it exists
      final dbPath = checkpoint['dbRestorePath'] as String?;
      if (dbPath != null) {
        try {
          await File(dbPath).delete();
        } catch (_) {}
      }
    }
    await _clearCheckpoint();
    _logger.info('Discarded pending import checkpoint');
  }

  static Future<String> _checkpointPath() async {
    final dbDir = await DatabaseHelper.getDatabasePath();
    final dir = File(dbDir).parent.path;
    return '$dir${Platform.pathSeparator}$_checkpointFileName';
  }

  static Future<void> _saveCheckpoint({
    required String dbRestorePath,
    required Map<String, dynamic> keys,
    required Map<String, dynamic> preferences,
    required String exportType,
    required bool clearExistingData,
    required Map<String, dynamic> bundleMetadata,
  }) async {
    // Non-sensitive metadata written to disk
    final data = {
      'dbRestorePath': dbRestorePath,
      'exportType': exportType,
      'clearExistingData': clearExistingData,
      'bundleMetadata': bundleMetadata,
      'savedAt': DateTime.now().toIso8601String(),
    };

    final path = await _checkpointPath();
    await File(path).writeAsString(jsonEncode(data));

    // Sensitive keys/preferences go to secure storage, never plaintext disk
    const storage = FlutterSecureStorage();
    final sensitive = jsonEncode({'keys': keys, 'preferences': preferences});
    await storage.write(key: _checkpointSensitiveKey, value: sensitive);

    _logger.info('💾 Import checkpoint saved (keys in secure storage)');
  }

  static Future<Map<String, dynamic>?> _loadCheckpoint() async {
    try {
      final path = await _checkpointPath();
      final file = File(path);
      if (!file.existsSync()) return null;

      final json = await file.readAsString();
      final data = jsonDecode(json) as Map<String, dynamic>;

      // Merge sensitive data back from secure storage
      const storage = FlutterSecureStorage();
      final sensitiveJson = await storage.read(key: _checkpointSensitiveKey);
      if (sensitiveJson != null) {
        final sensitive =
            jsonDecode(sensitiveJson) as Map<String, dynamic>;
        data['keys'] = sensitive['keys'];
        data['preferences'] = sensitive['preferences'];
      }

      return data;
    } catch (e) {
      _logger.warning('Failed to load checkpoint: $e');
      return null;
    }
  }

  static Future<void> _clearCheckpoint() async {
    try {
      final path = await _checkpointPath();
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
        _logger.info('🧹 Import checkpoint cleared');
      }
      // Also wipe sensitive data from secure storage
      const storage = FlutterSecureStorage();
      await storage.delete(key: _checkpointSensitiveKey);
    } catch (e) {
      _logger.fine('Failed to clear checkpoint: $e');
    }
  }

  // ──────────────────── Import rate limiting ────────────────────

  /// Check if a cooldown is active from previous failed attempts.
  /// Returns Duration.zero if no cooldown, otherwise the remaining wait time.
  static Future<Duration> _checkCooldown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trackerJson = prefs.getString(_attemptTrackerKey);
      if (trackerJson == null) return Duration.zero;

      final tracker = jsonDecode(trackerJson) as Map<String, dynamic>;
      final failCount = tracker['failCount'] as int? ?? 0;
      final lastFailTime = tracker['lastFailTime'] as int? ?? 0;

      if (failCount == 0) return Duration.zero;

      final backoffIdx = failCount.clamp(0, _backoffScheduleMs.length - 1);
      final cooldownMs = _backoffScheduleMs[backoffIdx];
      final elapsed = DateTime.now().millisecondsSinceEpoch - lastFailTime;
      final remaining = cooldownMs - elapsed;

      if (remaining <= 0) return Duration.zero;

      _logger.warning(
        '⏳ Import rate limit: ${(remaining / 1000).ceil()}s remaining '
        '(attempt ${failCount + 1})',
      );
      return Duration(milliseconds: remaining);
    } catch (e) {
      _logger.fine('Rate limit check failed, allowing attempt: $e');
      return Duration.zero;
    }
  }

  /// Record a failed passphrase attempt and escalate the backoff.
  static Future<void> _recordFailedAttempt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trackerJson = prefs.getString(_attemptTrackerKey);
      int failCount = 0;

      if (trackerJson != null) {
        final tracker = jsonDecode(trackerJson) as Map<String, dynamic>;
        failCount = tracker['failCount'] as int? ?? 0;
      }

      failCount++;
      final tracker = {
        'failCount': failCount,
        'lastFailTime': DateTime.now().millisecondsSinceEpoch,
      };

      await prefs.setString(_attemptTrackerKey, jsonEncode(tracker));
      final backoffIdx = failCount.clamp(0, _backoffScheduleMs.length - 1);
      _logger.warning(
        '🚫 Failed import attempt #$failCount. '
        'Next cooldown: ${_backoffScheduleMs[backoffIdx]}ms',
      );
    } catch (e) {
      _logger.fine('Failed to record attempt: $e');
    }
  }

  /// Reset attempt tracker after a successful import.
  static Future<void> _resetAttempts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_attemptTrackerKey);
    } catch (e) {
      _logger.fine('Failed to reset attempts: $e');
    }
  }
}
