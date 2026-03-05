import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/adaptive_power_manager.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'package:pak_connect/domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/services/hint_cache_manager.dart';
import 'package:pak_connect/presentation/controllers/discovery_overlay_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/widgets/discovery/discovery_types.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _FakeContactRepository extends Fake implements IContactRepository {
  int getAllContactsCalls = 0;
  int getContactByAnyIdCalls = 0;

  final Map<String, Contact?> contactsByAnyId = <String, Contact?>{};
  final List<Map<String, Contact>> _queuedContacts = <Map<String, Contact>>[];

  void queueContacts(Map<String, Contact> contacts) {
    _queuedContacts.add(Map<String, Contact>.from(contacts));
  }

  @override
  Future<Map<String, Contact>> getAllContacts() async {
    getAllContactsCalls++;
    if (_queuedContacts.isEmpty) {
      return <String, Contact>{};
    }
    return _queuedContacts.removeAt(0);
  }

  @override
  Future<Contact?> getContactByAnyId(String identifier) async {
    getContactByAnyIdCalls++;
    return contactsByAnyId[identifier];
  }
}

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCentral implements Central {
  const _TestCentral(this.uuid);

  @override
  final UUID uuid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({required this.container, required this.connectionInfoController});

  final ProviderContainer container;
  final StreamController<ConnectionInfo> connectionInfoController;

  DiscoveryOverlayController get controller =>
      container.read(discoveryOverlayControllerProvider.notifier);

  AsyncValue<DiscoveryOverlayState> get state =>
      container.read(discoveryOverlayControllerProvider);

  Future<DiscoveryOverlayState> build() =>
      container.read(discoveryOverlayControllerProvider.future);

  void pushConnectionInfo(ConnectionInfo info) {
    connectionInfoController.add(info);
  }

  Future<void> dispose() async {
    container.dispose();
    await connectionInfoController.close();
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
    batteryLevel: 85,
    isCharging: false,
    isAppInBackground: false,
  );
}

BurstScanningStatus _burstStatus({
  required bool isBurstActive,
  int? secondsUntilNextScan,
}) {
  return BurstScanningStatus(
    isBurstActive: isBurstActive,
    secondsUntilNextScan: secondsUntilNextScan,
    currentScanInterval: 60000,
    powerStats: _powerStats(),
  );
}

Contact _contact({required String key, required String displayName}) {
  final now = DateTime(2026, 1, 1, 10, 30);
  return Contact(
    publicKey: key,
    persistentPublicKey: key,
    currentEphemeralId: 'ephemeral-$key',
    displayName: displayName,
    trustStatus: TrustStatus.verified,
    securityLevel: SecurityLevel.high,
    firstSeen: now,
    lastSeen: now,
    lastSecuritySync: now,
  );
}

