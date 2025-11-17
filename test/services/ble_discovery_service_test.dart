import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_discovery_service.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/core/services/hint_scanner_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';

class MockCentralManager extends Mock implements CentralManager {}

class MockBLEStateManager extends Mock implements BLEStateManager {}

class MockHintScannerService extends Mock implements HintScannerService {}

void main() {
  late BLEDiscoveryService service;
  late MockCentralManager mockCentralManager;
  late MockBLEStateManager mockStateManager;
  late MockHintScannerService mockHintScanner;

  Map<String, dynamic> connectionInfoUpdates = {};

  setUp(() {
    mockCentralManager = MockCentralManager();
    mockStateManager = MockBLEStateManager();
    mockHintScanner = MockHintScannerService();

    when(mockStateManager.isPeripheralMode).thenReturn(false);

    service = BLEDiscoveryService(
      centralManager: mockCentralManager,
      stateManager: mockStateManager,
      hintScanner: mockHintScanner,
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
            connectionInfoUpdates = {
              'isScanning': isScanning,
              'statusMessage': statusMessage,
            };
          },
      isAdvertising: () => false,
      isConnected: () => false,
    );
  });

  group('BLEDiscoveryService', () {
    test('initial state is not scanning', () {
      expect(service.isDiscoveryActive, false);
      expect(service.currentScanningSource, null);
    });

    test('startScanning() begins discovery', () async {
      when(
        mockCentralManager.startDiscovery(
          serviceUUIDs: anyNamed('serviceUUIDs'),
        ),
      ).thenAnswer((_) async {});

      await service.startScanning(source: ScanningSource.manual);

      verify(
        mockCentralManager.startDiscovery(
          serviceUUIDs: anyNamed('serviceUUIDs'),
        ),
      ).called(1);
      expect(service.isDiscoveryActive, true);
      expect(service.currentScanningSource, ScanningSource.manual);
    });

    test('stopScanning() stops discovery', () async {
      when(
        mockCentralManager.startDiscovery(
          serviceUUIDs: anyNamed('serviceUUIDs'),
        ),
      ).thenAnswer((_) async {});
      when(mockCentralManager.stopDiscovery()).thenAnswer((_) async {});

      await service.startScanning();
      expect(service.isDiscoveryActive, true);

      await service.stopScanning();
      expect(service.isDiscoveryActive, false);
      expect(service.currentScanningSource, null);
    });

    test('startScanning() skips if already scanning same source', () async {
      when(
        mockCentralManager.startDiscovery(
          serviceUUIDs: anyNamed('serviceUUIDs'),
        ),
      ).thenAnswer((_) async {});

      await service.startScanning(source: ScanningSource.manual);
      expect(service.isDiscoveryActive, true);

      // Try to start again with same source
      await service.startScanning(source: ScanningSource.manual);
      // Should not call startDiscovery again
      verify(
        mockCentralManager.startDiscovery(
          serviceUUIDs: anyNamed('serviceUUIDs'),
        ),
      ).called(1);
    });

    test('currentDiscoveredDevices returns copy of devices list', () {
      final devices1 = service.currentDiscoveredDevices;
      final devices2 = service.currentDiscoveredDevices;
      expect(
        identical(devices1, devices2),
        false,
      ); // Should be different list objects
    });
  });
}
