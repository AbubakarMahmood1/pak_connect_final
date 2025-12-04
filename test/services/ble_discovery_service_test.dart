import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_discovery_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/core/services/hint_scanner_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';

@GenerateNiceMocks([
  MockSpec<CentralManager>(),
  MockSpec<IBLEStateManagerFacade>(),
  MockSpec<HintScannerService>(),
])
import 'ble_discovery_service_test.mocks.dart';

void main() {
  late BLEDiscoveryService service;
  late MockCentralManager mockCentralManager;
  late MockIBLEStateManagerFacade mockStateManager;
  late MockHintScannerService mockHintScanner;
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  Map<String, dynamic> connectionInfoUpdates = {};

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    mockCentralManager = MockCentralManager();
    mockStateManager = MockIBLEStateManagerFacade();
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

  void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

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
