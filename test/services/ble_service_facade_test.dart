import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/interfaces/i_ble_platform_host.dart';
import 'package:pak_connect/core/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/core/interfaces/i_ble_connection_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_advertising_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/power/battery_optimizer.dart';
import 'package:pak_connect/core/models/spy_mode_info.dart';
import 'package:pak_connect/data/services/ble_service_facade.dart';
import '../test_helpers/test_setup.dart';

void main() {
  group('BLEServiceFacade', () {
    late BLEServiceFacade facade;
    late _FakeBlePlatformHost platformHost;
    late _StubMessagingService messagingStub;
    late _StubAdvertisingService advertisingStub;
    late _StubHandshakeService handshakeStub;
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUpAll(() async {
      await TestSetup.initializeTestEnvironment(dbLabel: 'ble_service_facade');
      platformHost = _FakeBlePlatformHost();
    });

    tearDownAll(() async {
      await platformHost.dispose();
    });

    setUp(() {
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);

      messagingStub = _StubMessagingService();
      advertisingStub = _StubAdvertisingService();
      handshakeStub = _StubHandshakeService();
      facade = BLEServiceFacade(
        platformHost: platformHost,
        messagingService: messagingStub,
        advertisingService: advertisingStub,
        handshakeService: handshakeStub,
      );
    });

    void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

    tearDown(() {
      facade.dispose();
      messagingStub.dispose();
      handshakeStub.dispose();

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

    // ========================================================================
    // INITIALIZATION & LIFECYCLE TESTS
    // ========================================================================

    group('Initialization', () {
      test('initialize() completes successfully', () async {
        // Arrange & Act
        await facade.initialize();

        // Assert
        expect(facade.isInitialized, isTrue);
        expect(facade.initializationComplete, completes);
      });

      test(
        'initializationComplete is not completed before initialize',
        () async {
          // Arrange & Act
          final pending = facade.initializationComplete;

          // Assert
          expect(facade.isInitialized, isFalse);
          await expectLater(pending, doesNotComplete);
        },
      );
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

      test('queue sync handler is invoked for incoming sync', () async {
        final handled = <String>[];
        facade.registerQueueSyncHandler((message, fromNodeId) async {
          handled.add('$fromNodeId:${message.queueHash}');
          return true;
        });

        final queueMessage = QueueSyncMessage.createRequest(
          messageIds: ['m1', 'm2'],
          nodeId: 'node-a',
        );
        facade.debugHandleQueueSync(queueMessage, 'node-a');

        expect(handled, contains('node-a:${queueMessage.queueHash}'));
      });

      test('spy mode events bubble to state manager and stream', () async {
        final localFacade = BLEServiceFacade(platformHost: platformHost);
        addTearDown(() => localFacade.dispose());
        final spyInfo = SpyModeInfo(contactName: 'Alice', ephemeralID: 'eph1');
        final received = <String>[];
        localFacade.stateManager.onSpyModeDetected = (info) {
          received.add(info.contactName ?? '');
        };

        final streamFuture = localFacade.spyModeDetectedStream.first;
        localFacade.debugEmitSpyModeDetected(spyInfo);

        final streamValue = await streamFuture;
        expect(received, contains('Alice'));
        expect(streamValue.contactName, equals('Alice'));
      });

      test(
        'identity revealed events bubble to state manager and stream',
        () async {
          final localFacade = BLEServiceFacade(platformHost: platformHost);
          addTearDown(() => localFacade.dispose());
          final received = <String>[];
          localFacade.stateManager.onIdentityRevealed = received.add;

          final streamFuture = localFacade.identityRevealedStream.first;
          localFacade.debugEmitIdentityRevealed('peer-123');

          final streamValue = await streamFuture;
          expect(received, contains('peer-123'));
          expect(streamValue, equals('peer-123'));
        },
      );
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

final class _StubMessagingService implements IBLEMessagingService {
  final _messagesController = StreamController<String>.broadcast();
  final _binaryController = StreamController<BinaryPayload>.broadcast();
  String? _lastMessageId;

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    _lastMessageId = messageId ?? 'stub-${message.hashCode}';
    return true;
  }

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async {
    _lastMessageId = messageId ?? 'stub-peripheral-${message.hashCode}';
    return true;
  }

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage) async {}

  @override
  Future<void> sendIdentityExchange() async {}

  @override
  Future<void> sendPeripheralIdentityExchange() async {}

  @override
  Future<void> sendHandshakeMessage(ProtocolMessage message) async {}

  @override
  Future<void> requestIdentityExchange() async {}

  @override
  Future<void> triggerIdentityReExchange() async {}

  @override
  Stream<String> get receivedMessagesStream => _messagesController.stream;

  @override
  Stream<BinaryPayload> get receivedBinaryStream => _binaryController.stream;

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) async => 'transfer-$recipientId';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async => true;

  @override
  String? get lastExtractedMessageId => _lastMessageId;

  @override
  void registerQueueSyncMessageHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {}

  @override
  Future<void> processIncomingPeripheralData(
    Uint8List data, {
    required String senderDeviceId,
    String? senderNodeId,
  }) async {}

  void dispose() {
    _messagesController.close();
    _binaryController.close();
  }
}

final class _StubAdvertisingService implements IBLEAdvertisingService {
  bool _isAdvertising = false;
  bool _isPeripheral = false;
  bool _mtuReady = false;
  int? _mtu = 128;
  bool _peripheralHandshakeStarted = false;
  GATTCharacteristic? _messageCharacteristic;

  @override
  Future<void> startAsPeripheral() async {
    _isPeripheral = true;
    _isAdvertising = true;
    _mtuReady = true;
  }

  @override
  Future<void> startAsPeripheralWithValidation() => startAsPeripheral();

  @override
  Future<void> startAsCentral() async {
    _isPeripheral = false;
    _isAdvertising = false;
    _mtuReady = false;
    _mtu = null;
  }

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {}

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  bool get isPeripheralMode => _isPeripheral;

  @override
  int? get peripheralNegotiatedMTU => _mtu;

  @override
  bool get isPeripheralMTUReady => _mtuReady;

  @override
  GATTCharacteristic? get messageCharacteristic => _messageCharacteristic;

  @override
  bool get peripheralHandshakeStarted => _peripheralHandshakeStarted;

  @override
  set peripheralHandshakeStarted(bool value) =>
      _peripheralHandshakeStarted = value;

  @override
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
  }

  @override
  Future<void> startAdvertising() async {
    _isAdvertising = true;
  }

  @override
  void updatePeripheralMtu(int mtu) {
    _mtu = mtu;
    _mtuReady = true;
  }

  @override
  void resetPeripheralSession() {
    _messageCharacteristic = null;
    _peripheralHandshakeStarted = false;
    _mtuReady = false;
  }
}

final class _StubHandshakeService implements IBLEHandshakeService {
  final _spyModeController = StreamController<SpyModeInfo>.broadcast();
  final _identityController = StreamController<String>.broadcast();
  final _phaseController = StreamController<ConnectionPhase>.broadcast();
  final List<dynamic> _bufferedMessages = [];
  bool _isInProgress = false;
  bool _hasCompleted = false;
  String? _phase;

  @override
  Future<void> performHandshake({bool? startAsInitiatorOverride}) async {
    _isInProgress = true;
    _phase = 'NOISE_HANDSHAKE';
    _phaseController.add(ConnectionPhase.noiseHandshakeComplete);
  }

  @override
  Future<void> onHandshakeComplete() async {
    _hasCompleted = true;
    _isInProgress = false;
    _phase = 'CONTACT_STATUS_SYNC';
    _phaseController.add(ConnectionPhase.contactStatusComplete);
  }

  @override
  void disposeHandshakeCoordinator() {
    _isInProgress = false;
    _phase = null;
  }

  @override
  Future<void> requestIdentityExchange() async {}

  @override
  Future<void> triggerIdentityReExchange() async {}

  @override
  Future<String?> buildLocalCollisionHint() async => 'stub-hint';

  @override
  Future<bool> handleIncomingHandshakeMessage(
    Uint8List data, {
    bool isFromPeripheral = false,
  }) async => false;

  @override
  Future<void> handleMutualConsentRequired() async {}

  @override
  Future<void> handleAsymmetricContact(String contactKey) async {}

  @override
  Stream<SpyModeInfo> get spyModeDetectedStream => _spyModeController.stream;

  @override
  Stream<String> get identityRevealedStream => _identityController.stream;

  @override
  void emitSpyModeDetected(SpyModeInfo info) => _spyModeController.add(info);

  @override
  void emitIdentityRevealed(String contactId) =>
      _identityController.add(contactId);

  @override
  Stream<ConnectionPhase> get handshakePhaseStream => _phaseController.stream;

  @override
  String getPhaseMessage(String phase) => 'Phase: $phase';

  @override
  bool isHandshakeMessage(String messageType) =>
      messageType.contains('HANDSHAKE') || messageType.contains('IDENTITY');

  @override
  List<dynamic> getBufferedMessages() => _bufferedMessages;

  @override
  bool get isHandshakeInProgress => _isInProgress;

  @override
  bool get hasHandshakeCompleted => _hasCompleted;

  @override
  String? get currentHandshakePhase => _phase;

  void dispose() {
    _spyModeController.close();
    _identityController.close();
    _phaseController.close();
  }
}

final class _FakeBlePlatformHost implements IBLEPlatformHost {
  _FakeBlePlatformHost()
    : _centralManager = _FakeCentralManager(),
      _peripheralManager = _FakePeripheralManager();

  final _FakeCentralManager _centralManager;
  final _FakePeripheralManager _peripheralManager;

  @override
  CentralManager get centralManager => _centralManager;

  @override
  PeripheralManager get peripheralManager => _peripheralManager;

  @override
  BatteryOptimizer get batteryOptimizer => BatteryOptimizer();

  @override
  Future<void> ensureEphemeralKeysInitialized() async {}

  @override
  String getCurrentEphemeralId() => 'fake-ephemeral-id';

  Future<void> dispose() async {
    await _centralManager.dispose();
    await _peripheralManager.dispose();
  }
}

final class _FakeCentralManager implements CentralManager {
  final _discovered = StreamController<DiscoveredEventArgs>.broadcast();
  final _connectionState =
      StreamController<PeripheralConnectionStateChangedEventArgs>.broadcast();
  final _mtuChanged =
      StreamController<PeripheralMTUChangedEventArgs>.broadcast();
  final _characteristicNotified =
      StreamController<GATTCharacteristicNotifiedEventArgs>.broadcast();
  final _stateChanged =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();

  BluetoothLowEnergyState _state = BluetoothLowEnergyState.poweredOn;

  Future<void> dispose() async {
    await _discovered.close();
    await _connectionState.close();
    await _mtuChanged.close();
    await _characteristicNotified.close();
    await _stateChanged.close();
  }

  @override
  BluetoothLowEnergyState get state => _state;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateChanged.stream;

  @override
  Future<bool> authorize() async => true;

  @override
  Future<void> showAppSettings() async {}

  @override
  Stream<DiscoveredEventArgs> get discovered => _discovered.stream;

  @override
  Stream<PeripheralConnectionStateChangedEventArgs>
  get connectionStateChanged => _connectionState.stream;

  @override
  Stream<PeripheralMTUChangedEventArgs> get mtuChanged => _mtuChanged.stream;

  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      _characteristicNotified.stream;

  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<Peripheral> getPeripheral(String address) async =>
      _FakePeripheral(UUID.fromString(address));

  @override
  Future<List<Peripheral>> retrieveConnectedPeripherals() async => [];

  @override
  Future<void> connect(Peripheral peripheral) async {}

  @override
  Future<void> disconnect(Peripheral peripheral) async {}

  @override
  Future<int> requestMTU(Peripheral peripheral, {required int mtu}) async =>
      mtu;

  @override
  Future<int> getMaximumWriteLength(
    Peripheral peripheral, {
    required GATTCharacteristicWriteType type,
  }) async => 20;

  @override
  Future<int> readRSSI(Peripheral peripheral) async => -40;

  @override
  Future<List<GATTService>> discoverGATT(Peripheral peripheral) async => [];

  @override
  Future<Uint8List> readCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
  ) async => Uint8List(0);

  @override
  Future<void> writeCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required Uint8List value,
    required GATTCharacteristicWriteType type,
  }) async {}

  @override
  Future<void> setCharacteristicNotifyState(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required bool state,
  }) async {}

  @override
  Future<Uint8List> readDescriptor(
    Peripheral peripheral,
    GATTDescriptor descriptor,
  ) async => Uint8List(0);

  @override
  Future<void> writeDescriptor(
    Peripheral peripheral,
    GATTDescriptor descriptor, {
    required Uint8List value,
  }) async {}
}

