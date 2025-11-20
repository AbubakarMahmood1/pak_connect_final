import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/interfaces/i_contact_repository.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/core/interfaces/i_message_repository.dart';
import 'package:pak_connect/core/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/core/interfaces/i_mesh_ble_service.dart';
import 'package:pak_connect/core/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/routing/network_topology_analyzer.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/services/mesh/mesh_relay_coordinator.dart';

void main() {
  group('MeshRelayCoordinator', () {
    late _FakeMeshBleService bleService;
    late _RecordingOfflineQueue messageQueue;
    late _StubSpamPreventionManager spamManager;
    late List<RelayDecision> relayDecisions;
    late List<RelayStatistics> relayStats;
    late List<String> deliveredMessages;

    MeshRelayCoordinator buildCoordinator({MeshRelayEngineFactory? factory}) {
      return MeshRelayCoordinator(
        bleService: bleService,
        onRelayDecision: relayDecisions.add,
        onRelayStatsUpdated: relayStats.add,
        onDeliverToSelf: (id, content, sender) async =>
            deliveredMessages.add(id),
        relayEngineFactory: factory,
      );
    }

    setUp(() {
      bleService = _FakeMeshBleService();
      messageQueue = _RecordingOfflineQueue();
      spamManager = _StubSpamPreventionManager();
      relayDecisions = [];
      relayStats = [];
      deliveredMessages = [];
    });

    test('initialize wires relay engine via injected factory', () async {
      late _FakeRelayEngine createdEngine;
      final coordinator = buildCoordinator(
        factory: (queue, spam) {
          createdEngine = _FakeRelayEngine(queue: queue, spamPrevention: spam);
          return createdEngine;
        },
      );

      await coordinator.initialize(
        nodeId: 'node-test',
        messageQueue: messageQueue,
        spamPrevention: spamManager,
      );

      expect(createdEngine.initializeCount, 1);

      const stats = RelayStatistics(
        totalRelayed: 1,
        totalDropped: 0,
        totalDeliveredToSelf: 0,
        totalBlocked: 0,
        totalProbabilisticSkip: 0,
        spamScore: 0.1,
        relayEfficiency: 0.9,
        activeRelayMessages: 0,
        networkSize: 1,
        currentRelayProbability: 0.8,
      );
      createdEngine.statistics = stats;
      expect(coordinator.relayStatistics, stats);
    });

    test(
      'sendRelayMessage reports error when no next hops are available',
      () async {
        final coordinator = buildCoordinator(
          factory: (queue, spam) =>
              _FakeRelayEngine(queue: queue, spamPrevention: spam),
        );

        bleService.connectionInfoValue = const ConnectionInfo(
          isConnected: false,
          isReady: false,
          statusMessage: 'offline',
        );
        bleService.currentSessionIdentifier = null;

        await coordinator.initialize(
          nodeId: 'node-empty',
          messageQueue: messageQueue,
          spamPrevention: spamManager,
        );

        final result = await coordinator.sendRelayMessage(
          content: 'payload',
          recipientPublicKey: 'recipient',
          chatId: 'chat',
        );

        expect(result.isSuccess, isFalse);
        expect(result.error, contains('No next hops'));
        expect(messageQueue.recordedMessages, isEmpty);
      },
    );

    test(
      'sendRelayMessage enqueues relay payload when hop is available',
      () async {
        final coordinator = buildCoordinator(
          factory: (queue, spam) =>
              _FakeRelayEngine(queue: queue, spamPrevention: spam),
        );

        bleService.connectionInfoValue = const ConnectionInfo(
          isConnected: true,
          isReady: true,
          statusMessage: 'connected',
        );
        bleService.currentSessionIdentifier = 'peer-abc';

        await coordinator.initialize(
          nodeId: 'node-relay',
          messageQueue: messageQueue,
          spamPrevention: spamManager,
        );

        final result = await coordinator.sendRelayMessage(
          content: 'message body',
          recipientPublicKey: 'recipient-key',
          chatId: 'chat-123',
          priority: MessagePriority.high,
        );

        expect(result.isRelay, isTrue);
        expect(result.nextHop, 'peer-abc');
        expect(messageQueue.recordedMessages.length, 1);
        final payload = messageQueue.recordedMessages.first;
        expect(payload['recipient'], 'recipient-key');
        expect(payload['sender'], 'node-relay');
        expect(payload['chatId'], contains('mesh_relay_peer-abc'));
        expect(payload['priority'], MessagePriority.high);
      },
    );

    test('shouldRelayThroughDevice applies basic heuristics', () async {
      final coordinator = buildCoordinator(
        factory: (queue, spam) =>
            _FakeRelayEngine(queue: queue, spamPrevention: spam),
      );

      bleService.connectionInfoValue = const ConnectionInfo(
        isConnected: true,
        isReady: true,
        statusMessage: 'connected',
      );
      bleService.currentSessionIdentifier = 'peer-xyz';

      await coordinator.initialize(
        nodeId: 'node-relay',
        messageQueue: messageQueue,
        spamPrevention: spamManager,
      );

      final now = DateTime.now();
      final directMessage = QueuedMessage(
        id: 'direct',
        chatId: 'chat',
        content: 'hello',
        recipientPublicKey: 'peer-xyz',
        senderPublicKey: 'node-relay',
        priority: MessagePriority.normal,
        queuedAt: now,
        maxRetries: 3,
      );

      expect(
        await coordinator.shouldRelayThroughDevice(directMessage, 'peer-xyz'),
        isFalse,
      );

      final relayCandidate = QueuedMessage(
        id: 'relay',
        chatId: 'chat',
        content: 'hello',
        recipientPublicKey: 'final-node',
        senderPublicKey: 'node-relay',
        priority: MessagePriority.normal,
        queuedAt: now,
        maxRetries: 3,
      );

      expect(
        await coordinator.shouldRelayThroughDevice(relayCandidate, 'peer-xyz'),
        isTrue,
      );
    });
  });
}

