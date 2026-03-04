import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' hide equals;
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/preferences_repository.dart';
import 'package:pak_connect/data/services/export_import/encryption_utils.dart';
import 'package:pak_connect/data/services/export_import/export_bundle.dart';
import 'package:pak_connect/data/services/export_import/import_service.dart';
import 'package:pak_connect/data/services/export_import/selective_backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/test_setup.dart';

void main() {
  final logRecords = <LogRecord>[];
  const allowedSeverePatterns = {'Import failed'};

  late Directory artifactDir;

  Future<void> insertContact({
    required String publicKey,
    required String displayName,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('contacts', {
      'public_key': publicKey,
      'display_name': displayName,
      'trust_status': 1,
      'security_level': 2,
      'first_seen': now,
      'last_seen': now,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<String> writeBundleFile({
    required String passphrase,
    required String databasePath,
    ExportType exportType = ExportType.contactsOnly,
    String version = '1.0.0',
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? keys,
    Map<String, dynamic>? preferences,
    String? checksumOverride,
  }) async {
    final salt = EncryptionUtils.generateSalt();
    final key = EncryptionUtils.deriveKey(passphrase, salt);

    final metadataPayload =
        metadata ??
        {
          'database_version': DatabaseHelper.currentVersion,
          'total_records': 1,
          'table_counts': {'contacts': 1},
        };

    final keysPayload =
        keys ??
        {
          'database_encryption_key': 'db-key-from-bundle',
          'ecdh_public_key': 'bundle-public-key',
          'ecdh_private_key': 'bundle-private-key',
          'key_version': 'v2',
        };

    final prefsPayload =
        preferences ??
        {
          'app_preferences': {'phase3_pref': 'enabled'},
          'username': 'Imported User',
          'device_id': 'imported-device-id',
          'theme_mode': 'dark',
        };

    final encryptedMetadata = EncryptionUtils.encrypt(
      jsonEncode(metadataPayload),
      key,
    );
    final encryptedKeys = EncryptionUtils.encrypt(jsonEncode(keysPayload), key);
    final encryptedPreferences = EncryptionUtils.encrypt(
      jsonEncode(prefsPayload),
      key,
    );

    final checksum =
        checksumOverride ??
        EncryptionUtils.calculateChecksum([
          encryptedMetadata,
          encryptedKeys,
          encryptedPreferences,
          databasePath,
        ]);

    final bundle = ExportBundle(
      version: version,
      timestamp: DateTime.now(),
      deviceId: 'source-device-id',
      username: 'Source User',
      exportType: exportType,
      encryptedMetadata: encryptedMetadata,
      encryptedKeys: encryptedKeys,
      encryptedPreferences: encryptedPreferences,
      databasePath: databasePath,
      salt: salt,
      checksum: checksum,
    );

    final bundlePath = join(
      artifactDir.path,
      'bundle_${DateTime.now().microsecondsSinceEpoch}.pakconnect',
    );
    await File(bundlePath).writeAsString(jsonEncode(bundle.toJson()));
    return bundlePath;
  }

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'phase3_import_service');
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);

    await TestSetup.configureTestDatabase(label: 'phase3_import_service');
    TestSetup.resetSharedPreferences();

    const storage = FlutterSecureStorage();
    await storage.deleteAll();

    await DatabaseHelper.database;
    final dbPath = await DatabaseHelper.getDatabasePath();
    artifactDir = Directory(join(dirname(dbPath), 'phase3_import_artifacts'));
    if (await artifactDir.exists()) {
      await artifactDir.delete(recursive: true);
    }
    await artifactDir.create(recursive: true);
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

    if (await artifactDir.exists()) {
      await artifactDir.delete(recursive: true);
    }
    await DatabaseHelper.close();
  });

  group('ImportService.validateBundle', () {
    test('returns invalid result when bundle file does not exist', () async {
      final result = await ImportService.validateBundle(
        bundlePath: join(artifactDir.path, 'missing.pakconnect'),
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(result['error'], contains('not found'));
    });

    test('returns invalid result for wrong passphrase', () async {
      final bundlePath = await writeBundleFile(
        passphrase: 'CorrectPassphrase123!',
        databasePath: join(artifactDir.path, 'db.db'),
      );

      final result = await ImportService.validateBundle(
        bundlePath: bundlePath,
        userPassphrase: 'WrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(result['error'], contains('Invalid passphrase'));
    });

    test('returns invalid result when checksum does not match', () async {
      final bundlePath = await writeBundleFile(
        passphrase: 'StrongPassphrase123!',
        databasePath: join(artifactDir.path, 'db.db'),
        checksumOverride: 'bad-checksum',
      );

      final result = await ImportService.validateBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(result['error'], contains('Checksum mismatch'));
    });
  });

  group('ImportService.importBundle', () {
    test('fails when bundle file is missing', () async {
      final result = await ImportService.importBundle(
        bundlePath: join(artifactDir.path, 'missing_import.pakconnect'),
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Bundle file not found'));
    });

    test('fails when bundle version is incompatible', () async {
      final bundlePath = await writeBundleFile(
        passphrase: 'StrongPassphrase123!',
        databasePath: join(artifactDir.path, 'db.db'),
        version: '2.0.0',
      );

      final result = await ImportService.importBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Incompatible bundle version'));
    });

    test('fails when required keys are missing in bundle payload', () async {
      final placeholderDb = File(join(artifactDir.path, 'placeholder.db'));
      await placeholderDb.writeAsString('placeholder');

      final bundlePath = await writeBundleFile(
        passphrase: 'StrongPassphrase123!',
        databasePath: placeholderDb.path,
        keys: {
          'database_encryption_key': 'db-key-only',
          'ecdh_public_key': 'missing-private-key',
        },
      );

      final result = await ImportService.importBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
        clearExistingData: false,
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Missing required keys'));
    });

    test('fails when referenced database file is absent', () async {
      final bundlePath = await writeBundleFile(
        passphrase: 'StrongPassphrase123!',
        databasePath: join(artifactDir.path, 'missing_database.db'),
      );

      final result = await ImportService.importBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
        clearExistingData: false,
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Database file not found'));
    });

    test(
      'restores contacts, secure keys, shared preferences, and typed app preferences',
      () async {
        await insertContact(
          publicKey: 'import-contact-key',
          displayName: 'Import Contact',
        );

        final selectiveBackup =
            await SelectiveBackupService.createSelectiveBackup(
              exportType: ExportType.contactsOnly,
              customBackupDir: artifactDir.path,
            );
        expect(selectiveBackup.success, isTrue);
        expect(selectiveBackup.backupPath, isNotNull);

        final bundlePath = await writeBundleFile(
          passphrase: 'StrongPassphrase123!',
          databasePath: selectiveBackup.backupPath!,
          preferences: {
            'app_preferences': {
              'pref_string': 'value',
              'pref_bool': true,
              'pref_int': 7,
              'pref_double': 2.5,
            },
            'username': 'Restored User',
            'device_id': 'restored-device-id',
            'theme_mode': 'light',
          },
        );

        final db = await DatabaseHelper.database;
        await db.delete('contacts');
        // DatabaseHelper.clearAllData() expects these helper tables.
        await db.execute(
          'CREATE TABLE IF NOT EXISTS messages_fts (dummy TEXT)',
        );
        await db.execute(
          'CREATE TABLE IF NOT EXISTS archived_messages_fts (dummy TEXT)',
        );

        const storage = FlutterSecureStorage();
        await storage.write(key: 'db_encryption_key_v1', value: 'old-db-key');
        await storage.write(key: 'ecdh_public_key_v2', value: 'old-public-key');
        await storage.write(
          key: 'ecdh_private_key_v2',
          value: 'old-private-key',
        );

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_display_name', 'Old User');
        await prefs.setString('my_persistent_device_id', 'old-device-id');
        await prefs.setString('theme_mode', 'dark');

        final result = await ImportService.importBundle(
          bundlePath: bundlePath,
          userPassphrase: 'StrongPassphrase123!',
          clearExistingData: true,
        );

        expect(result.success, isTrue);
        expect(result.recordsRestored, equals(1));
        expect(result.originalDeviceId, equals('source-device-id'));
        expect(result.originalUsername, equals('Source User'));

        final restoredDb = await DatabaseHelper.database;
        final restoredContacts = await restoredDb.query('contacts');
        expect(restoredContacts.length, equals(1));
        expect(
          restoredContacts.first['public_key'],
          equals('import-contact-key'),
        );

        expect(
          await storage.read(key: 'db_encryption_key_v1'),
          equals('db-key-from-bundle'),
        );
        expect(
          await storage.read(key: 'ecdh_public_key_v2'),
          equals('bundle-public-key'),
        );
        expect(
          await storage.read(key: 'ecdh_private_key_v2'),
          equals('bundle-private-key'),
        );

        expect(prefs.getString('user_display_name'), equals('Restored User'));
        expect(
          prefs.getString('my_persistent_device_id'),
          equals('restored-device-id'),
        );
        expect(prefs.getString('theme_mode'), equals('light'));

        final repo = PreferencesRepository();
        expect(
          await repo.getString('pref_string', defaultValue: ''),
          equals('value'),
        );
        expect(await repo.getBool('pref_bool', defaultValue: false), isTrue);
        expect(await repo.getInt('pref_int', defaultValue: 0), equals(7));
        expect(
          await repo.getDouble('pref_double', defaultValue: 0.0),
          closeTo(2.5, 0.001),
        );
      },
    );
  });
}
