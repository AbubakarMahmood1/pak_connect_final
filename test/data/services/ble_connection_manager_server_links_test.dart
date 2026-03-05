import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';

import '../../helpers/ble/ble_fakes.dart';
import 'ble_messaging_service_test.mocks.dart';

void main() {
  late MockCentralManager centralManager;
  late MockPeripheralManager peripheralManager;
  late BLEConnectionManager manager;

  setUp(() {
    centralManager = MockCentralManager();
    peripheralManager = MockPeripheralManager();
    manager = BLEConnectionManager(
      centralManager: centralManager,
      peripheralManager: peripheralManager,
    );
  });

  tearDown(() {
    manager.dispose();
  });

  group('BLEConnectionManager server links', () {
    test(
      'handleCentralConnected registers server link and emits stream',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000101',
        );
        final address = central.uuid.toString();

        final emittedFuture = manager.serverConnectionsStream.firstWhere(
          (connections) =>
              connections.any((connection) => connection.address == address),
        );

        manager.handleCentralConnected(central);

        final emitted = await emittedFuture.timeout(const Duration(seconds: 2));
        expect(manager.serverConnectionCount, 1);
        expect(manager.hasServerConnection(address), isTrue);
        expect(manager.hasServerLinkForPeer(address), isTrue);
        expect(emitted.single.address, address);
        expect(manager.isNoHintDebounceActive, isTrue);
      },
    );

    test(
      'handleCentralConnected rejects inbound when state is ready',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000102',
        );
        final address = central.uuid.toString();
        manager.markHandshakeComplete();

        manager.handleCentralConnected(central);
        await _settle();

        verify(peripheralManager.disconnect(central)).called(1);
        expect(manager.serverConnectionCount, 0);
        expect(manager.isResponderHandshakeBlocked(address), isTrue);
      },
    );

    test(
      'handleCentralConnected rejects duplicate inbound for same address',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000103',
        );

        manager.handleCentralConnected(central);
        await _settle();
        manager.handleCentralConnected(central);
        await _settle();

        verify(peripheralManager.disconnect(central)).called(1);
        expect(manager.serverConnectionCount, 1);
      },
    );

    test(
      'handleCentralDisconnected removes known server and clears callbacks',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000104',
        );
        final address = central.uuid.toString();

        var disconnectedAddress = '';
        var characteristicResetCalls = 0;
        var mtuResetCalls = 0;
        manager.onCentralDisconnected = (value) => disconnectedAddress = value;
        manager.onCharacteristicFound = (value) {
          if (value == null) {
            characteristicResetCalls++;
          }
        };
        manager.onMtuDetected = (value) {
          if (value == null) {
            mtuResetCalls++;
          }
        };

        manager.handleCentralConnected(central);
        await _settle();

        manager.handleCentralDisconnected(central);
        await _settle();

        expect(disconnectedAddress, address);
        expect(characteristicResetCalls, 1);
        expect(mtuResetCalls, 1);
        expect(manager.serverConnectionCount, 0);
      },
    );

    test('handleCentralDisconnected ignores unknown central', () async {
      final central = fakeCentralFromString(
        '00000000-0000-0000-0000-000000000105',
      );

      manager.handleCentralDisconnected(central);
      await _settle();

      expect(manager.serverConnectionCount, 0);
    });

    test(
      'handleCharacteristicSubscribed stores subscribed characteristic',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000106',
        );
        final characteristic = FakeGATTCharacteristic(
          uuid: UUID.fromString('00000000-0000-0000-0000-000000000601'),
        );

        manager.handleCentralConnected(central);
        await _settle();
        manager.handleCharacteristicSubscribed(central, characteristic);
        await _settle();

        final connection = manager.serverConnections.single;
        expect(connection.subscribedCharacteristic, same(characteristic));
      },
    );

    test(
      'handleCharacteristicSubscribed tears down duplicate inbound when ready and hint-colliding',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000107',
        );
        final address = central.uuid.toString();
        final characteristic = FakeGATTCharacteristic(
          uuid: UUID.fromString('00000000-0000-0000-0000-000000000701'),
        );

        manager.handleCentralConnected(central);
        await _settle();
        manager.cachePeerHintForAddress(address, 'peer-hint-107');
        manager.markHandshakeComplete();

        manager.handleCharacteristicSubscribed(central, characteristic);
        await _waitForCondition(() => manager.serverConnectionCount == 0);

        verify(peripheralManager.disconnect(central)).called(1);
        expect(manager.hasServerConnection(address), isFalse);
      },
    );

    test('updateServerMtu writes MTU onto tracked server connection', () async {
      final central = fakeCentralFromString(
        '00000000-0000-0000-0000-000000000108',
      );
      final address = central.uuid.toString();

      manager.handleCentralConnected(central);
      await _settle();
      manager.updateServerMtu(address, 185);
      await _settle();

      expect(manager.serverConnections.single.mtu, 185);
    });
  });

  group('BLEConnectionManager client/runtime guards', () {
    test(
      'connectToDevice skips outbound connect when peer already linked as server',
      () async {
        final uuid = '00000000-0000-0000-0000-000000000201';
        final central = fakeCentralFromString(uuid);
        final peripheral = fakePeripheralFromString(uuid);

        manager.handleCentralConnected(central);
        await _settle();
        await manager.connectToDevice(peripheral);

        verifyNever(centralManager.connect(any));
        expect(manager.clientConnectionCount, 0);
      },
    );

    test('connectToDevice skips weak RSSI below threshold', () async {
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-000000000202',
      );

      await manager.connectToDevice(peripheral, rssi: -120);

      verifyNever(centralManager.connect(any));
      expect(manager.clientConnectionCount, 0);
    });

    test(
      'scanForSpecificDevice returns null when bluetooth is not powered on',
      () async {
        when(
          centralManager.state,
        ).thenReturn(BluetoothLowEnergyState.poweredOff);

        final result = await manager.scanForSpecificDevice(
          timeout: const Duration(milliseconds: 50),
        );

        expect(result, isNull);
        verifyNever(
          centralManager.startDiscovery(serviceUUIDs: anyNamed('serviceUUIDs')),
        );
      },
    );

    test(
      'clearConnectionState keepMonitoring preserves active server links',
      () async {
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-000000000203',
        );
        final address = central.uuid.toString();

        manager.handleCentralConnected(central);
        await _settle();

        manager.clearConnectionState(keepMonitoring: true);

        expect(manager.serverConnectionCount, 1);
        expect(manager.hasServerConnection(address), isTrue);
        expect(manager.clientConnectionCount, 0);
      },
    );
  });
}

Future<void> _settle([int milliseconds = 25]) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
}

Future<void> _waitForCondition(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await _settle(10);
  }
  expect(predicate(), isTrue, reason: 'Timed out waiting for async condition');
}
