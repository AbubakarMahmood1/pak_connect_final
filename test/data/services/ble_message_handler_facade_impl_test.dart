import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade_impl.dart';
import 'package:pak_connect/data/models/ble_client_connection.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/utils/binary_fragmenter.dart';
import 'package:pak_connect/domain/utils/message_fragmenter.dart';
import '../../helpers/ble/ble_fakes.dart';
import 'ble_messaging_service_test.mocks.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BLEMessageHandlerFacadeImpl', () {
    late BLEMessageHandler handler;
    late BLEMessageHandlerFacadeImpl facade;
    late _FakeSeenMessageStore seenStore;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      seenStore = _FakeSeenMessageStore();
      handler = BLEMessageHandler(enableCleanupTimer: false);
      facade = BLEMessageHandlerFacadeImpl(
        handler,
        seenStore,
        enableFragmentCleanupTimer: false,
      );
    });

    tearDown(() {
      facade.dispose();
      BLEMessageHandlerFacadeImpl.clearDependencyResolvers();
    });

    tearDownAll(SecurityServiceLocator.clearServiceResolver);

    test(
      'sendMessage fails gracefully when adapter/connection context is missing',
      () async {
        final sent = await facade.sendMessage(
          recipientKey: 'recipient',
          content: 'hello',
          timeout: const Duration(seconds: 1),
        );

        expect(sent, isFalse);
      },
    );

    test(
      'initializeRelaySystem throws when no queue override/provider is available',
      () async {
        await expectLater(
          () =>
              facade.initializeRelaySystem(currentNodeId: 'node-missing-queue'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'initializeRelaySystem can resolve shared queue provider via static resolver',
      () async {
        final provider = _FakeSharedQueueProvider(
          queue: InMemoryOfflineMessageQueue(),
          initialized: false,
        );
        BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
          sharedQueueProviderResolver: () => provider,
        );

        final localFacade = BLEMessageHandlerFacadeImpl(
          BLEMessageHandler(enableCleanupTimer: false),
          _FakeSeenMessageStore(),
          enableFragmentCleanupTimer: false,
        );
        addTearDown(localFacade.dispose);

        await localFacade.initializeRelaySystem(
          currentNodeId: 'node-via-resolver',
        );
        expect(provider.initializeCalls, 1);
      },
    );

    test(
      'constructor consumes pre-initialized shared provider and delegates QR/queue helpers',
      () async {
        final provider = _FakeSharedQueueProvider(
          queue: InMemoryOfflineMessageQueue(),
          initialized: true,
        );
        final localFacade = BLEMessageHandlerFacadeImpl(
          BLEMessageHandler(enableCleanupTimer: false),
          _FakeSeenMessageStore(),
          sharedQueueProvider: provider,
          enableFragmentCleanupTimer: false,
        );
        addTearDown(localFacade.dispose);

        await localFacade.initializeRelaySystem(currentNodeId: 'node-preinit');
        await localFacade.handleQRIntroductionClaim(
          claimJson: '{"intro":"ok"}',
          fromDeviceId: 'dev-qr',
        );
        final isMatch = await localFacade.checkQRIntroductionMatch(
          receivedHash: 'hash-a',
          expectedHash: 'hash-a',
        );
        final isMismatch = await localFacade.checkQRIntroductionMatch(
          receivedHash: 'hash-a',
          expectedHash: 'hash-b',
        );
        final sent = await localFacade.sendQueueSyncMessage(
          toNodeId: 'peer-1',
          messageIds: ['m1', 'm2'],
        );

        expect(provider.initializeCalls, 0);
        expect(isMatch, isTrue);
        expect(isMismatch, isFalse);
        expect(sent, isTrue);
      },
    );

    test(
      'sendPeripheralMessage fails gracefully without peripheral-mode context',
      () async {
        final sent = await facade.sendPeripheralMessage(
          senderKey: 'sender',
          content: 'hello peripheral',
        );

        expect(sent, isFalse);
      },
    );

    test(
      'initializeRelaySystem works with queue override and returns stats',
      () async {
        facade.setMessageQueue(InMemoryOfflineMessageQueue());
        facade.setSpamPreventionManager(SpamPreventionManager());

        await facade.initializeRelaySystem(
          currentNodeId: 'node-a',
          onRelayMessageReceived: (_, _, _) {},
          onRelayDecisionMade: (_) {},
          onRelayStatsUpdated: (_) {},
          nextHopsProvider: () => ['peer-1', 'peer-2'],
        );

        final stats = await facade.getRelayStatistics();
        expect(stats.totalRelayed, greaterThanOrEqualTo(0));
        expect(stats.totalDropped, greaterThanOrEqualTo(0));
      },
    );

    test('setNextHopsProvider updates available relay hops', () {
      facade.setNextHopsProvider(() => ['hop-A', 'hop-B']);

      final hops = facade.getAvailableNextHops();
      expect(hops, ['hop-A', 'hop-B']);
    });

    test('setSeenMessageStore and forward payload accessor are safe', () {
      facade.setSeenMessageStore(_FakeSeenMessageStore());
      expect(facade.takeForwardReassembledPayload('missing-fragment'), isNull);
    });

    test(
      'setCurrentNodeId can build write adapter through resolver and still fail gracefully',
      () async {
        final legacyStateManager = BLEStateManager();
        BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
          legacyStateManagerResolver: () => legacyStateManager,
        );

        final localFacade = BLEMessageHandlerFacadeImpl(
          BLEMessageHandler(enableCleanupTimer: false),
          _FakeSeenMessageStore(),
          enableFragmentCleanupTimer: false,
        );
        addTearDown(localFacade.dispose);

        localFacade.setCurrentNodeId('node-with-adapter');
        final sent = await localFacade.sendMessage(
          recipientKey: 'recipient-a',
          content: 'payload',
          timeout: const Duration(seconds: 1),
        );
        expect(sent, isFalse);
      },
    );

    test(
      'sendMessage reports false when adapter exists but connection context is incomplete',
      () async {
        final legacyStateManager = BLEStateManager();
        BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
          legacyStateManagerResolver: () => legacyStateManager,
        );

        final connectionManager = MockBLEConnectionManager();
        final centralManager = MockCentralManager();

        when(connectionManager.connectedDevice).thenReturn(null);
        when(connectionManager.messageCharacteristic).thenReturn(null);

        final localFacade = BLEMessageHandlerFacadeImpl(
          BLEMessageHandler(enableCleanupTimer: false),
          _FakeSeenMessageStore(),
          connectionManager: connectionManager,
          getCentralManager: () => centralManager,
          getMessageCharacteristic: () => null,
          enableFragmentCleanupTimer: false,
        );
        addTearDown(localFacade.dispose);

        final sent = await localFacade.sendMessage(
          recipientKey: 'recipient-b',
          content: 'payload',
          timeout: const Duration(seconds: 1),
        );
        expect(sent, isFalse);
      },
    );

    test(
      'sendPeripheralMessage reports false when adapter exists but central/characteristic are missing',
      () async {
        final legacyStateManager = BLEStateManager()..setPeripheralMode(true);
        BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
          legacyStateManagerResolver: () => legacyStateManager,
        );

        final stateManager = MockIBLEStateManagerFacade();
        when(stateManager.isPeripheralMode).thenReturn(true);
        when(stateManager.getIdType()).thenReturn('ephemeral');

        final peripheralManager = MockPeripheralManager();
        final localFacade = BLEMessageHandlerFacadeImpl(
          BLEMessageHandler(enableCleanupTimer: false),
          _FakeSeenMessageStore(),
          stateManager: stateManager,
          getPeripheralManager: () => peripheralManager,
          getConnectedCentral: () => null,
          getPeripheralMessageCharacteristic: () => null,
          getPeripheralMtuReady: () => true,
          getPeripheralNegotiatedMtu: () => 64,
          enableFragmentCleanupTimer: false,
        );
        addTearDown(localFacade.dispose);

        final sent = await localFacade.sendPeripheralMessage(
          senderKey: 'sender-c',
          content: 'payload',
        );
        expect(sent, isFalse);
      },
    );

    test(
      'sendPeripheralMessage traverses adapter branch when context is present',
      () async {
        final legacyStateManager = BLEStateManager()..setPeripheralMode(true);
        BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
          legacyStateManagerResolver: () => legacyStateManager,
        );

        final stateManager = MockIBLEStateManagerFacade();
        when(stateManager.isPeripheralMode).thenReturn(true);
        when(stateManager.getIdType()).thenReturn('ephemeral');

        final peripheralManager = MockPeripheralManager();
        when(
          peripheralManager.notifyCharacteristic(
            any,
            any,
            value: anyNamed('value'),
          ),
        ).thenAnswer((_) async {});

        final connectedCentral = fakeCentralFromString(
          '00000000-0000-0000-0000-00000000a0a0',
        );
        final characteristic = GATTCharacteristic.mutable(
          uuid: UUID.fromString('00000000-0000-0000-0000-00000000b0b0'),
          properties: [GATTCharacteristicProperty.notify],
          permissions: [GATTCharacteristicPermission.read],
          descriptors: const [],
        );

        final localFacade = BLEMessageHandlerFacadeImpl(
          BLEMessageHandler(enableCleanupTimer: false),
          _FakeSeenMessageStore(),
          stateManager: stateManager,
          getPeripheralManager: () => peripheralManager,
          getConnectedCentral: () => connectedCentral,
          getPeripheralMessageCharacteristic: () => characteristic,
          getPeripheralMtuReady: () => true,
          getPeripheralNegotiatedMtu: () => 96,
          enableFragmentCleanupTimer: false,
        );
        addTearDown(localFacade.dispose);

        final sent = await localFacade.sendPeripheralMessage(
          senderKey: 'sender-d-0123456789abcdef',
          content: 'adapter path',
        );
        expect(sent, isA<bool>());
      },
    );

    group('exact-route prepared sends', () {
      late BLEStateManager routeStateManager;

      setUp(() async {
        routeStateManager = BLEStateManager()..setPeripheralMode(true);
        BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
          legacyStateManagerResolver: () => routeStateManager,
        );
        SecurityServiceLocator.configureServiceResolver(
          () => _RouteTestSecurityService(),
        );
        await EphemeralKeyManager.initialize(
          'route-test-private-key-123456789012345678901234567890',
        );
      });

      _RouteFacadeHarness buildRouteHarness({
        required MockBLEConnectionManager connectionManager,
        _RecordingCentralManager? centralManager,
        _RecordingPeripheralManager? peripheralManager,
      }) {
        final routeHandler = BLEMessageHandler(enableCleanupTimer: false);
        final routeFacade = BLEMessageHandlerFacadeImpl(
          routeHandler,
          _FakeSeenMessageStore(),
          connectionManager: connectionManager,
          getCentralManager: centralManager == null
              ? null
              : () => centralManager,
          getPeripheralManager: peripheralManager == null
              ? null
              : () => peripheralManager,
          enableFragmentCleanupTimer: false,
        );
        addTearDown(routeFacade.dispose);
        return _RouteFacadeHarness(routeFacade, routeHandler);
      }

      test(
        'central route writes through its pinned peripheral and characteristic',
        () async {
          const peerId = 'central-peer';
          const messageId = 'central-pinned-message';
          final connectionManager = MockBLEConnectionManager();
          final centralManager = _RecordingCentralManager();
          final peripheral = fakePeripheralFromString(
            '00000000-0000-0000-0000-00000000c001',
          );
          final characteristic = _routeCharacteristic(
            '00000000-0000-0000-0000-00000000c002',
            property: GATTCharacteristicProperty.write,
            permission: GATTCharacteristicPermission.write,
          );
          final connectedAt = DateTime.now();
          final connection = BLEClientConnection(
            address: peerId,
            peripheral: peripheral,
            connectedAt: connectedAt,
            messageCharacteristic: characteristic,
            mtu: 64,
          );
          BLEClientConnection? liveConnection = connection;
          when(
            connectionManager.clientConnectionForPeer(peerId),
          ).thenAnswer((_) => liveConnection);
          final harness = buildRouteHarness(
            connectionManager: connectionManager,
            centralManager: centralManager,
          );

          final task = harness.facade.prepareMessageToPeer(
            peerId: peerId,
            recipientKey: 'central-recipient',
            content: 'central payload',
            timeout: const Duration(seconds: 1),
            messageId: messageId,
          );
          expect(task, isNotNull);

          // Connection-manager metadata updates replace the record via
          // copyWith while preserving the physical route incarnation.
          liveConnection = connection.copyWith(mtu: 128);
          final outcome = task!((write) => write());
          await centralManager.firstWrite.future.timeout(
            const Duration(seconds: 5),
          );
          expect(harness.handler.messageAckTracker.complete(messageId), isTrue);

          expect(await outcome, isTrue);
          expect(centralManager.writeCount, greaterThan(0));
          expect(identical(centralManager.lastPeripheral, peripheral), isTrue);
          expect(
            identical(centralManager.lastCharacteristic, characteristic),
            isTrue,
          );
        },
      );

      test(
        'peripheral route notifies its pinned central and characteristic',
        () async {
          const peerId = 'peripheral-peer';
          const messageId = 'peripheral-pinned-message';
          final connectionManager = MockBLEConnectionManager();
          final peripheralManager = _RecordingPeripheralManager();
          final central = fakeCentralFromString(
            '00000000-0000-0000-0000-00000000d001',
          );
          final characteristic = _routeCharacteristic(
            '00000000-0000-0000-0000-00000000d002',
            property: GATTCharacteristicProperty.notify,
            permission: GATTCharacteristicPermission.read,
          );
          final connection = BLEServerConnection(
            address: peerId,
            central: central,
            connectedAt: DateTime.now(),
            subscribedCharacteristic: characteristic,
            mtu: 64,
          );
          BLEServerConnection? liveConnection = connection;
          when(
            connectionManager.serverConnectionForPeer(peerId),
          ).thenAnswer((_) => liveConnection);
          final harness = buildRouteHarness(
            connectionManager: connectionManager,
            peripheralManager: peripheralManager,
          );

          final task = harness.facade.preparePeripheralMessageToPeer(
            peerId: peerId,
            senderKey: 'peripheral-recipient',
            content: 'peripheral payload',
            messageId: messageId,
          );
          expect(task, isNotNull);

          liveConnection = connection.copyWith(mtu: 128);
          final outcome = task!((write) => write());
          await peripheralManager.firstWrite.future.timeout(
            const Duration(seconds: 5),
          );
          expect(harness.handler.messageAckTracker.complete(messageId), isTrue);

          expect(await outcome, isTrue);
          expect(peripheralManager.writeCount, greaterThan(0));
          expect(identical(peripheralManager.lastCentral, central), isTrue);
          expect(
            identical(peripheralManager.lastCharacteristic, characteristic),
            isTrue,
          );
        },
      );

      test('central preparation rejects a peer identity alias', () {
        const alias = 'central-session-alias';
        final connectionManager = MockBLEConnectionManager();
        final centralManager = _RecordingCentralManager();
        final connection = BLEClientConnection(
          address: 'physical-central-address',
          peripheral: fakePeripheralFromString(
            '00000000-0000-0000-0000-00000000e001',
          ),
          connectedAt: DateTime.now(),
          messageCharacteristic: _routeCharacteristic(
            '00000000-0000-0000-0000-00000000e002',
            property: GATTCharacteristicProperty.write,
            permission: GATTCharacteristicPermission.write,
          ),
        );
        when(
          connectionManager.clientConnectionForPeer(alias),
        ).thenReturn(connection);
        final harness = buildRouteHarness(
          connectionManager: connectionManager,
          centralManager: centralManager,
        );

        final task = harness.facade.prepareMessageToPeer(
          peerId: alias,
          recipientKey: 'recipient',
          content: 'payload',
          timeout: const Duration(seconds: 1),
        );

        expect(task, isNull);
        expect(centralManager.writeCount, 0);
      });

      test('peripheral preparation rejects a peer identity alias', () {
        const alias = 'peripheral-session-alias';
        final connectionManager = MockBLEConnectionManager();
        final peripheralManager = _RecordingPeripheralManager();
        final connection = BLEServerConnection(
          address: 'physical-peripheral-address',
          central: fakeCentralFromString(
            '00000000-0000-0000-0000-00000000f001',
          ),
          connectedAt: DateTime.now(),
          subscribedCharacteristic: _routeCharacteristic(
            '00000000-0000-0000-0000-00000000f002',
            property: GATTCharacteristicProperty.notify,
            permission: GATTCharacteristicPermission.read,
          ),
        );
        when(
          connectionManager.serverConnectionForPeer(alias),
        ).thenReturn(connection);
        final harness = buildRouteHarness(
          connectionManager: connectionManager,
          peripheralManager: peripheralManager,
        );

        final task = harness.facade.preparePeripheralMessageToPeer(
          peerId: alias,
          senderKey: 'recipient',
          content: 'payload',
        );

        expect(task, isNull);
        expect(peripheralManager.writeCount, 0);
      });

      test(
        'central route loss before scheduled execution performs no write',
        () async {
          const peerId = 'central-loss-peer';
          const messageId = 'central-loss-message';
          final connectionManager = MockBLEConnectionManager();
          final centralManager = _RecordingCentralManager();
          final connection = BLEClientConnection(
            address: peerId,
            peripheral: fakePeripheralFromString(
              '00000000-0000-0000-0000-000000001001',
            ),
            connectedAt: DateTime.now(),
            messageCharacteristic: _routeCharacteristic(
              '00000000-0000-0000-0000-000000001002',
              property: GATTCharacteristicProperty.write,
              permission: GATTCharacteristicPermission.write,
            ),
          );
          BLEClientConnection? liveConnection = connection;
          when(
            connectionManager.clientConnectionForPeer(peerId),
          ).thenAnswer((_) => liveConnection);
          final harness = buildRouteHarness(
            connectionManager: connectionManager,
            centralManager: centralManager,
          );
          final task = harness.facade.prepareMessageToPeer(
            peerId: peerId,
            recipientKey: 'central-loss-recipient',
            content: 'payload',
            timeout: const Duration(seconds: 1),
            messageId: messageId,
          );
          expect(task, isNotNull);

          final outcome = await task!((write) async {
            liveConnection = null;
            await write();
          });

          expect(outcome, isFalse);
          expect(centralManager.writeCount, 0);
          expect(
            harness.handler.messageAckTracker.isPending(messageId),
            isFalse,
          );
        },
      );

      test(
        'peripheral route replacement before scheduled execution performs no write',
        () async {
          const peerId = 'peripheral-replacement-peer';
          const messageId = 'peripheral-replacement-message';
          final connectionManager = MockBLEConnectionManager();
          final peripheralManager = _RecordingPeripheralManager();
          final connection = BLEServerConnection(
            address: peerId,
            central: fakeCentralFromString(
              '00000000-0000-0000-0000-000000002001',
            ),
            connectedAt: DateTime.now(),
            subscribedCharacteristic: _routeCharacteristic(
              '00000000-0000-0000-0000-000000002002',
              property: GATTCharacteristicProperty.notify,
              permission: GATTCharacteristicPermission.read,
            ),
          );
          BLEServerConnection? liveConnection = connection;
          when(
            connectionManager.serverConnectionForPeer(peerId),
          ).thenAnswer((_) => liveConnection);
          final harness = buildRouteHarness(
            connectionManager: connectionManager,
            peripheralManager: peripheralManager,
          );
          final task = harness.facade.preparePeripheralMessageToPeer(
            peerId: peerId,
            senderKey: 'peripheral-replacement-recipient',
            content: 'payload',
            messageId: messageId,
          );
          expect(task, isNotNull);

          final outcome = await task!((write) async {
            liveConnection = BLEServerConnection(
              address: peerId,
              central: fakeCentralFromString(
                '00000000-0000-0000-0000-000000002003',
              ),
              connectedAt: connection.connectedAt.add(
                const Duration(seconds: 1),
              ),
              subscribedCharacteristic: _routeCharacteristic(
                '00000000-0000-0000-0000-000000002004',
                property: GATTCharacteristicProperty.notify,
                permission: GATTCharacteristicPermission.read,
              ),
            );
            await write();
          });

          expect(outcome, isFalse);
          expect(peripheralManager.writeCount, 0);
          expect(
            harness.handler.messageAckTracker.isPending(messageId),
            isFalse,
          );
        },
      );
    });

    test(
      'processReceivedData handles chunked reassembly path without crashing',
      () async {
        final ping = ProtocolMessage.ping();
        final pingBytes = ping.toBytes(enableCompression: false);
        final chunks = MessageFragmenter.fragmentBytes(
          pingBytes,
          85,
          'impl_chunk_1',
        );

        String? result;
        for (final chunk in chunks) {
          result = await facade.processReceivedData(
            data: chunk.toBytes(),
            fromDeviceId: 'device-1',
            fromNodeId: 'node-1',
          );
        }

        expect(result, anyOf(isNull, isA<String>()));
      },
    );

    test(
      'forward binary callback is invoked for non-local recipients',
      () async {
        facade.setCurrentNodeId('local-node');

        final forwarded = <_ForwardCall>[];
        facade.onForwardBinaryFragment =
            (data, fragmentId, index, fromDeviceId, fromNodeId) {
              forwarded.add(
                _ForwardCall(
                  data: data,
                  fragmentId: fragmentId,
                  index: index,
                  fromDeviceId: fromDeviceId,
                  fromNodeId: fromNodeId,
                ),
              );
            };

        final fragments = BinaryFragmenter.fragment(
          data: Uint8List.fromList(List<int>.generate(64, (i) => i)),
          mtu: 55,
          originalType: BinaryPayloadType.media,
          recipient: 'remote-node',
        );

        for (final fragment in fragments) {
          await facade.processReceivedData(
            data: fragment,
            fromDeviceId: 'dev-forward',
            fromNodeId: 'node-forward',
          );
        }

        expect(forwarded, isNotEmpty);
        expect(forwarded.first.fragmentId, isNotEmpty);
        expect(forwarded.first.fromDeviceId, 'dev-forward');
        expect(forwarded.first.fromNodeId, 'node-forward');
      },
    );

    test('callback setters and dispose are safe to call repeatedly', () async {
      facade.onContactRequestReceived = (_, _) {};
      facade.onContactAcceptReceived = (_, _) {};
      facade.onContactRejectReceived = () {};
      facade.onCryptoVerificationReceived = (_, _) {};
      facade.onCryptoVerificationResponseReceived = (_, _, _, _) {};
      facade.onQueueSyncReceived = (_, _) {};
      facade.onSendQueueMessages = (_, _) {};
      facade.onQueueSyncCompleted = (_, _) {};
      facade.onRelayMessageReceived = (_, _, _) {};
      facade.onRelayMessageReceivedIds = (_, _, _) {};
      facade.onRelayDecisionMade = (_) {};
      facade.onRelayStatsUpdated = (_) {};
      facade.onTextMessageReceived = (_, _, _) async {};
      facade.onSendAckMessage = (_) {};
      facade.onSendRelayMessage = (_, _) {};
      facade.onIdentityRevealed = (_) {};
      facade.onBinaryPayloadReceived = (_, _, _, _, _, _) {};
      facade.onForwardBinaryFragment = (_, _, _, _, _) {};

      facade.dispose();
      facade.dispose();
    });
  });
}

