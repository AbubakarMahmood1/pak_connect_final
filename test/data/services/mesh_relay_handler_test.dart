import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/data/services/mesh_relay_handler.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class _MockQueue extends Mock implements OfflineMessageQueueContract {
  @override
  Future<void> markMessageDelivered(String messageId) => super.noSuchMethod(
    Invocation.method(#markMessageDelivered, [messageId]),
    returnValue: Future<void>.value(),
    returnValueForMissingStub: Future<void>.value(),
  );

  @override
  QueuedMessage? getMessageById(String messageId) => super.noSuchMethod(
    Invocation.method(#getMessageById, [messageId]),
    returnValue: null,
    returnValueForMissingStub: null,
  ) as QueuedMessage?;
}

class _FakeMeshRelayEngine implements MeshRelayEngine {
  String? initializedNodeId;
  Function(MeshRelayMessage message, String nextHopNodeId)? relayCallback;
  Function(String originalMessageId, String content, String originalSender)?
  deliverCallback;
  Function(RelayDecision decision)? decisionCallback;
  Function(RelayStatistics stats)? statsCallback;

  RelayProcessingResult incomingResult = RelayProcessingResult.dropped('noop');
  Object? incomingError;
  MeshRelayMessage? outgoingResult;
  Object? outgoingError;
  bool shouldDecrypt = false;
  RelayStatistics stats = const RelayStatistics(
    totalRelayed: 1,
    totalDropped: 0,
    totalDeliveredToSelf: 1,
    totalBlocked: 0,
    totalProbabilisticSkip: 0,
    spamScore: 0.0,
    relayEfficiency: 1.0,
    activeRelayMessages: 0,
    networkSize: 2,
    currentRelayProbability: 1.0,
  );

  MeshRelayMessage? lastIncomingMessage;
  String? lastFromNode;
  List<String>? lastNextHops;
  ProtocolMessageType? lastMessageType;

  @override
  Future<void> initialize({
    required String currentNodeId,
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)?
    onDeliverToSelf,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  }) async {
    initializedNodeId = currentNodeId;
    relayCallback = onRelayMessage;
    deliverCallback = onDeliverToSelf;
    decisionCallback = onRelayDecision;
    statsCallback = onStatsUpdated;
  }

  @override
  Future<RelayProcessingResult> processIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    List<String> availableNextHops = const [],
    ProtocolMessageType? messageType,
  }) async {
    lastIncomingMessage = relayMessage;
    lastFromNode = fromNodeId;
    lastNextHops = availableNextHops;
    lastMessageType = messageType;
    if (incomingError != null) {
      throw incomingError!;
    }
    return incomingResult;
  }

  @override
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? encryptedPayload,
    ProtocolMessageType? originalMessageType,
    bool sealedSender = false,
  }) async {
    if (outgoingError != null) {
      throw outgoingError!;
    }
    return outgoingResult;
  }

  @override
  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async {
    return shouldDecrypt;
  }

  @override
  RelayStatistics getStatistics() => stats;
}

class _FakeFactory implements IMeshRelayEngineFactory {
  _FakeFactory(this.engine);

  final _FakeMeshRelayEngine engine;
  int createCount = 0;
  bool? lastForceFloodMode;
  OfflineMessageQueueContract? lastQueue;
  SpamPreventionManager? lastSpamPrevention;

  @override
  MeshRelayEngine create({
    required OfflineMessageQueueContract messageQueue,
    required SpamPreventionManager spamPrevention,
    bool forceFloodMode = false,
    dynamic seenMessageStore,
  }) {
    createCount++;
    lastForceFloodMode = forceFloodMode;
    lastQueue = messageQueue;
    lastSpamPrevention = spamPrevention;
    return engine;
  }
}

RelayMetadata _metadata() => RelayMetadata(
  ttl: 4,
  hopCount: 2,
  routingPath: const ['origin-node', 'relay-node'],
  messageHash: 'relay-hash',
  priority: MessagePriority.normal,
  relayTimestamp: DateTime.fromMillisecondsSinceEpoch(1000),
  originalSender: 'sender-key',
  finalRecipient: 'recipient-key',
);

ProtocolMessage _relayProtocolMessage() => ProtocolMessage.meshRelay(
  originalMessageId: 'relay-msg-1',
  originalSender: 'sender-key',
  finalRecipient: 'recipient-key',
  relayMetadata: _metadata().toJson(),
  originalPayload: const {'content': 'hello'},
  originalMessageType: ProtocolMessageType.textMessage,
);

