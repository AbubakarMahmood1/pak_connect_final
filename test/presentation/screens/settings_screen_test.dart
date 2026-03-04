import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/presentation/controllers/settings_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/screens/settings_screen.dart';
import '../../test_helpers/mocks/mock_connection_service.dart';

class _NoopPreferencesRepository extends Fake
    implements IPreferencesRepository {}

class _NoopContactRepository extends Fake implements IContactRepository {}

class _NoopChatsRepository extends Fake implements IChatsRepository {}

class _NoopUserPreferences extends Fake implements IUserPreferences {}

class _NoopDatabaseProvider extends Fake implements IDatabaseProvider {}

class _RecordingConnectionService extends MockConnectionService {
  final List<bool?> refreshAdvertisingCalls = [];

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {
    refreshAdvertisingCalls.add(showOnlineStatus);
    await super.refreshAdvertising(showOnlineStatus: showOnlineStatus);
  }
}

class _TestSettingsScreenController extends SettingsController {
  _TestSettingsScreenController({Completer<void>? initializeGate})
    : _initializeGate = initializeGate,
      super(
        preferencesRepository: _NoopPreferencesRepository(),
        contactRepository: _NoopContactRepository(),
        chatsRepository: _NoopChatsRepository(),
        userPreferences: _NoopUserPreferences(),
        databaseProvider: _NoopDatabaseProvider(),
      ) {
    isLoading = true;
    showOnlineStatus = true;
    hintBroadcastEnabled = true;
    showReadReceipts = true;
    allowNewContacts = true;
    autoConnectKnownContacts = true;
    autoArchiveOldChats = true;
  }

  final Completer<void>? _initializeGate;

  int initializeCalls = 0;
  bool? lastOnlineStatus;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    isLoading = true;
    notifyListeners();
    if (_initializeGate != null) {
      await _initializeGate.future;
    }
    isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> setOnlineStatus(bool value) async {
    showOnlineStatus = value;
    lastOnlineStatus = value;
    notifyListeners();
  }
}

Future<void> _pumpSettingsScreen(
  WidgetTester tester, {
  required _TestSettingsScreenController controller,
  required IConnectionService connectionService,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWithValue(connectionService),
      ],
      child: MaterialApp(home: SettingsScreen(controller: controller)),
    ),
  );
  await tester.pump();
}

Future<void> _scrollUntilTextVisible(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.scrollUntilVisible(
    target,
    220,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  group('SettingsScreen', () {
    late _RecordingConnectionService connectionService;

    setUp(() {
      connectionService = _RecordingConnectionService()
        ..isPeripheralMode = false;
    });

    testWidgets('shows loading indicator until initialization completes', (
      tester,
    ) async {
      final gate = Completer<void>();
      final controller = _TestSettingsScreenController(initializeGate: gate);

      await _pumpSettingsScreen(
        tester,
        controller: controller,
        connectionService: connectionService,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(controller.initializeCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
    });

    testWidgets('renders main settings sections after initialize', (
      tester,
    ) async {
      final controller = _TestSettingsScreenController();

      await _pumpSettingsScreen(
        tester,
        controller: controller,
        connectionService: connectionService,
      );
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      await _scrollUntilTextVisible(tester, 'Privacy');
      expect(find.text('Privacy'), findsOneWidget);
      await _scrollUntilTextVisible(tester, 'Data & Storage');
      expect(find.text('Data & Storage'), findsOneWidget);
      await _scrollUntilTextVisible(tester, 'About');
      expect(find.text('About'), findsOneWidget);
      await _scrollUntilTextVisible(tester, '🛠️ Developer Tools');
      expect(find.text('🛠️ Developer Tools'), findsOneWidget);
    });

    testWidgets(
      'online status toggle refreshes advertising in peripheral mode',
      (tester) async {
        final controller = _TestSettingsScreenController();
        connectionService.isPeripheralMode = true;

        await _pumpSettingsScreen(
          tester,
          controller: controller,
          connectionService: connectionService,
        );
        await tester.pumpAndSettle();

        await _scrollUntilTextVisible(tester, 'Online Status');
        final onlineStatusText = find.text('Online Status').first;
        await tester.ensureVisible(onlineStatusText);
        await tester.pumpAndSettle();
        await tester.tap(onlineStatusText);
        await tester.pump();

        expect(controller.lastOnlineStatus, isFalse);
        expect(connectionService.refreshAdvertisingCalls, [false]);
      },
    );

    testWidgets('online status toggle skips refresh when not peripheral', (
      tester,
    ) async {
      final controller = _TestSettingsScreenController();
      connectionService.isPeripheralMode = false;

      await _pumpSettingsScreen(
        tester,
        controller: controller,
        connectionService: connectionService,
      );
      await tester.pumpAndSettle();

      await _scrollUntilTextVisible(tester, 'Online Status');
      final onlineStatusText = find.text('Online Status').first;
      await tester.ensureVisible(onlineStatusText);
      await tester.pumpAndSettle();
      await tester.tap(onlineStatusText);
      await tester.pump();

      expect(controller.lastOnlineStatus, isFalse);
      expect(connectionService.refreshAdvertisingCalls, isEmpty);
    });
  });
}
