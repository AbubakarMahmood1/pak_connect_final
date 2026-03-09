import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/services/notification_handler_factory.dart';
import 'package:pak_connect/presentation/controllers/settings_controller.dart';
import 'package:pak_connect/presentation/providers/theme_provider.dart';
import 'package:pak_connect/presentation/widgets/settings/about_section.dart';
import 'package:pak_connect/presentation/widgets/settings/appearance_section.dart';
import 'package:pak_connect/presentation/widgets/settings/data_storage_section.dart';
import 'package:pak_connect/presentation/widgets/settings/developer_tools_section.dart';
import 'package:pak_connect/presentation/widgets/settings/notification_section.dart';
import 'package:pak_connect/presentation/widgets/settings/privacy_section.dart';
import 'package:pak_connect/presentation/widgets/settings/settings_section_header.dart';

class _NoopPreferencesRepository extends Fake
    implements IPreferencesRepository {}

class _NoopContactRepository extends Fake implements IContactRepository {}

class _NoopChatsRepository extends Fake implements IChatsRepository {}

class _NoopUserPreferences extends Fake implements IUserPreferences {}

class _NoopDatabaseProvider extends Fake implements IDatabaseProvider {}

class _TestThemeModeNotifier extends ThemeModeNotifier {
  _TestThemeModeNotifier(this._initialMode);

  final ThemeMode _initialMode;
  ThemeMode? lastSetMode;

  @override
  ThemeMode build() => _initialMode;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    lastSetMode = mode;
    state = mode;
  }
}

class _TestSettingsController extends SettingsController {
  _TestSettingsController()
    : super(
        preferencesRepository: _NoopPreferencesRepository(),
        contactRepository: _NoopContactRepository(),
        chatsRepository: _NoopChatsRepository(),
        userPreferences: _NoopUserPreferences(),
        databaseProvider: _NoopDatabaseProvider(),
      ) {
    notificationsEnabled = true;
    backgroundNotifications = true;
    soundEnabled = true;
    vibrationEnabled = true;
    autoArchiveOldChats = true;
    archiveAfterDays = 30;
    disableHealthChecks = false;
    disableQueueSync = false;
    disableAutoConnect = false;
    disableDualRole = false;
    disableDiscoveryScheduler = false;
  }

  bool? lastNotificationsEnabled;
  bool? lastBackgroundNotifications;
  bool? lastSoundEnabled;
  bool? lastVibrationEnabled;
  bool? lastAutoArchiveOldChats;
  int? lastArchiveAfterDays;
  bool? lastDisableHealthChecks;
  bool? lastDisableQueueSync;
  bool? lastDisableAutoConnect;
  bool? lastDisableDualRole;
  bool? lastDisableDiscoveryScheduler;

  int triggerTestNotificationCalls = 0;
  int manualAutoArchiveCheckCalls = 0;
  int getStorageInfoCalls = 0;
  int clearAllDataCalls = 0;
  int clearCachesCalls = 0;
  int loadDatabaseStatsCalls = 0;
  int checkDatabaseIntegrityCalls = 0;
  int initializeCalls = 0;
  int loadPrivacyPolicyMarkdownCalls = 0;

  int manualAutoArchiveCheckResult = 0;
  StorageInfo storageInfoResult = StorageInfo(
    exists: true,
    sizeMB: '1.00',
    sizeKB: '1024',
  );
  DatabaseStats databaseStatsResult = DatabaseStats(
    sizeMB: '1.00',
    sizeKB: '1024',
    sizeBytes: '1048576',
    contacts: 1,
    chats: 2,
    messages: 3,
  );
  IntegrityResult integrityResult = IntegrityResult(
    isOk: true,
    raw: '[{integrity_check: ok}]',
  );
  BatteryInfoWrapper batteryInfoResult = BatteryInfoWrapper(
    80,
    false,
    'balanced',
    'Balanced power mode',
    DateTime(2026, 1, 1),
  );
  String privacyMarkdown = '# Privacy\nYour data stays local.';

  Object? setBackgroundNotificationsError;
  Object? triggerTestNotificationError;
  Object? manualAutoArchiveCheckError;
  Object? getStorageInfoError;
  Object? clearAllDataError;
  Object? clearCachesError;
  Object? loadDatabaseStatsError;
  Object? checkDatabaseIntegrityError;
  Object? loadPrivacyPolicyMarkdownError;

