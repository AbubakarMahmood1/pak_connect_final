import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/presentation/controllers/discovery_overlay_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_scanner_view.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_types.dart';

class _FakePeripheral implements Peripheral {
  _FakePeripheral(String uuid) : _uuid = UUID.fromString(uuid);

  final UUID _uuid;

  @override
  UUID get uuid => _uuid;
}

class _FakeConnectionService extends Fake implements IConnectionService {
  final Peripheral? connectedDeviceValue = null;
  final Central? connectedCentralValue = null;
  final int maxConnections = 4;

  @override
  Peripheral? get connectedDevice => connectedDeviceValue;

  @override
  Central? get connectedCentral => connectedCentralValue;

  @override
  int get maxCentralConnections => maxConnections;

  @override
  List<BLEServerConnection> get serverConnections => const [];
}

class _StubDiscoveryOverlayController extends DiscoveryOverlayController {
  _StubDiscoveryOverlayController({
    Map<String, ConnectionAttemptState>? attempts,
    this.unifiedScanningState = false,
  }) : _attempts = attempts ?? const {};

  final Map<String, ConnectionAttemptState> _attempts;
  final bool unifiedScanningState;

  @override
  ConnectionAttemptState attemptStateFor(String deviceId) {
    return _attempts[deviceId] ?? ConnectionAttemptState.none;
  }

  @override
  bool getUnifiedScanningState() => unifiedScanningState;
}

PowerManagementStats _powerStats() {
  return PowerManagementStats(
    currentScanInterval: 60000,
    currentHealthCheckInterval: 30000,
    consecutiveSuccessfulChecks: 1,
    consecutiveFailedChecks: 0,
    connectionQualityScore: 0.7,
    connectionStabilityScore: 0.8,
    timeSinceLastSuccess: const Duration(seconds: 10),
    qualityMeasurementsCount: 3,
    isBurstMode: false,
    powerMode: PowerMode.balanced,
    isDutyCycleScanning: false,
    batteryLevel: 80,
    isCharging: false,
    isAppInBackground: false,
  );
}

DiscoveredEventArgs _event(_FakePeripheral peripheral, int rssi) {
  return DiscoveredEventArgs(peripheral, rssi, Advertisement(name: 'device'));
}

DiscoveredDevice _knownDiscoveredDevice(_FakePeripheral peripheral, int rssi) {
  final event = _event(peripheral, rssi);
  final now = DateTime.now();
  final contact = Contact(
    publicKey: 'known-${peripheral.uuid}',
    displayName: 'Known One',
    trustStatus: TrustStatus.verified,
    securityLevel: SecurityLevel.high,
    firstSeen: now,
    lastSeen: now,
  );

  return DiscoveredDevice(
      deviceId: peripheral.uuid.toString(),
      ephemeralHint: DeviceDeduplicationManager.noHintValue,
      peripheral: peripheral,
      rssi: rssi,
      advertisement: event.advertisement,
      firstSeen: now,
      lastSeen: now,
    )
    ..isKnownContact = true
    ..contactInfo = EnhancedContact(
      contact: contact,
      lastSeenAgo: const Duration(minutes: 1),
      isRecentlyActive: true,
      interactionCount: 3,
      averageResponseTime: const Duration(minutes: 1),
      groupMemberships: const [],
    );
}

