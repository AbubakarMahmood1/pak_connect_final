import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/providers/app_permission_providers.dart';
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
  bool hasBlePermissions = true,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bleStateProvider.overrideWith((ref) => AsyncValue.data(state)),
        blePermissionsGrantedProvider.overrideWith(
          (ref) async => hasBlePermissions,
        ),
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

      expect(find.text('Setup complete'), findsOneWidget);
      expect(find.text('Open Home'), findsOneWidget);
      expect(find.text('Restore Backup'), findsOneWidget);
    });

    testWidgets('shows permission request UI when BLE is unauthorized', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.unauthorized,
        hasBlePermissions: false,
      );

      expect(find.text('Bluetooth Permission Required'), findsOneWidget);
      expect(find.text('Grant Permission'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
    });

    testWidgets(
      'shows background re-check UI when plugin says unauthorized but permissions are already granted',
      (tester) async {
        await _pumpPermissionScreen(
          tester,
          state: BluetoothLowEnergyState.unauthorized,
          hasBlePermissions: true,
        );

        expect(find.text('Finalizing Bluetooth access...'), findsOneWidget);
        expect(
          find.textContaining('Android permissions are granted'),
          findsOneWidget,
        );
        expect(find.text('Grant Permission'), findsNothing);
      },
    );

    testWidgets('shows powered off guidance when BLE is disabled', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.poweredOff,
        hasBlePermissions: false,
      );

      expect(find.text('Bluetooth is turned off'), findsOneWidget);
      expect(find.text('Settings > Bluetooth > Turn On'), findsOneWidget);
    });

    testWidgets('shows loading copy for unknown state', (tester) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.unknown,
        hasBlePermissions: false,
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

      await tester.tap(find.text('Why does mesh need this?'));
      await tester.pumpAndSettle();

      expect(find.text('Why Mesh Permissions?'), findsOneWidget);
      expect(
        find.text('Your messages never leave your devices'),
        findsOneWidget,
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(find.text('Why Mesh Permissions?'), findsNothing);
    });

    testWidgets('shows permission UI when Bluetooth is on but permission is missing', (
      tester,
    ) async {
      await _pumpPermissionScreen(
        tester,
        state: BluetoothLowEnergyState.poweredOn,
        hasBlePermissions: false,
      );

      expect(find.text('Nearby Devices Permission Required'), findsOneWidget);
      expect(find.text('Grant Permission'), findsOneWidget);
    });
  });
}
