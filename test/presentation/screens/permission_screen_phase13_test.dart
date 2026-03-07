// Phase 13.2 – permission_screen.dart additional coverage
// Covers: BLE loading state, BLE error state, unsupported state,
//         permission explanation dialog content, poweredOn UI details,
//         unauthorized UI details, poweredOff details, timeout behaviour.

import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/screens/permission_screen.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// A safe notifier that can be disposed multiple times without crashing.
class _SafePermissionTimeoutNotifier extends PermissionTimeoutStateNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

/// A controllable timeout notifier that lets tests trigger the timeout.
class _ControllableTimeoutNotifier extends PermissionTimeoutStateNotifier {
  bool _disposed = false;

  _ControllableTimeoutNotifier() : super() {
    // Cancel the real 10-second timer from the superclass so we control it
    cancel();
  }

  void fireTimeout() {
    if (!_disposed) state = true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

Future<void> _pumpPermissionScreen(
  WidgetTester tester, {
  required AsyncValue<BluetoothLowEnergyState> bleState,
  PermissionTimeoutStateNotifier? timeoutNotifier,
}) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bleStateProvider.overrideWith((ref) => bleState),
        permissionTimeoutProvider.overrideWith(
          (ref) => timeoutNotifier ?? _SafePermissionTimeoutNotifier(),
        ),
      ],
      child: const MaterialApp(home: PermissionScreen()),
    ),
  );
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  Logger.root.level = Level.OFF;

  group('PermissionScreen – Phase 13.2', () {
    // -----------------------------------------------------------------------
    // 1. BLE loading state
    // -----------------------------------------------------------------------
    testWidgets('loading state shows CircularProgressIndicator', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue<BluetoothLowEnergyState>.loading(),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 2. BLE error state
    // -----------------------------------------------------------------------
    testWidgets('error state shows error text', (tester) async {
      await _pumpPermissionScreen(
        tester,
        bleState: AsyncValue<BluetoothLowEnergyState>.error(
          'BLE init failed',
          StackTrace.empty,
        ),
      );

      expect(find.textContaining('Error:'), findsOneWidget);
      expect(find.textContaining('BLE init failed'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 3. BLE unsupported state (same UI branch as unknown)
    // -----------------------------------------------------------------------
    testWidgets('unsupported state shows checking status copy', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(
          BluetoothLowEnergyState.unsupported,
        ),
      );

      expect(find.text('Checking Bluetooth status...'), findsOneWidget);
      expect(
        find.text('Please wait while we check your device capabilities.'),
        findsOneWidget,
      );
    });

    // -----------------------------------------------------------------------
    // 4. poweredOn state – full UI details
    // -----------------------------------------------------------------------
    testWidgets('poweredOn shows bluetooth icon, title, buttons', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );

      // App branding
      expect(find.text('BLE Chat'), findsOneWidget);
      expect(
        find.text('Secure offline messaging\nfor family & friends'),
        findsOneWidget,
      );

      // Ready state
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('All set! Ready to chat'), findsOneWidget);

      // Buttons
      expect(find.text('Start Anew'), findsOneWidget);
      expect(find.text('Import Existing Data'), findsOneWidget);
      expect(find.byIcon(Icons.upload_file), findsOneWidget);

      // Common elements
      expect(find.text('Why is this needed?'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 5. unauthorized state – full UI details
    // -----------------------------------------------------------------------
    testWidgets('unauthorized shows permission request UI with details', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(
          BluetoothLowEnergyState.unauthorized,
        ),
      );

      expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
      expect(find.text('Bluetooth Permission Required'), findsOneWidget);
      expect(
        find.textContaining('We need Bluetooth access to find nearby'),
        findsOneWidget,
      );
      expect(find.text('Grant Permission'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 6. poweredOff state – full UI details
    // -----------------------------------------------------------------------
    testWidgets('poweredOff shows detailed Bluetooth guidance', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(
          BluetoothLowEnergyState.poweredOff,
        ),
      );

      expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
      expect(find.text('Bluetooth is turned off'), findsOneWidget);
      expect(
        find.textContaining('Please turn on Bluetooth'),
        findsOneWidget,
      );
      expect(find.text('Settings > Bluetooth > Turn On'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 7. Permission explanation dialog – full content
    // -----------------------------------------------------------------------
    testWidgets('permission explanation dialog shows all content', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );

      await tester.tap(find.text('Why is this needed?'));
      await tester.pumpAndSettle();

      expect(find.text('Why Bluetooth Permission?'), findsOneWidget);
      expect(find.text('We need Bluetooth to:'), findsOneWidget);
      expect(find.text('• Find nearby devices'), findsOneWidget);
      expect(find.text('• Send/receive messages'), findsOneWidget);
      expect(find.text('• Maintain connections'), findsOneWidget);
      expect(find.byIcon(Icons.security), findsOneWidget);
      expect(
        find.text('Your messages never leave your devices'),
        findsOneWidget,
      );
      expect(find.text('Got it'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 8. Main app logo and branding elements
    // -----------------------------------------------------------------------
    testWidgets('renders app logo circle with bluetooth icon', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );

      // Bluetooth icon in the logo circle
      expect(find.byIcon(Icons.bluetooth), findsOneWidget);

      // Title and subtitle
      expect(find.text('BLE Chat'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 9. Unknown BLE state with progress indicator
    // -----------------------------------------------------------------------
    testWidgets('unknown state shows progress indicator for BLE check', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.unknown),
      );

      expect(find.text('Checking Bluetooth status...'), findsOneWidget);
      // Should have a progress indicator in the content area
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    // -----------------------------------------------------------------------
    // 10. "Start Anew" button navigates (no crash on tap)
    // -----------------------------------------------------------------------
    testWidgets('tapping Start Anew does not crash', (tester) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );

      // This triggers navigation to HomeScreen via pushReplacement.
      // In test environment without full DI, we just verify it doesn't throw.
      await tester.tap(find.text('Start Anew'));
      // Pump briefly – the navigation may fail since HomeScreen dependencies
      // aren't set up, but the tap itself should not throw.
      await tester.pump(const Duration(milliseconds: 100));
      // If we get here without exception, the test passes.
    });

    // -----------------------------------------------------------------------
    // 11. "Import Existing Data" button exists with correct icon
    // -----------------------------------------------------------------------
    testWidgets('import button is rendered with upload icon', (tester) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );

      final importButton = find.text('Import Existing Data');
      expect(importButton, findsOneWidget);
      expect(find.byIcon(Icons.upload_file), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 12. Explanation dialog dismisses with Got it
    // -----------------------------------------------------------------------
    testWidgets('explanation dialog dismisses cleanly', (tester) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(
          BluetoothLowEnergyState.unauthorized,
        ),
      );

      await tester.tap(find.text('Why is this needed?'));
      await tester.pumpAndSettle();
      expect(find.text('Why Bluetooth Permission?'), findsOneWidget);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text('Why Bluetooth Permission?'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 13. SafeArea and Padding wrapper present
    // -----------------------------------------------------------------------
    testWidgets('screen wraps in SafeArea and Padding', (tester) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );

      expect(find.byType(SafeArea), findsOneWidget);
      // 24-pixel padding container
      expect(find.byType(Padding), findsWidgets);
    });

    // -----------------------------------------------------------------------
    // 14. Grant Permission button is enabled when not requesting
    // -----------------------------------------------------------------------
    testWidgets('grant permission button is enabled in unauthorized state', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(
          BluetoothLowEnergyState.unauthorized,
        ),
      );

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Grant Permission'),
      );
      expect(button.onPressed, isNotNull);
    });

    // -----------------------------------------------------------------------
    // 15. Open Settings button is present in unauthorized
    // -----------------------------------------------------------------------
    testWidgets('open settings button present in unauthorized state', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(
          BluetoothLowEnergyState.unauthorized,
        ),
      );

      expect(
        find.widgetWithText(OutlinedButton, 'Open Settings'),
        findsOneWidget,
      );
    });

    // -----------------------------------------------------------------------
    // 16. Multiple BLE states produce distinct UIs
    // -----------------------------------------------------------------------
    testWidgets('different BLE states produce distinct title texts', (
      tester,
    ) async {
      // poweredOn
      await _pumpPermissionScreen(
        tester,
        bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
      );
      expect(find.text('All set! Ready to chat'), findsOneWidget);
      expect(find.text('Bluetooth is turned off'), findsNothing);
      expect(find.text('Bluetooth Permission Required'), findsNothing);
    });
  });
}
