/// Phase 13 — DiscoveryOverlay additional widget tests covering:
/// - Different device list states (empty, error, loading)
/// - Peripheral view empty states
/// - Animation widgets in tree
/// - Connection status variations
/// - State configuration edge cases
/// - Gesture interactions
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/presentation/controllers/discovery_overlay_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_types.dart';
import 'package:pak_connect/presentation/widgets/discovery_overlay.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

// ---------------------------------------------------------------------------
// Stub controller
// ---------------------------------------------------------------------------

class _StubController extends DiscoveryOverlayController {
  _StubController(this._initialState);
  final DiscoveryOverlayState _initialState;

  @override
  Future<DiscoveryOverlayState> build() async => _initialState;

  @override
  void setShowScannerMode(bool value) {
    state = state.whenData(
      (current) => current.copyWith(showScannerMode: value),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PowerManagementStats _powerStats() => PowerManagementStats(
  currentScanInterval: 60000,
  currentHealthCheckInterval: 30000,
  consecutiveSuccessfulChecks: 0,
  consecutiveFailedChecks: 0,
  connectionQualityScore: 0.5,
  connectionStabilityScore: 0.5,
  timeSinceLastSuccess: Duration.zero,
  qualityMeasurementsCount: 0,
  isBurstMode: false,
  powerMode: PowerMode.balanced,
  isDutyCycleScanning: false,
  batteryLevel: 80,
  isCharging: false,
  isAppInBackground: false,
);

BurstScanningStatus _burstStatus() => BurstScanningStatus(
  isBurstActive: false,
  currentScanInterval: 60000,
  secondsUntilNextScan: 10,
  powerStats: _powerStats(),
);

Future<void> _pump(
  WidgetTester tester, {
  required _StubController controller,
  MockConnectionService? service,
  VoidCallback? onClose,
  Function(Peripheral)? onDeviceSelected,
  AsyncValue<List<Peripheral>>? devicesAsync,
  AsyncValue<Map<String, DiscoveredEventArgs>>? discoveryDataAsync,
  AsyncValue<ConnectionInfo>? connectionInfoAsync,
}) async {
  final svc = service ?? MockConnectionService();

  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWithValue(svc),
        connectionInfoProvider.overrideWith(
          (ref) =>
              connectionInfoAsync ??
              const AsyncValue.data(
                ConnectionInfo(isConnected: false, isReady: true),
              ),
        ),
        burstScanningStatusProvider.overrideWith(
          (ref) => Stream.value(_burstStatus()),
        ),
        burstScanningOperationsProvider.overrideWith((ref) => null),
        serverConnectionsStreamProvider.overrideWith(
          (ref) => Stream.value(const <BLEServerConnection>[]),
        ),
        discoveredDevicesProvider.overrideWith(
          (ref) => devicesAsync ?? const AsyncValue.data(<Peripheral>[]),
        ),
        discoveryDataProvider.overrideWith(
          (ref) =>
              discoveryDataAsync ??
              const AsyncValue.data(<String, DiscoveredEventArgs>{}),
        ),
        deduplicatedDevicesProvider.overrideWith(
          (ref) => Stream.value(const <String, DiscoveredDevice>{}),
        ),
        discoveryOverlayControllerProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: DiscoveryOverlay(
            onClose: onClose ?? () {},
            onDeviceSelected: onDeviceSelected ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('DiscoveryOverlay Phase 13', () {
    // ----- Initial state in peripheral mode -----
    testWidgets('starts in peripheral mode when showScannerMode is false', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(
          DiscoveryOverlayState.initial().copyWith(showScannerMode: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Connected Centrals'), findsOneWidget);
    });

    // ----- Gesture: modal tap does NOT close -----
    testWidgets('tapping modal content does not trigger onClose', (
      tester,
    ) async {
      var closed = 0;
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        onClose: () => closed++,
      );
      // Tap center of screen — inside the modal area
      await tester.tapAt(const Offset(600, 1000));
      await tester.pump();
      expect(closed, 0);
    });

    // ----- Double toggle -----
    testWidgets('double toggle returns to scanner view', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Connected Centrals'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Discovered Devices'), findsOneWidget);
    });

    // ----- Multiple rapid toggles -----
    testWidgets('multiple rapid toggles do not crash', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byIcon(Icons.swap_horiz));
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Even number of toggles → back to scanner
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Discovered Devices'), findsOneWidget);
    });

    // ----- Empty device list state -----
    testWidgets('empty devices shows bluetooth_disabled icon', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        devicesAsync: const AsyncValue.data(<Peripheral>[]),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
    });

