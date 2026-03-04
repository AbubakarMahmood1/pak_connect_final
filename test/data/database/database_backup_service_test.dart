import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:pak_connect/data/database/database_backup_service.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/test_setup.dart';

void main() {
  late Directory artifactDir;

  Future<void> insertContact(String publicKey, String displayName) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('contacts', {
      'public_key': publicKey,
      'display_name': displayName,
      'trust_status': 0,
      'security_level': 0,
      'first_seen': now,
      'last_seen': now,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> cleanupBackupDirectories() async {
    final dbPath = await DatabaseHelper.getDatabasePath();
    final baseDir = dirname(dbPath);

    final defaultBackupDir = Directory(join(baseDir, 'backups'));
    if (await defaultBackupDir.exists()) {
      await defaultBackupDir.delete(recursive: true);
    }
  }

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'phase3_database_backup',
    );
  });

  setUp(() async {
    TestSetup.resetSharedPreferences();
    await DatabaseHelper.close();
    DatabaseHelper.setTestDatabaseName(null);
    await DatabaseHelper.deleteDatabase();
    await DatabaseHelper.database;
    await cleanupBackupDirectories();

    final dbPath = await DatabaseHelper.getDatabasePath();
    artifactDir = Directory(join(dirname(dbPath), 'phase3_backup_artifacts'));
    if (await artifactDir.exists()) {
      await artifactDir.delete(recursive: true);
    }
    await artifactDir.create(recursive: true);
  });

  tearDown(() async {
    if (await artifactDir.exists()) {
      await artifactDir.delete(recursive: true);
    }
    await cleanupBackupDirectories();
    await DatabaseHelper.close();
    await DatabaseHelper.deleteDatabase();
  });

  group('BackupMetadata', () {
    test('toJson/fromJson round-trips correctly', () {
      final metadata = BackupMetadata(
        backupId: 'backup-123',
        timestamp: DateTime(2026, 3, 4),
        databaseVersion: 10,
        tableCounts: {'contacts': 3, 'messages': 9},
        checksum: 'abc123',
        totalRecords: 12,
        appVersion: '1.0.0',
      );

      final restored = BackupMetadata.fromJson(metadata.toJson());

      expect(restored.backupId, equals('backup-123'));
      expect(restored.timestamp, equals(DateTime(2026, 3, 4)));
      expect(restored.databaseVersion, equals(10));
      expect(restored.tableCounts['contacts'], equals(3));
      expect(restored.totalRecords, equals(12));
      expect(restored.appVersion, equals('1.0.0'));
    });
  });

  group('DatabaseBackupService', () {
    test('createBackup succeeds and produces verifiable metadata', () async {
      await insertContact('backup-contact', 'Backup Contact');

      final result = await DatabaseBackupService.createBackup(
        includeMetadata: true,
      );

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.backupPath, isNotNull);
      expect(result.metadata, isNotNull);
      expect(result.fileSizeBytes, greaterThan(0));

      final backupPath = result.backupPath!;
      expect(await File(backupPath).exists(), isTrue);
      expect(await File('$backupPath.meta.json').exists(), isTrue);

      final verify = await DatabaseBackupService.verifyBackup(backupPath);
      expect(verify, isA<bool>());

      final available = await DatabaseBackupService.getAvailableBackups();
      expect(available, isNotEmpty);
    });

    test('restoreBackup fails when backup file is missing', () async {
      final result = await DatabaseBackupService.restoreBackup(
        backupPath: join(artifactDir.path, 'missing_backup.db'),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('does not exist'));
    });

    test(
      'restoreBackup detects checksum mismatch when metadata is tampered',
      () async {
        await insertContact('checksum-contact', 'Checksum Contact');

        final sourcePath = await DatabaseHelper.getDatabasePath();
        final tamperedBackupPath = join(artifactDir.path, 'tampered_backup.db');
        await File(sourcePath).copy(tamperedBackupPath);

        final metadata = BackupMetadata(
          backupId: 'tampered',
          timestamp: DateTime.now(),
          databaseVersion: DatabaseHelper.currentVersion,
          tableCounts: {'contacts': 1},
          checksum: 'invalid-checksum',
          totalRecords: 1,
          appVersion: '1.0.0',
        );
        await File(
          '$tamperedBackupPath.meta.json',
        ).writeAsString(jsonEncode(metadata.toJson()));

        final result = await DatabaseBackupService.restoreBackup(
          backupPath: tamperedBackupPath,
          validateChecksum: true,
        );

        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Checksum validation failed'));
      },
    );

    test(
      'isBackupDue honors auto-backup settings and last backup timestamp',
      () async {
        expect(await DatabaseBackupService.isBackupDue(), isFalse);

        await DatabaseBackupService.setAutoBackupEnabled(true, intervalDays: 7);
        expect(await DatabaseBackupService.isBackupDue(), isTrue);

        final backupResult = await DatabaseBackupService.createBackup();
        expect(backupResult.success, isTrue);
        expect(await DatabaseBackupService.isBackupDue(), isFalse);
      },
    );

    test(
      'cleanupOldBackups removes oldest backup files in custom directory',
      () async {
        final backupDir = Directory(join(artifactDir.path, 'cleanup_target'));
        await backupDir.create(recursive: true);

        Future<void> writeBackupEntry({
          required String backupId,
          required DateTime timestamp,
        }) async {
          final dbFile = File(
            join(backupDir.path, 'pak_connect_backup_$backupId.db'),
          );
          await dbFile.writeAsString('backup-$backupId');

          final metadata = BackupMetadata(
            backupId: backupId,
            timestamp: timestamp,
            databaseVersion: 10,
            tableCounts: const {'contacts': 1},
            checksum: 'checksum-$backupId',
            totalRecords: 1,
            appVersion: '1.0.0',
          );

          await File(
            '${dbFile.path}.meta.json',
          ).writeAsString(jsonEncode(metadata.toJson()));
        }

        await writeBackupEntry(backupId: '1', timestamp: DateTime(2026, 1, 1));
        await writeBackupEntry(backupId: '2', timestamp: DateTime(2026, 2, 1));
        await writeBackupEntry(backupId: '3', timestamp: DateTime(2026, 3, 1));

        final deleted = await DatabaseBackupService.cleanupOldBackups(
          keepCount: 1,
          backupDirectory: backupDir.path,
        );

        expect(deleted, equals(2));

        final remaining = await DatabaseBackupService.getAvailableBackups(
          backupDirectory: backupDir.path,
        );
        expect(remaining.length, equals(1));
        expect(remaining.first.backupId, equals('3'));
      },
    );

    test(
      'getBackupStatistics includes preference and backup summary fields',
      () async {
        await DatabaseBackupService.setAutoBackupEnabled(true, intervalDays: 2);
        final result = await DatabaseBackupService.createBackup();
        expect(result.success, isTrue);

        final stats = await DatabaseBackupService.getBackupStatistics();

        expect(stats['total_backups'], greaterThanOrEqualTo(1));
        expect(stats['auto_backup_enabled'], isTrue);
        expect(stats['backup_interval_days'], equals(2));
        expect(stats.containsKey('last_backup'), isTrue);
        expect(stats.containsKey('backup_due'), isTrue);
        expect(stats['available_backups'], isA<List<dynamic>>());
      },
    );

    test(
      'performAutoBackupIfDue returns null when disabled and backup result when enabled',
      () async {
        await DatabaseBackupService.setAutoBackupEnabled(false);
        final skipped = await DatabaseBackupService.performAutoBackupIfDue();
        expect(skipped, isNull);

        await DatabaseBackupService.setAutoBackupEnabled(true, intervalDays: 1);
        final performed = await DatabaseBackupService.performAutoBackupIfDue();
        expect(performed, isNotNull);
        expect(performed!.success, isTrue);
      },
    );
  });
}
