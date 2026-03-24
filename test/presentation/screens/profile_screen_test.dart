import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test_helpers/test_service_registry.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart'
    show clearRuntimeAppServicesForTesting;
import 'package:pak_connect/presentation/screens/profile_screen.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class _FakeUserPreferences extends Fake implements IUserPreferences {
  _FakeUserPreferences({required this.deviceId, required this.name});

  String deviceId;
  String name;
  int regenerateCalls = 0;

  @override
  Future<String> getOrCreateDeviceId() async => deviceId;

  @override
  Future<void> regenerateKeyPair() async {
    regenerateCalls++;
  }

  @override
  Future<String> getUserName() async => name;

  @override
  Future<void> setUserName(String name) async {
    this.name = name;
  }

  @override
  Future<String?> getDeviceId() async => deviceId;

  @override
  Future<Map<String, String>> getOrCreateKeyPair() async => {
    'public': 'pub',
    'private': 'priv',
  };

  @override
  Future<String> getPublicKey() async => 'pub';

  @override
  Future<String> getPrivateKey() async => 'priv';

  @override
  Future<bool> getHintBroadcastEnabled() async => true;

  @override
  Future<void> setHintBroadcastEnabled(bool enabled) async {}
}

class _FakeContactRepository extends Fake implements IContactRepository {
  _FakeContactRepository({required this.contactCount, required this.verified});

  final int contactCount;
  final int verified;

  @override
  Future<int> getContactCount() async => contactCount;

  @override
  Future<int> getVerifiedContactCount() async => verified;
}

class _FakeChatsRepository extends Fake implements IChatsRepository {
  _FakeChatsRepository({required this.chatCount, required this.messageCount});

  final int chatCount;
  final int messageCount;

  @override
  Future<int> getChatCount() async => chatCount;

  @override
  Future<int> getTotalMessageCount() async => messageCount;
}

class _FakeArchiveRepository extends Fake implements IArchiveRepository {
  _FakeArchiveRepository({required this.archivedCount});

  final int archivedCount;

  @override
  Future<int> getArchivedChatsCount() async => archivedCount;
}

class _FakeDatabaseProvider extends Fake implements IDatabaseProvider {
  _FakeDatabaseProvider(this.sizeMb);

  final String sizeMb;

  @override
  Future<Map<String, dynamic>> getDatabaseSize() async => {'size_mb': sizeMb};

  @override
  Future<Database> get database => throw UnimplementedError();
}

class _UsernameHarness {
  _UsernameHarness({required this.initialName});

  final String initialName;
  final List<String> updatedNames = <String>[];
}

class _TestUsernameNotifier extends UsernameNotifier {
  _TestUsernameNotifier(this.harness);

  final _UsernameHarness harness;

  @override
  Future<String> build() async => harness.initialName;

  @override
  Future<void> updateUsername(String newUsername) async {
    harness.updatedNames.add(newUsername);
    state = AsyncValue.data(newUsername);
  }
}

Future<void> _pumpProfileScreen(
  WidgetTester tester, {
  required _UsernameHarness usernameHarness,
}) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        usernameProvider.overrideWith(
          () => _TestUsernameNotifier(usernameHarness),
        ),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    ),
  );

  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _scrollUntilVisible(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    250,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  final locator = serviceRegistry;

  late _FakeUserPreferences userPreferences;

  setUp(() async {
    await locator.reset();
    clearRuntimeAppServicesForTesting();

    userPreferences = _FakeUserPreferences(
      deviceId: 'device-123',
      name: 'Alice',
    );

    locator.registerSingleton<IUserPreferences>(userPreferences);
    locator.registerSingleton<IContactRepository>(
      _FakeContactRepository(contactCount: 4, verified: 2),
    );
    locator.registerSingleton<IChatsRepository>(
      _FakeChatsRepository(chatCount: 3, messageCount: 12),
    );
    locator.registerSingleton<IArchiveRepository>(
      _FakeArchiveRepository(archivedCount: 1),
    );
    locator.registerSingleton<IDatabaseProvider>(_FakeDatabaseProvider('5.50'));
  });

  tearDown(() async {
    await locator.reset();
    clearRuntimeAppServicesForTesting();
  });

  group('ProfileScreen', () {
    testWidgets('renders loaded profile statistics and device id', (
      tester,
    ) async {
      await _pumpProfileScreen(
        tester,
        usernameHarness: _UsernameHarness(initialName: 'Alice'),
      );

      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Device ID'), findsOneWidget);
      expect(find.text('device-123'), findsOneWidget);

      expect(find.text('Statistics'), findsOneWidget);
      expect(find.text('Contacts'), findsOneWidget);
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('5.50 MB'), findsOneWidget);
    });

    testWidgets('edits display name through username provider notifier', (
      tester,
    ) async {
      final harness = _UsernameHarness(initialName: 'Alice');
      await _pumpProfileScreen(tester, usernameHarness: harness);

      await tester.tap(find.text('Alice').first);
      await tester.pumpAndSettle();
      expect(find.text('Edit Display Name'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(harness.updatedNames, ['Bob']);
      expect(find.text('Name updated successfully'), findsOneWidget);
    });

    testWidgets('regenerates keys after user confirmation', (tester) async {
      await _pumpProfileScreen(
        tester,
        usernameHarness: _UsernameHarness(initialName: 'Alice'),
      );

      await _scrollUntilVisible(tester, 'Regenerate Encryption Keys');
      await tester.tap(find.text('Regenerate Encryption Keys'));
      await tester.pumpAndSettle();
      expect(find.text('Regenerate Keys?'), findsOneWidget);

      await tester.tap(find.text('Regenerate'));
      await tester.pumpAndSettle();

      expect(userPreferences.regenerateCalls, 1);
      expect(
        find.text('Encryption keys regenerated successfully'),
        findsOneWidget,
      );
    });

    testWidgets('copies device id and confirms via snackbar', (tester) async {
      await _pumpProfileScreen(
        tester,
        usernameHarness: _UsernameHarness(initialName: 'Alice'),
      );

      await tester.tap(find.byIcon(Icons.copy));
      await tester.pumpAndSettle();

      expect(find.text('Device ID copied to clipboard'), findsOneWidget);
    });
  });
}
