// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pak_connect/main.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'test_helpers/app_core_test_harness.dart';
import 'test_helpers/mocks/mock_connection_service.dart';
import 'test_helpers/test_setup.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;
  late Completer<void> initializationGate;
  StreamSubscription<LogRecord>? logSubscription;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'widget');
  });

  setUp(() {
    AppCore.resetForTesting();
    initializationGate = Completer<void>();
    AppCore.initializationOverride = () => initializationGate.future;
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(logRecords.add);
  });

  tearDown(() async {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
    await logSubscription?.cancel();
    logSubscription = null;
    AppCore.instance.dispose();
    if (!initializationGate.isCompleted) {
      initializationGate.complete();
    }
    AppCore.initializationOverride = null;
    AppCore.resetForTesting();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final fakeBleService = MockConnectionService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      unawaited(fakeBleService.dispose());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bleServiceProvider.overrideWithValue(fakeBleService)],
        child: const PakConnectApp(),
      ),
    );
  }

  testWidgets('PakConnect app initialization smoke test', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    // Wait for the initialization process
    await tester.pump();

    // Verify that the app loads without crashing
    expect(find.byType(MaterialApp), findsOneWidget);

    // The app should show either loading screen or permission screen
    final hasLoadingIndicator = find
        .byType(LinearProgressIndicator)
        .evaluate()
        .isNotEmpty;
    final hasPermissionScreen = find
        .text('Bluetooth Permissions')
        .evaluate()
        .isNotEmpty;

    // At least one of these should be present
    expect(hasLoadingIndicator || hasPermissionScreen, isTrue);
  });

  testWidgets('App wrapper handles initialization states', (
    WidgetTester tester,
  ) async {
    // Test that the app wrapper can handle different states without crashing
    await pumpApp(tester);

    // Verify MaterialApp is created
    expect(find.byType(MaterialApp), findsOneWidget);

    // Let the app initialize without waiting for all animations to settle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Should not throw any exceptions during initialization
  });
}
