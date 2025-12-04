// Tests for export/import functionality
// Ensures data portability works correctly and securely

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/export_import/encryption_utils.dart';
import 'package:pak_connect/data/services/export_import/export_bundle.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'export_import');
  });

  group('EncryptionUtils', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('generateSalt creates 32-byte random salt', () {
      final salt1 = EncryptionUtils.generateSalt();
      final salt2 = EncryptionUtils.generateSalt();

      expect(salt1.length, equals(32));
      expect(salt2.length, equals(32));

      // Salts should be different (extremely unlikely to be same)
      expect(salt1, isNot(equals(salt2)));
    });

    test('deriveKey produces consistent output for same inputs', () {
      const passphrase = 'TestPassphrase123!';
      final salt = Uint8List.fromList(List.filled(32, 42));

      final key1 = EncryptionUtils.deriveKey(passphrase, salt);
      final key2 = EncryptionUtils.deriveKey(passphrase, salt);

      expect(key1, equals(key2));
      expect(key1.length, equals(32)); // 256 bits
    });

    test('deriveKey produces different output for different passphrases', () {
      const passphrase1 = 'TestPassphrase123!';
      const passphrase2 = 'DifferentPass456!';
      final salt = Uint8List.fromList(List.filled(32, 42));

      final key1 = EncryptionUtils.deriveKey(passphrase1, salt);
      final key2 = EncryptionUtils.deriveKey(passphrase2, salt);

      expect(key1, isNot(equals(key2)));
    });

    test('deriveKey produces different output for different salts', () {
      const passphrase = 'TestPassphrase123!';
      final salt1 = Uint8List.fromList(List.filled(32, 42));
      final salt2 = Uint8List.fromList(List.filled(32, 99));

      final key1 = EncryptionUtils.deriveKey(passphrase, salt1);
      final key2 = EncryptionUtils.deriveKey(passphrase, salt2);

      expect(key1, isNot(equals(key2)));
    });

    test('encrypt/decrypt round-trip preserves data', () {
      const plaintext = 'This is secret data that should be encrypted!';
      const passphrase = 'SecurePassphrase123!';
      final salt = EncryptionUtils.generateSalt();
      final key = EncryptionUtils.deriveKey(passphrase, salt);

      final encrypted = EncryptionUtils.encrypt(plaintext, key);
      final decrypted = EncryptionUtils.decrypt(encrypted, key);

      expect(decrypted, equals(plaintext));
    });

    test('encrypt produces different output each time (due to IV)', () {
      const plaintext = 'Same plaintext';
      const passphrase = 'SecurePassphrase123!';
      final salt = EncryptionUtils.generateSalt();
      final key = EncryptionUtils.deriveKey(passphrase, salt);

      final encrypted1 = EncryptionUtils.encrypt(plaintext, key);
      final encrypted2 = EncryptionUtils.encrypt(plaintext, key);

      expect(encrypted1, isNot(equals(encrypted2)));

      // But both decrypt to same plaintext
      expect(EncryptionUtils.decrypt(encrypted1, key), equals(plaintext));
      expect(EncryptionUtils.decrypt(encrypted2, key), equals(plaintext));
    });

    test('decrypt returns null for wrong key', () {
      const plaintext = 'Secret data';
      const passphrase1 = 'CorrectPassphrase123!';
      const passphrase2 = 'WrongPassphrase456!';
      final salt = EncryptionUtils.generateSalt();

      final key1 = EncryptionUtils.deriveKey(passphrase1, salt);
      final key2 = EncryptionUtils.deriveKey(passphrase2, salt);

      final encrypted = EncryptionUtils.encrypt(plaintext, key1);
      final decrypted = EncryptionUtils.decrypt(encrypted, key2);

      expect(decrypted, isNull);
    });

    test('decrypt returns null for corrupted data', () {
      const plaintext = 'Secret data';
      const passphrase = 'SecurePassphrase123!';
      final salt = EncryptionUtils.generateSalt();
      final key = EncryptionUtils.deriveKey(passphrase, salt);

      final encrypted = EncryptionUtils.encrypt(plaintext, key);

      // Corrupt the encrypted data
      final corrupted = '${encrypted.substring(0, encrypted.length - 5)}XXXXX';

      final decrypted = EncryptionUtils.decrypt(corrupted, key);
      expect(decrypted, isNull);
    });

    test('encrypt/decrypt handles JSON data', () {
      final data = {
        'username': 'TestUser',
        'device_id': 'device123',
        'settings': {'theme': 'dark', 'notifications': true},
      };

      const passphrase = 'SecurePassphrase123!';
      final salt = EncryptionUtils.generateSalt();
      final key = EncryptionUtils.deriveKey(passphrase, salt);

      final plaintext = jsonEncode(data);
      final encrypted = EncryptionUtils.encrypt(plaintext, key);
      final decrypted = EncryptionUtils.decrypt(encrypted, key);

      expect(decrypted, isNotNull);
      final decodedData = jsonDecode(decrypted!);
      expect(decodedData, equals(data));
    });

    test('calculateChecksum is consistent', () {
      final data = ['data1', 'data2', 'data3'];

      final checksum1 = EncryptionUtils.calculateChecksum(data);
      final checksum2 = EncryptionUtils.calculateChecksum(data);

      expect(checksum1, equals(checksum2));
      expect(checksum1.length, equals(64)); // SHA-256 hex = 64 chars
    });

    test('calculateChecksum changes with data', () {
      final data1 = ['data1', 'data2', 'data3'];
      final data2 = ['data1', 'data2', 'data4'];

      final checksum1 = EncryptionUtils.calculateChecksum(data1);
      final checksum2 = EncryptionUtils.calculateChecksum(data2);

      expect(checksum1, isNot(equals(checksum2)));
    });
  });

  group('PassphraseValidation', () {
    test('rejects passphrase shorter than 12 characters', () {
      final validation = EncryptionUtils.validatePassphrase('Short123');

      expect(validation.isValid, isFalse);
      expect(validation.warnings, contains(contains('12 characters')));
    });

    test('rejects passphrase without sufficient character variety', () {
      // Only lowercase - missing 3 types
      final validation1 = EncryptionUtils.validatePassphrase('lowercaseonly');
      expect(validation1.isValid, isFalse);

      // Only numbers - missing 3 types
      final validation2 = EncryptionUtils.validatePassphrase('123456789012');
      expect(validation2.isValid, isFalse);
    });

    test('accepts passphrase with 3 character types', () {
      // Has lowercase, uppercase, numbers (missing symbols is OK)
      final validation = EncryptionUtils.validatePassphrase('ValidPass123');
      expect(validation.isValid, isTrue);

      // Has lowercase, numbers, symbols (missing uppercase is OK)
      final validation2 = EncryptionUtils.validatePassphrase('valid_pass_123!');
      expect(validation2.isValid, isTrue);
    });

    test('strong passphrase has high strength score', () {
      final validation = EncryptionUtils.validatePassphrase(
        'VerySecureP@ssphrase2024!',
      );

      expect(validation.isValid, isTrue);
      expect(validation.isStrong, isTrue);
      expect(validation.strength, greaterThan(0.7));
    });

    test('accepts very long passphrases without maximum limit', () {
      // 50+ character passphrase should work fine
      final longPassphrase =
          'ThisIsAVeryLongPassphraseThatExceeds50Characters123!@#';
      final validation = EncryptionUtils.validatePassphrase(longPassphrase);

      expect(validation.isValid, isTrue);
      expect(
        validation.strength,
        greaterThan(0.7),
      ); // Should have high strength
    });

    test('detects common patterns', () {
      final validation = EncryptionUtils.validatePassphrase(
        'Password123!', // Has "password" pattern but meets requirements
      );

      expect(validation.isValid, isTrue);
      expect(validation.warnings, contains(contains('common patterns')));
      expect(validation.strength, lessThan(0.7)); // Reduced by pattern penalty
    });

    test('recognizes all symbol types', () {
      // Test various symbols are recognized
      final validation1 = EncryptionUtils.validatePassphrase('testPass123!');
      expect(validation1.isValid, isTrue);

      final validation2 = EncryptionUtils.validatePassphrase('testPass123@');
      expect(validation2.isValid, isTrue);

      final validation3 = EncryptionUtils.validatePassphrase('testPass123#');
      expect(validation3.isValid, isTrue);
    });
  });

  group('ExportBundle', () {
    test('toJson/fromJson round-trip preserves data', () {
      final bundle = ExportBundle(
        version: '1.0.0',
        timestamp: DateTime.now(),
        deviceId: 'device123',
        username: 'TestUser',
        encryptedMetadata: 'encrypted_meta_data',
        encryptedKeys: 'encrypted_keys_data',
        encryptedPreferences: 'encrypted_prefs_data',
        databasePath: '/path/to/database.db',
        salt: Uint8List.fromList(List.filled(32, 42)),
        checksum: 'abc123checksum',
      );

      final json = bundle.toJson();
      final restored = ExportBundle.fromJson(json);

      expect(restored.version, equals(bundle.version));
      expect(restored.timestamp, equals(bundle.timestamp));
      expect(restored.deviceId, equals(bundle.deviceId));
      expect(restored.username, equals(bundle.username));
      expect(restored.encryptedMetadata, equals(bundle.encryptedMetadata));
      expect(restored.encryptedKeys, equals(bundle.encryptedKeys));
      expect(
        restored.encryptedPreferences,
        equals(bundle.encryptedPreferences),
      );
      expect(restored.databasePath, equals(bundle.databasePath));
      expect(restored.salt, equals(bundle.salt));
      expect(restored.checksum, equals(bundle.checksum));
    });
  });

  group('ExportResult', () {
    test('success result has correct properties', () {
      final result = ExportResult.success(
        bundlePath: '/path/to/bundle.pakconnect',
        bundleSize: 1024000,
      );

      expect(result.success, isTrue);
      expect(result.errorMessage, isNull);
      expect(result.bundlePath, isNotNull);
      expect(result.bundleSize, equals(1024000));
    });

    test('failure result has correct properties', () {
      final result = ExportResult.failure('Something went wrong');

      expect(result.success, isFalse);
      expect(result.errorMessage, equals('Something went wrong'));
      expect(result.bundlePath, isNull);
      expect(result.bundleSize, isNull);
    });
  });

  group('ImportResult', () {
    test('success result has correct properties', () {
      final result = ImportResult.success(
        recordsRestored: 1234,
        originalDeviceId: 'device123',
        originalUsername: 'TestUser',
        backupTimestamp: DateTime(2024, 10, 8),
      );

      expect(result.success, isTrue);
      expect(result.errorMessage, isNull);
      expect(result.recordsRestored, equals(1234));
      expect(result.originalDeviceId, equals('device123'));
      expect(result.originalUsername, equals('TestUser'));
    });

    test('failure result has correct properties', () {
      final result = ImportResult.failure('Import failed');

      expect(result.success, isFalse);
      expect(result.errorMessage, equals('Import failed'));
      expect(result.recordsRestored, equals(0));
      expect(result.originalDeviceId, isNull);
      expect(result.originalUsername, isNull);
    });
  });
}
