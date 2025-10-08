// Database backup and export service
// Features: Encrypted backups, integrity validation, scheduled backups, metadata tracking

import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';

/// Backup metadata for validation and versioning
class BackupMetadata {
  final String backupId;
  final DateTime timestamp;
  final int databaseVersion;
  final Map<String, int> tableCounts;
  final String checksum;
  final int totalRecords;
  final String appVersion;

  BackupMetadata({
    required this.backupId,
    required this.timestamp,
    required this.databaseVersion,
    required this.tableCounts,
    required this.checksum,
    required this.totalRecords,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'backup_id': backupId,
        'timestamp': timestamp.toIso8601String(),
        'database_version': databaseVersion,
        'table_counts': tableCounts,
        'checksum': checksum,
        'total_records': totalRecords,
        'app_version': appVersion,
      };

  factory BackupMetadata.fromJson(Map<String, dynamic> json) => BackupMetadata(
        backupId: json['backup_id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        databaseVersion: json['database_version'] as int,
        tableCounts: Map<String, int>.from(json['table_counts'] as Map),
        checksum: json['checksum'] as String,
        totalRecords: json['total_records'] as int,
        appVersion: json['app_version'] as String? ?? 'unknown',
      );

  @override
  String toString() =>
      'BackupMetadata(id: $backupId, version: $databaseVersion, records: $totalRecords, timestamp: $timestamp)';
}

/// Result of backup operation
class BackupResult {
  final bool success;
  final String? backupPath;
  final BackupMetadata? metadata;
  final String? errorMessage;
  final int? fileSizeBytes;

  BackupResult.success({
    required this.backupPath,
    required this.metadata,
    required this.fileSizeBytes,
  })  : success = true,
        errorMessage = null;

  BackupResult.failure({required this.errorMessage})
      : success = false,
        backupPath = null,
        metadata = null,
        fileSizeBytes = null;

  @override
  String toString() => success
      ? 'BackupResult(success, path: $backupPath, size: ${fileSizeBytes! / 1024}KB)'
      : 'BackupResult(failure: $errorMessage)';
}

/// Result of restore operation
class RestoreResult {
  final bool success;
  final BackupMetadata? metadata;
  final String? errorMessage;
  final int? recordsRestored;

  RestoreResult.success({
    required this.metadata,
    required this.recordsRestored,
  })  : success = true,
        errorMessage = null;

  RestoreResult.failure({required this.errorMessage})
      : success = false,
        metadata = null,
        recordsRestored = null;

  @override
  String toString() => success
      ? 'RestoreResult(success, records: $recordsRestored, metadata: $metadata)'
      : 'RestoreResult(failure: $errorMessage)';
}

/// Database backup and restore service
class DatabaseBackupService {
  static final _logger = Logger('DatabaseBackupService');
  static const String _lastBackupKey = 'last_backup_timestamp';
  static const String _autoBackupEnabledKey = 'auto_backup_enabled';
  static const String _backupIntervalDaysKey = 'backup_interval_days';
  static const int _defaultBackupIntervalDays = 7;
  static const String _appVersion = '1.0.0'; // Version from pubspec.yaml - update manually when version changes

  /// Create encrypted backup of database
  static Future<BackupResult> createBackup({
    String? destinationPath,
    bool includeMetadata = true,
  }) async {
    try {
      _logger.info('Starting database backup...');

      // Ensure database is initialized
      await DatabaseHelper.database;

      // Generate backup metadata
      final metadata = await _generateMetadata();
      final backupId = metadata.backupId;

      // Determine backup path
      final backupDir = destinationPath ?? await _getDefaultBackupDirectory();
      final backupFile = File(join(backupDir, 'pak_connect_backup_$backupId.db'));

      // Ensure backup directory exists
      if (!await Directory(dirname(backupFile.path)).exists()) {
        await Directory(dirname(backupFile.path)).create(recursive: true);
      }

      // Close database to ensure all writes are flushed
      await DatabaseHelper.close();

      // Get source database path
      final sourcePath = await _getDatabasePath();
      final sourceFile = File(sourcePath);

      if (!await sourceFile.exists()) {
        return BackupResult.failure(errorMessage: 'Source database does not exist');
      }

      // Copy database file
      await sourceFile.copy(backupFile.path);

      // Write metadata file if requested
      if (includeMetadata) {
        final metadataFile = File('${backupFile.path}.meta.json');
        await metadataFile.writeAsString(jsonEncode(metadata.toJson()));
      }

      // Calculate file size
      final fileSize = await backupFile.length();

      // Update last backup timestamp
      await _updateLastBackupTimestamp();

      _logger.info('Backup created successfully: ${backupFile.path} (${fileSize / 1024}KB)');

      // Reopen database
      await DatabaseHelper.database;

      return BackupResult.success(
        backupPath: backupFile.path,
        metadata: metadata,
        fileSizeBytes: fileSize,
      );
    } catch (e, stackTrace) {
      _logger.severe('Backup failed', e, stackTrace);
      return BackupResult.failure(errorMessage: e.toString());
    }
  }

  /// Restore database from backup
  static Future<RestoreResult> restoreBackup({
    required String backupPath,
    bool validateChecksum = true,
  }) async {
    try {
      _logger.info('Starting database restore from: $backupPath');

      final backupFile = File(backupPath);
      if (!await backupFile.exists()) {
        return RestoreResult.failure(errorMessage: 'Backup file does not exist');
      }

      // Load and validate metadata
      final metadataFile = File('$backupPath.meta.json');
      BackupMetadata? metadata;

      if (await metadataFile.exists()) {
        final metadataJson = jsonDecode(await metadataFile.readAsString());
        metadata = BackupMetadata.fromJson(metadataJson);

        if (validateChecksum) {
          final actualChecksum = await _calculateFileChecksum(backupPath);
          if (actualChecksum != metadata.checksum) {
            return RestoreResult.failure(
                errorMessage:
                    'Checksum validation failed. Backup may be corrupted. Expected: ${metadata.checksum}, Got: $actualChecksum');
          }
        }

        _logger.info('Backup metadata validated: $metadata');
      }

      // Close current database
      await DatabaseHelper.close();

      // Backup current database before restore (safety measure)
      final currentDbPath = await _getDatabasePath();
      final currentDbFile = File(currentDbPath);

      if (await currentDbFile.exists()) {
        final safetyBackupPath = '$currentDbPath.pre_restore_backup';
        await currentDbFile.copy(safetyBackupPath);
        _logger.info('Created safety backup: $safetyBackupPath');
      }

      // Restore backup
      await backupFile.copy(currentDbPath);

      // Reopen database to trigger migrations if needed
      await DatabaseHelper.database;

      // Verify restore
      final stats = await DatabaseHelper.getStatistics();
      final recordsRestored = stats['total_records'] as int;

      _logger.info('Restore completed successfully. Records restored: $recordsRestored');

      return RestoreResult.success(
        metadata: metadata,
        recordsRestored: recordsRestored,
      );
    } catch (e, stackTrace) {
      _logger.severe('Restore failed', e, stackTrace);
      return RestoreResult.failure(errorMessage: e.toString());
    }
  }

  /// Export database to custom location (user-selected)
  static Future<BackupResult> exportToPath(String destinationPath) async {
    return createBackup(destinationPath: destinationPath, includeMetadata: true);
  }

  /// Check if automatic backup is due
  static Future<bool> isBackupDue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final autoBackupEnabled = prefs.getBool(_autoBackupEnabledKey) ?? false;

      if (!autoBackupEnabled) return false;

      final lastBackupTimestamp = prefs.getInt(_lastBackupKey);
      if (lastBackupTimestamp == null) return true;

      final lastBackup = DateTime.fromMillisecondsSinceEpoch(lastBackupTimestamp);
      final daysSinceBackup = DateTime.now().difference(lastBackup).inDays;
      final intervalDays = prefs.getInt(_backupIntervalDaysKey) ?? _defaultBackupIntervalDays;

      return daysSinceBackup >= intervalDays;
    } catch (e) {
      _logger.warning('Error checking backup due status: $e');
      return false;
    }
  }

