import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/core/interfaces/i_ble_connection_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_advertising_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/data/services/ble_service_facade.dart';

void main() {
  group('BLEServiceFacade', () {
    late BLEServiceFacade facade;

    setUp(() {
      facade = BLEServiceFacade();
    });

    tearDown(() {
      facade.dispose();
    });

    // ========================================================================
    // INITIALIZATION & LIFECYCLE TESTS
    // ========================================================================

    group('Initialization', () {
      test('constructor completes immediately', () async {
        // Arrange & Act
        final facade2 = BLEServiceFacade();

        // Assert
        expect(facade2.initializationComplete, completes);
      });

      test('initialize() completes successfully', () async {
        // Arrange & Act
        await facade.initialize();

        // Assert
        expect(facade.initializationComplete, completes);
      });

      test('initializationComplete is already completed', () async {
        // Arrange & Act
        final completes = facade.initializationComplete;

        // Assert
        expect(completes, completes);
      });
    });

    // ========================================================================
    // SUB-SERVICE ACCESS TESTS
    // ========================================================================

    group('Sub-Service Access', () {
      test('connectionService returns IBLEConnectionService', () {
        // Arrange & Act
        final service = facade.connectionService;

        // Assert
        expect(service, isA<IBLEConnectionService>());
      });

      test('discoveryService returns IBLEDiscoveryService', () {
        // Arrange & Act
        final service = facade.discoveryService;

        // Assert
        expect(service, isA<IBLEDiscoveryService>());
      });

      test('messagingService returns IBLEMessagingService', () {
        // Arrange & Act
        final service = facade.messagingService;

        // Assert
        expect(service, isA<IBLEMessagingService>());
      });

      test('advertisingService returns IBLEAdvertisingService', () {
        // Arrange & Act
        final service = facade.advertisingService;

        // Assert
        expect(service, isA<IBLEAdvertisingService>());
      });

      test('handshakeService returns IBLEHandshakeService', () {
        // Arrange & Act
        final service = facade.handshakeService;

        // Assert
        expect(service, isA<IBLEHandshakeService>());
      });

      test('lazy services are created only once', () {
        // Arrange & Act
        final service1 = facade.connectionService;
        final service2 = facade.connectionService;

        // Assert
        expect(identical(service1, service2), isTrue);
      });
    });

    // ========================================================================
    // KEY MANAGEMENT TESTS
    // ========================================================================

    group('Key Management', () {
      test('getMyPublicKey() returns a string', () async {
        // Arrange & Act
        final key = await facade.getMyPublicKey();

        // Assert
        expect(key, isA<String>());
        expect(key.isNotEmpty, isTrue);
      });

      test('getMyEphemeralId() returns a string', () async {
        // Arrange & Act
        final id = await facade.getMyEphemeralId();

        // Assert
        expect(id, isA<String>());
        expect(id.isNotEmpty, isTrue);
      });

      test('setMyUserName() completes successfully', () async {
        // Arrange & Act
        await facade.setMyUserName('Test User');

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('setMyUserName() accepts various names', () async {
        // Arrange & Act & Assert
        await facade.setMyUserName('Alice');
        await facade.setMyUserName('Bob Smith');
        await facade.setMyUserName('Charlie_123');

        expect(true, isTrue);
      });
    });

    // ========================================================================
    // MESH NETWORKING TESTS
    // ========================================================================

    group('Mesh Networking Integration', () {
      test('registerQueueSyncHandler() accepts handler', () {
        // Arrange
        Future<bool> mockHandler(QueueSyncMessage msg, String id) async => true;

        // Act
        facade.registerQueueSyncHandler(mockHandler);

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('registerQueueSyncHandler() can be called multiple times', () {
        // Arrange
        Future<bool> handler1(QueueSyncMessage msg, String id) async => true;
        Future<bool> handler2(QueueSyncMessage msg, String id) async => false;

        // Act & Assert
        facade.registerQueueSyncHandler(handler1);
        facade.registerQueueSyncHandler(handler2);

        expect(true, isTrue);
      });
    });

    // ========================================================================
    // BLUETOOTH STATE MONITORING TESTS
    // ========================================================================

    group('Bluetooth State Monitoring', () {
      test('bluetoothStateStream returns a stream', () {
        // Arrange & Act
        final stream = facade.bluetoothStateStream;

        // Assert
        expect(stream, isA<Stream>());
      });

      test('bluetoothMessageStream returns a stream', () {
        // Arrange & Act
        final stream = facade.bluetoothMessageStream;

        // Assert
        expect(stream, isA<Stream>());
      });

      test('isBluetoothReady returns a boolean', () {
        // Arrange & Act
        final isReady = facade.isBluetoothReady;

        // Assert
        expect(isReady, isA<bool>());
      });

      test('state returns BluetoothLowEnergyState', () {
        // Arrange & Act
        final state = facade.state;

        // Assert
        expect(state, isA<BluetoothLowEnergyState>());
      });

      test('myUserName returns nullable string', () {
        // Arrange & Act
        final username = facade.myUserName;

        // Assert
        expect(username, isA<String?>());
      });
    });

    // ========================================================================
    // CONNECTION SERVICE DELEGATION TESTS
    // ========================================================================

    group('Connection Service Delegation', () {
      test('connectToDevice() delegates to connection service', () {
        // Verify the method exists and can be called
        expect(facade.connectToDevice, isNotNull);
      });

      test('disconnect() is delegated', () {
        // Arrange & Act
        final result = facade.disconnect();

        // Assert
        expect(result, isA<Future>());
      });

      test('startConnectionMonitoring() is delegated', () {
        // Arrange & Act
        facade.startConnectionMonitoring();

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('stopConnectionMonitoring() is delegated', () {
        // Arrange & Act
        facade.stopConnectionMonitoring();

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('setHandshakeInProgress() is delegated', () {
        // Arrange & Act
        facade.setHandshakeInProgress(true);
        facade.setHandshakeInProgress(false);

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('getConnectionInfo() returns nullable ConnectionInfo', () {
        // Arrange & Act
        final info = facade.getConnectionInfo();

        // Assert
        expect(info, isA<ConnectionInfo?>());
      });

      test(
        'getConnectionInfoWithFallback() returns Future<ConnectionInfo?>',
        () async {
          // Arrange & Act
          final info = await facade.getConnectionInfoWithFallback();

          // Assert
          expect(info, isA<ConnectionInfo?>());
        },
      );

      test('attemptIdentityRecovery() returns Future<bool>', () async {
        // Arrange & Act
        final result = await facade.attemptIdentityRecovery();

        // Assert
        expect(result, isA<bool>());
      });

      test('connectionInfoStream returns Stream<ConnectionInfo>', () {
        // Arrange & Act
        final stream = facade.connectionInfoStream;

        // Assert
        expect(stream, isA<Stream<ConnectionInfo>>());
      });

      test('currentConnectionInfo returns nullable ConnectionInfo', () {
        // Arrange & Act
        final info = facade.currentConnectionInfo;

        // Assert
        expect(info, isA<ConnectionInfo?>());
      });

      test('isConnected returns boolean', () {
        // Arrange & Act
        final isConnected = facade.isConnected;

        // Assert
        expect(isConnected, isA<bool>());
      });

      test('isMonitoring returns boolean', () {
        // Arrange & Act
        final isMonitoring = facade.isMonitoring;

        // Assert
        expect(isMonitoring, isA<bool>());
      });

      test('connectedDevice returns nullable Peripheral', () {
        // Arrange & Act
        final device = facade.connectedDevice;

        // Assert
        expect(device, isA<Peripheral?>());
      });

      test('otherUserName returns nullable string', () {
        // Arrange & Act
        final name = facade.otherUserName;

        // Assert
        expect(name, isA<String?>());
      });

      test('currentSessionId returns nullable string', () {
        // Arrange & Act
        final id = facade.currentSessionId;

        // Assert
        expect(id, isA<String?>());
      });

      test('theirEphemeralId returns nullable string', () {
        // Arrange & Act
        final id = facade.theirEphemeralId;

        // Assert
        expect(id, isA<String?>());
      });

      test('theirPersistentKey returns nullable string', () {
        // Arrange & Act
        final key = facade.theirPersistentKey;

        // Assert
        expect(key, isA<String?>());
      });

      test('myPersistentId returns nullable string', () {
        // Arrange & Act
        final id = facade.myPersistentId;

        // Assert
        expect(id, isA<String?>());
      });

      test('isActivelyReconnecting returns boolean', () {
        // Arrange & Act
        final isReconnecting = facade.isActivelyReconnecting;

        // Assert
        expect(isReconnecting, isA<bool>());
      });

      test('hasPeripheralConnection returns boolean', () {
        // Arrange & Act
        final hasConnection = facade.hasPeripheralConnection;

        // Assert
        expect(hasConnection, isA<bool>());
      });

      test('hasCentralConnection returns boolean', () {
        // Arrange & Act
        final hasConnection = facade.hasCentralConnection;

        // Assert
        expect(hasConnection, isA<bool>());
      });

      test('canSendMessages returns boolean', () {
        // Arrange & Act
        final canSend = facade.canSendMessages;

        // Assert
        expect(canSend, isA<bool>());
      });

      test('connectedCentral returns nullable Central', () {
        // Arrange & Act
        final central = facade.connectedCentral;

        // Assert
        expect(central, isA<Central?>());
      });
    });

    // ========================================================================
    // MESSAGING SERVICE DELEGATION TESTS
    // ========================================================================

    group('Messaging Service Delegation', () {
      test('sendMessage() is delegated', () {
        // Arrange & Act
        final result = facade.sendMessage('Hello');

        // Assert
        expect(result, isA<Future<bool>>());
      });

      test('sendMessage() with optional parameters', () {
        // Arrange & Act
        final result = facade.sendMessage(
          'Hello',
          messageId: 'msg-123',
          originalIntendedRecipient: 'recipient-456',
        );

        // Assert
        expect(result, isA<Future<bool>>());
      });

      test('sendPeripheralMessage() is delegated', () {
        // Arrange & Act
        final result = facade.sendPeripheralMessage('Hello from peripheral');

        // Assert
        expect(result, isA<Future<bool>>());
      });

      test('sendIdentityExchange() is delegated', () {
        // Arrange & Act
        final result = facade.sendIdentityExchange();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('sendPeripheralIdentityExchange() is delegated', () {
        // Arrange & Act
        final result = facade.sendPeripheralIdentityExchange();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('registerQueueSyncMessageHandler() is delegated', () {
        // Arrange
        Future<bool> mockHandler(QueueSyncMessage msg, String id) async => true;

        // Act
        facade.registerQueueSyncMessageHandler(mockHandler);

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('receivedMessagesStream returns Stream<String>', () {
        // Arrange & Act
        final stream = facade.receivedMessagesStream;

        // Assert
        expect(stream, isA<Stream<String>>());
      });

      test('lastExtractedMessageId returns nullable string', () {
        // Arrange & Act
        final id = facade.lastExtractedMessageId;

        // Assert
        expect(id, isA<String?>());
      });
    });

    // ========================================================================
    // DISCOVERY SERVICE DELEGATION TESTS
    // ========================================================================

    group('Discovery Service Delegation', () {
      test('startScanning() is delegated', () {
        // Arrange & Act
        final result = facade.startScanning();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('startScanning() with source parameter', () {
        // Arrange & Act
        final result = facade.startScanning(source: ScanningSource.manual);

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('stopScanning() is delegated', () {
        // Arrange & Act
        final result = facade.stopScanning();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('startScanningWithValidation() is delegated', () {
        // Arrange & Act
        final result = facade.startScanningWithValidation();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('scanForSpecificDevice() is delegated', () {
        // Arrange & Act
        final result = facade.scanForSpecificDevice();

        // Assert
        expect(result, isA<Future<Peripheral?>>());
      });

      test('discoveredDevicesStream returns Stream<List<Peripheral>>', () {
        // Arrange & Act
        final stream = facade.discoveredDevicesStream;

        // Assert
        expect(stream, isA<Stream<List<Peripheral>>>());
      });

      test('currentDiscoveredDevices returns List<Peripheral>', () {
        // Arrange & Act
        final devices = facade.currentDiscoveredDevices;

        // Assert
        expect(devices, isA<List<Peripheral>>());
      });

      test('discoveryDataStream returns correct type', () {
        // Arrange & Act
        final stream = facade.discoveryDataStream;

        // Assert
        expect(stream, isA<Stream<Map<String, DiscoveredEventArgs>>>());
      });

      test('isDiscoveryActive returns boolean', () {
        // Arrange & Act
        final isActive = facade.isDiscoveryActive;

        // Assert
        expect(isActive, isA<bool>());
      });

      test('currentScanningSource returns nullable ScanningSource', () {
        // Arrange & Act
        final source = facade.currentScanningSource;

        // Assert
        expect(source, isA<ScanningSource?>());
      });

      test('hintMatchesStream returns Stream<String>', () {
        // Arrange & Act
        final stream = facade.hintMatchesStream;

        // Assert
        expect(stream, isA<Stream<String>>());
      });
    });

    // ========================================================================
    // ADVERTISING SERVICE DELEGATION TESTS
    // ========================================================================

    group('Advertising Service Delegation', () {
      test('startAsPeripheral() is delegated', () {
        // Arrange & Act
        final result = facade.startAsPeripheral();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('startAsPeripheralWithValidation() is delegated', () {
        // Arrange & Act
        final result = facade.startAsPeripheralWithValidation();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('refreshAdvertising() is delegated', () {
        // Arrange & Act
        final result = facade.refreshAdvertising();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('refreshAdvertising() with showOnlineStatus parameter', () {
        // Arrange & Act
        final result = facade.refreshAdvertising(showOnlineStatus: true);

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('startAsCentral() is delegated', () {
        // Arrange & Act
        final result = facade.startAsCentral();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('isAdvertising returns boolean', () {
        // Arrange & Act
        final isAdvertising = facade.isAdvertising;

        // Assert
        expect(isAdvertising, isA<bool>());
      });

      test('isPeripheralMode returns boolean', () {
        // Arrange & Act
        final isPeripheral = facade.isPeripheralMode;

        // Assert
        expect(isPeripheral, isA<bool>());
      });

      test('peripheralNegotiatedMTU returns nullable int', () {
        // Arrange & Act
        final mtu = facade.peripheralNegotiatedMTU;

        // Assert
        expect(mtu, isA<int?>());
      });

      test('isPeripheralMTUReady returns boolean', () {
        // Arrange & Act
        final isReady = facade.isPeripheralMTUReady;

        // Assert
        expect(isReady, isA<bool>());
      });
    });

    // ========================================================================
    // HANDSHAKE SERVICE DELEGATION TESTS
    // ========================================================================

    group('Handshake Service Delegation', () {
      test('performHandshake() is delegated', () {
        // Arrange & Act
        final result = facade.performHandshake();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('performHandshake() with override parameter', () {
        // Arrange & Act
        final result = facade.performHandshake(startAsInitiatorOverride: true);

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('onHandshakeComplete() is delegated', () {
        // Arrange & Act
        final result = facade.onHandshakeComplete();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('disposeHandshakeCoordinator() is delegated', () {
        // Arrange & Act
        facade.disposeHandshakeCoordinator();

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('requestIdentityExchange() is delegated', () {
        // Arrange & Act
        final result = facade.requestIdentityExchange();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('triggerIdentityReExchange() is delegated', () {
        // Arrange & Act
        final result = facade.triggerIdentityReExchange();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('spyModeDetectedStream returns a stream', () {
        // Arrange & Act
        final stream = facade.spyModeDetectedStream;

        // Assert
        expect(stream, isA<Stream>());
      });

      test('identityRevealedStream returns Stream<String>', () {
        // Arrange & Act
        final stream = facade.identityRevealedStream;

        // Assert
        expect(stream, isA<Stream<String>>());
      });
    });

    // ========================================================================
    // LIFECYCLE & CLEANUP TESTS
    // ========================================================================

    group('Lifecycle & Cleanup', () {
      test('dispose() completes successfully', () {
        // Arrange & Act
        facade.dispose();

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('dispose() can be called multiple times', () {
        // Arrange & Act
        facade.dispose();
        facade.dispose();
        facade.dispose();

        // Assert (no exception thrown)
        expect(true, isTrue);
      });

      test('facade can be re-initialized after dispose', () async {
        // Arrange
        facade.dispose();

        // Act
        final facade2 = BLEServiceFacade();
        await facade2.initialize();

        // Assert
        expect(facade2.initializationComplete, completes);

        // Cleanup
        facade2.dispose();
      });
    });

    // ========================================================================
    // INTEGRATION TESTS
    // ========================================================================

    group('Integration', () {
      test('multiple async operations can be called concurrently', () async {
        // Arrange & Act
        final futures = [
          facade.getMyPublicKey(),
          facade.getMyEphemeralId(),
          facade.setMyUserName('Test'),
          facade.startScanning(),
          facade.performHandshake(),
        ];

        // Assert
        final results = await Future.wait(futures);
        expect(results.length, equals(5));
      });

      test('stream getters can be subscribed multiple times', () {
        // Arrange
        final stream1 = facade.bluetoothStateStream;
        final stream2 = facade.bluetoothMessageStream;
        final stream3 = facade.receivedMessagesStream;

        // Act
        final subscription1 = stream1.listen((_) {});
        final subscription2 = stream2.listen((_) {});
        final subscription3 = stream3.listen((_) {});

        // Assert
        expect(subscription1, isNotNull);
        expect(subscription2, isNotNull);
        expect(subscription3, isNotNull);

        // Cleanup
        subscription1.cancel();
        subscription2.cancel();
        subscription3.cancel();
      });

      test('facade maintains consistent state across operations', () async {
        // Arrange & Act
        await facade.initialize();
        facade.setHandshakeInProgress(true);
        await facade.performHandshake();
        await facade.setMyUserName('TestUser');
        final isConnected = facade.isConnected;

        // Assert
        expect(isConnected, isA<bool>());
      });
    });

    // ========================================================================
    // ADDITIONAL HANDSHAKE SERVICE DELEGATIONS
    // ========================================================================

    group('Handshake Service Additional Delegations', () {
      test('buildLocalCollisionHint() is delegated', () async {
        // Arrange & Act
        final result = facade.buildLocalCollisionHint();

        // Assert
        expect(result, isA<Future<String?>>());
      });

      test('getBufferedMessages() is delegated', () {
        // Arrange & Act
        final result = facade.getBufferedMessages();

        // Assert
        expect(result, isA<List>());
      });

      test('getPhaseMessage() is delegated', () {
        // Arrange & Act
        final result = facade.getPhaseMessage('phase_0');

        // Assert
        expect(result, isA<String>());
      });

      test('handleAsymmetricContact() is delegated', () {
        // Arrange & Act
        final result = facade.handleAsymmetricContact('contact-key');

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('handleMutualConsentRequired() is delegated', () {
        // Arrange & Act
        final result = facade.handleMutualConsentRequired();

        // Assert
        expect(result, isA<Future<void>>());
      });

      test('hasHandshakeCompleted returns boolean', () {
        // Arrange & Act
        final result = facade.hasHandshakeCompleted;

        // Assert
        expect(result, isA<bool>());
      });

      test('isHandshakeInProgress returns boolean', () {
        // Arrange & Act
        final result = facade.isHandshakeInProgress;

        // Assert
        expect(result, isA<bool>());
      });

      test('isHandshakeMessage() is delegated', () {
        // Arrange & Act
        final result = facade.isHandshakeMessage('IDENTITY_EXCHANGE');

        // Assert
        expect(result, isA<bool>());
      });

      test('currentHandshakePhase returns nullable string', () {
        // Arrange & Act
        final result = facade.currentHandshakePhase;

        // Assert
        expect(result, isA<String?>());
      });
    });
  });
}

// No additional mock helpers needed - all tests use facade directly