  @override
  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    lastNotificationsEnabled = value;
  }

  @override
  Future<void> setBackgroundNotifications(bool value) async {
    if (setBackgroundNotificationsError != null) {
      throw setBackgroundNotificationsError!;
    }
    backgroundNotifications = value;
    lastBackgroundNotifications = value;
  }

  @override
  Future<void> setSoundEnabled(bool value) async {
    soundEnabled = value;
    lastSoundEnabled = value;
  }

  @override
  Future<void> setVibrationEnabled(bool value) async {
    vibrationEnabled = value;
    lastVibrationEnabled = value;
  }

  @override
  Future<void> triggerTestNotification() async {
    triggerTestNotificationCalls++;
    if (triggerTestNotificationError != null) {
      throw triggerTestNotificationError!;
    }
  }

  @override
  Future<void> setAutoArchiveOldChats(bool value) async {
    autoArchiveOldChats = value;
    lastAutoArchiveOldChats = value;
  }

  @override
  Future<void> setArchiveAfterDays(int days) async {
    archiveAfterDays = days;
    lastArchiveAfterDays = days;
  }

  @override
  Future<int> manualAutoArchiveCheck() async {
    manualAutoArchiveCheckCalls++;
    if (manualAutoArchiveCheckError != null) {
      throw manualAutoArchiveCheckError!;
    }
    return manualAutoArchiveCheckResult;
  }

  @override
  Future<StorageInfo> getStorageInfo() async {
    getStorageInfoCalls++;
    if (getStorageInfoError != null) {
      throw getStorageInfoError!;
    }
    return storageInfoResult;
  }

  @override
  Future<bool> clearAllData() async {
    clearAllDataCalls++;
    if (clearAllDataError != null) {
      throw clearAllDataError!;
    }
    return true;
  }

  @override
  Future<void> clearCaches() async {
    clearCachesCalls++;
    if (clearCachesError != null) {
      throw clearCachesError!;
    }
  }

  @override
  Future<DatabaseStats> loadDatabaseStats() async {
    loadDatabaseStatsCalls++;
    if (loadDatabaseStatsError != null) {
      throw loadDatabaseStatsError!;
    }
    return databaseStatsResult;
  }

  @override
  Future<IntegrityResult> checkDatabaseIntegrity() async {
    checkDatabaseIntegrityCalls++;
    if (checkDatabaseIntegrityError != null) {
      throw checkDatabaseIntegrityError!;
    }
    return integrityResult;
  }

  @override
  BatteryInfoWrapper getBatteryInfo() => batteryInfoResult;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<String> loadPrivacyPolicyMarkdown() async {
    loadPrivacyPolicyMarkdownCalls++;
    if (loadPrivacyPolicyMarkdownError != null) {
      throw loadPrivacyPolicyMarkdownError!;
    }
    return privacyMarkdown;
  }

  @override
  Future<void> setDisableHealthChecks(bool value) async {
    disableHealthChecks = value;
    lastDisableHealthChecks = value;
  }

  @override
  Future<void> setDisableQueueSync(bool value) async {
    disableQueueSync = value;
    lastDisableQueueSync = value;
  }

  @override
  Future<void> setDisableAutoConnect(bool value) async {
    disableAutoConnect = value;
    lastDisableAutoConnect = value;
  }

  @override
  Future<void> setDisableDualRole(bool value) async {
    disableDualRole = value;
    lastDisableDualRole = value;
  }

  @override
  Future<void> setDisableDiscoveryScheduler(bool value) async {
    disableDiscoveryScheduler = value;
    lastDisableDiscoveryScheduler = value;
  }
}

Future<void> _pumpWidgetHarness(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pump();
}

Future<_TestThemeModeNotifier> _pumpAppearanceHarness(
  WidgetTester tester, {
  ThemeMode initialMode = ThemeMode.system,
}) async {
  late _TestThemeModeNotifier notifier;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith(() {
          notifier = _TestThemeModeNotifier(initialMode);
          return notifier;
        }),
      ],
      child: const MaterialApp(home: Scaffold(body: AppearanceSection())),
    ),
  );
  await tester.pump();

  return notifier;
}