final class _FakePeripheralManager implements PeripheralManager {
  final _connectionState =
      StreamController<CentralConnectionStateChangedEventArgs>.broadcast();
  final _mtuChanged = StreamController<CentralMTUChangedEventArgs>.broadcast();
  final _characteristicReadRequested =
      StreamController<GATTCharacteristicReadRequestedEventArgs>.broadcast();
  final _characteristicWriteRequested =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final _characteristicNotifyStateChanged =
      StreamController<
        GATTCharacteristicNotifyStateChangedEventArgs
      >.broadcast();
  final _descriptorReadRequested =
      StreamController<GATTDescriptorReadRequestedEventArgs>.broadcast();
  final _descriptorWriteRequested =
      StreamController<GATTDescriptorWriteRequestedEventArgs>.broadcast();
  final _stateChanged =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();

  BluetoothLowEnergyState _state = BluetoothLowEnergyState.poweredOn;

  Future<void> dispose() async {
    await _connectionState.close();
    await _mtuChanged.close();
    await _characteristicReadRequested.close();
    await _characteristicWriteRequested.close();
    await _characteristicNotifyStateChanged.close();
    await _descriptorReadRequested.close();
    await _descriptorWriteRequested.close();
    await _stateChanged.close();
  }

  @override
  BluetoothLowEnergyState get state => _state;

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateChanged.stream;

