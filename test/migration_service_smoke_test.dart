import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'migration_service_smoke',
    );
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.configureTestDatabase(label: 'migration_service_smoke');
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

  test(
    'MigrationService cleans legacy SharedPreferences without touching SQLite state',
    () async {
      SharedPreferences.setMockInitialValues(_buildMockPrefs());

      final result = await MigrationService.migrate();

      expect(result.success, isTrue);
      expect(result.migrationCounts['obsolete_keys_removed'], equals(8));

      final db = await DatabaseHelper.database;
      final contacts = await db.query('contacts');
      final chats = await db.query('chats');
      final messages = await db.query('messages');
      final offlineQueue = await db.query('offline_message_queue');

      expect(contacts, isEmpty);
      expect(chats, isEmpty);
      expect(messages, isEmpty);
      expect(offlineQueue, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('sqlite_migration_completed'), isTrue);
      expect(prefs.containsKey('enhanced_contacts_v2'), isFalse);
      expect(prefs.containsKey('chat_messages'), isFalse);
      expect(prefs.containsKey('offline_message_queue_v2'), isFalse);
      expect(prefs.containsKey('deleted_message_ids_v1'), isFalse);
      expect(prefs.containsKey('device_public_key_mapping'), isFalse);
      expect(prefs.containsKey('chat_unread_counts'), isFalse);
      expect(prefs.containsKey('contact_last_seen'), isFalse);
      expect(
        prefs.getKeys().any((key) => key.startsWith('migration_backup_')),
        isFalse,
      );
    },
  );
}

Map<String, Object> _buildMockPrefs() {
  return {
    'enhanced_contacts_v2': ['legacy-contact'],
    'chat_messages': ['legacy-message'],
    'offline_message_queue_v2': ['legacy-queue'],
    'deleted_message_ids_v1': ['legacy-deleted-message'],
    'device_public_key_mapping': 'DEVICE123:pk_alice',
    'chat_unread_counts': 'pk_alice:2',
    'contact_last_seen': 'pk_alice:1700000000',
    'migration_backup_contacts': 'backup-json',
  };
}