Future<void> _pumpScanner(
  WidgetTester tester, {
  required AsyncValue<List<Peripheral>> devicesAsync,
  required AsyncValue<Map<String, DiscoveredEventArgs>> discoveryDataAsync,
  required AsyncValue<Map<String, DiscoveredDevice>> deduplicatedDevicesAsync,
  required DiscoveryOverlayState state,
  required _StubDiscoveryOverlayController controller,
  required BurstScanningStatus burstStatus,
  required ConnectionInfo connectionInfo,
  required _FakeConnectionService connectionService,
  required Future<void> Function() onStartScanning,
  required Future<void> Function(Peripheral device) onConnect,
  required void Function(Peripheral device) onRetry,
  required void Function(Peripheral device) onOpenChat,
  required void Function(String message) onError,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWithValue(connectionService),
        connectionInfoProvider.overrideWith(
          (ref) => AsyncValue.data(connectionInfo),
        ),
        burstScanningStatusProvider.overrideWith(
          (ref) => Stream.value(burstStatus),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: DiscoveryScannerView(
            devicesAsync: devicesAsync,
            discoveryDataAsync: discoveryDataAsync,
            deduplicatedDevicesAsync: deduplicatedDevicesAsync,
            activeConnectedIds: const {},
            readyConnectedCount: 1,
            state: state,
            controller: controller,
            maxDevices: 10,
            logger: Logger('DiscoveryScannerViewTest'),
            onStartScanning: onStartScanning,
            onConnect: onConnect,
            onRetry: onRetry,
            onOpenChat: onOpenChat,
            onError: onError,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final defaultStatus = BurstScanningStatus(
    isBurstActive: false,
    secondsUntilNextScan: 12,
    currentScanInterval: 60000,
    powerStats: _powerStats(),
  );
  const defaultConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
  );

  group('DiscoveryScannerView', () {
    testWidgets('renders loading state with burst-aware status text', (
      tester,
    ) async {
      var startCalls = 0;
      await _pumpScanner(
        tester,
        devicesAsync: const AsyncValue<List<Peripheral>>.loading(),
        discoveryDataAsync: const AsyncValue.data({}),
        deduplicatedDevicesAsync: const AsyncValue.data({}),
        state: DiscoveryOverlayState.initial(),
        controller: _StubDiscoveryOverlayController(),
        burstStatus: defaultStatus,
        connectionInfo: defaultConnectionInfo,
        connectionService: _FakeConnectionService(),
        onStartScanning: () async => startCalls++,
        onConnect: (_) async {},
        onRetry: (_) {},
        onOpenChat: (_) {},
        onError: (_) {},
      );

      expect(
        find.text('Waiting scan - Tap timer for manual scan'),
        findsOneWidget,
      );
      expect(find.text('1/4 connections'), findsOneWidget);

      await tester.tap(find.text('12').first);
      await tester.pump();
      expect(startCalls, 1);
    });

    testWidgets('renders error state and retries scanning', (tester) async {
      var startCalls = 0;
      await _pumpScanner(
        tester,
        devicesAsync: AsyncValue.error(
          StateError('scan failed'),
          StackTrace.empty,
        ),
        discoveryDataAsync: const AsyncValue.data({}),
        deduplicatedDevicesAsync: const AsyncValue.data({}),
        state: DiscoveryOverlayState.initial(),
        controller: _StubDiscoveryOverlayController(),
        burstStatus: defaultStatus,
        connectionInfo: defaultConnectionInfo,
        connectionService: _FakeConnectionService(),
        onStartScanning: () async => startCalls++,
        onConnect: (_) async {},
        onRetry: (_) {},
        onOpenChat: (_) {},
        onError: (_) {},
      );

      expect(find.text('Error loading devices'), findsOneWidget);
      expect(find.textContaining('scan failed'), findsOneWidget);

      await tester.tap(find.text('Try Again'));
      await tester.pump();
      expect(startCalls, 1);
    });

    testWidgets('renders empty state with manual scan guidance', (
      tester,
    ) async {
      await _pumpScanner(
        tester,
        devicesAsync: const AsyncValue.data([]),
        discoveryDataAsync: const AsyncValue.data({}),
        deduplicatedDevicesAsync: const AsyncValue.data({}),
        state: DiscoveryOverlayState.initial(),
        controller: _StubDiscoveryOverlayController(
          unifiedScanningState: false,
        ),
        burstStatus: defaultStatus,
        connectionInfo: defaultConnectionInfo,
        connectionService: _FakeConnectionService(),
        onStartScanning: () async {},
        onConnect: (_) async {},
        onRetry: (_) {},
        onOpenChat: (_) {},
        onError: (_) {},
      );

      expect(
        find.text('Make sure other devices are in discoverable mode'),
        findsOneWidget,
      );
      expect(
        find.text('Tap the timer circle above to scan manually'),
        findsOneWidget,
      );
    });

    testWidgets(
      'renders known/new sections and dispatches connect/retry actions',
      (tester) async {
        final known = _FakePeripheral('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
        final freshNew = _FakePeripheral(
          'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        );
        final failed = _FakePeripheral('cccccccc-cccc-cccc-cccc-cccccccccccc');

        final discovered = [known, freshNew, failed];
        final discoveryData = {
          known.uuid.toString(): _event(known, -40),
          freshNew.uuid.toString(): _event(freshNew, -55),
          failed.uuid.toString(): _event(failed, -65),
        };
        final deduplicated = {
          known.uuid.toString(): _knownDiscoveredDevice(known, -40),
        };

        final now = DateTime.now();
        final state = DiscoveryOverlayState.initial().copyWith(
          deviceLastSeen: {
            known.uuid.toString(): now,
            freshNew.uuid.toString(): now,
            failed.uuid.toString(): now,
          },
        );

        final attempts = {
          failed.uuid.toString(): ConnectionAttemptState.failed,
        };
        final controller = _StubDiscoveryOverlayController(attempts: attempts);

        Peripheral? connectedDevice;
        Peripheral? retriedDevice;

        await _pumpScanner(
          tester,
          devicesAsync: AsyncValue.data(discovered),
          discoveryDataAsync: AsyncValue.data(discoveryData),
          deduplicatedDevicesAsync: AsyncValue.data(deduplicated),
          state: state,
          controller: controller,
          burstStatus: defaultStatus,
          connectionInfo: const ConnectionInfo(
            isConnected: false,
            isReady: true,
          ),
          connectionService: _FakeConnectionService(),
          onStartScanning: () async {},
          onConnect: (device) async => connectedDevice = device,
          onRetry: (device) => retriedDevice = device,
          onOpenChat: (_) {},
          onError: (_) {},
        );
        await tester.pumpAndSettle();

        expect(find.text('Known Contacts'), findsOneWidget);
        expect(find.text('New Devices'), findsOneWidget);
        expect(find.text('Known One'), findsOneWidget);
        expect(find.text('Device bbbbbbbb'), findsOneWidget);
        expect(find.text('Device cccccccc'), findsOneWidget);

        await tester.tap(find.text('Known One'));
        await tester.pump();
        expect(connectedDevice, same(known));

        await tester.tap(find.text('Device cccccccc'));
        await tester.pump();
        expect(retriedDevice, same(failed));
      },
    );
  });
}
