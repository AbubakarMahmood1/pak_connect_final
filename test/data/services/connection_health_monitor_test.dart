import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/data/services/connection_health_monitor.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';

import '../../helpers/ble/ble_fakes.dart';
import 'ble_connection_service_test.mocks.dart';

void main() {
  group('ConnectionHealthMonitor', () {
    setUp(() {
      resetMockitoState();
      KillSwitches.disableHealthChecks = false;
    });

    tearDown(() {
      KillSwitches.disableHealthChecks = false;
    });

    test('start and stop toggle monitoring state and callbacks', () {
      final monitorTransitions = <bool>[];
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => false,
        onMonitoringChanged: monitorTransitions.add,
      );

      monitor.start();

      expect(monitor.isMonitoring, isTrue);
      expect(monitor.isActivelyReconnecting, isTrue);

      monitor.stop();

      expect(monitor.isMonitoring, isFalse);
      expect(monitorTransitions, [true, false]);
    });

    test('start is blocked when health checks kill switch is enabled', () {
      KillSwitches.disableHealthChecks = true;
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => false,
      );

      monitor.start();

      expect(monitor.isMonitoring, isFalse);
      expect(monitor.isHealthChecking, isFalse);
    });

    test('startHealthChecks requires active BLE connection', () {
      var hasConnection = false;
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => hasConnection,
      );
      addTearDown(monitor.stop);

      monitor.startHealthChecks();
      expect(monitor.isMonitoring, isFalse);
      expect(monitor.awaitingHandshake, isFalse);

      hasConnection = true;
      monitor.startHealthChecks();

      expect(monitor.isMonitoring, isTrue);
      expect(monitor.isHealthChecking, isTrue);
      expect(monitor.awaitingHandshake, isTrue);
    });

    test('health-check loop writes ping when connection is healthy', () async {
      final centralManager = MockCentralManager();
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000001',
      );
      final characteristic = FakeGATTCharacteristic();
      final writes = <int>[];

      when(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((_) async {
        writes.add(1);
      });

      final monitor = _buildMonitor(
        centralManager: centralManager,
        hasBleConnection: () => true,
        getConnectedDevice: () => peripheral,
        getMessageCharacteristic: () => characteristic,
      );
      addTearDown(monitor.stop);

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      verify(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      );
      expect(writes, isNotEmpty);
      expect(monitor.isHealthChecking, isTrue);
    });

    test(
      'health-check failures clear connection state and raise reconnection flag',
      () async {
        final centralManager = MockCentralManager();
        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-000000000002',
        );
        final characteristic = FakeGATTCharacteristic();
        final reconnectionFlags = <bool>[];

        when(
          centralManager.writeCharacteristic(
            any,
            any,
            value: anyNamed('value'),
            type: anyNamed('type'),
          ),
        ).thenThrow(Exception('ping failed'));
        when(centralManager.disconnect(any)).thenAnswer((_) async {});

        final monitor = _buildMonitor(
          centralManager: centralManager,
          hasBleConnection: () => true,
          maxReconnectAttempts: 1,
          getConnectedDevice: () => peripheral,
          getMessageCharacteristic: () => characteristic,
          onReconnectionFlagChanged: reconnectionFlags.add,
        );
        addTearDown(monitor.stop);

        monitor.start();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        verify(centralManager.disconnect(any));
        expect(reconnectionFlags, contains(true));
        expect(reconnectionFlags.last, isFalse);
        expect(monitor.isMonitoring, isFalse);
      },
    );

    test('awaiting handshake suppresses health-check writes', () async {
      final centralManager = MockCentralManager();
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000003',
      );
      final characteristic = FakeGATTCharacteristic();

      when(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((_) async {});

      final monitor = _buildMonitor(
        centralManager: centralManager,
        hasBleConnection: () => true,
        getConnectedDevice: () => peripheral,
        getMessageCharacteristic: () => characteristic,
      );
      addTearDown(monitor.stop);

      monitor.start();
      monitor.setAwaitingHandshake(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verifyNever(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      );
    });

    test('reconnection success transitions back to health checking', () async {
      final centralManager = MockCentralManager();
      final foundDevice = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000004',
      );
      final reconnectionFlags = <bool>[];
      var hasConnection = false;
      var scanCalls = 0;
      var connectCalls = 0;

      final monitor = _buildMonitor(
        centralManager: centralManager,
        hasBleConnection: () => hasConnection,
        getReconnectTarget: () => foundDevice,
        scanForReconnectTarget:
            ({
              required String expectedPeripheralUuid,
              Duration timeout = const Duration(seconds: 8),
            }) async {
              scanCalls++;
              expect(expectedPeripheralUuid, foundDevice.uuid.toString());
              return foundDevice;
            },
        connectToDevice: (device) async {
          connectCalls++;
          hasConnection = true;
        },
        onReconnectionFlagChanged: reconnectionFlags.add,
      );
      addTearDown(monitor.stop);

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(scanCalls, greaterThan(0));
      expect(connectCalls, 1);
      expect(reconnectionFlags, containsAllInOrder([true, false]));
      expect(monitor.isHealthChecking, isTrue);
      expect(monitor.isReconnection, isFalse);
    });

    test('reconnection stops after max attempts without discovery', () async {
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => false,
        maxReconnectAttempts: 1,
      );

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(monitor.isMonitoring, isFalse);
    });

    test('relay viability keeps monitor in health-check mode', () async {
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => false,
        hasViableRelayConnection: () => true,
      );
      addTearDown(monitor.stop);

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(monitor.isHealthChecking, isTrue);
      expect(monitor.isActivelyReconnecting, isFalse);
    });

    test('active client link skips reconnection attempt', () async {
      var scanCalls = 0;
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => false,
        hasActiveClientLink: () => true,
        scanForReconnectTarget:
            ({
              required String expectedPeripheralUuid,
              Duration timeout = const Duration(seconds: 8),
            }) async {
              scanCalls++;
              return null;
            },
      );
      addTearDown(monitor.stop);

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(scanCalls, 0);
      expect(monitor.isHealthChecking, isTrue);
    });

    test('active link recovery clears a stale reconnection flag', () async {
      final centralManager = MockCentralManager();
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000009',
      );
      final characteristic = FakeGATTCharacteristic();
      final reconnectionFlags = <bool>[];
      var activeLink = false;
      var writeAttempts = 0;
      when(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((_) async {
        if (writeAttempts++ == 0) {
          throw Exception('link failed');
        }
      });
      when(centralManager.disconnect(any)).thenAnswer((_) async {});

      final monitor = _buildMonitor(
        centralManager: centralManager,
        hasBleConnection: () => true,
        getConnectedDevice: () => peripheral,
        getMessageCharacteristic: () => characteristic,
        clearConnectionState: ({bool keepMonitoring = false}) async {
          activeLink = true;
        },
        hasActiveClientLink: () => activeLink,
        onReconnectionFlagChanged: reconnectionFlags.add,
      );
      addTearDown(monitor.stop);

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(reconnectionFlags, containsAllInOrder([true, false]));
      expect(monitor.isHealthChecking, isTrue);
      expect(monitor.isReconnection, isFalse);
    });

    test(
      'pending client connection suppresses reconnection scanning',
      () async {
        var scanCalls = 0;
        final monitor = _buildMonitor(
          centralManager: MockCentralManager(),
          hasBleConnection: () => false,
          hasPendingClientConnection: () => true,
          scanForReconnectTarget:
              ({
                required String expectedPeripheralUuid,
                Duration timeout = const Duration(seconds: 8),
              }) async {
                scanCalls++;
                return null;
              },
        );
        addTearDown(monitor.stop);

        monitor.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(scanCalls, 0);
        expect(monitor.isActivelyReconnecting, isTrue);
      },
    );

    test(
      'missing reconnect target fails the attempt without scanning',
      () async {
        var scanCalls = 0;
        final finished = <bool>[];
        final monitor = _buildMonitor(
          centralManager: MockCentralManager(),
          hasBleConnection: () => false,
          getReconnectTarget: () => null,
          scanForReconnectTarget:
              ({
                required String expectedPeripheralUuid,
                Duration timeout = const Duration(seconds: 8),
              }) async {
                scanCalls++;
                return null;
              },
          onReconnectionAttemptFinished: (_, success) => finished.add(success),
        );
        addTearDown(monitor.stop);

        monitor.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(scanCalls, 0);
        expect(finished, contains(false));
      },
    );

    test(
      'connect return without a live link is not reported as success',
      () async {
        final target = fakePeripheralFromString(
          '00000000-0000-0000-0000-000000000005',
        );
        final finished = <bool>[];
        final monitor = _buildMonitor(
          centralManager: MockCentralManager(),
          hasBleConnection: () => false,
          getReconnectTarget: () => target,
          scanForReconnectTarget:
              ({
                required String expectedPeripheralUuid,
                Duration timeout = const Duration(seconds: 8),
              }) async => target,
          connectToDevice: (_) async {},
          onReconnectionAttemptFinished: (_, success) => finished.add(success),
        );
        addTearDown(monitor.stop);

        monitor.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(finished, contains(false));
        expect(finished, isNot(contains(true)));
        expect(monitor.isActivelyReconnecting, isTrue);
      },
    );

    test(
      'stop during scan prevents the stale attempt from connecting',
      () async {
        final target = fakePeripheralFromString(
          '00000000-0000-0000-0000-000000000006',
        );
        final scanStarted = Completer<void>();
        final scanResult = Completer<Peripheral?>();
        var connectCalls = 0;
        final finished = <bool>[];
        final monitor = _buildMonitor(
          centralManager: MockCentralManager(),
          hasBleConnection: () => false,
          getReconnectTarget: () => target,
          scanForReconnectTarget:
              ({
                required String expectedPeripheralUuid,
                Duration timeout = const Duration(seconds: 8),
              }) {
                scanStarted.complete();
                return scanResult.future;
              },
          connectToDevice: (_) async => connectCalls++,
          onReconnectionAttemptFinished: (_, success) => finished.add(success),
        );

        monitor.start();
        await scanStarted.future.timeout(const Duration(seconds: 1));
        monitor.stop();
        scanResult.complete(target);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(connectCalls, 0);
        expect(finished, isNot(contains(true)));
      },
    );

    test('stop during connect suppresses stale reconnect success', () async {
      final target = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000007',
      );
      final connectStarted = Completer<void>();
      final connectResult = Completer<void>();
      var targetLinked = false;
      final finished = <bool>[];
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => targetLinked,
        getReconnectTarget: () => target,
        scanForReconnectTarget:
            ({
              required String expectedPeripheralUuid,
              Duration timeout = const Duration(seconds: 8),
            }) async => target,
        connectToDevice: (_) async {
          connectStarted.complete();
          await connectResult.future;
          targetLinked = true;
        },
        hasReconnectTargetLink: (_) => targetLinked,
        onReconnectionAttemptFinished: (_, success) => finished.add(success),
      );

      monitor.start();
      await connectStarted.future.timeout(const Duration(seconds: 1));
      monitor.stop();
      connectResult.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(finished, isNot(contains(true)));
      expect(monitor.isMonitoring, isFalse);
    });

    test('an unrelated BLE link cannot satisfy reconnect success', () async {
      final target = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000008',
      );
      var unrelatedLinkExists = false;
      final finished = <bool>[];
      final monitor = _buildMonitor(
        centralManager: MockCentralManager(),
        hasBleConnection: () => unrelatedLinkExists,
        getReconnectTarget: () => target,
        scanForReconnectTarget:
            ({
              required String expectedPeripheralUuid,
              Duration timeout = const Duration(seconds: 8),
            }) async => target,
        connectToDevice: (_) async => unrelatedLinkExists = true,
        hasReconnectTargetLink: (_) => false,
        onReconnectionAttemptFinished: (_, success) => finished.add(success),
      );
      addTearDown(monitor.stop);

      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(finished, contains(false));
      expect(finished, isNot(contains(true)));
    });
  });
}

