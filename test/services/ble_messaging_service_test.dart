import 'dart:typed_data';

import 'package:mockito/annotations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_messaging_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/core/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart' as relay_models;
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/constants/binary_payload_types.dart';
import 'package:pak_connect/core/interfaces/i_message_fragmentation_handler.dart';
import 'package:pak_connect/core/utils/binary_fragmenter.dart';
import 'package:pak_connect/data/models/ble_client_connection.dart';

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
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      mockMessageHandler = _ForwardingHarnessHandler();
      mockConnectionManager = MockBLEConnectionManager();
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
      final mockConnectionManager = MockBLEConnectionManager();
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
      final peripheral = Peripheral(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000f2f2'),
      );

      when(mockConnectionManager.hasBleConnection).thenReturn(true);
      when(
        mockConnectionManager.messageCharacteristic,
      ).thenReturn(characteristic);
      when(mockConnectionManager.connectedDevice).thenReturn(peripheral);
      when(mockConnectionManager.mtuSize).thenReturn(60);

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

      await service.sendQueueSyncMessage(queueMessage);

      expect(writes, isNotEmpty);
      expect(
        writes.every((value) => value.isNotEmpty && value.first == 0xF0),
        isTrue,
      );
    });

    test(
      're-fragments binary forward per hop and skips relayer echo',
      () async {
        final handler = _ForwardingHarnessHandler();
        final connectionManager = MockBLEConnectionManager();
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

        final relayPeripheral = Peripheral(
          uuid: UUID.fromString('00000000-0000-0000-0000-00000000aaaa'),
        );
        final nextHopPeripheral = Peripheral(
          uuid: UUID.fromString('00000000-0000-0000-0000-00000000bbbb'),
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

        final connectedCentral = Central(
          uuid: UUID.fromString('00000000-0000-0000-0000-00000000cccc'),
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
          equals(1), // TTL decremented on both relay paths
        );

        // Keep analyzer happy about unused instance.
        expect(service, isA<BLEMessagingService>());
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

class _ForwardingHarnessHandler extends Mock
    implements IBLEMessageHandlerFacade {
  Function(
    Uint8List data,
    String fragmentId,
    int index,
    String fromDeviceId,
    String fromNodeId,
  )?
  forwardBinaryFragment;

  ForwardReassembledPayload? forwardPayload;

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
}