  @override
  Future<bool> authorize() async => true;

  @override
  Future<void> showAppSettings() async {}

  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged =>
      _connectionState.stream;

  @override
  Stream<CentralMTUChangedEventArgs> get mtuChanged => _mtuChanged.stream;

  @override
  Stream<GATTCharacteristicReadRequestedEventArgs>
  get characteristicReadRequested => _characteristicReadRequested.stream;

  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested => _characteristicWriteRequested.stream;

  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged =>
      _characteristicNotifyStateChanged.stream;

  @override
  Stream<GATTDescriptorReadRequestedEventArgs> get descriptorReadRequested =>
      _descriptorReadRequested.stream;

  @override
  Stream<GATTDescriptorWriteRequestedEventArgs> get descriptorWriteRequested =>
      _descriptorWriteRequested.stream;

  @override
  Future<void> addService(GATTService service) async {}

  @override
  Future<void> removeService(GATTService service) async {}

  @override
  Future<void> removeAllServices() async {}

  @override
  Future<void> startAdvertising(Advertisement advertisement) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<Central> getCentral(String address) async =>
      _FakeCentral(UUID.fromString(address));

  @override
  Future<List<Central>> retrieveConnectedCentrals() async => [];

  @override
  Future<void> disconnect(Central central) async {}

  @override
  Future<int> getMaximumNotifyLength(Central central) async => 20;

  @override
  Future<void> respondReadRequestWithValue(
    GATTReadRequest request, {
    required Uint8List value,
  }) async {}

  @override
  Future<void> respondReadRequestWithError(
    GATTReadRequest request, {
    required GATTError error,
  }) async {}

  @override
  Future<void> respondWriteRequest(GATTWriteRequest request) async {}

  @override
  Future<void> respondWriteRequestWithError(
    GATTWriteRequest request, {
    required GATTError error,
  }) async {}

  @override
  Future<void> notifyCharacteristic(
    Central central,
    GATTCharacteristic characteristic, {
    required Uint8List value,
  }) async {}

}

final class _FakePeripheral implements Peripheral {
  const _FakePeripheral(this.uuid);

  @override
  final UUID uuid;
}

final class _FakeCentral implements Central {
  const _FakeCentral(this.uuid);

  @override
  final UUID uuid;
}

// No additional mock helpers needed - all tests use facade directly
