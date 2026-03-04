import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/preference_keys.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/auto_archive_scheduler.dart';
import 'package:pak_connect/domain/services/notification_service.dart';
import 'package:pak_connect/presentation/controllers/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class _FakePreferencesRepository extends Fake
    implements IPreferencesRepository {
  _FakePreferencesRepository({
    Map<String, dynamic>? initialValues,
    this.throwOnAutoConnectRead = false,
  }) : values = initialValues ?? <String, dynamic>{};

  final Map<String, dynamic> values;
  final bool throwOnAutoConnectRead;
  final Map<String, bool> boolWrites = <String, bool>{};
  final Map<String, int> intWrites = <String, int>{};

  @override
  Future<bool> getBool(String key, {bool? defaultValue}) async {
    if (throwOnAutoConnectRead &&
        key == PreferenceKeys.autoConnectKnownContacts) {
      throw StateError('forced read failure');
    }
    final value = values[key];
    if (value is bool) return value;
    return defaultValue ?? false;
  }

  @override
  Future<int> getInt(String key, {int? defaultValue}) async {
    final value = values[key];
    if (value is int) return value;
    return defaultValue ?? 0;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
    boolWrites[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    values[key] = value;
    intWrites[key] = value;
  }

  @override
  Future<void> clearAll() async {
    values.clear();
  }
}

class _FakeContactRepository extends Fake implements IContactRepository {
  int contactCount = 0;
  final Map<String, Contact> contacts = <String, Contact>{};
  final List<String> deletedPublicKeys = <String>[];

  @override
  Future<int> getContactCount() async => contactCount;

  @override
  Future<Map<String, Contact>> getAllContacts() async =>
      Map<String, Contact>.from(contacts);

  @override
  Future<bool> deleteContact(String publicKey) async {
    deletedPublicKeys.add(publicKey);
    contacts.remove(publicKey);
    return true;
  }
}

class _FakeChatsRepository extends Fake implements IChatsRepository {
  int chatCount = 0;
  int totalMessageCount = 0;

  @override
  Future<int> getChatCount() async => chatCount;

  @override
  Future<int> getTotalMessageCount() async => totalMessageCount;
}

class _FakeUserPreferences extends Fake implements IUserPreferences {
  bool hintBroadcastEnabled = true;

  @override
  Future<bool> getHintBroadcastEnabled() async => hintBroadcastEnabled;

  @override
  Future<void> setHintBroadcastEnabled(bool enabled) async {
    hintBroadcastEnabled = enabled;
  }
}

class _FakeDatabaseProvider extends Fake implements IDatabaseProvider {
  _FakeDatabaseProvider(this.sizeInfo, {Database? database})
    : _database = database;

  final Map<String, dynamic> sizeInfo;
  final Database? _database;

  @override
  Future<Map<String, dynamic>> getDatabaseSize() async =>
      Map<String, dynamic>.from(sizeInfo);

  @override
  Future<Database> get database async {
    if (_database == null) {
      throw UnimplementedError('database not needed in this test suite');
    }
    return _database;
  }
}

class _RecordingTransaction extends Fake implements Transaction {
  final List<String> deletedTables = <String>[];

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    deletedTables.add(table);
    return 1;
  }
}

class _RecordingDatabase extends Fake implements Database {
  _RecordingDatabase({List<Map<String, Object?>>? integrityRows})
    : integrityRows =
          integrityRows ??
          <Map<String, Object?>>[
            <String, Object?>{'integrity_check': 'ok'},
          ];

  final _RecordingTransaction transactionRecorder = _RecordingTransaction();
  final List<String> rawQueries = <String>[];
  final List<Map<String, Object?>> integrityRows;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    return action(transactionRecorder);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    rawQueries.add(sql);
    return integrityRows;
  }
}