MeshRelayMessage _relayMessage() => MeshRelayMessage(
  originalMessageId: 'relay-msg-1',
  originalContent: 'hello',
  relayMetadata: _metadata(),
  relayNodeId: 'relay-node',
  relayedAt: DateTime.fromMillisecondsSinceEpoch(2000),
  originalMessageType: ProtocolMessageType.textMessage,
);

QueuedMessage _queuedMessage() => QueuedMessage(
  id: 'queue-1',
  chatId: 'chat-1',
  content: 'payload',
  recipientPublicKey: 'recipient-key',
  senderPublicKey: 'sender-key',
  priority: MessagePriority.normal,
  queuedAt: DateTime.fromMillisecondsSinceEpoch(1234),
  maxRetries: 3,
);

void main() {
  group('MeshRelayHandler', () {
    late _FakeMeshRelayEngine engine;
    late _FakeFactory factory;
    late _MockQueue queue;
    late MeshRelayHandler handler;

    setUp(() {
      Logger.root.level = Level.OFF;
      MeshRelayHandler.clearRelayEngineFactoryResolver();
      engine = _FakeMeshRelayEngine();
      factory = _FakeFactory(engine);
      queue = _MockQueue();
      handler = MeshRelayHandler(relayEngineFactory: factory);
    });

    tearDown(() {
      MeshRelayHandler.clearRelayEngineFactoryResolver();
    });

    test('initializeRelaySystem wires factory, engine, and forwarded callbacks', () async {
      var initDecisionCallbackCalls = 0;
      var propertyDecisionCallbackCalls = 0;
      var initStatsCallbackCalls = 0;
      var propertyStatsCallbackCalls = 0;

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
        forceFloodRouting: false,
        onRelayDecisionMade: (_) => initDecisionCallbackCalls++,
        onRelayStatsUpdated: (_) => initStatsCallbackCalls++,
      );
      handler.onRelayDecisionMade = (_) => propertyDecisionCallbackCalls++;
      handler.onRelayStatsUpdated = (_) => propertyStatsCallbackCalls++;

      expect(factory.createCount, 1);
      expect(factory.lastQueue, same(queue));
      expect(factory.lastForceFloodMode, isFalse);
      expect(factory.lastSpamPrevention, isNotNull);
      expect(engine.initializedNodeId, 'node-self');

      engine.decisionCallback?.call(
        RelayDecision.relayed(
          messageId: 'mid',
          nextHopNodeId: 'next-hop',
          hopCount: 2,
        ),
      );
      engine.statsCallback?.call(engine.stats);

      expect(initDecisionCallbackCalls, 1);
      expect(propertyDecisionCallbackCalls, 1);
      expect(initStatsCallbackCalls, 1);
      expect(propertyStatsCallbackCalls, 1);
    });

    test('initializeRelaySystem resolves relay engine via static resolver', () async {
      MeshRelayHandler.configureRelayEngineFactoryResolver(() => factory);
      final resolvedHandler = MeshRelayHandler();

      await resolvedHandler.initializeRelaySystem(
        currentNodeId: 'resolved-node',
        messageQueue: queue,
      );

      expect(factory.createCount, 1);
      expect(engine.initializedNodeId, 'resolved-node');
    });

    test('initializeRelaySystem throws when no factory is configured', () async {
      final noFactoryHandler = MeshRelayHandler();

      await expectLater(
        () => noFactoryHandler.initializeRelaySystem(
          currentNodeId: 'node-x',
          messageQueue: queue,
        ),
        throwsStateError,
      );
    });

    test('next hops provider returns values and handles provider exceptions', () {
      expect(handler.getAvailableNextHops(), isEmpty);

      handler.setNextHopsProvider(() => ['a', 'b']);
      expect(handler.getAvailableNextHops(), ['a', 'b']);

      handler.setNextHopsProvider(() => throw StateError('provider boom'));
      expect(handler.getAvailableNextHops(), isEmpty);
    });

    test('handleIncomingRelay returns null when engine is missing or sender is null', () async {
      final notInitialized = MeshRelayHandler(relayEngineFactory: factory);

      expect(
        await notInitialized.handleIncomingRelay(
          protocolMessage: _relayProtocolMessage(),
          senderPublicKey: 'sender-key',
        ),
        isNull,
      );

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      expect(
        await handler.handleIncomingRelay(
          protocolMessage: _relayProtocolMessage(),
          senderPublicKey: null,
        ),
        isNull,
      );
    });

    test('handleIncomingRelay validates relay payload and catches engine exceptions', () async {
      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      expect(
        await handler.handleIncomingRelay(
          protocolMessage: ProtocolMessage.ping(),
          senderPublicKey: 'sender-key',
        ),
        isNull,
      );

      engine.incomingError = StateError('relay failure');
      expect(
        await handler.handleIncomingRelay(
          protocolMessage: _relayProtocolMessage(),
          senderPublicKey: 'sender-key',
        ),
        isNull,
      );
    });

    test('handleIncomingRelay returns delivered content and sends relay ACK', () async {
      ProtocolMessage? ackMessage;
      handler.onSendAckMessage = (message) => ackMessage = message;

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );
      handler.setNextHopsProvider(() => ['hop-1', 'hop-2']);

      engine.incomingResult = RelayProcessingResult.deliveredToSelf('delivered');

      final content = await handler.handleIncomingRelay(
        protocolMessage: _relayProtocolMessage(),
        senderPublicKey: 'sender-key',
      );

      expect(content, 'delivered');
      expect(engine.lastFromNode, 'sender-key');
      expect(engine.lastNextHops, ['hop-1', 'hop-2']);
      expect(engine.lastMessageType, ProtocolMessageType.textMessage);
      expect(ackMessage, isNotNull);
      expect(ackMessage?.relayAckOriginalMessageId, 'relay-msg-1');
      expect(ackMessage?.relayAckDelivered, isTrue);
      expect(ackMessage?.payload['ackRoutingPath'], ['relay-node', 'origin-node']);
    });

    test('handleIncomingRelay returns null for relayed, dropped, blocked and error results', () async {
      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      final outcomes = <RelayProcessingResult>[
        RelayProcessingResult.relayed('next-hop'),
        RelayProcessingResult.dropped('ttl exceeded'),
        RelayProcessingResult.blocked('spam score high'),
        RelayProcessingResult.error('crypto failure'),
      ];

      for (final outcome in outcomes) {
        engine.incomingResult = outcome;

        final result = await handler.handleIncomingRelay(
          protocolMessage: _relayProtocolMessage(),
          senderPublicKey: 'sender-key',
        );

        expect(result, isNull);
      }
    });

    test('handleRelayAck marks originated queued message as delivered', () async {
      when(queue.getMessageById('orig-1')).thenReturn(_queuedMessage());
      MessageId? callbackMessageId;
      String? callbackContent;
      String? callbackSender;
      handler.onRelayMessageReceivedIds = (id, content, sender) {
        callbackMessageId = id;
        callbackContent = content;
        callbackSender = sender;
      };

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      await handler.handleRelayAck(
        originalMessageId: 'orig-1',
        relayNode: 'relay-node',
        delivered: true,
      );

      verify(queue.markMessageDelivered('orig-1')).called(1);
      expect(callbackMessageId, const MessageId('orig-1'));
      expect(callbackContent, 'payload');
      expect(callbackSender, 'sender-key');
    });

    test('handleRelayAck propagates backwards when current node is in routing path', () async {
      when(queue.getMessageById('orig-2')).thenReturn(null);
      ProtocolMessage? forwardedAck;
      handler.onSendAckMessage = (message) => forwardedAck = message;

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      await handler.handleRelayAck(
        originalMessageId: 'orig-2',
        relayNode: 'relay-node',
        delivered: true,
        ackRoutingPath: const ['origin-node', 'node-self', 'relay-node'],
      );

      expect(forwardedAck, isNotNull);
      expect(forwardedAck?.relayAckOriginalMessageId, 'orig-2');
      expect(
        forwardedAck?.payload['ackRoutingPath'],
        ['origin-node', 'node-self', 'relay-node'],
      );
    });

    test('handleRelayAck skips propagation when routing path missing or origin reached', () async {
      when(queue.getMessageById('orig-3')).thenReturn(null);
      var sendCalls = 0;
      handler.onSendAckMessage = (_) => sendCalls++;

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      await handler.handleRelayAck(
        originalMessageId: 'orig-3',
        relayNode: 'relay-node',
        delivered: true,
      );
      await handler.handleRelayAck(
        originalMessageId: 'orig-3',
        relayNode: 'relay-node',
        delivered: true,
        ackRoutingPath: const ['node-self'],
      );

      expect(sendCalls, 0);
    });

    test('createOutgoingRelay and typed wrapper forward result and catch errors', () async {
      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      final relayMessage = _relayMessage();
      engine.outgoingResult = relayMessage;

      final created = await handler.createOutgoingRelay(
        originalMessageId: 'orig-4',
        originalContent: 'payload',
        finalRecipientPublicKey: 'peer-key',
      );
      final createdWithId = await handler.createOutgoingRelayWithId(
        originalMessageId: const MessageId('orig-5'),
        originalContent: 'payload-id',
        finalRecipientPublicKey: 'peer-key-2',
      );

      expect(created, same(relayMessage));
      expect(createdWithId, same(relayMessage));

      engine.outgoingError = StateError('create failed');
      expect(
        await handler.createOutgoingRelay(
          originalMessageId: 'orig-6',
          originalContent: 'payload',
          finalRecipientPublicKey: 'peer-key',
        ),
        isNull,
      );
    });

    test('createOutgoingRelay returns null when engine has not been initialized', () async {
      final noInitHandler = MeshRelayHandler(relayEngineFactory: factory);

      final result = await noInitHandler.createOutgoingRelay(
        originalMessageId: 'orig-7',
        originalContent: 'payload',
        finalRecipientPublicKey: 'peer-key',
      );

      expect(result, isNull);
    });

    test('shouldAttemptDecryption and getRelayStatistics proxy to engine', () async {
      final noInitHandler = MeshRelayHandler(relayEngineFactory: factory);
      expect(
        await noInitHandler.shouldAttemptDecryption(
          finalRecipientPublicKey: 'peer',
          originalSenderPublicKey: 'sender',
        ),
        isFalse,
      );
      expect(noInitHandler.getRelayStatistics(), isNull);

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );
      engine.shouldDecrypt = true;

      expect(
        await handler.shouldAttemptDecryption(
          finalRecipientPublicKey: 'peer',
          originalSenderPublicKey: 'sender',
        ),
        isTrue,
      );
      expect(handler.getRelayStatistics(), same(engine.stats));
    });

    test('engine callbacks route outgoing relay and local delivery callbacks', () async {
      ProtocolMessage? relayedMessage;
      String? relayedHop;
      String? deliveredId;
      MessageId? deliveredIdTyped;
      String? deliveredContent;
      String? deliveredSender;

      handler.onSendRelayMessage = (message, nextHop) {
        relayedMessage = message;
        relayedHop = nextHop;
      };
      handler.onRelayMessageReceived = (id, content, sender) {
        deliveredId = id;
        deliveredContent = content;
        deliveredSender = sender;
      };
      handler.onRelayMessageReceivedIds = (id, content, sender) {
        deliveredIdTyped = id;
      };

      await handler.initializeRelaySystem(
        currentNodeId: 'node-self',
        messageQueue: queue,
      );

      engine.relayCallback?.call(_relayMessage(), 'next-hop-node');
      expect(relayedHop, 'next-hop-node');
      expect(relayedMessage?.type, ProtocolMessageType.meshRelay);
      expect(relayedMessage?.meshRelayOriginalMessageId, 'relay-msg-1');

      engine.deliverCallback?.call('relay-msg-2', 'hello-self', 'sender-self');
      expect(deliveredId, 'relay-msg-2');
      expect(deliveredIdTyped, const MessageId('relay-msg-2'));
      expect(deliveredContent, 'hello-self');
      expect(deliveredSender, 'sender-self');
    });

    test('dispose is safe and setCurrentNodeId updates ACK sender', () async {
      ProtocolMessage? forwardedAck;
      handler.onSendAckMessage = (message) => forwardedAck = message;

      await handler.initializeRelaySystem(
        currentNodeId: 'old-node',
        messageQueue: queue,
      );
      handler.setCurrentNodeId('new-node');
      when(queue.getMessageById('orig-8')).thenReturn(null);

      await handler.handleRelayAck(
        originalMessageId: 'orig-8',
        relayNode: 'relay-node',
        delivered: true,
        ackRoutingPath: const ['origin', 'new-node', 'relay-node'],
      );

      expect(forwardedAck?.relayAckRelayNode, 'new-node');
      handler.dispose();
    });
  });
}
