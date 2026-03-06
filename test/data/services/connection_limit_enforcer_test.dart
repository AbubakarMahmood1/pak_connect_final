import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/models/ble_client_connection.dart';
import 'package:pak_connect/data/models/connection_limit_config.dart';
import 'package:pak_connect/data/services/connection_limit_enforcer.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/power_mode.dart';

import '../../helpers/ble/ble_fakes.dart';

class _FakeCentralManager implements CentralManager {
  final List<Peripheral> disconnected = <Peripheral>[];
  final Set<UUID> disconnectFailures = <UUID>{};

  @override
  Future<void> disconnect(Peripheral peripheral) async {
    disconnected.add(peripheral);
    if (disconnectFailures.contains(peripheral.uuid)) {
      throw StateError('disconnect failed');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BLEClientConnection _client({
  required String address,
  required int seed,
  required DateTime connectedAt,
}) {
  return BLEClientConnection(
    address: address,
    peripheral: FakePeripheral(
      uuid: UUID(Uint8List.fromList(List.filled(16, seed))),
    ),
    connectedAt: connectedAt,
  );
}

BLEServerConnection _server({
  required String address,
  required int seed,
  required DateTime connectedAt,
}) {
  return BLEServerConnection(
    address: address,
    central: FakeCentral(uuid: UUID(Uint8List.fromList(List.filled(16, seed)))),
    connectedAt: connectedAt,
  );
}

void main() {
  late ConnectionLimitEnforcer enforcer;
  late _FakeCentralManager centralManager;

  setUp(() {
    enforcer = ConnectionLimitEnforcer();
    centralManager = _FakeCentralManager();
  });

  test('rssiThresholdForPowerMode returns expected thresholds', () {
    expect(enforcer.rssiThresholdForPowerMode(PowerMode.performance), -95);
    expect(enforcer.rssiThresholdForPowerMode(PowerMode.balanced), -85);
    expect(enforcer.rssiThresholdForPowerMode(PowerMode.powerSaver), -75);
    expect(enforcer.rssiThresholdForPowerMode(PowerMode.ultraLowPower), -65);
  });

  test('isTransientConnectError matches known retryable patterns', () {
    expect(
      enforcer.isTransientConnectError(Exception('Connection timeout')),
      isTrue,
    );
    expect(
      enforcer.isTransientConnectError(Exception('GATT 133 generic')),
      isTrue,
    );
    expect(
      enforcer.isTransientConnectError(Exception('status=147 broken link')),
      isTrue,
    );
    expect(
      enforcer.isTransientConnectError(Exception('Gatt error 133')),
      isTrue,
    );
    expect(
      enforcer.isTransientConnectError(Exception('permanent auth failure')),
      isFalse,
    );
  });

  test('enforceConnectionLimits no-ops when under all limits', () async {
    final clientConnections = <String, BLEClientConnection>{
      'c1': _client(
        address: 'c1',
        seed: 1,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    };
    final serverConnections = <String, BLEServerConnection>{
      's1': _server(
        address: 's1',
        seed: 2,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    };

    var advertisingUpdates = 0;

    await enforcer.enforceConnectionLimits(
      limitConfig: ConnectionLimitConfig.forPowerMode(PowerMode.performance),
      clientConnections: clientConnections,
      serverConnections: serverConnections,
      centralManager: centralManager,
      updateAdvertisingState: () async => advertisingUpdates++,
      formatAddress: (address) => address,
    );

    expect(centralManager.disconnected, isEmpty);
    expect(serverConnections, hasLength(1));
    expect(advertisingUpdates, 0);
  });

  test(
    'disconnects oldest clients and removes entry when disconnect fails',
    () async {
      final oldest = _client(
        address: 'oldest-client',
        seed: 3,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 30)),
      );
      final middle = _client(
        address: 'middle-client',
        seed: 4,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 20)),
      );
      final newest = _client(
        address: 'newest-client',
        seed: 5,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );

      final clientConnections = <String, BLEClientConnection>{
        oldest.address: oldest,
        middle.address: middle,
        newest.address: newest,
      };

      final serverConnections = <String, BLEServerConnection>{};
      centralManager.disconnectFailures.add(oldest.peripheral.uuid);

      var advertisingUpdates = 0;

      await enforcer.enforceConnectionLimits(
        limitConfig: ConnectionLimitConfig.forPowerMode(
          PowerMode.ultraLowPower,
        ),
        clientConnections: clientConnections,
        serverConnections: serverConnections,
        centralManager: centralManager,
        updateAdvertisingState: () async => advertisingUpdates++,
        formatAddress: (address) => 'fmt:$address',
      );

      expect(centralManager.disconnected, hasLength(1));
      expect(centralManager.disconnected.first.uuid, oldest.peripheral.uuid);
      expect(clientConnections.containsKey(oldest.address), isFalse);
      expect(advertisingUpdates, 1);
    },
  );

  test(
    'disconnects oldest server entries and updates advertising state',
    () async {
      final first = _server(
        address: 'server-1',
        seed: 11,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 30)),
      );
      final second = _server(
        address: 'server-2',
        seed: 12,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 20)),
      );
      final latest = _server(
        address: 'server-3',
        seed: 13,
        connectedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      final serverConnections = <String, BLEServerConnection>{
        first.address: first,
        second.address: second,
        latest.address: latest,
      };

      var advertisingUpdates = 0;

      await enforcer.enforceConnectionLimits(
        limitConfig: ConnectionLimitConfig.forPowerMode(
          PowerMode.ultraLowPower,
        ),
        clientConnections: {},
        serverConnections: serverConnections,
        centralManager: centralManager,
        updateAdvertisingState: () async => advertisingUpdates++,
        formatAddress: (address) => address,
      );

      expect(serverConnections.keys, {'server-3'});
      expect(advertisingUpdates, 1);
    },
  );
}
