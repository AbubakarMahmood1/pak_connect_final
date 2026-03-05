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
import 'package:pak_connect/presentation/widgets/discovery_overlay.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _StubDiscoveryOverlayController extends DiscoveryOverlayController {
  _StubDiscoveryOverlayController(this.initialState);

  final DiscoveryOverlayState initialState;

  @override
  Future<DiscoveryOverlayState> build() async => initialState;

  @override
  void setShowScannerMode(bool value) {
    state = state.whenData(
      (current) => current.copyWith(showScannerMode: value),
    );
  }
}

PowerManagementStats _powerStats() {
  return PowerManagementStats(
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
}

BurstScanningStatus _burstStatus() {
  return BurstScanningStatus(
    isBurstActive: false,
    currentScanInterval: 60000,
    secondsUntilNextScan: 10,
    powerStats: _powerStats(),
  );
}

Future<void> _pumpOverlay(
  WidgetTester tester, {
  required _StubDiscoveryOverlayController controller,
  required MockConnectionService connectionService,
  required void Function() onClose,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWithValue(connectionService),
        connectionInfoProvider.overrideWith(
          (ref) => const AsyncValue.data(
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
          (ref) => const AsyncValue.data(<Peripheral>[]),
        ),
        discoveryDataProvider.overrideWith(
          (ref) => const AsyncValue.data(<String, DiscoveredEventArgs>{}),
        ),
        deduplicatedDevicesProvider.overrideWith(
          (ref) => Stream.value(const <String, DiscoveredDevice>{}),
        ),
        discoveryOverlayControllerProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: DiscoveryOverlay(onClose: onClose, onDeviceSelected: (_) {}),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('DiscoveryOverlay', () {
    testWidgets('renders scanner header and closes via close icon', (
      tester,
    ) async {
      final controller = _StubDiscoveryOverlayController(
        DiscoveryOverlayState.initial(),
      );
      final connectionService = MockConnectionService();
      var closeCalls = 0;

      await _pumpOverlay(
        tester,
        controller: controller,
        connectionService: connectionService,
        onClose: () => closeCalls++,
      );

      expect(find.text('Discovered Devices'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(closeCalls, 1);
    });

    testWidgets('toggles between scanner and peripheral views', (tester) async {
      final controller = _StubDiscoveryOverlayController(
        DiscoveryOverlayState.initial(),
      );
      final connectionService = MockConnectionService();

      await _pumpOverlay(
        tester,
        controller: controller,
        connectionService: connectionService,
        onClose: () {},
      );

      expect(find.text('Discovered Devices'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Connected Centrals'), findsOneWidget);
    });

    testWidgets('tapping backdrop triggers onClose callback', (tester) async {
      final controller = _StubDiscoveryOverlayController(
        DiscoveryOverlayState.initial(),
      );
      final connectionService = MockConnectionService();
      var closeCalls = 0;

      await _pumpOverlay(
        tester,
        controller: controller,
        connectionService: connectionService,
        onClose: () => closeCalls++,
      );

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();

      expect(closeCalls, 1);
    });
  });
}