class _ForwardCall {
  _ForwardCall({
    required this.data,
    required this.fragmentId,
    required this.index,
    required this.fromDeviceId,
    required this.fromNodeId,
  });

  final Uint8List data;
  final String fragmentId;
  final int index;
  final String fromDeviceId;
  final String fromNodeId;
}

class _FakeSeenMessageStore implements ISeenMessageStore {
  @override
  Future<void> initialize() async {}

  @override
  bool hasDelivered(String messageId) => false;

  @override
  bool hasRead(String messageId) => false;

  @override
  Future<void> markDelivered(String messageId) async {}

  @override
  Future<void> markRead(String messageId) async {}

  @override
  Map<String, dynamic> getStatistics() => const {};

  @override
  Future<void> clear() async {}

  @override
  Future<void> performMaintenance() async {}
}

class _FakeSharedQueueProvider
    with SharedMessageQueueProviderWaitMixin
    implements ISharedMessageQueueProvider {
  _FakeSharedQueueProvider({required this.queue, required bool initialized})
    : _initialized = initialized;

  final InMemoryOfflineMessageQueue queue;
  bool _initialized;
  int initializeCalls = 0;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isInitializing => false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    _initialized = true;
  }

  @override
  InMemoryOfflineMessageQueue get messageQueue => queue;
}