DiscoveredEventArgs _event({required String uuid, required int rssi}) {
  return DiscoveredEventArgs(
    _TestPeripheral(UUID.fromString(uuid)),
    rssi,
    Advertisement(
      name: 'overlay-test-device',
      manufacturerSpecificData: <ManufacturerSpecificData>[],
    ),
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    DeviceDeduplicationManager.clearAll();
    HintCacheManager.dispose();
    HintCacheManager.clearContactRepository();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    DeviceDeduplicationManager.clearAll();
    HintCacheManager.dispose();
    HintCacheManager.clearContactRepository();
    await getIt.reset();
  });

  _Harness createHarness({
    required MockConnectionService connectionService,
    required BurstScanningStatus burstStatus,
  }) {
    final connectionInfoController =
        StreamController<ConnectionInfo>.broadcast();
    final connectionInfoStreamProvider = StreamProvider<ConnectionInfo>(
      (ref) => connectionInfoController.stream,
    );

    final container = ProviderContainer(
      overrides: [
        connectionServiceProvider.overrideWithValue(connectionService),
        burstScanningStatusProvider.overrideWith(
          (ref) => Stream<BurstScanningStatus>.multi((controller) {
            controller.add(burstStatus);
            controller.close();
          }),
        ),
        connectionInfoProvider.overrideWith(
          (ref) => ref.watch(connectionInfoStreamProvider),
        ),
      ],
    );

    return _Harness(
      container: container,
      connectionInfoController: connectionInfoController,
    );
  }

  void registerContactRepository(_FakeContactRepository repository) {
    if (getIt.isRegistered<IContactRepository>()) {
      getIt.unregister<IContactRepository>();
    }
    getIt.registerSingleton<IContactRepository>(repository);
    HintCacheManager.configureContactRepository(contactRepository: repository);
  }

  group('DiscoveryOverlayController', () {
    test(
      'build loads contacts and scan helpers reflect burst status',
      () async {
        final repository = _FakeContactRepository()
          ..queueContacts(<String, Contact>{
            'peer-1': _contact(key: 'peer-1', displayName: 'Peer One'),
          });
        registerContactRepository(repository);

        final harness = createHarness(
          connectionService: MockConnectionService(),
          burstStatus: _burstStatus(
            isBurstActive: false,
            secondsUntilNextScan: 9,
          ),
        );
        addTearDown(harness.dispose);

        final state = await harness.build();
        expect(state.contacts.keys, contains('peer-1'));
        expect(state.showScannerMode, isTrue);
        expect(repository.getAllContactsCalls, greaterThanOrEqualTo(1));
        expect(harness.controller.getUnifiedScanningState(), isFalse);
        expect(harness.controller.canTriggerManualScan(), isTrue);
      },
    );

    test('scan helpers block manual scan while burst mode is active', () async {
      final repository = _FakeContactRepository()
        ..queueContacts(<String, Contact>{});
      registerContactRepository(repository);

      final harness = createHarness(
        connectionService: MockConnectionService(),
        burstStatus: _burstStatus(isBurstActive: true, secondsUntilNextScan: 2),
      );
      addTearDown(harness.dispose);
      await harness.build();
      final burstSub = harness.container
          .listen<AsyncValue<BurstScanningStatus>>(
            burstScanningStatusProvider,
            (_, __) {},
            fireImmediately: true,
          );
      addTearDown(burstSub.close);
      await _settle();

      expect(harness.controller.getUnifiedScanningState(), isTrue);
      expect(harness.controller.canTriggerManualScan(), isFalse);
    });

    test(
      'mutators update scanner mode, attempts, timestamps, and stale cleanup',
      () async {
        final repository = _FakeContactRepository()
          ..queueContacts(<String, Contact>{});
        registerContactRepository(repository);

        final harness = createHarness(
          connectionService: MockConnectionService(),
          burstStatus: _burstStatus(
            isBurstActive: false,
            secondsUntilNextScan: 12,
          ),
        );
        addTearDown(harness.dispose);
        await harness.build();

        harness.controller.setShowScannerMode(false);
        expect(harness.state.requireValue.showScannerMode, isFalse);

        harness.controller.setAttemptState(
          'device-1',
          ConnectionAttemptState.connecting,
        );
        expect(
          harness.controller.attemptStateFor('device-1'),
          ConnectionAttemptState.connecting,
        );
        expect(
          harness.controller.attemptStateFor('unknown'),
          ConnectionAttemptState.none,
        );

        harness.controller.updateDeviceLastSeen('fresh-device');
        expect(
          harness.state.requireValue.deviceLastSeen.containsKey('fresh-device'),
          isTrue,
        );

        final current = harness.state.requireValue;
        harness.controller.state = AsyncValue<DiscoveryOverlayState>.data(
          current.copyWith(
            deviceLastSeen: <String, DateTime>{
              'stale-device': DateTime.now().subtract(
                const Duration(minutes: 4),
              ),
              'fresh-device': DateTime.now(),
            },
            connectionAttempts: <String, ConnectionAttemptState>{
              'stale-device': ConnectionAttemptState.failed,
              'fresh-device': ConnectionAttemptState.connected,
            },
          ),
        );

        harness.controller.cleanupStaleDevices();
        final cleaned = harness.state.requireValue;
        expect(cleaned.deviceLastSeen.containsKey('stale-device'), isFalse);
        expect(cleaned.connectionAttempts.containsKey('stale-device'), isFalse);
        expect(cleaned.deviceLastSeen.containsKey('fresh-device'), isTrue);

        harness.controller.recordIncomingConnection();
        expect(harness.state.requireValue.lastIncomingConnectionAt, isNotNull);
      },
    );

    test(
      'peripheral listener records incoming connection events on Android',
      () async {
        final repository = _FakeContactRepository()
          ..queueContacts(<String, Contact>{});
        registerContactRepository(repository);

        final connectionService = MockConnectionService()
          ..isPeripheralMode = true;
        final harness = createHarness(
          connectionService: connectionService,
          burstStatus: _burstStatus(
            isBurstActive: false,
            secondsUntilNextScan: 10,
          ),
        );
        addTearDown(harness.dispose);
        await harness.build();

        expect(harness.state.requireValue.lastIncomingConnectionAt, isNull);

        connectionService.emitPeripheralConnectionChange(
          CentralConnectionStateChangedEventArgs(
            _TestCentral(
              UUID.fromString('11111111-1111-1111-1111-111111111111'),
            ),
            ConnectionState.connected,
          ),
        );
        await _settle();

        expect(harness.state.requireValue.lastIncomingConnectionAt, isNotNull);
      },
    );

    test(
      'identity updates refresh contacts and propagate resolved contact by persistent key',
      () async {
        final repository = _FakeContactRepository()
          ..queueContacts(<String, Contact>{})
          ..queueContacts(<String, Contact>{
            'peer-persistent': _contact(
              key: 'peer-persistent',
              displayName: 'Resolved Peer',
            ),
          })
          ..contactsByAnyId['peer-persistent'] = _contact(
            key: 'peer-persistent',
            displayName: 'Resolved Peer',
          );
        registerContactRepository(repository);

        const deviceId = '22222222-2222-2222-2222-222222222222';
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(uuid: deviceId, rssi: -48),
        );
        await _settle();

        final connectionService = MockConnectionService();
        await connectionService.connectToDevice(
          _TestPeripheral(UUID.fromString(deviceId)),
        );
        connectionService.theirPersistentPublicKey = 'peer-persistent';

        final harness = createHarness(
          connectionService: connectionService,
          burstStatus: _burstStatus(
            isBurstActive: false,
            secondsUntilNextScan: 11,
          ),
        );
        addTearDown(harness.dispose);
        await harness.build();
        final callsBeforeUpdate = repository.getAllContactsCalls;

        harness.pushConnectionInfo(
          const ConnectionInfo(
            isConnected: true,
            isReady: true,
            otherUserName: 'Alias from link',
          ),
        );
        await _settle();

        final deduped = DeviceDeduplicationManager.getDevice(deviceId);
        expect(repository.getAllContactsCalls, greaterThan(callsBeforeUpdate));
        expect(repository.getContactByAnyIdCalls, greaterThanOrEqualTo(1));
        expect(deduped, isNotNull);
        expect(deduped!.isKnownContact, isTrue);
        expect(deduped.contactInfo?.displayName, 'Resolved Peer');
      },
    );

    test(
      'identity propagation falls back to session id and remote alias',
      () async {
        final repository = _FakeContactRepository()
          ..queueContacts(<String, Contact>{})
          ..queueContacts(<String, Contact>{});
        registerContactRepository(repository);

        const deviceId = '33333333-3333-3333-3333-333333333333';
        DeviceDeduplicationManager.processDiscoveredDevice(
          _event(uuid: deviceId, rssi: -55),
        );
        await _settle();

        final connectionService = MockConnectionService();
        await connectionService.connectToDevice(
          _TestPeripheral(UUID.fromString(deviceId)),
        );
        connectionService.theirPersistentPublicKey = null;
        connectionService.currentSessionId = 'session-fallback';

        final harness = createHarness(
          connectionService: connectionService,
          burstStatus: _burstStatus(
            isBurstActive: false,
            secondsUntilNextScan: 14,
          ),
        );
        addTearDown(harness.dispose);
        await harness.build();

        harness.pushConnectionInfo(
          const ConnectionInfo(
            isConnected: true,
            isReady: true,
            otherUserName: 'Fallback Alias',
          ),
        );
        await _settle();

        final deduped = DeviceDeduplicationManager.getDevice(deviceId);
        expect(deduped, isNotNull);
        expect(deduped!.isKnownContact, isTrue);
        expect(deduped.contactInfo?.displayName, 'Fallback Alias');
        expect(deduped.contactInfo?.contact.publicKey, 'session-fallback');
        expect(deduped.contactInfo?.contact.securityLevel, SecurityLevel.low);
      },
    );
  });
}
