import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_connection_service.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/connection_state.dart'
    show ChatConnectionState;
import 'package:pak_connect/core/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/core/bluetooth/bluetooth_state_monitor.dart';
import 'package:pak_connect/core/discovery/device_deduplication_manager.dart';
import '../helpers/ble/ble_fakes.dart';

@GenerateNiceMocks([
  MockSpec<IBLEStateManagerFacade>(),
  MockSpec<BLEConnectionManager>(),
  MockSpec<CentralManager>(),
  MockSpec<BluetoothStateMonitor>(),
])
import 'ble_connection_service_test.mocks.dart';

void main() {
  late BLEConnectionService service;
  late MockIBLEStateManagerFacade mockStateManager;
  late _MockConnectionManagerWithAddresses mockConnectionManager;
  late MockCentralManager mockCentralManager;
  late MockBluetoothStateMonitor mockBluetoothMonitor;
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
  });

  tearDown(() {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
  });

  void createService() {
    // Create service with callback
    service = BLEConnectionService(
      stateManager: mockStateManager,
      connectionManager: mockConnectionManager,
      centralManager: mockCentralManager,
      bluetoothStateMonitor: mockBluetoothMonitor,
      onUpdateConnectionInfo:
          ({
            bool? isConnected,
            bool? isReady,
            String? otherUserName,
            String? statusMessage,
            bool? isScanning,
            bool? isAdvertising,
            bool? isReconnecting,
          }) {
            // Do nothing
          },
    );
  }

  group('BLEConnectionService', () {
    test('can be instantiated', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service, isNotNull);
    });

    test('has public API methods', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.connectToDevice, isNotNull);
      expect(service.disconnect, isNotNull);
      expect(service.startConnectionMonitoring, isNotNull);
      expect(service.stopConnectionMonitoring, isNotNull);
      expect(service.setHandshakeInProgress, isNotNull);
      expect(service.getConnectionInfoWithFallback, isNotNull);
      expect(service.attemptIdentityRecovery, isNotNull);
    });

    test('has state getters', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      when(mockStateManager.isPeripheralMode).thenReturn(false);
      when(mockStateManager.otherUserName).thenReturn(null);
      when(mockStateManager.currentSessionId).thenReturn(null);
      when(mockConnectionManager.connectedDevice).thenReturn(null);
      when(mockConnectionManager.isMonitoring).thenReturn(false);
      when(mockConnectionManager.hasBleConnection).thenReturn(false);
      when(mockConnectionManager.isActivelyReconnecting).thenReturn(false);

      createService();

      expect(service.isConnected, isFalse);
      expect(service.isMonitoring, isFalse);
      expect(service.currentConnectionInfo, isNotNull);
      expect(service.connectedDevice, isNull);
      expect(service.otherUserName, isNull);
      expect(service.currentSessionId, isNull);
    });

    test('current connection info is initialized', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.currentConnectionInfo.isConnected, false);
      expect(
        service.currentConnectionInfo.statusMessage,
        contains('Disconnected'),
      );
    });

    test('peripheral handshake flag can be set', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.peripheralHandshakeStarted, false);
      service.peripheralHandshakeStarted = true;
      expect(service.peripheralHandshakeStarted, true);
    });

    test('mesh networking flag can be set', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.meshNetworkingStarted, false);
      service.meshNetworkingStarted = true;
      expect(service.meshNetworkingStarted, true);
    });

    test('connected central property can be set', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.connectedCentral, isNull);
      service.connectedCentral = null;
      expect(service.connectedCentral, isNull);
    });

    test('can dispose connection', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      service.disposeConnection();
      verify(mockConnectionManager.stopConnectionMonitoring()).called(1);
    });

    test('getConnectionInfo() returns current state', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      final info = service.getConnectionInfo();
      expect(info, isNotNull);
      expect(info?.isConnected, false);
    });

    test('connection info stream is available', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.connectionInfoStream, emits(isA<ConnectionInfo>()));
    });

    test('has peripheral connection property', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.hasPeripheralConnection, false);
    });

    test('has central connection property', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.hasCentralConnection, false);
    });

    test('can send messages property', () {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.canSendMessages, false);
    });

    test('auto-connect backs off when slots are unavailable', () async {
      mockStateManager = MockIBLEStateManagerFacade();
      mockConnectionManager = _MockConnectionManagerWithAddresses();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      when(
        mockCentralManager.stateChanged,
      ).thenAnswer((_) => const Stream.empty());
      when(mockConnectionManager.clientConnectionCount).thenReturn(3);
      when(mockConnectionManager.maxClientConnections).thenReturn(3);
      when(mockConnectionManager.canAcceptClientConnection).thenReturn(false);
      when(mockStateManager.isPeripheralMode).thenReturn(false);

      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000dcba',
      );

      createService();
      service.setupConnectionInitialization();
      addTearDown(() {
        DeviceDeduplicationManager.onKnownContactDiscovered = null;
      });

      final callback = DeviceDeduplicationManager.onKnownContactDiscovered;
      expect(callback, isNotNull);

      await callback!(peripheral, 'Bob');
      await Future<void>.delayed(Duration.zero);

      verifyNever(mockConnectionManager.connectToDevice(peripheral));
    });

    test(
      'auto-connect skips dial when tracker reports existing link',
      () async {
        mockStateManager = MockIBLEStateManagerFacade();
        mockConnectionManager = _MockConnectionManagerWithAddresses();
        mockCentralManager = MockCentralManager();
        mockBluetoothMonitor = MockBluetoothStateMonitor();

        when(
          mockCentralManager.stateChanged,
        ).thenAnswer((_) => const Stream.empty());
        when(mockConnectionManager.clientConnectionCount).thenReturn(0);
        when(mockConnectionManager.maxClientConnections).thenReturn(3);
        when(mockConnectionManager.canAcceptClientConnection).thenReturn(true);
        when(mockStateManager.isPeripheralMode).thenReturn(false);

        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000abcd',
        );
        mockConnectionManager.connectedAddressesStub = [
          peripheral.uuid.toString(),
        ];

        createService();
        service.setupConnectionInitialization();
        addTearDown(() {
          DeviceDeduplicationManager.onKnownContactDiscovered = null;
        });

        final callback = DeviceDeduplicationManager.onKnownContactDiscovered;
        expect(callback, isNotNull);

        await callback!(peripheral, 'Alice');
        await Future<void>.delayed(Duration.zero);

        verifyNever(mockConnectionManager.connectToDevice(peripheral));
      },
    );

    test(
      'auto-connect vetoes when hint collision or existing link is detected',
      () {
        mockStateManager = MockIBLEStateManagerFacade();
        mockConnectionManager = _MockConnectionManagerWithAddresses();
        mockCentralManager = MockCentralManager();
        mockBluetoothMonitor = MockBluetoothStateMonitor();

        const deviceId = '00000000-0000-0000-0000-00000000abcd';
        const hint = 'hint-$deviceId';

        when(
          mockCentralManager.stateChanged,
        ).thenAnswer((_) => const Stream.empty());
        when(mockConnectionManager.clientConnectionCount).thenReturn(0);
        when(mockConnectionManager.maxClientConnections).thenReturn(3);
        when(mockConnectionManager.canAcceptClientConnection).thenReturn(true);
        when(mockStateManager.isPeripheralMode).thenReturn(false);
        when(
          mockConnectionManager.connectionState,
        ).thenReturn(ChatConnectionState.ready);
        mockConnectionManager.hasClientLink = false;
        mockConnectionManager.hasServerLink = false;
        mockConnectionManager.hasPendingClient = false;
        mockConnectionManager.hasHintCollision = true;

        createService();
        service.setupConnectionInitialization();
        addTearDown(() {
          DeviceDeduplicationManager.shouldAutoConnect = null;
          DeviceDeduplicationManager.onKnownContactDiscovered = null;
        });

        final predicate = DeviceDeduplicationManager.shouldAutoConnect;
        expect(predicate, isNotNull);

        final device = _buildDiscoveredDevice(deviceId: deviceId, hint: hint);

        final shouldConnect = predicate!(device);

        expect(shouldConnect, isFalse);
      },
    );
  });
}

DiscoveredDevice _buildDiscoveredDevice({
  required String deviceId,
  required String hint,
}) {
  return DiscoveredDevice(
    deviceId: deviceId,
    ephemeralHint: hint,
    peripheral: fakePeripheralFromString(deviceId),
    rssi: -50,
    advertisement: Advertisement(name: 'Known'),
    firstSeen: DateTime.now().subtract(const Duration(seconds: 5)),
    lastSeen: DateTime.now(),
  );
}

class _MockConnectionManagerWithAddresses extends MockBLEConnectionManager {
  List<String> connectedAddressesStub = const [];
  bool hasClientLink = false;
  bool hasServerLink = false;
  bool hasPendingClient = false;
  bool hasHintCollision = false;

  @override
  List<String> get connectedAddresses => connectedAddressesStub;

  @override
  bool hasClientLinkForPeer(String? peerAddress) => hasClientLink;

  @override
  bool hasServerLinkForPeer(String? peerAddress) => hasServerLink;

  @override
  bool hasPendingClientForPeer(String? peerAddress) => hasPendingClient;

  @override
  bool hasAnyLinkForPeerHint(String? peerHint) => hasHintCollision;
}