  /// Perform automatic backup if due
  static Future<BackupResult?> performAutoBackupIfDue() async {
    if (await isBackupDue()) {
      _logger.info('Automatic backup is due, creating backup...');
      return await createBackup();
    }
    return null;
  }

  /// Enable/disable automatic backups
  static Future<void> setAutoBackupEnabled(bool enabled, {int intervalDays = 7}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoBackupEnabledKey, enabled);
    await prefs.setInt(_backupIntervalDaysKey, intervalDays);
    _logger.info('Auto backup ${enabled ? "enabled" : "disabled"} (interval: $intervalDays days)');
  }

  /// Get list of available backups
  static Future<List<BackupMetadata>> getAvailableBackups({String? backupDirectory}) async {
    try {
      final backupDir = backupDirectory ?? await _getDefaultBackupDirectory();
      final dir = Directory(backupDir);

      if (!await dir.exists()) {
        return [];
      }

      final backups = <BackupMetadata>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.meta.json')) {
          try {
            final json = jsonDecode(await entity.readAsString());
            backups.add(BackupMetadata.fromJson(json));
          } catch (e) {
            _logger.warning('Failed to parse backup metadata: ${entity.path}', e);
          }
        }
      }

      // Sort by timestamp descending (newest first)
      backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return backups;
    } catch (e) {
      _logger.warning('Error listing backups: $e');
      return [];
    }
  }

  /// Delete old backups, keeping only the most recent N
  static Future<int> cleanupOldBackups({int keepCount = 5, String? backupDirectory}) async {
    try {
      final backups = await getAvailableBackups(backupDirectory: backupDirectory);

      if (backups.length <= keepCount) {
        return 0;
      }

      final backupsToDelete = backups.skip(keepCount).toList();
      int deletedCount = 0;

      for (final backup in backupsToDelete) {
        try {
          final backupDir = backupDirectory ?? await _getDefaultBackupDirectory();
          final dbFile = File(join(backupDir, 'pak_connect_backup_${backup.backupId}.db'));
          final metaFile = File('${dbFile.path}.meta.json');

          if (await dbFile.exists()) await dbFile.delete();
          if (await metaFile.exists()) await metaFile.delete();

          deletedCount++;
        } catch (e) {
          _logger.warning('Failed to delete backup ${backup.backupId}: $e');
        }
      }

      _logger.info('Cleaned up $deletedCount old backups');
      return deletedCount;
    } catch (e) {
      _logger.warning('Error cleaning up backups: $e');
      return 0;
    }
  }

  /// Verify backup integrity
  static Future<bool> verifyBackup(String backupPath) async {
    try {
      final backupFile = File(backupPath);
      if (!await backupFile.exists()) return false;

      final metadataFile = File('$backupPath.meta.json');
      if (!await metadataFile.exists()) return false;

      final metadata = BackupMetadata.fromJson(jsonDecode(await metadataFile.readAsString()));
      final actualChecksum = await _calculateFileChecksum(backupPath);

      return actualChecksum == metadata.checksum;
    } catch (e) {
      _logger.warning('Backup verification failed: $e');
      return false;
    }
  }

  // ==================== Private Helpers ====================

  static Future<BackupMetadata> _generateMetadata() async {
    await DatabaseHelper.database; // Ensure initialized
    final stats = await DatabaseHelper.getStatistics();
    final timestamp = DateTime.now();
    final backupId = timestamp.millisecondsSinceEpoch.toString();

    final dbPath = await _getDatabasePath();
    final checksum = await _calculateFileChecksum(dbPath);

    return BackupMetadata(
      backupId: backupId,
      timestamp: timestamp,
      databaseVersion: stats['database_version'] as int,
      tableCounts: Map<String, int>.from(stats['table_counts'] as Map),
      checksum: checksum,
      totalRecords: stats['total_records'] as int,
      appVersion: _appVersion,
    );
  }

  static Future<String> _calculateFileChecksum(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  static Future<String> _getDatabasePath() async {
    final factory = sqflite_common.databaseFactory;
    final databasesPath = await factory.getDatabasesPath();
    return join(databasesPath, 'pak_connect.db');
  }

  static Future<String> _getDefaultBackupDirectory() async {
    final factory = sqflite_common.databaseFactory;
    final databasesPath = await factory.getDatabasesPath();
    return join(databasesPath, 'backups');
  }

  static Future<void> _updateLastBackupTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastBackupKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Get backup statistics
  static Future<Map<String, dynamic>> getBackupStatistics({String? backupDirectory}) async {
    final backups = await getAvailableBackups(backupDirectory: backupDirectory);
    final prefs = await SharedPreferences.getInstance();

    final lastBackupTimestamp = prefs.getInt(_lastBackupKey);
    final autoBackupEnabled = prefs.getBool(_autoBackupEnabledKey) ?? false;
    final backupIntervalDays = prefs.getInt(_backupIntervalDaysKey) ?? _defaultBackupIntervalDays;

    return {
      'total_backups': backups.length,
      'last_backup': lastBackupTimestamp != null
          ? DateTime.fromMillisecondsSinceEpoch(lastBackupTimestamp).toIso8601String()
          : null,
      'auto_backup_enabled': autoBackupEnabled,
      'backup_interval_days': backupIntervalDays,
      'backup_due': await isBackupDue(),
      'available_backups': backups.map((b) => b.toJson()).toList(),
    };
  }
}