Contact _contact(String publicKey) {
  final now = DateTime(2026, 1, 1);
  return Contact(
    publicKey: publicKey,
    persistentPublicKey: null,
    currentEphemeralId: null,
    displayName: 'Contact $publicKey',
    trustStatus: TrustStatus.newContact,
    securityLevel: SecurityLevel.low,
    firstSeen: now,
    lastSeen: now,
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    NotificationService.dispose();
    AutoArchiveScheduler.stop();
    AutoArchiveScheduler.clearConfiguration();
    KillSwitches.disableHealthChecks = false;
    KillSwitches.disableQueueSync = false;
    KillSwitches.disableAutoConnect = false;
    KillSwitches.disableDualRoleAuto = false;
    KillSwitches.disableDiscoveryScheduler = false;
  });

  group('SettingsController', () {
    test(
      'initialize loads preferences and applies auto-connect fallback',
      () async {
        final preferences = _FakePreferencesRepository(
          initialValues: <String, dynamic>{
            PreferenceKeys.notificationsEnabled: false,
            PreferenceKeys.backgroundNotifications: true,
            PreferenceKeys.soundEnabled: false,
            PreferenceKeys.vibrationEnabled: false,
            PreferenceKeys.showReadReceipts: false,
            PreferenceKeys.showOnlineStatus: false,
            PreferenceKeys.allowNewContacts: false,
            PreferenceKeys.autoArchiveOldChats: true,
            PreferenceKeys.archiveAfterDays: 45,
            PreferenceKeys.killSwitchHealthChecks: true,
            PreferenceKeys.killSwitchQueueSync: true,
            PreferenceKeys.killSwitchAutoConnect: false,
            PreferenceKeys.killSwitchDualRole: true,
            PreferenceKeys.killSwitchDiscoveryScheduler: false,
          },
          throwOnAutoConnectRead: true,
        );
        final contacts = _FakeContactRepository();
        final chats = _FakeChatsRepository();
        final userPrefs = _FakeUserPreferences()..hintBroadcastEnabled = false;
        final database = _FakeDatabaseProvider(<String, dynamic>{
          'exists': true,
          'size_mb': '1.25',
          'size_kb': '1280',
          'size_bytes': 1310720,
        });

        final controller = SettingsController(
          preferencesRepository: preferences,
          contactRepository: contacts,
          chatsRepository: chats,
          userPreferences: userPrefs,
          databaseProvider: database,
        );

        await controller.initialize();

        expect(controller.isLoading, isFalse);
        expect(controller.notificationsEnabled, isFalse);
        expect(controller.soundEnabled, isFalse);
        expect(controller.vibrationEnabled, isFalse);
        expect(controller.showReadReceipts, isFalse);
        expect(controller.showOnlineStatus, isFalse);
        expect(controller.allowNewContacts, isFalse);
        expect(controller.hintBroadcastEnabled, isFalse);
        expect(controller.autoArchiveOldChats, isTrue);
        expect(controller.archiveAfterDays, 45);

        expect(
          controller.autoConnectKnownContacts,
          PreferenceDefaults.autoConnectKnownContacts,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.autoConnectKnownContacts],
          PreferenceDefaults.autoConnectKnownContacts,
        );
        expect(KillSwitches.disableHealthChecks, isTrue);
        expect(KillSwitches.disableQueueSync, isTrue);
        expect(KillSwitches.disableDualRoleAuto, isTrue);
      },
    );

    test(
      'setters update in-memory state and persist preference writes',
      () async {
        final preferences = _FakePreferencesRepository();
        final contacts = _FakeContactRepository();
        final chats = _FakeChatsRepository();
        final userPrefs = _FakeUserPreferences();
        final database = _FakeDatabaseProvider(<String, dynamic>{
          'exists': true,
          'size_mb': '0.50',
          'size_kb': '512',
          'size_bytes': 524288,
        });

        final controller = SettingsController(
          preferencesRepository: preferences,
          contactRepository: contacts,
          chatsRepository: chats,
          userPreferences: userPrefs,
          databaseProvider: database,
        );

        await controller.setNotificationsEnabled(false);
        await controller.setBackgroundNotifications(false);
        await controller.setSoundEnabled(false);
        await controller.setVibrationEnabled(false);
        await controller.setReadReceipts(false);
        await controller.setOnlineStatus(false);
        await controller.setAllowNewContacts(false);
        await controller.setHintBroadcastEnabled(false);
        await controller.setAutoConnectKnownContacts(true);
        await controller.setDisableHealthChecks(true);
        await controller.setDisableQueueSync(true);
        await controller.setDisableAutoConnect(true);
        await controller.setDisableDualRole(true);
        await controller.setDisableDiscoveryScheduler(true);
        await controller.setAutoArchiveOldChats(true);
        await controller.setArchiveAfterDays(7);

        expect(controller.notificationsEnabled, isFalse);
        expect(controller.backgroundNotifications, isFalse);
        expect(controller.soundEnabled, isFalse);
        expect(controller.vibrationEnabled, isFalse);
        expect(controller.showReadReceipts, isFalse);
        expect(controller.showOnlineStatus, isFalse);
        expect(controller.allowNewContacts, isFalse);
        expect(controller.hintBroadcastEnabled, isFalse);
        expect(controller.autoConnectKnownContacts, isTrue);
        expect(controller.disableHealthChecks, isTrue);
        expect(controller.disableQueueSync, isTrue);
        expect(controller.disableAutoConnect, isTrue);
        expect(controller.disableDualRole, isTrue);
        expect(controller.disableDiscoveryScheduler, isTrue);
        expect(controller.autoArchiveOldChats, isTrue);
        expect(controller.archiveAfterDays, 7);

        expect(
          preferences.boolWrites[PreferenceKeys.notificationsEnabled],
          isFalse,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.backgroundNotifications],
          isFalse,
        );
        expect(preferences.boolWrites[PreferenceKeys.soundEnabled], isFalse);
        expect(
          preferences.boolWrites[PreferenceKeys.vibrationEnabled],
          isFalse,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.showReadReceipts],
          isFalse,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.showOnlineStatus],
          isFalse,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.allowNewContacts],
          isFalse,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.autoConnectKnownContacts],
          isTrue,
        );
        expect(
          preferences.boolWrites[PreferenceKeys.autoArchiveOldChats],
          isTrue,
        );
        expect(preferences.intWrites[PreferenceKeys.archiveAfterDays], 7);
        expect(userPrefs.hintBroadcastEnabled, isFalse);
        expect(KillSwitches.disableHealthChecks, isTrue);
        expect(KillSwitches.disableQueueSync, isTrue);
        expect(KillSwitches.disableAutoConnect, isTrue);
        expect(KillSwitches.disableDualRoleAuto, isTrue);
        expect(KillSwitches.disableDiscoveryScheduler, isTrue);
      },
    );

    test('storage and stats methods use repository/provider values', () async {
      final preferences = _FakePreferencesRepository();
      final contacts = _FakeContactRepository()..contactCount = 4;
      final chats = _FakeChatsRepository()
        ..chatCount = 3
        ..totalMessageCount = 12;
      final userPrefs = _FakeUserPreferences();
      final database = _FakeDatabaseProvider(<String, dynamic>{
        'exists': true,
        'size_mb': '2.00',
        'size_kb': '2048',
        'size_bytes': 2097152,
      });

      final controller = SettingsController(
        preferencesRepository: preferences,
        contactRepository: contacts,
        chatsRepository: chats,
        userPreferences: userPrefs,
        databaseProvider: database,
      );

      final storage = await controller.getStorageInfo();
      final stats = await controller.loadDatabaseStats();

      expect(storage.exists, isTrue);
      expect(storage.sizeMB, '2.00');
      expect(storage.sizeKB, '2048');

      expect(stats.contacts, 4);
      expect(stats.chats, 3);
      expect(stats.messages, 12);
      expect(stats.sizeMB, '2.00');
      expect(stats.sizeKB, '2048');
      expect(stats.sizeBytes, '2097152');
    });

    test('clearAllData wipes core tables, contacts, and preferences', () async {
      final preferences = _FakePreferencesRepository(
        initialValues: <String, dynamic>{'seeded': true},
      );
      final contacts = _FakeContactRepository()
        ..contacts['pk-1'] = _contact('pk-1')
        ..contacts['pk-2'] = _contact('pk-2');
      final database = _RecordingDatabase();

      final controller = SettingsController(
        preferencesRepository: preferences,
        contactRepository: contacts,
        chatsRepository: _FakeChatsRepository(),
        userPreferences: _FakeUserPreferences(),
        databaseProvider: _FakeDatabaseProvider(<String, dynamic>{
          'exists': true,
        }, database: database),
      );

      final result = await controller.clearAllData();

      expect(result, isTrue);
      expect(
        database.transactionRecorder.deletedTables,
        orderedEquals(<String>[
          'archived_messages',
          'archived_chats',
          'deleted_message_ids',
          'queue_sync_state',
          'offline_message_queue',
          'messages',
          'chats',
          'contact_last_seen',
          'device_mappings',
          'contacts',
          'migration_metadata',
          'app_preferences',
        ]),
      );
      expect(contacts.deletedPublicKeys, containsAll(<String>['pk-1', 'pk-2']));
      expect(contacts.deletedPublicKeys.length, 2);
      expect(preferences.values, isEmpty);
    });

    test('checkDatabaseIntegrity evaluates pragma output', () async {
      final okDatabase = _RecordingDatabase(
        integrityRows: <Map<String, Object?>>[
          <String, Object?>{'integrity_check': 'ok'},
        ],
      );
      final okController = SettingsController(
        preferencesRepository: _FakePreferencesRepository(),
        contactRepository: _FakeContactRepository(),
        chatsRepository: _FakeChatsRepository(),
        userPreferences: _FakeUserPreferences(),
        databaseProvider: _FakeDatabaseProvider(<String, dynamic>{
          'exists': true,
        }, database: okDatabase),
      );

      final okResult = await okController.checkDatabaseIntegrity();
      expect(okResult.isOk, isTrue);
      expect(okDatabase.rawQueries, contains('PRAGMA integrity_check'));

      final badDatabase = _RecordingDatabase(
        integrityRows: <Map<String, Object?>>[
          <String, Object?>{'integrity_check': 'not ok'},
        ],
      );
      final badController = SettingsController(
        preferencesRepository: _FakePreferencesRepository(),
        contactRepository: _FakeContactRepository(),
        chatsRepository: _FakeChatsRepository(),
        userPreferences: _FakeUserPreferences(),
        databaseProvider: _FakeDatabaseProvider(<String, dynamic>{
          'exists': true,
        }, database: badDatabase),
      );

      final badResult = await badController.checkDatabaseIntegrity();
      expect(badResult.isOk, isFalse);
      expect(badDatabase.rawQueries, contains('PRAGMA integrity_check'));
    });

    test(
      'disposed controller returns safe defaults and no-op behavior',
      () async {
        final controller = SettingsController(
          preferencesRepository: _FakePreferencesRepository(),
          contactRepository: _FakeContactRepository(),
          chatsRepository: _FakeChatsRepository(),
          userPreferences: _FakeUserPreferences(),
          databaseProvider: _FakeDatabaseProvider(<String, dynamic>{}),
        );

        controller.dispose();

        await controller.initialize();
        await controller.setNotificationsEnabled(false);
        final manualCheckResult = await controller.manualAutoArchiveCheck();
        final storage = await controller.getStorageInfo();
        final stats = await controller.loadDatabaseStats();
        final integrity = await controller.checkDatabaseIntegrity();
        final markdown = await controller.loadPrivacyPolicyMarkdown();
        final batteryInfo = controller.getBatteryInfo();

        expect(manualCheckResult, 0);
        expect(storage.exists, isFalse);
        expect(stats.contacts, 0);
        expect(stats.chats, 0);
        expect(stats.messages, 0);
        expect(integrity.isOk, isFalse);
        expect(integrity.raw, 'disposed');
        expect(markdown, '');
        expect(batteryInfo.level, 0);
        expect(batteryInfo.isCharging, isFalse);
        expect(
          controller.notificationsEnabled,
          PreferenceDefaults.notificationsEnabled,
        );
      },
    );

    test('non-disposed utility methods complete without throwing', () async {
      final controller = SettingsController(
        preferencesRepository: _FakePreferencesRepository(),
        contactRepository: _FakeContactRepository(),
        chatsRepository: _FakeChatsRepository(),
        userPreferences: _FakeUserPreferences(),
        databaseProvider: _FakeDatabaseProvider(<String, dynamic>{
          'exists': true,
          'size_mb': '0.10',
          'size_kb': '100',
          'size_bytes': 102400,
        }),
      );

      await controller.triggerTestNotification();
      await controller.clearCaches();
      final result = await controller.manualAutoArchiveCheck();

      expect(result, 0);
    });
  });
}