class _RouteFacadeHarness {
  const _RouteFacadeHarness(this.facade, this.handler);

  final BLEMessageHandlerFacadeImpl facade;
  final BLEMessageHandler handler;
}

GATTCharacteristic _routeCharacteristic(
  String uuid, {
  required GATTCharacteristicProperty property,
  required GATTCharacteristicPermission permission,
}) => GATTCharacteristic.mutable(
  uuid: UUID.fromString(uuid),
  properties: <GATTCharacteristicProperty>[property],
  permissions: <GATTCharacteristicPermission>[permission],
  descriptors: const <GATTDescriptor>[],
);

class _RecordingCentralManager implements CentralManager {
  final Completer<void> firstWrite = Completer<void>();
  Peripheral? lastPeripheral;
  GATTCharacteristic? lastCharacteristic;
  int writeCount = 0;

  @override
  Future<void> writeCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required Uint8List value,
    required GATTCharacteristicWriteType type,
  }) async {
    writeCount++;
    lastPeripheral = peripheral;
    lastCharacteristic = characteristic;
    if (!firstWrite.isCompleted) firstWrite.complete();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingPeripheralManager implements PeripheralManager {
  final Completer<void> firstWrite = Completer<void>();
  Central? lastCentral;
  GATTCharacteristic? lastCharacteristic;
  int writeCount = 0;

  @override
  Future<void> notifyCharacteristic(
    Central central,
    GATTCharacteristic characteristic, {
    required Uint8List value,
  }) async {
    writeCount++;
    lastCentral = central;
    lastCharacteristic = characteristic;
    if (!firstWrite.isCompleted) firstWrite.complete();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RouteTestSecurityService implements ISecurityService {
  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}

  @override
  void unregisterIdentityMapping(String persistentPublicKey) {}

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async => SecurityLevel.low;

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async => EncryptionMethod.noise(publicKey);

  @override
  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  ) async => 'route-test:$message';

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) => encryptMessage(message, publicKey, repo);

  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async => encryptedMessage;

  @override
  Future<String> decryptMessageByType(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) => decryptMessage(encryptedMessage, publicKey, repo);

  @override
  Future<String> decryptSealedMessage({
    required String encryptedMessage,
    required CryptoHeader cryptoHeader,
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async => encryptedMessage;

  @override
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => true;
}
