import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  /// Create a **v1** legacy bundle (unkeyed SHA-256 checksum, external DB path).
  Future<String> writeV1BundleFile({
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

  /// Create a **v2** self-contained bundle (HMAC-SHA256, embedded encrypted DB).
  Future<String> writeV2BundleFile({
    required String passphrase,
    required Uint8List databaseBytes,
    ExportType exportType = ExportType.contactsOnly,
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? keys,
    Map<String, dynamic>? preferences,
    String? hmacOverride,
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
    final encryptedDatabase = EncryptionUtils.encrypt(
      base64Encode(databaseBytes),
      key,
    );

    final hmac =
        hmacOverride ??
        EncryptionUtils.calculateHmac([
          encryptedMetadata,
          encryptedKeys,
          encryptedPreferences,
          encryptedDatabase,
        ], key);

    final bundle = ExportBundle(
      version: '2.0.0',
      timestamp: DateTime.now(),
      deviceId: 'source-device-id',
      username: 'Source User',
      exportType: exportType,
      encryptedMetadata: encryptedMetadata,
      encryptedKeys: encryptedKeys,
      encryptedPreferences: encryptedPreferences,
      encryptedDatabase: encryptedDatabase,
      salt: salt,
      hmac: hmac,
    );

    final bundlePath = join(
      artifactDir.path,
      'bundle_v2_${DateTime.now().microsecondsSinceEpoch}.pakconnect',
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

  // ── Existing v1 validation tests (backward compat) ──

  group('ImportService.validateBundle (v1 legacy)', () {
    test('returns invalid result when bundle file does not exist', () async {
      final result = await ImportService.validateBundle(
        bundlePath: join(artifactDir.path, 'missing.pakconnect'),
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(result['error'], contains('not found'));
    });

    test('returns invalid result for wrong passphrase', () async {
      final bundlePath = await writeV1BundleFile(
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
      final bundlePath = await writeV1BundleFile(
        passphrase: 'StrongPassphrase123!',
        databasePath: join(artifactDir.path, 'db.db'),
        checksumOverride: 'bad-checksum',
      );

      final result = await ImportService.validateBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(
        result['error'],
        contains('Integrity check failed'),
      );
    });
  });

  // ── v1 import tests (backward compat) ──

  group('ImportService.importBundle (v1 legacy)', () {
    test('fails when bundle file is missing', () async {
      final result = await ImportService.importBundle(
        bundlePath: join(artifactDir.path, 'missing_import.pakconnect'),
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Bundle file not found'));
    });

    test('fails when bundle version is incompatible', () async {
      final bundlePath = await writeV1BundleFile(
        passphrase: 'StrongPassphrase123!',
        databasePath: join(artifactDir.path, 'db.db'),
        version: '99.0.0',
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

      final bundlePath = await writeV1BundleFile(
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
      final bundlePath = await writeV1BundleFile(
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
      'v1: restores contacts, secure keys, shared preferences, and typed app preferences',
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

        final bundlePath = await writeV1BundleFile(
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

  // ── v2 self-contained bundle tests ──

  group('ImportService v2 self-contained bundles', () {
    test('v2 bundle round-trip: embed DB, import without external file',
        () async {
      await insertContact(
        publicKey: 'v2-contact-key',
        displayName: 'V2 Contact',
      );

      final selectiveBackup =
          await SelectiveBackupService.createSelectiveBackup(
            exportType: ExportType.contactsOnly,
            customBackupDir: artifactDir.path,
          );
      expect(selectiveBackup.success, isTrue);

      // Read actual DB bytes and create a v2 bundle
      final dbBytes = await File(selectiveBackup.backupPath!).readAsBytes();

      final bundlePath = await writeV2BundleFile(
        passphrase: 'StrongPassphrase123!',
        databaseBytes: dbBytes,
      );

      // Delete the original backup file — v2 should not need it
      await File(selectiveBackup.backupPath!).delete();

      final db = await DatabaseHelper.database;
      await db.delete('contacts');
      await db.execute(
        'CREATE TABLE IF NOT EXISTS messages_fts (dummy TEXT)',
      );
      await db.execute(
        'CREATE TABLE IF NOT EXISTS archived_messages_fts (dummy TEXT)',
      );

      const storage = FlutterSecureStorage();
      await storage.write(key: 'db_encryption_key_v1', value: 'old-key');

      final result = await ImportService.importBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
        clearExistingData: true,
      );

      expect(result.success, isTrue);
      expect(result.recordsRestored, equals(1));

      final restoredDb = await DatabaseHelper.database;
      final contacts = await restoredDb.query('contacts');
      expect(contacts.length, equals(1));
      expect(contacts.first['public_key'], equals('v2-contact-key'));
    });

    test('v2 validateBundle reports self_contained: true', () async {
      final dbBytes = Uint8List.fromList(utf8.encode('test-db-placeholder'));
      final bundlePath = await writeV2BundleFile(
        passphrase: 'StrongPassphrase123!',
        databaseBytes: dbBytes,
      );

      final result = await ImportService.validateBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isTrue);
      expect(result['self_contained'], isTrue);
      expect(result['version'], equals('2.0.0'));
    });
  });

  // ── HMAC tamper resistance tests (Phase 3A) ──

  group('HMAC tamper resistance', () {
    test(
      'v2: modifying encrypted payload and recomputing SHA-256 still fails '
      '(HMAC requires the key)',
      () async {
        final dbBytes =
            Uint8List.fromList(utf8.encode('test-db-placeholder'));
        final salt = EncryptionUtils.generateSalt();
        final key =
            EncryptionUtils.deriveKey('StrongPassphrase123!', salt);

        final encMeta = EncryptionUtils.encrypt(
          jsonEncode({
            'database_version': DatabaseHelper.currentVersion,
            'total_records': 0,
            'table_counts': {},
          }),
          key,
        );
        final encKeys = EncryptionUtils.encrypt(
          jsonEncode({
            'database_encryption_key': 'k1',
            'ecdh_public_key': 'k2',
            'ecdh_private_key': 'k3',
            'key_version': 'v2',
          }),
          key,
        );
        final encPrefs = EncryptionUtils.encrypt(
          jsonEncode({
            'app_preferences': {},
            'username': 'u',
            'device_id': 'd',
          }),
          key,
        );
        final encDb = EncryptionUtils.encrypt(
          base64Encode(dbBytes),
          key,
        );

        // Legitimate HMAC
        final legitimateHmac = EncryptionUtils.calculateHmac(
          [encMeta, encKeys, encPrefs, encDb],
          key,
        );

        // Attacker replaces encryptedKeys with their own payload
        final attackerKey = EncryptionUtils.deriveKey('AttackerPass123!',
            EncryptionUtils.generateSalt());
        final tamperedKeys = EncryptionUtils.encrypt(
          jsonEncode({
            'database_encryption_key': 'ATTACKER-DB-KEY',
            'ecdh_public_key': 'ATTACKER-PUB',
            'ecdh_private_key': 'ATTACKER-PRIV',
            'key_version': 'v2',
          }),
          attackerKey,
        );

        // Attacker recomputes plain SHA-256 (would pass old v1 check)
        final attackerSha = EncryptionUtils.calculateChecksum(
          [encMeta, tamperedKeys, encPrefs, encDb],
        );

        // Bundle with tampered keys — using legitimate HMAC (which won't match)
        final bundle = ExportBundle(
          version: '2.0.0',
          timestamp: DateTime.now(),
          deviceId: 'd',
          username: 'u',
          exportType: ExportType.full,
          encryptedMetadata: encMeta,
          encryptedKeys: tamperedKeys,
          encryptedPreferences: encPrefs,
          encryptedDatabase: encDb,
          salt: salt,
          hmac: legitimateHmac, // original HMAC, won't match tampered data
        );

        final bundlePath = join(
          artifactDir.path,
          'tampered_${DateTime.now().microsecondsSinceEpoch}.pakconnect',
        );
        await File(bundlePath).writeAsString(jsonEncode(bundle.toJson()));

        final result = await ImportService.validateBundle(
          bundlePath: bundlePath,
          userPassphrase: 'StrongPassphrase123!',
        );

        expect(result['valid'], isFalse);
        expect(
          result['error'],
          contains('Integrity check failed'),
        );

        // Also: attacker cannot forge the HMAC because they don't have the key
        // (they would need the passphrase to derive it)
        expect(attackerSha, isNot(equals(legitimateHmac)),
            reason: 'SHA-256 ≠ HMAC — different algorithms, different output');
      },
    );

    test('v2: bundle with forged HMAC is rejected', () async {
      final dbBytes = Uint8List.fromList(utf8.encode('db-data'));

      final bundlePath = await writeV2BundleFile(
        passphrase: 'StrongPassphrase123!',
        databaseBytes: dbBytes,
        hmacOverride: 'forged-hmac-value',
      );

      final result = await ImportService.validateBundle(
        bundlePath: bundlePath,
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(result['error'], contains('Integrity check failed'));
    });
  });

  // ── Import ordering safety tests (Phase 3B) ──

  group('Import ordering safety', () {
    test(
      'v1: missing DB file does NOT clear existing data when clearExistingData=true',
      () async {
        // Set up existing data that should be preserved on failure
        const storage = FlutterSecureStorage();
        await storage.write(
          key: 'db_encryption_key_v1',
          value: 'precious-existing-key',
        );
        await storage.write(
          key: 'ecdh_public_key_v2',
          value: 'precious-pub-key',
        );
        await storage.write(
          key: 'ecdh_private_key_v2',
          value: 'precious-priv-key',
        );

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_display_name', 'Original User');

        await insertContact(
          publicKey: 'existing-contact',
          displayName: 'Existing Contact',
        );

        // Create a v1 bundle pointing to a non-existent DB
        final bundlePath = await writeV1BundleFile(
          passphrase: 'StrongPassphrase123!',
          databasePath: join(artifactDir.path, 'DOES_NOT_EXIST.db'),
        );

        final result = await ImportService.importBundle(
          bundlePath: bundlePath,
          userPassphrase: 'StrongPassphrase123!',
          clearExistingData: true,
        );

        // Import should fail
        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Database file not found'));

        // Existing data should be PRESERVED (not wiped)
        expect(
          await storage.read(key: 'db_encryption_key_v1'),
          equals('precious-existing-key'),
          reason: 'Secure storage should not be cleared before DB is verified',
        );
        expect(
          prefs.getString('user_display_name'),
          equals('Original User'),
          reason: 'SharedPreferences should not be cleared before DB is verified',
        );
      },
    );
  });

  // ── ExportBundle model tests (Phase 3D) ──

  group('ExportBundle model v2 support', () {
    test('v2 toJson/fromJson round-trip preserves encryptedDatabase and hmac',
        () {
      final salt = Uint8List.fromList(List.generate(32, (i) => i));
      final bundle = ExportBundle(
        version: '2.0.0',
        timestamp: DateTime(2026, 1, 1),
        deviceId: 'dev',
        username: 'user',
        exportType: ExportType.contactsOnly,
        encryptedMetadata: 'enc-meta',
        encryptedKeys: 'enc-keys',
        encryptedPreferences: 'enc-prefs',
        encryptedDatabase: 'enc-db-data',
        salt: salt,
        hmac: 'hmac-value',
      );

      expect(bundle.isSelfContained, isTrue);
      expect(bundle.isLegacy, isFalse);

      final json = bundle.toJson();
      expect(json.containsKey('encrypted_database'), isTrue);
      expect(json.containsKey('hmac'), isTrue);
      expect(json.containsKey('database_path'), isFalse);
      expect(json.containsKey('checksum'), isFalse);

      final restored = ExportBundle.fromJson(json);
      expect(restored.encryptedDatabase, equals('enc-db-data'));
      expect(restored.hmac, equals('hmac-value'));
      expect(restored.isSelfContained, isTrue);
      expect(restored.version, equals('2.0.0'));
    });

    test('v1 toJson/fromJson round-trip preserves databasePath and checksum',
        () {
      final salt = Uint8List.fromList(List.generate(32, (i) => i));
      final bundle = ExportBundle(
        version: '1.0.0',
        timestamp: DateTime(2026, 1, 1),
        deviceId: 'dev',
        username: 'user',
        encryptedMetadata: 'enc-meta',
        encryptedKeys: 'enc-keys',
        encryptedPreferences: 'enc-prefs',
        databasePath: '/some/path/db.sqlite',
        salt: salt,
        checksum: 'sha256-hash',
      );

      expect(bundle.isSelfContained, isFalse);
      expect(bundle.isLegacy, isTrue);

      final json = bundle.toJson();
      expect(json.containsKey('database_path'), isTrue);
      expect(json.containsKey('checksum'), isTrue);

      final restored = ExportBundle.fromJson(json);
      expect(restored.databasePath, equals('/some/path/db.sqlite'));
      expect(restored.checksum, equals('sha256-hash'));
      expect(restored.isLegacy, isTrue);
    });
  });
}