void main() {
  group('SettingsSectionHeader', () {
    testWidgets('renders title text', (tester) async {
      await _pumpWidgetHarness(
        tester,
        const SettingsSectionHeader(title: 'Section Title'),
      );

      expect(find.text('Section Title'), findsOneWidget);
    });
  });

  group('AppearanceSection', () {
    testWidgets('renders theme options and updates selected mode on tap', (
      tester,
    ) async {
      final notifier = await _pumpAppearanceHarness(
        tester,
        initialMode: ThemeMode.system,
      );

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);

      await tester.tap(find.text('Dark'));
      await tester.pump();
      expect(notifier.lastSetMode, ThemeMode.dark);

      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(notifier.lastSetMode, ThemeMode.light);
    });
  });

  group('PrivacySection', () {
    testWidgets('invokes callbacks and emits messages for key toggles', (
      tester,
    ) async {
      final messages = <String>[];
      bool? hintValue;
      bool? autoConnectValue;

      await _pumpWidgetHarness(
        tester,
        PrivacySection(
          hintBroadcastEnabled: true,
          showReadReceipts: true,
          showOnlineStatus: true,
          allowNewContacts: true,
          autoConnectKnownContacts: true,
          rateLimitUnknown: 5,
          rateLimitKnown: 25,
          rateLimitFriend: 100,
          onHintBroadcastChanged: (value) async => hintValue = value,
          onReadReceiptsChanged: (value) async {},
          onOnlineStatusChanged: (value) async {},
          onAllowNewContactsChanged: (value) async {},
          onAutoConnectChanged: (value) async => autoConnectValue = value,
          onRateLimitUnknownChanged: (value) async {},
          onRateLimitKnownChanged: (value) async {},
          onRateLimitFriendChanged: (value) async {},
          onShowMessage: messages.add,
        ),
      );

      await tester.tap(find.widgetWithText(SwitchListTile, 'Broadcast Hints'));
      await tester.pump();
      expect(hintValue, isFalse);
      expect(messages.last, contains('Spy mode enabled'));

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Auto-Connect to Known Contacts'),
      );
      await tester.pump();
      expect(autoConnectValue, isFalse);
      expect(messages.last, contains('Auto-connect disabled'));
    });
  });

  group('AboutSection', () {
    testWidgets('shows about and help dialogs', (tester) async {
      final controller = _TestSettingsController();
      await _pumpWidgetHarness(tester, AboutSection(controller: controller));

      await tester.tap(find.text('About PakConnect'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Secure peer-to-peer messaging with mesh networking and end-to-end encryption.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Help & Support'));
      await tester.pumpAndSettle();
      expect(find.text('Getting Started'), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
    });

    testWidgets('loads markdown privacy policy and renders it', (tester) async {
      final controller = _TestSettingsController()
        ..privacyMarkdown = '# Privacy Policy\nAll data stays local.';
      await _pumpWidgetHarness(tester, AboutSection(controller: controller));

      await tester.tap(find.text('Privacy Policy'));
      await tester.pumpAndSettle();

      expect(find.text('Privacy Policy'), findsWidgets);
      expect(find.text('All data stays local.'), findsOneWidget);
      expect(controller.loadPrivacyPolicyMarkdownCalls, 1);
    });

    testWidgets('shows fallback privacy dialog when markdown load fails', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..loadPrivacyPolicyMarkdownError = StateError('missing asset');
      await _pumpWidgetHarness(tester, AboutSection(controller: controller));

      await tester.tap(find.text('Privacy Policy'));
      await tester.pumpAndSettle();

      expect(find.text('Your Privacy Matters'), findsOneWidget);
      expect(find.textContaining('Error loading full policy'), findsOneWidget);
    });
  });

  group('NotificationSection', () {
    testWidgets('renders minimal mode and updates notification toggle', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..notificationsEnabled = false;
      String? errorMessage;

      await _pumpWidgetHarness(
        tester,
        NotificationSection(
          controller: controller,
          onShowError: (message) => errorMessage = message,
        ),
      );

      expect(find.text('Enable Notifications'), findsOneWidget);
      expect(find.text('Sound'), findsNothing);

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Enable Notifications'),
      );
      await tester.pump();
      expect(controller.lastNotificationsEnabled, isTrue);
      expect(errorMessage, isNull);
    });

    testWidgets('handles in-app notification toggles and test action', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..notificationsEnabled = true
        ..triggerTestNotificationError = StateError('boom');
      String? errorMessage;

      await _pumpWidgetHarness(
        tester,
        NotificationSection(
          controller: controller,
          onShowError: (message) => errorMessage = message,
        ),
      );

      final supportsBackground =
          NotificationHandlerFactory.isBackgroundNotificationSupported();
      expect(
        find.text('System Notifications'),
        supportsBackground ? findsOneWidget : findsNothing,
      );

      await tester.tap(find.widgetWithText(SwitchListTile, 'Sound'));
      await tester.pump();
      expect(controller.lastSoundEnabled, isFalse);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Vibration'));
      await tester.pump();
      expect(controller.lastVibrationEnabled, isFalse);

      await tester.tap(find.text('Test Notification'));
      await tester.pump();
      expect(controller.triggerTestNotificationCalls, 1);
      expect(errorMessage, contains('Failed to test notification'));
    });
  });

  group('DataStorageSection', () {
    testWidgets('shows archive controls only when auto-archive is enabled', (
      tester,
    ) async {
      final enabledController = _TestSettingsController()
        ..autoArchiveOldChats = true;
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: enabledController),
      );
      expect(find.text('Archive After'), findsOneWidget);
      expect(find.text('Check Inactive Chats Now'), findsOneWidget);

      final disabledController = _TestSettingsController()
        ..autoArchiveOldChats = false;
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: disabledController),
      );
      expect(find.text('Archive After'), findsNothing);
      expect(find.text('Check Inactive Chats Now'), findsNothing);
    });

    testWidgets('updates archive configuration via switch and dialog', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..autoArchiveOldChats = true
        ..archiveAfterDays = 30;
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: controller),
      );

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Auto-Archive Old Chats'),
      );
      await tester.pump();
      expect(controller.lastAutoArchiveOldChats, isFalse);

      await tester.tap(find.text('Archive After'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('90'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(controller.lastArchiveAfterDays, 90);
    });

    testWidgets('manual auto-archive success path shows snackbar', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..autoArchiveOldChats = true
        ..manualAutoArchiveCheckResult = 2;
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: controller),
      );

      await tester.tap(find.text('Check Inactive Chats Now'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Auto-archived 2 inactive chats'),
        findsOneWidget,
      );
    });

    testWidgets('manual auto-archive failure path shows snackbar', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..autoArchiveOldChats = true
        ..manualAutoArchiveCheckError = StateError('scheduler failed');
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: controller),
      );

      await tester.tap(find.text('Check Inactive Chats Now'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Failed to check inactive chats'),
        findsOneWidget,
      );
    });

    testWidgets('storage usage dialog success and failure paths', (
      tester,
    ) async {
      final controller = _TestSettingsController()
        ..storageInfoResult = StorageInfo(
          exists: true,
          sizeMB: '3.50',
          sizeKB: '3584',
        );
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: controller),
      );

      await tester.tap(find.text('Storage Usage'));
      await tester.pumpAndSettle();
      expect(find.text('Database: 3.50 MB'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      controller.getStorageInfoError = StateError('disk unavailable');
      await tester.tap(find.text('Storage Usage'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Failed to calculate storage'),
        findsOneWidget,
      );
    });

    testWidgets('clear-all-data cancel and failure paths', (tester) async {
      final controller = _TestSettingsController();
      await _pumpWidgetHarness(
        tester,
        DataStorageSection(controller: controller),
      );

      await tester.tap(find.text('Clear All Data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.clearAllDataCalls, 0);

      controller.clearAllDataError = StateError('delete failed');
      await tester.tap(find.text('Clear All Data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete All'));
      await tester.pumpAndSettle();
      expect(controller.clearAllDataCalls, 1);
      expect(find.textContaining('Failed to clear data'), findsOneWidget);
    });
  });

  group('DeveloperToolsSection', () {
    testWidgets('wires actions, toggles, and dialogs', (tester) async {
      final controller = _TestSettingsController()
        ..manualAutoArchiveCheckResult = 1
        ..databaseStatsResult = DatabaseStats(
          sizeMB: '9.00',
          sizeKB: '9216',
          sizeBytes: '9437184',
          contacts: 4,
          chats: 5,
          messages: 60,
        )
        ..integrityResult = IntegrityResult(
          isOk: true,
          raw: '[{integrity_check: ok}]',
        )
        ..batteryInfoResult = BatteryInfoWrapper(
          67,
          false,
          'balanced',
          'Balanced mode',
          DateTime.now().subtract(const Duration(minutes: 3)),
        );
      final messages = <String>[];
      final errors = <String>[];

      await _pumpWidgetHarness(
        tester,
        DeveloperToolsSection(
          controller: controller,
          onShowMessage: messages.add,
          onShowError: errors.add,
        ),
      );

      await tester.tap(find.text('Test').first);
      await tester.pumpAndSettle();
      expect(controller.triggerTestNotificationCalls, 1);
      expect(messages.last, contains('Test notification triggered'));

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Disable health checks'),
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Disable queue sync'),
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Disable auto-connect'),
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Disable dual-role auto'),
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Disable discovery scheduler'),
      );
      await tester.pump();
      expect(controller.lastDisableHealthChecks, isTrue);
      expect(controller.lastDisableQueueSync, isTrue);
      expect(controller.lastDisableAutoConnect, isTrue);
      expect(controller.lastDisableDualRole, isTrue);
      expect(controller.lastDisableDiscoveryScheduler, isTrue);

      await tester.tap(find.text('Check').first);
      await tester.pumpAndSettle();
      expect(messages.last, contains('Archived 1 inactive chat'));

      await tester.tap(find.text('View').first);
      await tester.pumpAndSettle();
      expect(find.text('Battery Optimizer'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('View').last);
      await tester.tap(find.text('View').last);
      await tester.pumpAndSettle();
      expect(find.text('Database Info'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Clear').first);
      await tester.tap(find.text('Clear').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.clearCachesCalls, 0);

      await tester.ensureVisible(find.text('Check').last);
      await tester.tap(find.text('Check').last);
      await tester.pumpAndSettle();
      expect(find.text('Database Integrity'), findsWidgets);
      expect(find.textContaining('Database is healthy'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(errors, isEmpty);
    });
  });
}
