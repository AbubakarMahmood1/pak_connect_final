import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_connection_service.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/core/bluetooth/bluetooth_state_monitor.dart';

// Generate mocks for dependencies
class MockBLEStateManager extends Mock implements BLEStateManager {}

class MockBLEConnectionManager extends Mock implements BLEConnectionManager {}

class MockCentralManager extends Mock implements CentralManager {}

class MockBluetoothStateMonitor extends Mock implements BluetoothStateMonitor {}

void main() {
  late BLEConnectionService service;
  late MockBLEStateManager mockStateManager;
  late MockBLEConnectionManager mockConnectionManager;
  late MockCentralManager mockCentralManager;
  late MockBluetoothStateMonitor mockBluetoothMonitor;

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
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service, isNotNull);
    });

    test('has public API methods', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
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
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
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
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
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
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.peripheralHandshakeStarted, false);
      service.peripheralHandshakeStarted = true;
      expect(service.peripheralHandshakeStarted, true);
    });

    test('mesh networking flag can be set', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.meshNetworkingStarted, false);
      service.meshNetworkingStarted = true;
      expect(service.meshNetworkingStarted, true);
    });

    test('connected central property can be set', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.connectedCentral, isNull);
      service.connectedCentral = null;
      expect(service.connectedCentral, isNull);
    });

    test('can dispose connection', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      service.disposeConnection();
      expect(service.connectionInfoController, isNull);
    });

    test('getConnectionInfo() returns current state', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      final info = service.getConnectionInfo();
      expect(info, isNotNull);
      expect(info?.isConnected, false);
    });

    test('connection info stream is available', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      final stream = service.connectionInfoStream;
      expect(stream, isNotNull);
    });

    test('has peripheral connection property', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.hasPeripheralConnection, false);
    });

    test('has central connection property', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.hasCentralConnection, false);
    });

    test('can send messages property', () {
      mockStateManager = MockBLEStateManager();
      mockConnectionManager = MockBLEConnectionManager();
      mockCentralManager = MockCentralManager();
      mockBluetoothMonitor = MockBluetoothStateMonitor();

      createService();

      expect(service.canSendMessages, false);
    });
  });
}
