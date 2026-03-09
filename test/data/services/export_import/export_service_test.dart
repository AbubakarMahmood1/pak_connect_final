import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' hide equals;
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/services/export_import/export_bundle.dart';
import 'package:pak_connect/data/services/export_import/export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/test_setup.dart';

void main() {
  final logRecords = <LogRecord>[];
  const allowedSeverePatterns = {'Export failed'};

  Future<void> insertContact({
    required String publicKey,
    required String displayName,
  }) async {
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

  Future<void> seedRequiredKeys() async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'db_encryption_key_v1', value: 'db-key-v1');
    await storage.write(key: 'ecdh_public_key_v2', value: 'ecdh-public-key');
    await storage.write(key: 'ecdh_private_key_v2', value: 'ecdh-private-key');
  }

  Future<void> seedUserIdentityPrefs() async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('app_preferences', {
      'key': 'phase3_pref',
      'value': 'enabled',
      'value_type': 'string',
      'created_at': now,
      'updated_at': now,
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_display_name', 'Phase3 User');
    await prefs.setString('my_persistent_device_id', 'phase3-device-id');
    await prefs.setString('theme_mode', 'light');
  }

  Future<void> cleanupArtifacts() async {
    final dbPath = await DatabaseHelper.getDatabasePath();
    final baseDir = dirname(dbPath);

    for (final child in ['exports', 'selective_backups']) {
      final dir = Directory(join(baseDir, child));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  Future<void> deleteBundleAndBackup(String bundlePath) async {
    final bundleFile = File(bundlePath);
    if (!await bundleFile.exists()) {
      return;
    }

    await bundleFile.delete();
  }

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'phase3_export_service');
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);

    await TestSetup.configureTestDatabase(label: 'phase3_export_service');
    TestSetup.resetSharedPreferences();

    const storage = FlutterSecureStorage();
    await storage.deleteAll();

    await DatabaseHelper.database;
    await cleanupArtifacts();
  });

  tearDown(() async {
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) => !allowedSeverePatterns.any(
            (pattern) => log.message.contains(pattern),
          ),
        )
        .toList();

    expect(
      severeErrors,
      isEmpty,
      reason:
          'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
    );

    await DatabaseHelper.close();
  });

  group('ExportService', () {
    test('createExport rejects weak passphrases early', () async {
      final result = await ExportService.createExport(
        userPassphrase: 'short',
        exportType: ExportType.contactsOnly,
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Weak passphrase'));
    });

    test(
      'createExport fails cleanly when secure-storage keys are missing',
      () async {
        await insertContact(publicKey: 'alice-key', displayName: 'Alice');

        final result = await ExportService.createExport(
          userPassphrase: 'StrongPassphrase123!',
          exportType: ExportType.contactsOnly,
        );

        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Missing encryption keys'));

        final db = await DatabaseHelper.database;
        final contacts = await db.query('contacts');
        expect(contacts, isNotEmpty);
      },
    );

    test(
      'createExport builds a contacts-only bundle when requirements are met',
      () async {
        await seedRequiredKeys();
        await seedUserIdentityPrefs();
        await insertContact(publicKey: 'bob-key', displayName: 'Bob');

        final customDir = await Directory.systemTemp.createTemp(
          'pak_export_phase3_',
        );

        final result = await ExportService.createExport(
          userPassphrase: 'StrongPassphrase123!',
          customPath: customDir.path,
          exportType: ExportType.contactsOnly,
        );

        expect(result.success, isTrue);
        expect(result.bundlePath, isNotNull);
        expect(result.recordCount, equals(1));
        expect(result.exportType, equals(ExportType.contactsOnly));

        final bundleFile = File(result.bundlePath!);
        expect(await bundleFile.exists(), isTrue);

        final json =
            jsonDecode(await bundleFile.readAsString()) as Map<String, dynamic>;
        expect(json['version'], equals('2.0.0'));
        expect(json['export_type'], equals('contactsOnly'));
        expect(json['username'], equals('Phase3 User'));
        expect(json['device_id'], equals('phase3-device-id'));
        expect(json.containsKey('encrypted_database'), isTrue,
            reason: 'v2 bundles must embed encrypted database');
        expect(json.containsKey('hmac'), isTrue,
            reason: 'v2 bundles must have HMAC');
        expect(json.containsKey('database_path'), isFalse,
            reason: 'v2 bundles should not have database_path');

        await deleteBundleAndBackup(result.bundlePath!);
        await customDir.delete(recursive: true);
      },
    );

    test(
      'listAvailableExports sorts newest first and cleanup removes old files',
      () async {
        await seedRequiredKeys();
        await seedUserIdentityPrefs();
        await insertContact(publicKey: 'charlie-key', displayName: 'Charlie');

        final first = await ExportService.createExport(
          userPassphrase: 'StrongPassphrase123!',
          exportType: ExportType.contactsOnly,
        );
        expect(first.success, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 5));

        final second = await ExportService.createExport(
          userPassphrase: 'StrongPassphrase123!',
          exportType: ExportType.contactsOnly,
        );
        expect(second.success, isTrue);

        final exportDir = await ExportService.getDefaultExportDirectory();
        await File(
          join(exportDir, 'broken_export.pakconnect'),
        ).writeAsString('{invalid json');

        final exports = await ExportService.listAvailableExports();
        expect(exports.length, equals(2));
        expect(
          exports.first.timestamp.compareTo(exports.last.timestamp),
          greaterThanOrEqualTo(0),
        );

        final deleted = await ExportService.cleanupOldExports(keepCount: 1);
        expect(deleted, equals(1));

        final remaining = await ExportService.listAvailableExports();
        expect(remaining.length, equals(1));

        await deleteBundleAndBackup(first.bundlePath!);
        await deleteBundleAndBackup(second.bundlePath!);
      },
    );

    test('getDefaultExportDirectory is colocated with database path', () async {
      final dbPath = await DatabaseHelper.getDatabasePath();
      final expected = join(dirname(dbPath), 'exports');

      final exportDir = await ExportService.getDefaultExportDirectory();

      expect(exportDir, equals(expected));
    });
  });
}
