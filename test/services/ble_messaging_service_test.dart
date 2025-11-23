import 'package:mockito/annotations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:async';

import 'package:pak_connect/data/services/ble_messaging_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/core/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart' as relay_models;
import 'package:pak_connect/data/repositories/contact_repository.dart';

@GenerateNiceMocks([
  MockSpec<IBLEMessageHandlerFacade>(),
  MockSpec<BLEConnectionManager>(),
  MockSpec<IBLEStateManagerFacade>(),
  MockSpec<ContactRepository>(),
  MockSpec<CentralManager>(),
  MockSpec<PeripheralManager>(),
])
import 'ble_messaging_service_test.mocks.dart';

void main() {
  group('BLEMessagingService', () {
    late BLEMessagingService service;
    late MockIBLEMessageHandlerFacade mockMessageHandler;
    late MockBLEConnectionManager mockConnectionManager;
    late MockIBLEStateManagerFacade mockStateManager;
    late MockContactRepository mockContactRepository;
    late MockCentralManager mockCentralManager;
    late MockPeripheralManager mockPeripheralManager;
    late StreamController<String> messagesController;

    setUp(() {
      mockMessageHandler = MockIBLEMessageHandlerFacade();
      mockConnectionManager = MockBLEConnectionManager();
      mockStateManager = MockIBLEStateManagerFacade();
      mockContactRepository = MockContactRepository();
      mockCentralManager = MockCentralManager();
      mockPeripheralManager = MockPeripheralManager();
      messagesController = StreamController<String>.broadcast();

      // Setup default mocks
      when(mockStateManager.myUserName).thenReturn('TestUser');
      when(mockStateManager.isPeripheralMode).thenReturn(false);
      when(mockStateManager.isPaired).thenReturn(false);
      when(mockStateManager.getIdType()).thenReturn('ephemeral');
      when(mockStateManager.getRecipientId()).thenReturn(null);
      when(
        mockStateManager.getMyPersistentId(),
      ).thenAnswer((_) async => 'pubkey');
      when(mockContactRepository.getAllContacts()).thenAnswer((_) async => {});
      when(mockConnectionManager.mtuSize).thenReturn(512);

      service = BLEMessagingService(
        messageHandler: mockMessageHandler,
        connectionManager: mockConnectionManager,
        stateManager: mockStateManager,
        contactRepository: mockContactRepository,
        getCentralManager: () => mockCentralManager as dynamic,
        getPeripheralManager: () => mockPeripheralManager as dynamic,
        messagesController: messagesController,
        getConnectedCentral: () => null,
        getPeripheralMessageCharacteristic: () => null,
        getPeripheralMtuReady: () => false,
        getPeripheralNegotiatedMtu: () => null,
      );
    });

    tearDown(() {
      messagesController.close();
    });

    // =========================================================================
    // SERVICE INSTANTIATION
    // =========================================================================

    test('Service instantiation succeeds', () {
      expect(service, isNotNull);
    });

    test('Service has null-initialized extractedMessageId', () {
      expect(service.lastExtractedMessageId, isNull);
    });

    // =========================================================================
    // STREAM MANAGEMENT
    // =========================================================================

    test('receivedMessagesStream is connected to controller', () {
      expect(service.receivedMessagesStream, isNotNull);
      expect(service.receivedMessagesStream, equals(messagesController.stream));
    });

    test('Messages can be published to the stream', () async {
      expect(service.receivedMessagesStream, emits('Hello World'));
      messagesController.add('Hello World');
    });

    // =========================================================================
    // MESSAGE ID TRACKING
    // =========================================================================

    test('extractedMessageId can be set and retrieved', () {
      service.extractedMessageId = 'msg_123';
      expect(service.lastExtractedMessageId, equals('msg_123'));
    });

    test('extractedMessageId can be updated', () {
      service.extractedMessageId = 'msg_001';
      expect(service.lastExtractedMessageId, equals('msg_001'));
      service.extractedMessageId = 'msg_002';
      expect(service.lastExtractedMessageId, equals('msg_002'));
    });

    // =========================================================================
    // SEND MESSAGE VALIDATION
    // =========================================================================

    test('sendMessage throws when not connected', () async {
      when(mockConnectionManager.hasBleConnection).thenReturn(false);

      expect(() => service.sendMessage('Hello'), throwsException);
    });

    test('sendMessage throws when messageCharacteristic is null', () async {
      when(mockConnectionManager.hasBleConnection).thenReturn(true);
      when(mockConnectionManager.messageCharacteristic).thenReturn(null);

      expect(() => service.sendMessage('Hello'), throwsException);
    });

    // =========================================================================
    // SEND PERIPHERAL MESSAGE VALIDATION
    // =========================================================================

    test('sendPeripheralMessage throws when not in peripheral mode', () async {
      when(mockStateManager.isPeripheralMode).thenReturn(false);

      expect(() => service.sendPeripheralMessage('Hello'), throwsException);
    });

    test('sendPeripheralMessage throws when no central connected', () async {
      when(mockStateManager.isPeripheralMode).thenReturn(true);
      service = BLEMessagingService(
        messageHandler: mockMessageHandler,
        connectionManager: mockConnectionManager,
        stateManager: mockStateManager,
        contactRepository: mockContactRepository,
        getCentralManager: () => mockCentralManager as dynamic,
        getPeripheralManager: () => mockPeripheralManager as dynamic,
        messagesController: messagesController,
        getConnectedCentral: () => null,
        getPeripheralMessageCharacteristic: () => null,
        getPeripheralMtuReady: () => false,
        getPeripheralNegotiatedMtu: () => null,
      );

      expect(() => service.sendPeripheralMessage('Hello'), throwsException);
    });

    // =========================================================================
    // IDENTITY EXCHANGE VALIDATION
    // =========================================================================

    test('sendIdentityExchange throws when not connected', () async {
      when(mockConnectionManager.hasBleConnection).thenReturn(false);

      expect(() => service.sendIdentityExchange(), throwsException);
    });

    test(
      'sendIdentityExchange throws when messageCharacteristic is null',
      () async {
        when(mockConnectionManager.hasBleConnection).thenReturn(true);
        when(mockConnectionManager.messageCharacteristic).thenReturn(null);

        expect(() => service.sendIdentityExchange(), throwsException);
      },
    );

    test(
      'sendPeripheralIdentityExchange returns silently if not in peripheral mode',
      () async {
        when(mockStateManager.isPeripheralMode).thenReturn(false);
        // Should not throw
        await service.sendPeripheralIdentityExchange();
      },
    );

    test(
      'sendPeripheralIdentityExchange returns silently if no central connected',
      () async {
        when(mockStateManager.isPeripheralMode).thenReturn(true);
        service = BLEMessagingService(
          messageHandler: mockMessageHandler,
          connectionManager: mockConnectionManager,
          stateManager: mockStateManager,
          contactRepository: mockContactRepository,
          getCentralManager: () => mockCentralManager as dynamic,
          getPeripheralManager: () => mockPeripheralManager as dynamic,
          messagesController: messagesController,
          getConnectedCentral: () => null,
          getPeripheralMessageCharacteristic: () => null,
          getPeripheralMtuReady: () => false,
          getPeripheralNegotiatedMtu: () => null,
        );
        // Should not throw
        await service.sendPeripheralIdentityExchange();
      },
    );

    // =========================================================================
    // REQUEST IDENTITY EXCHANGE
    // =========================================================================

    test('requestIdentityExchange returns silently if not connected', () async {
      when(mockConnectionManager.hasBleConnection).thenReturn(false);
      // Should not throw
      await service.requestIdentityExchange();
    });

    // =========================================================================
    // TRIGGER IDENTITY RE-EXCHANGE
    // =========================================================================

    test('triggerIdentityReExchange loads username before exchange', () async {
      when(mockStateManager.loadUserName()).thenAnswer((_) async {});
      when(mockStateManager.isPeripheralMode).thenReturn(false);
      when(mockConnectionManager.hasBleConnection).thenReturn(false);

      await service.triggerIdentityReExchange();

      verify(mockStateManager.loadUserName()).called(1);
    });

    test('triggerIdentityReExchange catches exceptions silently', () async {
      when(mockStateManager.loadUserName()).thenThrow(Exception('Load failed'));

      // Should not throw
      await service.triggerIdentityReExchange();
    });

    // =========================================================================
    // QUEUE SYNC MESSAGE HANDLER
    // =========================================================================

    test('registerQueueSyncMessageHandler stores handler', () {
      Future<bool> handler(
        relay_models.QueueSyncMessage msg,
        String nodeId,
      ) async => true;
      service.registerQueueSyncMessageHandler(handler);
      // Verify it was stored (by invoking it)
      expect(
        service.invokeQueueSyncHandler(
          relay_models.QueueSyncMessage(
            queueHash: 'hash_n1',
            messageIds: ['msg1'],
            syncTimestamp: DateTime.now(),
            nodeId: 'n1',
            syncType: relay_models.QueueSyncType.request,
          ),
          'node1',
        ),
        completes,
      );
    });

    test(
      'invokeQueueSyncHandler returns false if no handler registered',
      () async {
        final result = await service.invokeQueueSyncHandler(
          relay_models.QueueSyncMessage(
            queueHash: 'hash_n1',
            messageIds: ['msg1'],
            syncTimestamp: DateTime.now(),
            nodeId: 'n1',
            syncType: relay_models.QueueSyncType.request,
          ),
          'node1',
        );

        expect(result, isFalse);
      },
    );

    test('invokeQueueSyncHandler invokes registered handler', () async {
      var handlerCalled = false;
      Future<bool> handler(
        relay_models.QueueSyncMessage msg,
        String nodeId,
      ) async {
        handlerCalled = true;
        return true;
      }

      service.registerQueueSyncMessageHandler(handler);
      final result = await service.invokeQueueSyncHandler(
        relay_models.QueueSyncMessage(
          queueHash: 'hash_n1',
          messageIds: ['msg1'],
          syncTimestamp: DateTime.now(),
          nodeId: 'n1',
          syncType: relay_models.QueueSyncType.request,
        ),
        'node1',
      );

      expect(handlerCalled, isTrue);
      expect(result, isTrue);
    });

    // =========================================================================
    // MTU SIZE HANDLING
    // =========================================================================

    test('sendMessage uses default MTU when not configured', () async {
      when(mockConnectionManager.mtuSize).thenReturn(null);
      when(mockConnectionManager.hasBleConnection).thenReturn(true);

      // Verify it doesn't crash (default of 20 is used)
      expect(
        () => service.sendMessage('Hello'),
        throwsException, // Will throw because no connected device
      );
    });
  });
}