ConnectionHealthMonitor _buildMonitor({
  required CentralManager centralManager,
  required bool Function() hasBleConnection,
  Peripheral? Function()? getConnectedDevice,
  Peripheral? Function()? getReconnectTarget,
  GATTCharacteristic? Function()? getMessageCharacteristic,
  Future<void> Function({bool keepMonitoring})? clearConnectionState,
  Future<Peripheral?> Function({
    required String expectedPeripheralUuid,
    Duration timeout,
  })?
  scanForReconnectTarget,
  Future<void> Function(Peripheral device)? connectToDevice,
  bool Function(String expectedPeripheralUuid)? hasReconnectTargetLink,
  bool Function()? hasViableRelayConnection,
  void Function(bool active)? onMonitoringChanged,
  void Function(bool isReconnection)? onReconnectionFlagChanged,
  void Function(String? peerId, bool success)? onReconnectionAttemptFinished,
  bool Function()? hasActiveClientLink,
  bool Function()? isCollisionResolving,
  bool Function()? hasPendingClientConnection,
  int minInterval = 10,
  int maxInterval = 10,
  int healthCheckInterval = 10,
  int maxReconnectAttempts = 2,
}) {
  final defaultReconnectTarget = fakePeripheralFromString(
    '00000000-0000-0000-0000-000000000099',
  );
  return ConnectionHealthMonitor(
    logger: Logger('ConnectionHealthMonitorTest'),
    centralManager: centralManager,
    minInterval: minInterval,
    maxInterval: maxInterval,
    maxReconnectAttempts: maxReconnectAttempts,
    healthCheckInterval: healthCheckInterval,
    getConnectedDevice: getConnectedDevice ?? () => null,
    getReconnectTarget: getReconnectTarget ?? () => defaultReconnectTarget,
    getMessageCharacteristic: getMessageCharacteristic ?? () => null,
    hasBleConnection: hasBleConnection,
    clearConnectionState:
        clearConnectionState ?? ({bool keepMonitoring = false}) async {},
    scanForReconnectTarget:
        scanForReconnectTarget ??
        ({
          required String expectedPeripheralUuid,
          Duration timeout = const Duration(seconds: 8),
        }) async => null,
    connectToDevice: connectToDevice ?? (Peripheral device) async {},
    hasReconnectTargetLink: hasReconnectTargetLink ?? (_) => hasBleConnection(),
    hasViableRelayConnection: hasViableRelayConnection ?? () => false,
    onMonitoringChanged: onMonitoringChanged,
    onReconnectionFlagChanged: onReconnectionFlagChanged,
    onReconnectionAttemptFinished: onReconnectionAttemptFinished,
    hasActiveClientLink: hasActiveClientLink,
    isCollisionResolving: isCollisionResolving,
    hasPendingClientConnection: hasPendingClientConnection,
  );
}
