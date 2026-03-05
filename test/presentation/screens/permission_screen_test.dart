import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/screens/permission_screen.dart';

class _SafePermissionTimeoutNotifier extends PermissionTimeoutStateNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

Future<void> _pumpPermissionScreen(
  WidgetTester tester, {
  required BluetoothLowEnergyState state,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bleStateProvider.overrideWith((ref) => AsyncValue.data(state)),
        permissionTimeoutProvider.overrideWith(
          (ref) => _SafePermissionTimeoutNotifier(),
        ),
      ],
      child: const MaterialApp(home: PermissionScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  group('PermissionScreen', () {
    testWidgets('shows ready state UI when BLE is powered on', (tester) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.poweredOn,
      );

      expect(find.text('All set! Ready to chat'), findsOneWidget);
      expect(find.text('Start Anew'), findsOneWidget);
      expect(find.text('Import Existing Data'), findsOneWidget);
    });

    testWidgets('shows permission request UI when BLE is unauthorized', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.unauthorized,
      );

      expect(find.text('Bluetooth Permission Required'), findsOneWidget);
      expect(find.text('Grant Permission'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
    });

    testWidgets('shows powered off guidance when BLE is disabled', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.poweredOff,
      );

      expect(find.text('Bluetooth is turned off'), findsOneWidget);
      expect(find.text('Settings > Bluetooth > Turn On'), findsOneWidget);
    });

    testWidgets('shows loading copy for unknown state', (tester) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.unknown,
      );

      expect(find.text('Checking Bluetooth status...'), findsOneWidget);
      expect(
        find.text('Please wait while we check your device capabilities.'),
        findsOneWidget,
      );
    });

    testWidgets('opens and closes permission explanation dialog', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.poweredOn,
      );

      await tester.tap(find.text('Why is this needed?'));
      await tester.pumpAndSettle();

      expect(find.text('Why Bluetooth Permission?'), findsOneWidget);
      expect(
        find.text('Your messages never leave your devices'),
        findsOneWidget,
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(find.text('Why Bluetooth Permission?'), findsNothing);
    });
  });
}
