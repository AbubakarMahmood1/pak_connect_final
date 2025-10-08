// Import service for restoring encrypted data bundles
// Restores .pakconnect files with all user data and encryption keys

import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database_helper.dart';
import '../../database/database_backup_service.dart';
import '../../repositories/preferences_repository.dart';
import 'export_bundle.dart';
import 'encryption_utils.dart';

class ImportService {
  static final _logger = Logger('ImportService');
  
  /// Import and restore from encrypted bundle
  /// 
  /// WARNING: This will REPLACE all existing data!
  /// Returns ImportResult with details of the restore operation
  static Future<ImportResult> importBundle({
    required String bundlePath,
    required String userPassphrase,
    bool clearExistingData = true,
  }) async {
    try {
      _logger.info('🔐 Starting import process...');
      _logger.info('Bundle: $bundlePath');
      
      // 1. Read and parse bundle file
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
      
      // 2. Validate version compatibility
      _logger.info('Validating version compatibility...');
      if (!_isCompatibleVersion(bundle.version)) {
        return ImportResult.failure(
          'Incompatible bundle version: ${bundle.version}. '
          'Expected: 1.0.0',
        );
      }
      
      // 3. Derive decryption key from passphrase
      _logger.info('Deriving decryption key...');
      final decryptionKey = EncryptionUtils.deriveKey(
        userPassphrase,
        bundle.salt,
      );
      
      // 4. Decrypt and verify metadata first (validates passphrase)
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
      _logger.fine('Bundle contains ${metadata['total_records']} total records');
      
      // 5. Verify checksum
      _logger.info('Verifying bundle integrity...');
      final calculatedChecksum = EncryptionUtils.calculateChecksum([
        bundle.encryptedMetadata,
        bundle.encryptedKeys,
        bundle.encryptedPreferences,
        bundle.databasePath,
      ]);
      
      if (calculatedChecksum != bundle.checksum) {
        return ImportResult.failure(
          'Bundle integrity check failed. '
          'File may be corrupted or tampered with.',
        );
      }
      
      _logger.info('Bundle integrity verified');
      
      // 6. Decrypt keys and preferences
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
      
      _logger.info('All data decrypted successfully');
      
      // 7. Clear existing data if requested
      if (clearExistingData) {
        _logger.warning('⚠️ Clearing all existing data...');
        await _clearExistingData();
        _logger.info('Existing data cleared');
      }
      
      // 8. Restore encryption keys to secure storage
      _logger.info('Restoring encryption keys...');
      await _restoreKeys(keys);
      _logger.info('Keys restored to secure storage');
      
      // 9. Verify database file exists
      final dbFile = File(bundle.databasePath);
      if (!await dbFile.exists()) {
        return ImportResult.failure(
          'Database file not found: ${bundle.databasePath}',
        );
      }
      
      // 10. Restore database
      _logger.info('Restoring database...');
      final restoreResult = await DatabaseBackupService.restoreBackup(
        backupPath: bundle.databasePath,
        validateChecksum: true,
      );
      
      if (!restoreResult.success) {
        return ImportResult.failure(
          'Database restore failed: ${restoreResult.errorMessage}',
        );
      }
      
      _logger.info('Database restored: ${restoreResult.recordsRestored} records');
      
      // 11. Restore preferences
      _logger.info('Restoring preferences...');
      await _restorePreferences(preferences);
      _logger.info('Preferences restored');
      
      // 12. Success!
      _logger.info('✅ Import complete!');
      
      return ImportResult.success(
        recordsRestored: restoreResult.recordsRestored ?? 0,
        originalDeviceId: bundle.deviceId,
        originalUsername: bundle.username,
        backupTimestamp: bundle.timestamp,
      );
      
    } catch (e, stackTrace) {
      _logger.severe('❌ Import failed', e, stackTrace);
      
      // Try to reopen database even if import fails
      try {
        await DatabaseHelper.database;
      } catch (_) {
        // Ignore errors during recovery
      }
      
      return ImportResult.failure('Import failed: $e');
    }
  }
  