    testWidgets('empty devices shows discoverable hint text', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        devicesAsync: const AsyncValue.data(<Peripheral>[]),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Make sure other devices are in discoverable mode'),
        findsOneWidget,
      );
    });

    // ----- Error device list state -----
    testWidgets('error in devices shows error icon', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        devicesAsync: AsyncValue.error(
          Exception('BLE error'),
          StackTrace.empty,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    // ----- Loading device list state -----
    testWidgets('loading devices shows progress indicator', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        devicesAsync: const AsyncValue.loading(),
      );
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    // ----- Peripheral view empty states -----
    testWidgets('peripheral view empty shows "No devices connected"', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(
          DiscoveryOverlayState.initial().copyWith(showScannerMode: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('No devices connected'), findsOneWidget);
    });

    testWidgets(
      'peripheral view empty shows "Waiting for others to discover you..."',
      (tester) async {
        await _pump(
          tester,
          controller: _StubController(
            DiscoveryOverlayState.initial().copyWith(showScannerMode: false),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.text('Waiting for others to discover you...'),
          findsOneWidget,
        );
      },
    );

    testWidgets('peripheral view empty shows wifi_tethering icon', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(
          DiscoveryOverlayState.initial().copyWith(showScannerMode: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byIcon(Icons.wifi_tethering), findsWidgets);
    });

    // ----- Widget tree structure -----
    testWidgets('FadeTransition present in tree', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      expect(find.byType(FadeTransition), findsWidgets);
    });

    testWidgets('ScaleTransition present in tree', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      expect(find.byType(ScaleTransition), findsWidgets);
    });

    testWidgets('BackdropFilter present in tree', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('AnimatedSwitcher present in tree', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      expect(find.byType(AnimatedSwitcher), findsOneWidget);
    });

    testWidgets('Divider present in scanner view', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Divider), findsWidgets);
    });

    // ----- Connection info states -----
    testWidgets('connectionInfo with isReady=false renders normally', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        connectionInfoAsync: const AsyncValue.data(
          ConnectionInfo(isConnected: false, isReady: false),
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    testWidgets(
      'connectionInfo with isConnected=true isReady=true renders normally',
      (tester) async {
        await _pump(
          tester,
          controller: _StubController(DiscoveryOverlayState.initial()),
          connectionInfoAsync: const AsyncValue.data(
            ConnectionInfo(
              isConnected: true,
              isReady: true,
              otherUserName: 'Peer',
            ),
          ),
        );
        expect(find.byType(DiscoveryOverlay), findsOneWidget);
      },
    );

    testWidgets('connectionInfo with isScanning=true renders normally', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        connectionInfoAsync: const AsyncValue.data(
          ConnectionInfo(
            isConnected: false,
            isReady: false,
            isScanning: true,
          ),
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    testWidgets('connectionInfo with isAdvertising=true renders normally', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        connectionInfoAsync: const AsyncValue.data(
          ConnectionInfo(
            isConnected: false,
            isReady: false,
            isAdvertising: true,
          ),
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    // ----- State configuration edge cases -----
    testWidgets('overlay with connection attempts in state renders', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(
          DiscoveryOverlayState.initial().copyWith(
            connectionAttempts: {
              'device-1': ConnectionAttemptState.connecting,
              'device-2': ConnectionAttemptState.failed,
            },
          ),
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    testWidgets('overlay with device last seen timestamps renders', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(
          DiscoveryOverlayState.initial().copyWith(
            deviceLastSeen: {
              'device-1': DateTime.now(),
              'device-2': DateTime.now().subtract(const Duration(minutes: 5)),
            },
          ),
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    testWidgets('overlay with lastIncomingConnectionAt renders', (
      tester,
    ) async {
      await _pump(
        tester,
        controller: _StubController(
          DiscoveryOverlayState(
            contacts: const {},
            deviceLastSeen: const {},
            connectionAttempts: const {},
            showScannerMode: true,
            lastIncomingConnectionAt: DateTime.now(),
          ),
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    // ----- Provider error resilience -----
    testWidgets('error in discoveryData does not crash', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        discoveryDataAsync: AsyncValue.error(
          Exception('data error'),
          StackTrace.empty,
        ),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    testWidgets('loading discoveryData does not crash', (tester) async {
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        discoveryDataAsync: const AsyncValue.loading(),
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
    });

    // ----- Callback wiring -----
    testWidgets('onDeviceSelected callback is accepted without error', (
      tester,
    ) async {
      Peripheral? selected;
      await _pump(
        tester,
        controller: _StubController(DiscoveryOverlayState.initial()),
        onDeviceSelected: (device) => selected = device,
      );
      expect(find.byType(DiscoveryOverlay), findsOneWidget);
      // Callback wired; actual selection needs BLE Peripheral objects.
      expect(selected, isNull);
    });
  });
}
