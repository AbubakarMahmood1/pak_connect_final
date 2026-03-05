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
          getConnectedDevice: () => peripheral,
          getMessageCharacteristic: () => characteristic,
          onReconnectionFlagChanged: reconnectionFlags.add,
        );
        addTearDown(monitor.stop);

        monitor.start();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        verify(centralManager.disconnect(any));
        expect(reconnectionFlags, contains(true));
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
      var scanCalls = 0;
      var connectCalls = 0;

      final monitor = _buildMonitor(
        centralManager: centralManager,
        hasBleConnection: () => false,
        scanForSpecificDevice:
            ({Duration timeout = const Duration(seconds: 8)}) async {
              scanCalls++;
              return foundDevice;
            },
        connectToDevice: (device) async {
          connectCalls++;
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
        scanForSpecificDevice:
            ({Duration timeout = const Duration(seconds: 8)}) async {
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

    test(
      'pending client connection suppresses reconnection scanning',
      () async {
        var scanCalls = 0;
        final monitor = _buildMonitor(
          centralManager: MockCentralManager(),
          hasBleConnection: () => false,
          hasPendingClientConnection: () => true,
          scanForSpecificDevice:
              ({Duration timeout = const Duration(seconds: 8)}) async {
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
  });
}

ConnectionHealthMonitor _buildMonitor({
  required CentralManager centralManager,
  required bool Function() hasBleConnection,
  Peripheral? Function()? getConnectedDevice,
  GATTCharacteristic? Function()? getMessageCharacteristic,
  Future<void> Function({bool keepMonitoring})? clearConnectionState,
  Future<Peripheral?> Function({Duration timeout})? scanForSpecificDevice,
  Future<void> Function(Peripheral device)? connectToDevice,
  bool Function()? hasViableRelayConnection,
  void Function(bool active)? onMonitoringChanged,
  void Function(bool isReconnection)? onReconnectionFlagChanged,
  bool Function()? hasActiveClientLink,
  bool Function()? isCollisionResolving,
  bool Function()? hasPendingClientConnection,
  int minInterval = 10,
  int maxInterval = 10,
  int healthCheckInterval = 10,
  int maxReconnectAttempts = 2,
}) {
  return ConnectionHealthMonitor(
    logger: Logger('ConnectionHealthMonitorTest'),
    centralManager: centralManager,
    minInterval: minInterval,
    maxInterval: maxInterval,
    maxReconnectAttempts: maxReconnectAttempts,
    healthCheckInterval: healthCheckInterval,
    getConnectedDevice: getConnectedDevice ?? () => null,
    getMessageCharacteristic: getMessageCharacteristic ?? () => null,
    hasBleConnection: hasBleConnection,
    clearConnectionState:
        clearConnectionState ?? ({bool keepMonitoring = false}) async {},
    scanForSpecificDevice:
        scanForSpecificDevice ??
        ({Duration timeout = const Duration(seconds: 8)}) async => null,
    connectToDevice: connectToDevice ?? (Peripheral device) async {},
    hasViableRelayConnection: hasViableRelayConnection ?? () => false,
    onMonitoringChanged: onMonitoringChanged,
    onReconnectionFlagChanged: onReconnectionFlagChanged,
    hasActiveClientLink: hasActiveClientLink,
    isCollisionResolving: isCollisionResolving,
    hasPendingClientConnection: hasPendingClientConnection,
  );
}