  /// Validate bundle without importing
  /// 
  /// Useful for previewing what will be imported
  static Future<Map<String, dynamic>> validateBundle({
    required String bundlePath,
    required String userPassphrase,
  }) async {
    try {
      // Read bundle
      final bundleFile = File(bundlePath);
      if (!await bundleFile.exists()) {
        return {
          'valid': false,
          'error': 'Bundle file not found',
        };
      }
      
      final bundleJson = await bundleFile.readAsString();
      final bundle = ExportBundle.fromJson(
        jsonDecode(bundleJson) as Map<String, dynamic>,
      );
      
      // Check version
      if (!_isCompatibleVersion(bundle.version)) {
        return {
          'valid': false,
          'error': 'Incompatible version: ${bundle.version}',
        };
      }
      
      // Try to decrypt metadata
      final decryptionKey = EncryptionUtils.deriveKey(
        userPassphrase,
        bundle.salt,
      );
      
      final metadataJson = EncryptionUtils.decrypt(
        bundle.encryptedMetadata,
        decryptionKey,
      );
      
      if (metadataJson == null) {
        return {
          'valid': false,
          'error': 'Invalid passphrase',
        };
      }
      
      final metadata = jsonDecode(metadataJson) as Map<String, dynamic>;
      
      // Verify checksum
      final calculatedChecksum = EncryptionUtils.calculateChecksum([
        bundle.encryptedMetadata,
        bundle.encryptedKeys,
        bundle.encryptedPreferences,
        bundle.databasePath,
      ]);
      
      if (calculatedChecksum != bundle.checksum) {
        return {
          'valid': false,
          'error': 'Checksum mismatch - file may be corrupted',
        };
      }
      
      // Success - return bundle info
      return {
        'valid': true,
        'version': bundle.version,
        'timestamp': bundle.timestamp.toIso8601String(),
        'username': bundle.username,
        'device_id': bundle.deviceId,
        'database_version': metadata['database_version'],
        'total_records': metadata['total_records'],
        'table_counts': metadata['table_counts'],
      };
      
    } catch (e) {
      return {
        'valid': false,
        'error': 'Validation failed: $e',
      };
    }
  }
  
  /// Clear all existing data
  /// 
  /// WARNING: This is destructive!
  static Future<void> _clearExistingData() async {
    // Close database before clearing
    await DatabaseHelper.close();
    
    // Clear SQLite database
    await DatabaseHelper.clearAllData();
    
    // Clear SharedPreferences (except migration flags)
    final prefs = await SharedPreferences.getInstance();
    final keysToKeep = [
      'sqlite_migration_completed',
      'first_launch_complete', // Keep first launch flag
    ];
    
    final allKeys = prefs.getKeys();
    for (final key in allKeys) {
      if (!keysToKeep.contains(key)) {
        await prefs.remove(key);
      }
    }
    
    // Clear secure storage
    const storage = FlutterSecureStorage();
    await storage.deleteAll();
  }
  
  /// Restore encryption keys to secure storage
  static Future<void> _restoreKeys(Map<String, dynamic> keys) async {
    const storage = FlutterSecureStorage();
    
    // Validate keys exist
    if (!keys.containsKey('database_encryption_key') ||
        !keys.containsKey('ecdh_public_key') ||
        !keys.containsKey('ecdh_private_key')) {
      throw Exception('Missing required keys in bundle');
    }
    
    // Restore database encryption key
    await storage.write(
      key: 'db_encryption_key_v1',
      value: keys['database_encryption_key'] as String,
    );
    
    // Restore ECDH keypair
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
  
  /// Restore preferences to both repositories
  static Future<void> _restorePreferences(Map<String, dynamic> preferences) async {
    final prefs = await SharedPreferences.getInstance();
    final prefsRepo = PreferencesRepository();
    
    // Restore app preferences to SQLite
    final appPrefs = preferences['app_preferences'] as Map<String, dynamic>?;
    if (appPrefs != null) {
      for (final entry in appPrefs.entries) {
        try {
          // Determine type and restore appropriately
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
    
    // Restore SharedPreferences
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
      await prefs.setString(
        'theme_mode',
        preferences['theme_mode'] as String,
      );
    }
  }
  
  /// Check if bundle version is compatible
  static bool _isCompatibleVersion(String version) {
    // For now, only support 1.0.0
    // Future versions can add migration logic here
    return version == '1.0.0';
  }
}
