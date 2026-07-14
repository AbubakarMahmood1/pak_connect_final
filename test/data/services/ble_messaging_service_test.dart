import 'dart:async';
import 'dart:typed_data';

import 'package:mockito/annotations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_messaging_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/domain/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart'
    as relay_models;
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/interfaces/i_message_fragmentation_handler.dart';
import 'package:pak_connect/data/services/message_fragmentation_handler.dart';
import 'package:pak_connect/domain/utils/binary_fragmenter.dart';
import 'package:pak_connect/data/models/ble_client_connection.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import '../../helpers/ble/ble_fakes.dart';

@GenerateNiceMocks([
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
    late _ForwardingHarnessHandler mockMessageHandler;
    late MockBLEConnectionManager mockConnectionManager;
    late MockIBLEStateManagerFacade mockStateManager;
    late MockContactRepository mockContactRepository;
    late MockCentralManager mockCentralManager;
    late MockPeripheralManager mockPeripheralManager;
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUp(() {
      resetMockitoState();
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      mockMessageHandler = _ForwardingHarnessHandler();
      mockConnectionManager = _MockBLEConnectionManagerWithHandshake();
      mockStateManager = MockIBLEStateManagerFacade();
      mockContactRepository = MockContactRepository();
      mockCentralManager = MockCentralManager();
      mockPeripheralManager = MockPeripheralManager();

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
        getConnectedCentral: () => null,
        getPeripheralMessageCharacteristic: () => null,
        getPeripheralMtuReady: () => false,
        getPeripheralNegotiatedMtu: () => null,
      );
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
      expect(service.receivedMessagesStream, isA<Stream<String>>());
    });

    test('Messages can be published to the stream', () async {
      expect(service.receivedMessagesStream, emits('Hello World'));
      service.debugEmitReceivedMessage('Hello World');
    });

    test('valid text equal to the retired failure sentinel is handled, not '
        'misclassified as a GATT failure', () async {
      mockMessageHandler.nextProcessResult = '__INBOUND_PROCESS_FAILED__';

      final status = await service.processIncomingPeripheralData(
        Uint8List.fromList([1, 2, 3]),
        senderDeviceId: 'device-b',
        senderNodeId: 'node-b',
      );

      expect(status, InboundProcessStatus.handled);
    });

    test(
      'typed inbound processing failure maps to failed GATT status',
      () async {
        mockMessageHandler.nextProcessError =
            const InboundMessageProcessingException('corrupt frame');

        final status = await service.processIncomingPeripheralData(
          Uint8List.fromList([9, 9, 9]),
          senderDeviceId: 'device-b',
          senderNodeId: 'node-b',
        );

        expect(status, InboundProcessStatus.failed);
      },
    );

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

    test('oversized protocol payload uses binary envelope', () async {
      final mockMessageHandler = _ForwardingHarnessHandler();
      final mockConnectionManager = _MockBLEConnectionManagerWithHandshake();
      final mockStateManager = MockIBLEStateManagerFacade();
      final mockContactRepository = MockContactRepository();
      final mockCentralManager = MockCentralManager();
      final mockPeripheralManager = MockPeripheralManager();

      when(mockStateManager.myUserName).thenReturn('TestUser');
      when(mockStateManager.isPeripheralMode).thenReturn(false);
      when(mockStateManager.isPaired).thenReturn(false);
      when(mockStateManager.getIdType()).thenReturn('ephemeral');
      when(mockStateManager.getRecipientId()).thenReturn(null);
      when(
        mockStateManager.getMyPersistentId(),
      ).thenAnswer((_) async => 'pubkey');
      when(mockContactRepository.getAllContacts()).thenAnswer((_) async => {});

      final characteristic = GATTCharacteristic.mutable(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000f1f1'),
        properties: [GATTCharacteristicProperty.write],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: const [],
      );
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000f2f2',
      );
      final address = peripheral.uuid.toString();
      final connection = BLEClientConnection(
        address: address,
        peripheral: peripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 60,
      );

      when(mockConnectionManager.hasBleConnection).thenReturn(true);
      when(
        mockConnectionManager.messageCharacteristic,
      ).thenReturn(characteristic);
      when(mockConnectionManager.connectedDevice).thenReturn(peripheral);
      when(mockConnectionManager.mtuSize).thenReturn(60);
      when(
        mockConnectionManager.clientConnectionForPeer(address),
      ).thenReturn(connection);

      final writes = <Uint8List>[];
      when(
        mockCentralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((invocation) async {
        writes.add(invocation.namedArguments[#value] as Uint8List);
      });

      final service = BLEMessagingService(
        messageHandler: mockMessageHandler,
        connectionManager: mockConnectionManager,
        stateManager: mockStateManager,
        contactRepository: mockContactRepository,
        getCentralManager: () => mockCentralManager as dynamic,
        getPeripheralManager: () => mockPeripheralManager as dynamic,
        getConnectedCentral: () => null,
        getPeripheralMessageCharacteristic: () => null,
        getPeripheralMtuReady: () => false,
        getPeripheralNegotiatedMtu: () => null,
      );

      final queueMessage = relay_models.QueueSyncMessage(
        queueHash: 'h',
        messageIds: List.generate(
          80,
          (i) => 'id-${List.filled(8, 'x').join()}-$i',
        ),
        syncTimestamp: DateTime.now(),
        nodeId: 'node-oversize',
        syncType: relay_models.QueueSyncType.request,
      );

      await service.sendQueueSyncMessage(queueMessage, peerId: address);

      expect(writes, isNotEmpty);
      expect(
        writes.every((value) => value.isNotEmpty && value.first == 0xF0),
        isTrue,
      );
    });

    test('re-fragments binary forward per hop and skips relayer echo', () async {
      final handler = _ForwardingHarnessHandler();
      final connectionManager = _MockBLEConnectionManagerWithHandshake();
      final stateManager = MockIBLEStateManagerFacade();
      final contactRepository = MockContactRepository();
      final centralManager = MockCentralManager();
      final peripheralManager = MockPeripheralManager();

      when(stateManager.isPeripheralMode).thenReturn(true);
      when(contactRepository.getAllContacts()).thenAnswer((_) async => {});

      final characteristic = GATTCharacteristic.mutable(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000f0f0'),
        properties: [GATTCharacteristicProperty.write],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: const [],
      );

      final relayPeripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000aaaa',
      );
      final nextHopPeripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000bbbb',
      );

      final relayConnection = BLEClientConnection(
        address: relayPeripheral.uuid.toString(),
        peripheral: relayPeripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 200,
      );
      final nextHopConnection = BLEClientConnection(
        address: nextHopPeripheral.uuid.toString(),
        peripheral: nextHopPeripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 64,
      );

      when(
        connectionManager.clientConnections,
      ).thenReturn([relayConnection, nextHopConnection]);

      final connectedCentral = fakeCentralFromString(
        '00000000-0000-0000-0000-00000000cccc',
      );
      final peripheralCharacteristic = GATTCharacteristic.mutable(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000d0d0'),
        properties: [GATTCharacteristicProperty.notify],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: const [],
      );

      final writes = <_WriteCall>[];
      when(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((invocation) async {
        writes.add(
          _WriteCall(
            target: _Target.central,
            deviceId: (invocation.positionalArguments[0] as Peripheral).uuid
                .toString(),
            value: invocation.namedArguments[#value] as Uint8List,
          ),
        );
      });

      when(
        peripheralManager.notifyCharacteristic(
          any,
          any,
          value: anyNamed('value'),
        ),
      ).thenAnswer((invocation) async {
        writes.add(
          _WriteCall(
            target: _Target.peripheral,
            deviceId: (invocation.positionalArguments[0] as Central).uuid
                .toString(),
            value: invocation.namedArguments[#value] as Uint8List,
          ),
        );
      });

      final service = BLEMessagingService(
        messageHandler: handler,
        connectionManager: connectionManager,
        stateManager: stateManager,
        contactRepository: contactRepository,
        getCentralManager: () => centralManager,
        getPeripheralManager: () => peripheralManager,
        getConnectedCentral: () => connectedCentral,
        getPeripheralMessageCharacteristic: () => peripheralCharacteristic,
        getPeripheralMtuReady: () => true,
        getPeripheralNegotiatedMtu: () => 120,
      );

      final payload = Uint8List.fromList(List.generate(140, (i) => i % 256));
      handler.forwardPayload = ForwardReassembledPayload(
        bytes: payload,
        originalType: BinaryPayloadType.media,
        recipient: 'node-c',
        ttl: 2,
      );
      final upstreamFragments = BinaryFragmenter.fragment(
        data: payload,
        mtu: 90,
        originalType: BinaryPayloadType.media,
        recipient: 'node-c',
        ttl: 2,
      );

      handler.forwardBinaryFragment?.call(
        upstreamFragments.first,
        'feedcafe',
        0,
        relayPeripheral.uuid.toString(),
        'node-upstream',
      );

      // Allow the write queue to flush both central and peripheral sends.
      await Future<void>.delayed(Duration(milliseconds: 150));

      final centralWrites = writes
          .where((w) => w.target == _Target.central)
          .toList();
      expect(centralWrites, isNotEmpty);
      expect(
        centralWrites.every(
          (w) => w.deviceId == nextHopConnection.peripheral.uuid.toString(),
        ),
        isTrue,
      );
      expect(
        centralWrites.any(
          (w) => w.deviceId == relayConnection.peripheral.uuid.toString(),
        ),
        isFalse,
      );

      const ttlOffset = 1 + 8 + 2 + 2; // magic + id + idx + total
      expect(
        centralWrites.every((w) => w.value.length <= nextHopConnection.mtu!),
        isTrue,
      );
      expect(centralWrites.first.value[ttlOffset], equals(1));

      final peripheralWrites = writes
          .where((w) => w.target == _Target.peripheral)
          .toList();
      expect(peripheralWrites, hasLength(1));
      expect(peripheralWrites.first.value.length <= 120, isTrue);
      expect(
        peripheralWrites.first.value[ttlOffset],
        equals(
          2,
        ), // Direct forwards preserve handler-adjusted TTL (no extra decrement)
      );

      // Keep analyzer happy about unused instance.
      expect(service, isA<BLEMessagingService>());
    });

    test(
      're-fragments to the smallest downstream MTU and avoids writing back to relayer',
      () async {
        final handler = _ForwardingHarnessHandler();
        final connectionManager = _MockBLEConnectionManagerWithHandshake();
        final stateManager = MockIBLEStateManagerFacade();
        final contactRepository = MockContactRepository();
        final centralManager = MockCentralManager();

        when(stateManager.isPeripheralMode).thenReturn(false);
        when(contactRepository.getAllContacts()).thenAnswer((_) async => {});

        final characteristic = GATTCharacteristic.mutable(
          uuid: UUID.fromString('00000000-0000-0000-0000-00000000f0f1'),
          properties: [GATTCharacteristicProperty.write],
          permissions: [GATTCharacteristicPermission.write],
          descriptors: const [],
        );

        final relayer = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000aaaa',
        );
        final nextHop = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000bbbb',
        );

        final relayerConn = BLEClientConnection(
          address: relayer.uuid.toString(),
          peripheral: relayer,
          connectedAt: DateTime.now(),
          messageCharacteristic: characteristic,
          mtu: 200,
        );
        final constrainedConn = BLEClientConnection(
          address: nextHop.uuid.toString(),
          peripheral: nextHop,
          connectedAt: DateTime.now(),
          messageCharacteristic: characteristic,
          mtu: 60,
        );

        when(
          connectionManager.clientConnections,
        ).thenReturn([relayerConn, constrainedConn]);

        final writes = <_WriteCall>[];
        when(
          centralManager.writeCharacteristic(
            any,
            any,
            value: anyNamed('value'),
            type: anyNamed('type'),
          ),
        ).thenAnswer((invocation) async {
          writes.add(
            _WriteCall(
              target: _Target.central,
              deviceId: (invocation.positionalArguments[0] as Peripheral).uuid
                  .toString(),
              value: invocation.namedArguments[#value] as Uint8List,
            ),
          );
        });

        final service = BLEMessagingService(
          messageHandler: handler,
          connectionManager: connectionManager,
          stateManager: stateManager,
          contactRepository: contactRepository,
          getCentralManager: () => centralManager,
          getPeripheralManager: () => MockPeripheralManager(),
          getConnectedCentral: () => null,
          getPeripheralMessageCharacteristic: () => null,
          getPeripheralMtuReady: () => false,
          getPeripheralNegotiatedMtu: () => null,
        );

        final payload = Uint8List.fromList(List.generate(160, (i) => i % 256));
        handler.forwardPayload = ForwardReassembledPayload(
          bytes: payload,
          originalType: BinaryPayloadType.media,
          recipient: 'node-z',
          ttl: 3,
        );
        final upstreamFragments = BinaryFragmenter.fragment(
          data: payload,
          mtu: 100,
          originalType: BinaryPayloadType.media,
          recipient: 'node-z',
          ttl: 3,
        );

        handler.forwardBinaryFragment?.call(
          upstreamFragments.first,
          'deadbeef',
          0,
          relayer.uuid.toString(),
          'node-upstream',
        );

        await Future<void>.delayed(Duration(milliseconds: 120));

        // Only forward to the constrained next hop (not back to the relayer).
        expect(
          writes.every(
            (w) => w.deviceId == constrainedConn.peripheral.uuid.toString(),
          ),
          isTrue,
        );
        expect(
          writes.every((w) => w.value.length <= constrainedConn.mtu!),
          isTrue,
        );

        const ttlOffset = 1 + 8 + 2 + 2;
        expect(
          writes.every((w) => w.value[ttlOffset] == 2),
          isTrue, // TTL decremented from 3 -> 2 on forward.
        );

        // Keep analyzer happy about unused instance.
        expect(service, isA<BLEMessagingService>());
      },
    );
  });

  group('BLEMessagingService peer-targeted queue sync', () {
    late _ForwardingHarnessHandler handler;
    late _MockBLEConnectionManagerWithHandshake connectionManager;
    late MockIBLEStateManagerFacade stateManager;
    late MockContactRepository contactRepository;
    late MockCentralManager centralManager;
    late MockPeripheralManager peripheralManager;
    late List<_WriteCall> writes;

    BLEMessagingService buildService({
      Object? Function()? getConnectedCentral,
      Object? Function()? getPeripheralMessageCharacteristic,
    }) {
      return BLEMessagingService(
        messageHandler: handler,
        connectionManager: connectionManager,
        stateManager: stateManager,
        contactRepository: contactRepository,
        getCentralManager: () => centralManager,
        getPeripheralManager: () => peripheralManager,
        getConnectedCentral: getConnectedCentral ?? () => null,
        getPeripheralMessageCharacteristic:
            getPeripheralMessageCharacteristic ?? () => null,
        getPeripheralMtuReady: () => false,
        getPeripheralNegotiatedMtu: () => null,
      );
    }

    relay_models.QueueSyncMessage buildSyncMessage({int messageCount = 1}) =>
        relay_models.QueueSyncMessage(
          queueHash: 'hash',
          messageIds: List<String>.generate(
            messageCount,
            (index) => 'message-id-${index.toString().padLeft(4, '0')}',
          ),
          syncTimestamp: DateTime.now(),
          nodeId: 'node-self',
          syncType: relay_models.QueueSyncType.request,
        );

    setUp(() {
      resetMockitoState();
      handler = _ForwardingHarnessHandler();
      connectionManager = _MockBLEConnectionManagerWithHandshake();
      stateManager = MockIBLEStateManagerFacade();
      contactRepository = MockContactRepository();
      centralManager = MockCentralManager();
      peripheralManager = MockPeripheralManager();
      writes = [];

      when(stateManager.isPeripheralMode).thenReturn(false);
      when(stateManager.getRecipientId()).thenReturn(null);
      when(stateManager.currentSessionId).thenReturn(null);
      when(stateManager.theirEphemeralId).thenReturn(null);
      when(stateManager.theirPersistentKey).thenReturn(null);
      when(contactRepository.getAllContacts()).thenAnswer((_) async => {});
      when(connectionManager.mtuSize).thenReturn(512);
      when(connectionManager.clientConnectionCount).thenReturn(0);
      when(connectionManager.serverConnectionCount).thenReturn(0);
      when(connectionManager.hasBleConnection).thenReturn(false);
      when(connectionManager.messageCharacteristic).thenReturn(null);
      when(connectionManager.connectedDevice).thenReturn(null);
      when(connectionManager.clientConnectionForPeer(any)).thenReturn(null);
      when(connectionManager.serverConnectionForPeer(any)).thenReturn(null);
      when(connectionManager.serverConnections).thenReturn(const []);

      when(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenAnswer((invocation) async {
        writes.add(
          _WriteCall(
            target: _Target.central,
            deviceId: (invocation.positionalArguments[0] as Peripheral).uuid
                .toString(),
            value: invocation.namedArguments[#value] as Uint8List,
          ),
        );
      });
      when(
        peripheralManager.notifyCharacteristic(
          any,
          any,
          value: anyNamed('value'),
        ),
      ).thenAnswer((invocation) async {
        writes.add(
          _WriteCall(
            target: _Target.peripheral,
            deviceId: (invocation.positionalArguments[0] as Central).uuid
                .toString(),
            value: invocation.namedArguments[#value] as Uint8List,
          ),
        );
      });
    });

    GATTCharacteristic writableCharacteristic(String uuid) =>
        GATTCharacteristic.mutable(
          uuid: UUID.fromString(uuid),
          properties: [GATTCharacteristicProperty.write],
          permissions: [GATTCharacteristicPermission.write],
          descriptors: const [],
        );

    test('direct payload admission carries the exact address and queued '
        'recipient without awaiting its outcome', () async {
      final outcome = Completer<bool>();
      handler.centralRouteOutcome = outcome.future;
      when(stateManager.getRecipientId()).thenReturn('unrelated-global-peer');
      final service = buildService();

      final attempt = service.trySendMessageOnRoute(
        'payload',
        transportAddress: 'device-a',
        messageId: 'message-a',
        intendedRecipient: 'queued-recipient',
      );

      expect(attempt, isNotNull);
      expect(handler.centralRouteAttempts, [
        (
          peerId: 'device-a',
          recipientKey: 'queued-recipient',
          messageId: 'message-a',
        ),
      ]);
      expect(outcome.isCompleted, isFalse);

      outcome.complete(true);
      expect(await attempt!, isTrue);
    });

    test(
      'direct payload admission falls through to an exact server route',
      () async {
        final outcome = Completer<bool>();
        handler.peripheralRouteOutcome = outcome.future;
        final service = buildService();

        final attempt = service.trySendMessageOnRoute(
          'payload',
          transportAddress: 'device-server',
          messageId: 'message-server',
          intendedRecipient: 'queued-recipient',
        );

        expect(attempt, isNotNull);
        expect(handler.centralRouteAttempts, isEmpty);
        expect(handler.peripheralRouteAttempts, [
          (
            peerId: 'device-server',
            senderKey: 'queued-recipient',
            messageId: 'message-server',
          ),
        ]);

        outcome.complete(false);
        expect(await attempt!, isFalse);
      },
    );

    test('direct payload without an exact handler route is not admitted', () {
      final service = buildService();

      final attempt = service.trySendMessageOnRoute(
        'payload',
        transportAddress: 'missing-device',
        messageId: 'missing-message',
        intendedRecipient: 'queued-recipient',
      );

      expect(attempt, isNull);
      expect(handler.centralRouteAttempts, isEmpty);
      expect(handler.peripheralRouteAttempts, isEmpty);
    });

    test(
      'route-bound direct writes share one serialized transport lane',
      () async {
        final writeGates = <String, Completer<void>>{
          for (var index = 0; index < 4; index++)
            'message-$index': Completer<void>(),
        };
        final outcomes = <String, Completer<bool>>{
          for (var index = 0; index < 4; index++)
            'message-$index': Completer<bool>(),
        };
        final started = <String>[];
        var active = 0;
        var maxActive = 0;
        handler.centralRouteTaskProvider = (messageId) =>
            (scheduleWrite) async {
              await scheduleWrite(() async {
                active++;
                if (active > maxActive) maxActive = active;
                started.add(messageId);
                try {
                  await writeGates[messageId]!.future;
                } finally {
                  active--;
                }
              });
              return outcomes[messageId]!.future;
            };
        final service = buildService();

        final attempts = <Future<bool>>[];
        for (var index = 0; index < 4; index++) {
          final attempt = service.trySendMessageOnRoute(
            'payload-$index',
            transportAddress: 'device-a',
            messageId: 'message-$index',
            intendedRecipient: 'queued-recipient',
          );
          expect(attempt, isNotNull);
          attempts.add(attempt!);
        }

        expect(handler.centralRouteAttempts, hasLength(4));
        await _waitUntil(() => started.length == 1);
        expect(started, <String>['message-0']);
        expect(maxActive, 1);

        for (var index = 0; index < 4; index++) {
          writeGates['message-$index']!.complete();
          if (index < 3) {
            await _waitUntil(() => started.length == index + 2);
            expect(maxActive, 1);
          }
        }

        await _waitUntil(() => active == 0);
        expect(
          outcomes.values.every((outcome) => !outcome.isCompleted),
          isTrue,
          reason: 'the physical-write lane must advance before remote ACKs',
        );
        for (final outcome in outcomes.values) {
          outcome.complete(true);
        }
        expect(await Future.wait(attempts), everyElement(isTrue));
        expect(started, outcomes.keys.toList());
        expect(maxActive, 1);
      },
    );

    test(
      'a failed serialized route write does not strand later work',
      () async {
        final started = <String>[];
        handler.centralRouteTaskProvider = (messageId) =>
            (scheduleWrite) async {
              try {
                await scheduleWrite(() async {
                  started.add(messageId);
                  if (messageId == 'message-fails') {
                    throw StateError('injected physical write failure');
                  }
                });
                return true;
              } catch (_) {
                return false;
              }
            };
        final service = buildService();

        final failed = service.trySendMessageOnRoute(
          'first-payload',
          transportAddress: 'device-a',
          messageId: 'message-fails',
          intendedRecipient: 'queued-recipient',
        );
        final succeeded = service.trySendMessageOnRoute(
          'second-payload',
          transportAddress: 'device-a',
          messageId: 'message-succeeds',
          intendedRecipient: 'queued-recipient',
        );

        expect(failed, isNotNull);
        expect(succeeded, isNotNull);
        expect(await failed!, isFalse);
        expect(await succeeded!, isTrue);
        expect(started, <String>['message-fails', 'message-succeeds']);
      },
    );

    test(
      'direct and protocol route writes use the same serialized lane',
      () async {
        final directWriteStarted = Completer<void>();
        final directWriteGate = Completer<void>();
        final directOutcome = Completer<bool>();
        handler.centralRouteTaskProvider = (_) => (scheduleWrite) async {
          await scheduleWrite(() async {
            directWriteStarted.complete();
            await directWriteGate.future;
          });
          return directOutcome.future;
        };
        final characteristic = writableCharacteristic(
          '00000000-0000-0000-0000-00000000c1c1',
        );
        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000c2c2',
        );
        final address = peripheral.uuid.toString();
        final connection = BLEClientConnection(
          address: address,
          peripheral: peripheral,
          connectedAt: DateTime.now(),
          messageCharacteristic: characteristic,
          mtu: 128,
        );
        when(
          connectionManager.clientConnectionForPeer(address),
        ).thenReturn(connection);
        final service = buildService();

        final directAttempt = service.trySendMessageOnRoute(
          'direct-payload',
          transportAddress: address,
          messageId: 'direct-message',
          intendedRecipient: 'queued-recipient',
        );
        final protocolAttempt = service.trySendProtocolMessageOnRoute(
          ProtocolMessage.ping(),
          transportAddress: address,
        );

        expect(directAttempt, isNotNull);
        expect(protocolAttempt, isNotNull);
        await directWriteStarted.future;
        expect(
          writes,
          isEmpty,
          reason: 'protocol traffic must wait behind the admitted direct write',
        );

        directWriteGate.complete();
        expect(await protocolAttempt!, isTrue);
        expect(directOutcome.isCompleted, isFalse);
        expect(writes, isNotEmpty);
        expect(writes.every((write) => write.deviceId == address), isTrue);
        directOutcome.complete(true);
        expect(await directAttempt!, isTrue);
      },
    );

    test('route-bound protocol admission rejects an identity alias', () {
      final characteristic = writableCharacteristic(
        '00000000-0000-0000-0000-00000000d1d1',
      );
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000d2d2',
      );
      final connection = BLEClientConnection(
        address: peripheral.uuid.toString(),
        peripheral: peripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 128,
      );
      when(
        connectionManager.clientConnectionForPeer('session-alias'),
      ).thenReturn(connection);
      final service = buildService();

      final attempt = service.trySendProtocolMessageOnRoute(
        ProtocolMessage.ping(),
        transportAddress: 'session-alias',
      );

      expect(attempt, isNull);
      expect(writes, isEmpty);
    });

    test(
      'route-bound protocol admission writes only to the exact client',
      () async {
        final characteristic = writableCharacteristic(
          '00000000-0000-0000-0000-00000000d3d3',
        );
        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000d4d4',
        );
        final address = peripheral.uuid.toString();
        final connection = BLEClientConnection(
          address: address,
          peripheral: peripheral,
          connectedAt: DateTime.now(),
          messageCharacteristic: characteristic,
          mtu: 128,
        );
        when(
          connectionManager.clientConnectionForPeer(address),
        ).thenReturn(connection);
        final service = buildService();

        final attempt = service.trySendProtocolMessageOnRoute(
          ProtocolMessage.ping(),
          transportAddress: address,
        );

        expect(attempt, isNotNull);
        expect(await attempt!, isTrue);
        expect(writes, isNotEmpty);
        expect(writes.every((write) => write.deviceId == address), isTrue);
      },
    );

    test(
      'route loss after protocol admission fails without using another link',
      () async {
        final characteristic = writableCharacteristic(
          '00000000-0000-0000-0000-00000000d5d5',
        );
        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000d6d6',
        );
        final address = peripheral.uuid.toString();
        final connection = BLEClientConnection(
          address: address,
          peripheral: peripheral,
          connectedAt: DateTime.now(),
          messageCharacteristic: characteristic,
          mtu: 128,
        );
        when(
          connectionManager.clientConnectionForPeer(address),
        ).thenReturnInOrder([connection, null]);
        final service = buildService();

        final attempt = service.trySendProtocolMessageOnRoute(
          ProtocolMessage.ping(),
          transportAddress: address,
        );

        expect(
          attempt,
          isNotNull,
          reason: 'the exact route accepted admission',
        );
        expect(await attempt!, isFalse);
        expect(writes, isEmpty);
      },
    );

    test(
      'unresolvable peer id never falls back to the sole active link',
      () async {
        final characteristic = writableCharacteristic(
          '00000000-0000-0000-0000-00000000e1e1',
        );
        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000e2e2',
        );
        when(connectionManager.hasBleConnection).thenReturn(true);
        when(
          connectionManager.messageCharacteristic,
        ).thenReturn(characteristic);
        when(connectionManager.connectedDevice).thenReturn(peripheral);
        when(connectionManager.clientConnectionCount).thenReturn(1);

        final service = buildService();
        final sent = await service.sendQueueSyncMessage(
          buildSyncMessage(),
          peerId: 'unknown-node-id-flavor',
        );

        expect(
          sent,
          isFalse,
          reason:
              'queue sync must fail closed instead of guessing that the sole '
              'link is the requested peer',
        );
        expect(writes, isEmpty);
      },
    );

    test(
      'session alias is not resolved through unrelated global BLE state',
      () async {
        final characteristic = writableCharacteristic(
          '00000000-0000-0000-0000-00000000e3e3',
        );
        final peripheral = fakePeripheralFromString(
          '00000000-0000-0000-0000-00000000e4e4',
        );
        final address = peripheral.uuid.toString();
        final aliasedConnection = BLEClientConnection(
          address: address,
          peripheral: peripheral,
          connectedAt: DateTime.now(),
          messageCharacteristic: characteristic,
          mtu: 200,
        );
        when(stateManager.currentSessionId).thenReturn('session-xyz');
        when(connectionManager.hasBleConnection).thenReturn(true);
        when(
          connectionManager.messageCharacteristic,
        ).thenReturn(characteristic);
        when(connectionManager.connectedDevice).thenReturn(peripheral);
        when(connectionManager.clientConnectionCount).thenReturn(2);
        when(
          connectionManager.clientConnectionForPeer('session-xyz'),
        ).thenReturn(aliasedConnection);
        final service = buildService();
        final sent = await service.sendQueueSyncMessage(
          buildSyncMessage(),
          peerId: 'session-xyz',
        );

        expect(sent, isFalse);
        expect(writes, isEmpty);
      },
    );

    test('large targeted client payload uses exact route and no global '
        'recipient', () async {
      final characteristic = writableCharacteristic(
        '00000000-0000-0000-0000-00000000e4e5',
      );
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000e4e6',
      );
      final address = peripheral.uuid.toString();
      final targetConnection = BLEClientConnection(
        address: address,
        peripheral: peripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 80,
      );

      // Simulate another first/global client with a much larger MTU.
      when(stateManager.getRecipientId()).thenReturn('unrelated-global-peer');
      when(connectionManager.mtuSize).thenReturn(512);
      when(connectionManager.clientConnectionCount).thenReturn(2);
      when(
        connectionManager.clientConnectionForPeer(address),
      ).thenReturn(targetConnection);

      final service = buildService();
      final sent = await service.sendQueueSyncMessage(
        buildSyncMessage(messageCount: 80),
        peerId: address,
      );

      expect(sent, isTrue);
      expect(writes.length, greaterThan(1));
      expect(writes.every((write) => write.deviceId == address), isTrue);
      expect(
        writes.every((write) => write.value.length <= targetConnection.mtu!),
        isTrue,
        reason: 'every targeted write must respect the target client MTU',
      );
      final envelopes = writes
          .map((write) => BinaryFragmentEnvelope.decode(write.value))
          .toList(growable: false);
      expect(envelopes, everyElement(isNotNull));
      expect(
        envelopes.every((envelope) => envelope!.recipient == null),
        isTrue,
        reason:
            'an exact point-to-point protocol route must reassemble locally '
            'instead of inheriting an unrelated global recipient',
      );
    });

    test('unresolvable peer id with multiple links fails fast without '
        'writing to the wrong peer', () async {
      final characteristic = writableCharacteristic(
        '00000000-0000-0000-0000-00000000e5e5',
      );
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000e6e6',
      );
      when(connectionManager.hasBleConnection).thenReturn(true);
      when(connectionManager.messageCharacteristic).thenReturn(characteristic);
      when(connectionManager.connectedDevice).thenReturn(peripheral);
      when(connectionManager.clientConnectionCount).thenReturn(2);

      final service = buildService();
      final sent = await service.sendQueueSyncMessage(
        buildSyncMessage(),
        peerId: 'unknown-node-id-flavor',
      );

      expect(sent, isFalse);
      expect(writes, isEmpty);
    });

    test('transport failure returns false instead of throwing', () async {
      final characteristic = writableCharacteristic(
        '00000000-0000-0000-0000-00000000e7e7',
      );
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000e8e8',
      );
      final address = peripheral.uuid.toString();
      final connection = BLEClientConnection(
        address: address,
        peripheral: peripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 128,
      );
      when(connectionManager.hasBleConnection).thenReturn(true);
      when(connectionManager.messageCharacteristic).thenReturn(characteristic);
      when(connectionManager.connectedDevice).thenReturn(peripheral);
      when(connectionManager.clientConnectionCount).thenReturn(1);
      when(
        connectionManager.clientConnectionForPeer(address),
      ).thenReturn(connection);
      when(
        centralManager.writeCharacteristic(
          any,
          any,
          value: anyNamed('value'),
          type: anyNamed('type'),
        ),
      ).thenThrow(Exception('GATT write failed'));

      final service = buildService();
      final sent = await service.sendQueueSyncMessage(
        buildSyncMessage(),
        peerId: address,
      );

      expect(
        sent,
        isFalse,
        reason:
            'callers use unawaited(); a thrown error would surface as an '
            'unhandled async exception instead of a false result',
      );
    });

    test('route lost after preflight returns false instead of reporting the '
        'queued sync as sent', () async {
      final characteristic = writableCharacteristic(
        '00000000-0000-0000-0000-00000000e8e9',
      );
      final peripheral = fakePeripheralFromString(
        '00000000-0000-0000-0000-00000000e8ea',
      );
      final address = peripheral.uuid.toString();
      final connection = BLEClientConnection(
        address: address,
        peripheral: peripheral,
        connectedAt: DateTime.now(),
        messageCharacteristic: characteristic,
        mtu: 128,
      );

      when(connectionManager.clientConnectionCount).thenReturn(2);
      when(
        connectionManager.clientConnectionForPeer(address),
      ).thenReturnInOrder([
        connection, // sendQueueSyncMessage preflight
        null, // serialized write executes after the route disappears
      ]);

      final service = buildService();
      final sent = await service.sendQueueSyncMessage(
        buildSyncMessage(),
        peerId: address,
      );

      expect(sent, isFalse);
      expect(writes, isEmpty);
    });

    test('targeted server route is used even when the legacy global link '
        'checks see no connection', () async {
      final notifyCharacteristic = GATTCharacteristic.mutable(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000e9e9'),
        properties: [GATTCharacteristicProperty.notify],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: const [],
      );
      final central = fakeCentralFromString(
        '00000000-0000-0000-0000-00000000eaea',
      );
      final address = central.uuid.toString();
      final serverConnection = BLEServerConnection(
        address: address,
        central: central,
        connectedAt: DateTime.now(),
        subscribedCharacteristic: notifyCharacteristic,
      );

      // Legacy global checks all say "no link": not in peripheral mode,
      // no client connection. Only the peer-targeted server route exists.
      when(connectionManager.serverConnectionCount).thenReturn(1);
      when(
        connectionManager.serverConnectionForPeer(address),
      ).thenReturn(serverConnection);

      final service = buildService();
      final sent = await service
          .sendQueueSyncMessage(buildSyncMessage(), peerId: address)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => fail(
              'sendQueueSyncMessage hung: the write queue dropped the '
              'targeted write and its completer never completed',
            ),
          );

      expect(sent, isTrue);
      expect(writes, hasLength(1));
      expect(writes.single.target, _Target.peripheral);
      expect(writes.single.deviceId, address);
    });

    test(
      'peer-targeted server fragmentation respects the target server MTU',
      () async {
        final notifyCharacteristic = GATTCharacteristic.mutable(
          uuid: UUID.fromString('00000000-0000-0000-0000-00000000ebeb'),
          properties: [GATTCharacteristicProperty.notify],
          permissions: [GATTCharacteristicPermission.read],
          descriptors: const [],
        );
        final central = fakeCentralFromString(
          '00000000-0000-0000-0000-00000000ecec',
        );
        final address = central.uuid.toString();
        final serverConnection = BLEServerConnection(
          address: address,
          central: central,
          connectedAt: DateTime.now(),
          subscribedCharacteristic: notifyCharacteristic,
          mtu: 80,
        );

        when(connectionManager.mtuSize).thenReturn(512);
        when(connectionManager.serverConnectionCount).thenReturn(1);
        when(
          connectionManager.serverConnectionForPeer(address),
        ).thenReturn(serverConnection);

        final service = buildService();
        final sent = await service.sendQueueSyncMessage(
          buildSyncMessage(messageCount: 80),
          peerId: address,
        );

        expect(sent, isTrue);
        expect(writes, isNotEmpty);
        expect(
          writes.every((write) => write.target == _Target.peripheral),
          isTrue,
        );
        expect(writes.every((write) => write.deviceId == address), isTrue);
        expect(
          writes.every((write) => write.value.length <= serverConnection.mtu!),
          isTrue,
          reason: 'every targeted notification must respect the server MTU',
        );
      },
    );
  });
}

