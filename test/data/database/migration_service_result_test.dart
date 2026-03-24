import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'migration_service_result',
    );
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.configureTestDatabase(label: 'migration_service_result');
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
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
    await TestSetup.nukeDatabase();
  });

  group('MigrationResult', () {
    test('toJson serializes all fields', () {
      final result = MigrationResult(
        success: true,
        message: 'OK',
        migrationCounts: {'obsolete_keys_removed': 5},
        checksums: {'contacts': 'abc123'},
        duration: const Duration(milliseconds: 1234),
        backupPath: 'backup_key',
        errors: ['err1'],
        warnings: ['warn1'],
      );

      final json = result.toJson();
      expect(json['success'], isTrue);
      expect(json['message'], equals('OK'));
      expect(json['migrationCounts'], equals({'obsolete_keys_removed': 5}));
      expect(json['checksums'], equals({'contacts': 'abc123'}));
      expect(json['durationMs'], equals(1234));
      expect(json['backupPath'], equals('backup_key'));
      expect(json['errors'], equals(['err1']));
      expect(json['warnings'], equals(['warn1']));
    });

    test('toJson handles defaults', () {
      const result = MigrationResult(
        success: false,
        message: 'failed',
        migrationCounts: {},
        checksums: {},
        duration: Duration.zero,
      );

      final json = result.toJson();
      expect(json['backupPath'], isNull);
      expect(json['errors'], isEmpty);
      expect(json['warnings'], isEmpty);
    });
  });

  group('needsMigration', () {
    test('returns false when already migrated', () async {
      SharedPreferences.setMockInitialValues({
        'sqlite_migration_completed': true,
      });

      final result = await MigrationService.needsMigration();
      expect(result, isFalse);

      final loggedAlready = logRecords.any(
        (r) => r.message.contains('Migration already completed'),
      );
      expect(loggedAlready, isTrue);
    });

    test('returns false when no obsolete data exists', () async {
      SharedPreferences.setMockInitialValues({});

      final result = await MigrationService.needsMigration();
      expect(result, isFalse);

      final loggedNoData = logRecords.any(
        (r) => r.message.contains('No data to migrate'),
      );
      expect(loggedNoData, isTrue);
    });

    test('returns false and logs warning when obsolete keys exist', () async {
      SharedPreferences.setMockInitialValues({
        'chat_messages': ['legacy-message'],
      });

      final result = await MigrationService.needsMigration();
      expect(result, isFalse);

      final warningLogged = logRecords.any(
        (r) =>
            r.level == Level.WARNING &&
            r.message.contains('migration support has been removed'),
      );
      expect(warningLogged, isTrue);
    });
  });

  group('migrate', () {
    test(
      'marks migration complete when no obsolete keys are present',
      () async {
        SharedPreferences.setMockInitialValues({});

        final result = await MigrationService.migrate();

        expect(result.success, isTrue);
        expect(result.migrationCounts['obsolete_keys_removed'], equals(0));
        expect(result.warnings, isEmpty);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('sqlite_migration_completed'), isTrue);
      },
    );

    test('removes obsolete plaintext keys and backup keys', () async {
      SharedPreferences.setMockInitialValues({
        'enhanced_contacts_v2': ['legacy-contact'],
        'deleted_message_ids_v1': ['legacy-id'],
        'migration_backup_contacts': 'backup-json',
      });

      final result = await MigrationService.migrate();

      expect(result.success, isTrue);
      expect(result.migrationCounts['obsolete_keys_removed'], equals(3));
      expect(result.warnings, isNotEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('enhanced_contacts_v2'), isFalse);
      expect(prefs.containsKey('deleted_message_ids_v1'), isFalse);
      expect(prefs.containsKey('migration_backup_contacts'), isFalse);
      expect(prefs.getBool('sqlite_migration_completed'), isTrue);
    });

    test('reports removed key count across multiple obsolete stores', () async {
      SharedPreferences.setMockInitialValues({
        'enhanced_contacts_v2': ['legacy-contact'],
        'chat_messages': ['legacy-message'],
        'offline_message_queue_v2': ['legacy-queue'],
        'device_public_key_mapping': 'legacy-map',
        'chat_unread_counts': 'chat-a:2',
        'contact_last_seen': 'pk-a:1700',
      });

      final result = await MigrationService.migrate();

      expect(result.success, isTrue);
      expect(result.migrationCounts['obsolete_keys_removed'], equals(6));
      expect(result.message, contains('Removed 6 obsolete plaintext keys'));
    });
  });
}
