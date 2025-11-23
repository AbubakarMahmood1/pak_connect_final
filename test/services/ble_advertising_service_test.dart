import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/bluetooth/advertising_manager.dart';
import 'package:pak_connect/core/bluetooth/peripheral_initializer.dart';
import 'package:pak_connect/core/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/data/services/ble_advertising_service.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';

@GenerateNiceMocks([
  MockSpec<IBLEStateManagerFacade>(),
  MockSpec<BLEConnectionManager>(),
  MockSpec<AdvertisingManager>(),
  MockSpec<PeripheralInitializer>(),
  MockSpec<PeripheralManager>(),
])
import 'ble_advertising_service_test.mocks.dart';

void main() {
  late MockIBLEStateManagerFacade mockStateManager;
  late MockBLEConnectionManager mockConnectionManager;
  late MockAdvertisingManager mockAdvertisingManager;
  late MockPeripheralInitializer mockPeripheralInitializer;
  late MockPeripheralManager mockPeripheralManager;
  late BLEAdvertisingService service;
  Map<String, dynamic>? lastConnectionUpdate;

  setUp(() {
    mockStateManager = MockIBLEStateManagerFacade();
    mockConnectionManager = MockBLEConnectionManager();
    mockAdvertisingManager = MockAdvertisingManager();
    mockPeripheralInitializer = MockPeripheralInitializer();
    mockPeripheralManager = MockPeripheralManager();

    when(mockAdvertisingManager.isAdvertising).thenReturn(false);
    when(
      mockPeripheralInitializer.safelyAddService(
        any,
        timeout: anyNamed('timeout'),
      ),
    ).thenAnswer((_) async => true);
    when(
      mockAdvertisingManager.startAdvertising(
        myPublicKey: anyNamed('myPublicKey'),
        timeout: anyNamed('timeout'),
        skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
      ),
    ).thenAnswer((_) async => true);
    when(
      mockStateManager.getMyPersistentId(),
    ).thenAnswer((_) async => 'node-123');
    when(mockConnectionManager.stopMeshNetworking()).thenAnswer((_) async {});
    when(mockPeripheralManager.removeAllServices()).thenAnswer((_) async {});
    when(mockStateManager.theyHaveUsAsContact).thenReturn(true);
    when(mockStateManager.weHaveThemAsContact).thenAnswer((_) async => false);
    when(mockStateManager.currentSessionId).thenReturn('session-1');
    when(mockStateManager.otherUserName).thenReturn('Peer');

    lastConnectionUpdate = null;

    service = BLEAdvertisingService(
      stateManager: mockStateManager,
      connectionManager: mockConnectionManager,
      advertisingManager: mockAdvertisingManager,
      peripheralInitializer: mockPeripheralInitializer,
      peripheralManager: mockPeripheralManager,
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
            lastConnectionUpdate = {
              'isConnected': isConnected,
              'isReady': isReady,
              'otherUserName': otherUserName,
              'statusMessage': statusMessage,
              'isScanning': isScanning,
              'isAdvertising': isAdvertising,
              'isReconnecting': isReconnecting,
            };
          },
    );
  });

  group('startAsPeripheral', () {
    test('returns early when already advertising', () async {
      when(mockAdvertisingManager.isAdvertising).thenReturn(true);

      await service.startAsPeripheral();

      verifyNever(
        mockPeripheralInitializer.safelyAddService(
          any,
          timeout: anyNamed('timeout'),
        ),
      );
      verifyNever(
        mockAdvertisingManager.startAdvertising(
          myPublicKey: anyNamed('myPublicKey'),
          timeout: anyNamed('timeout'),
          skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
        ),
      );
    });

    test('initializes service and starts advertising when idle', () async {
      await service.startAsPeripheral();

      verify(mockStateManager.setPeripheralMode(true)).called(1);
      verify(
        mockPeripheralInitializer.safelyAddService(
          any,
          timeout: anyNamed('timeout'),
        ),
      ).called(1);
      verify(
        mockAdvertisingManager.startAdvertising(
          myPublicKey: captureAnyNamed('myPublicKey'),
          timeout: anyNamed('timeout'),
          skipIfAlreadyAdvertising: true,
        ),
      ).called(1);
      expect(lastConnectionUpdate?['isAdvertising'], true);
    });

    test('marks peripheral mode before configuring services', () async {
      await service.startAsPeripheral();

      verify(mockStateManager.setPeripheralMode(true)).called(1);
    });

    test('throws when GATT service addition fails', () async {
      when(
        mockPeripheralInitializer.safelyAddService(
          any,
          timeout: anyNamed('timeout'),
        ),
      ).thenAnswer((_) async => false);

      await expectLater(service.startAsPeripheral(), throwsA(isA<Exception>()));
      expect(lastConnectionUpdate?['isAdvertising'], false);
    });

    test('throws when advertising manager fails to start', () async {
      when(
        mockAdvertisingManager.startAdvertising(
          myPublicKey: anyNamed('myPublicKey'),
          timeout: anyNamed('timeout'),
          skipIfAlreadyAdvertising: anyNamed('skipIfAlreadyAdvertising'),
        ),
      ).thenAnswer((_) async => false);

      await expectLater(service.startAsPeripheral(), throwsA(isA<Exception>()));
      expect(lastConnectionUpdate?['statusMessage'], 'Peripheral mode failed');
    });
  });

  test(
    'startAsPeripheralWithValidation delegates to startAsPeripheral',
    () async {
      await service.startAsPeripheralWithValidation();

      verify(mockStateManager.setPeripheralMode(true)).called(1);
    },
  );

  group('startAsCentral', () {
    test('resets state and stops mesh networking', () async {
      await service.startAsCentral();

      verify(mockStateManager.setPeripheralMode(false)).called(1);
      verify(mockConnectionManager.stopMeshNetworking()).called(1);
      verify(mockPeripheralManager.removeAllServices()).called(1);
      verify(
        mockStateManager.preserveContactRelationship(
          otherPublicKey: anyNamed('otherPublicKey'),
          otherName: anyNamed('otherName'),
          theyHaveUs: anyNamed('theyHaveUs'),
          weHaveThem: anyNamed('weHaveThem'),
        ),
      ).called(1);
      expect(lastConnectionUpdate?['isAdvertising'], false);
      expect(lastConnectionUpdate?['statusMessage'], 'Ready to scan');
    });

    test('continues when stopping mesh networking throws', () async {
      when(
        mockConnectionManager.stopMeshNetworking(),
      ).thenThrow(Exception('stop failure'));

      await service.startAsCentral();

      verify(mockPeripheralManager.removeAllServices()).called(1);
      expect(lastConnectionUpdate?['isConnected'], false);
    });

    test('preserves last contact relationship snapshot', () async {
      when(mockStateManager.currentSessionId).thenReturn('session-id');
      when(mockStateManager.otherUserName).thenReturn('Peer');
      when(mockStateManager.theyHaveUsAsContact).thenReturn(true);
      when(mockStateManager.weHaveThemAsContact).thenAnswer((_) async => false);

      await service.startAsCentral();

      final captured = verify(
        mockStateManager.preserveContactRelationship(
          otherPublicKey: captureAnyNamed('otherPublicKey'),
          otherName: captureAnyNamed('otherName'),
          theyHaveUs: captureAnyNamed('theyHaveUs'),
          weHaveThem: captureAnyNamed('weHaveThem'),
        ),
      ).captured;

      expect(captured[0], 'session-id');
      expect(captured[1], 'Peer');
      expect(captured[2], true);
      expect(captured[3], false);
    });
  });

  group('refreshAdvertising', () {
    test('skips when not in peripheral mode', () async {
      when(mockStateManager.isPeripheralMode).thenReturn(false);

      await service.refreshAdvertising();
    });

    test('refreshes advertising data when peripheral mode active', () async {
      when(mockStateManager.isPeripheralMode).thenReturn(true);

      await service.refreshAdvertising(showOnlineStatus: true);

      verify(
        mockAdvertisingManager.refreshAdvertising(
          myPublicKey: 'node-123',
          showOnlineStatus: true,
        ),
      ).called(1);
      expect(
        lastConnectionUpdate?['statusMessage'],
        'Advertising - discoverable',
      );
    });
  });

  group('state getters', () {
    test('isAdvertising proxies manager state', () {
      when(mockAdvertisingManager.isAdvertising).thenReturn(true);
      expect(service.isAdvertising, true);
    });

    test('isPeripheralMode proxies state manager', () {
      when(mockStateManager.isPeripheralMode).thenReturn(false);
      expect(service.isPeripheralMode, false);
    });

    test('peripheralNegotiatedMTU exposes cached value', () {
      expect(service.peripheralNegotiatedMTU, isNull);
    });

    test('isPeripheralMTUReady exposes negotiation flag', () {
      expect(service.isPeripheralMTUReady, isFalse);
    });
  });
}