enum _Target { central, peripheral }

class _WriteCall {
  _WriteCall({
    required this.target,
    required this.deviceId,
    required this.value,
  });

  final _Target target;
  final String deviceId;
  final Uint8List value;
}

class _MockBLEConnectionManagerWithHandshake extends MockBLEConnectionManager {
  bool handshakeInProgress = false;

  @override
  bool get isHandshakeInProgress => handshakeInProgress;

  @override
  bool get awaitingHandshake => false;
}

class _ForwardingHarnessHandler extends Mock
    implements IBLEMessageHandlerFacade, IRouteBoundBleMessageHandlerFacade {
  Function(
    Uint8List data,
    String fragmentId,
    int index,
    String fromDeviceId,
    String fromNodeId,
  )?
  forwardBinaryFragment;

  ForwardReassembledPayload? forwardPayload;
  String? nextProcessResult;
  Object? nextProcessError;
  Future<bool>? centralRouteOutcome;
  Future<bool>? peripheralRouteOutcome;
  RouteBoundBleSendTask? Function(String messageId)? centralRouteTaskProvider;
  RouteBoundBleSendTask? Function(String messageId)?
  peripheralRouteTaskProvider;
  final List<({String peerId, String recipientKey, String messageId})>
  centralRouteAttempts = [];
  final List<({String peerId, String senderKey, String messageId})>
  peripheralRouteAttempts = [];

  @override
  RouteBoundBleSendTask? prepareMessageToPeer({
    required String peerId,
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  }) {
    final task =
        centralRouteTaskProvider?.call(messageId ?? '') ??
        (centralRouteOutcome == null ? null : (_) => centralRouteOutcome!);
    if (task == null) return null;
    centralRouteAttempts.add((
      peerId: peerId,
      recipientKey: recipientKey,
      messageId: messageId ?? '',
    ));
    return task;
  }

  @override
  RouteBoundBleSendTask? preparePeripheralMessageToPeer({
    required String peerId,
    required String senderKey,
    required String content,
    String? messageId,
  }) {
    final task =
        peripheralRouteTaskProvider?.call(messageId ?? '') ??
        (peripheralRouteOutcome == null
            ? null
            : (_) => peripheralRouteOutcome!);
    if (task == null) return null;
    peripheralRouteAttempts.add((
      peerId: peerId,
      senderKey: senderKey,
      messageId: messageId ?? '',
    ));
    return task;
  }

  @override
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    final error = nextProcessError;
    if (error != null) {
      throw error;
    }
    return nextProcessResult;
  }

  @override
  set onForwardBinaryFragment(
    Function(
      Uint8List data,
      String fragmentId,
      int index,
      String fromDeviceId,
      String fromNodeId,
    )?
    callback,
  ) {
    forwardBinaryFragment = callback;
  }

  @override
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId) =>
      forwardPayload;

  @override
  set onBinaryPayloadReceived(
    Function(
      Uint8List data,
      int originalType,
      String fragmentId,
      int ttl,
      String? recipient,
      String? senderNodeId,
    )?
    callback,
  ) {}

  @override
  set onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)?
    callback,
  ) {}

  @override
  set onTextMessageReceived(
    Future<void> Function(
      String content,
      String? messageId,
      String? senderNodeId,
    )?
    callback,
  ) {}
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for test condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
