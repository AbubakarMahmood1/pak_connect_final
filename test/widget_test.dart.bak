// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pak_connect/main.dart';

void main() {
  testWidgets('PakConnect app initialization smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: PakConnectApp()));

    // Wait for the initialization process
    await tester.pump();

    // Verify that the app loads without crashing
    expect(find.byType(MaterialApp), findsOneWidget);
    
    // The app should show either loading screen or permission screen
    final hasLoadingIndicator = find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
    final hasPermissionScreen = find.text('Bluetooth Permissions').evaluate().isNotEmpty;
    
    // At least one of these should be present
    expect(hasLoadingIndicator || hasPermissionScreen, isTrue);
  });
  
  testWidgets('App wrapper handles initialization states', (WidgetTester tester) async {
    // Test that the app wrapper can handle different states without crashing
    await tester.pumpWidget(const ProviderScope(child: PakConnectApp()));
    
    // Verify MaterialApp is created
    expect(find.byType(MaterialApp), findsOneWidget);
    
    // Let the app settle
    await tester.pumpAndSettle(const Duration(seconds: 2));
    
    // Should not throw any exceptions during initialization
  });
}