class _RecordingOfflineQueue extends OfflineMessageQueue {
  final List<Map<String, dynamic>> recordedMessages = [];

  @override
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const [],
  }) async {
    final id = 'queued_${recordedMessages.length}';
    recordedMessages.add({
      'id': id,
      'chatId': chatId,
      'content': content,
      'recipient': recipientPublicKey,
      'sender': senderPublicKey,
      'priority': priority,
    });
    return id;
  }
}

class _StubSpamPreventionManager extends SpamPreventionManager {
  @override
  Future<void> initialize() async {}

  @override
  SpamPreventionStatistics getStatistics() => const SpamPreventionStatistics(
    totalAllowed: 0,
    totalBlocked: 0,
    blockRate: 0,
    averageSpamScore: 0,
    activeTrustScores: 0,
    processedHashes: 0,
  );
}

class _FakeRelayEngine extends MeshRelayEngine {
  static const RelayStatistics _defaultStats = RelayStatistics(
    totalRelayed: 0,
    totalDropped: 0,
    totalDeliveredToSelf: 0,
    totalBlocked: 0,
    totalProbabilisticSkip: 0,
    spamScore: 0,
    relayEfficiency: 0,
    activeRelayMessages: 0,
    networkSize: 0,
    currentRelayProbability: 0,
  );

  int initializeCount = 0;
  RelayStatistics? statistics;

  _FakeRelayEngine({
    required OfflineMessageQueue queue,
    required SpamPreventionManager spamPrevention,
  }) : super(
         repositoryProvider: _StubRepositoryProvider(),
         seenMessageStore: _StubSeenMessageStore(),
         messageQueue: queue,
         spamPrevention: spamPrevention,
       );

  @override
  Future<void> initialize({
    required String currentNodeId,
    IMeshRoutingService? routingService,
    NetworkTopologyAnalyzer? topologyAnalyzer,
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)?
    onDeliverToSelf,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  }) async {
    initializeCount++;
  }

  @override
  RelayStatistics getStatistics() => statistics ?? _defaultStats;
}

class _StubRepositoryProvider implements IRepositoryProvider {
  _StubRepositoryProvider()
    : contactRepository = _MockContactRepository(),
      messageRepository = _MockMessageRepository();

  @override
  final IContactRepository contactRepository;

  @override
  final IMessageRepository messageRepository;
}

class _StubSeenMessageStore implements ISeenMessageStore {
  @override
  Future<void> clear() async {}

  @override
  Future<void> markDelivered(String messageId) async {}

  @override
  Future<void> markRead(String messageId) async {}

  @override
  Future<void> performMaintenance() async {}

  @override
  bool hasDelivered(String messageId) => false;

  @override
  bool hasRead(String messageId) => false;

  @override
  Map<String, dynamic> getStatistics() => const {};
}

class _FakeMeshBleService implements IMeshBleService {
  ConnectionInfo connectionInfoValue = const ConnectionInfo(
    isConnected: true,
    isReady: true,
    statusMessage: 'connected',
  );

  String? currentSessionIdentifier = 'peer-default';

  @override
  Stream<ConnectionInfo> get connectionInfo =>
      Stream<ConnectionInfo>.value(connectionInfoValue);

  @override
  ConnectionInfo get currentConnectionInfo => connectionInfoValue;

  @override
  String? get currentSessionId => currentSessionIdentifier;

  @override
  bool get canSendMessages => true;

  @override
  bool get hasPeripheralConnection => false;

  @override
  bool get isPeripheralMode => false;

  @override
  bool get isConnected => connectionInfoValue.isConnected;

  @override
  bool get canAcceptMoreConnections => true;

  @override
  int get activeConnectionCount => 1;

  @override
  int get maxCentralConnections => 3;

  @override
  List<String> get activeConnectionDeviceIds =>
      currentSessionIdentifier == null ? [] : [currentSessionIdentifier!];

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
      const Stream.empty();

  @override
  Stream<String> get receivedMessages => const Stream.empty();

  @override
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges => const Stream.empty();

  @override
  Future<String> getMyEphemeralId() async => 'ephemeral';

  @override
  Future<String> getMyPublicKey() async => 'public';

  @override
  String? get theirPersistentPublicKey => null;

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {}

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async => true;

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async => true;

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {}

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {}

  @override
  Future<void> stopScanning() async {}
}

class _MockContactRepository extends Mock implements IContactRepository {}

class _MockMessageRepository extends Mock implements IMessageRepository {}
