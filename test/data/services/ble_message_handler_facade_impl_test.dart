import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade_impl.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
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
          onRelayMessageReceived: (_, __, ___) {},
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
      facade.onContactRequestReceived = (_, __) {};
      facade.onContactAcceptReceived = (_, __) {};
      facade.onContactRejectReceived = () {};
      facade.onCryptoVerificationReceived = (_, __) {};
      facade.onCryptoVerificationResponseReceived = (_, __, ___, ____) {};
      facade.onQueueSyncReceived = (_, __) {};
      facade.onSendQueueMessages = (_, __) {};
      facade.onQueueSyncCompleted = (_, __) {};
      facade.onRelayMessageReceived = (_, __, ___) {};
      facade.onRelayMessageReceivedIds = (_, __, ___) {};
      facade.onRelayDecisionMade = (_) {};
      facade.onRelayStatsUpdated = (_) {};
      facade.onTextMessageReceived = (_, __, ___) async {};
      facade.onSendAckMessage = (_) {};
      facade.onSendRelayMessage = (_, __) {};
      facade.onIdentityRevealed = (_) {};
      facade.onBinaryPayloadReceived = (_, __, ___, ____, _____, ______) {};
      facade.onForwardBinaryFragment = (_, __, ___, ____, _____) {};

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

class _FakeSharedQueueProvider implements ISharedMessageQueueProvider {
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
