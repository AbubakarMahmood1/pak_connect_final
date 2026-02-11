import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/mesh/mesh_relay_coordinator.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  group('MeshRelayCoordinator', () {
    late _FakeMeshBleService bleService;
    late _RecordingOfflineQueue messageQueue;
    late _StubSpamPreventionManager spamManager;
    late List<RelayDecision> relayDecisions;
    late List<RelayStatistics> relayStats;
    late List<String> deliveredMessages;
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

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
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);

      bleService = _FakeMeshBleService();
      messageQueue = _RecordingOfflineQueue();
      spamManager = _StubSpamPreventionManager();
      relayDecisions = [];
      relayStats = [];
      deliveredMessages = [];
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
        expect(result.nextHop, startsWith('ALL_NEIGHBORS'));
        expect(messageQueue.recordedMessages.length, 1);
        final payload = messageQueue.recordedMessages.first;
        expect(payload['recipient'], 'peer-abc');
        expect(payload['sender'], 'node-relay');
        expect(payload['chatId'], contains('broadcast_relay_peer-abc'));
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

class _RecordingOfflineQueue extends InMemoryOfflineMessageQueue {
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
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  }) async {
    final id = await super.queueMessage(
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      isRelayMessage: isRelayMessage,
      relayMetadata: relayMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: relayNodeId,
      messageHash: messageHash,
      persistToStorage: persistToStorage,
    );

    recordedMessages.add({
      'id': id,
      'chatId': chatId,
      'content': content,
      'recipient': recipientPublicKey,
      'sender': senderPublicKey,
      'priority': priority,
      'persist': persistToStorage,
      'isRelay': isRelayMessage,
      'originalMessageId': originalMessageId,
      'relayNodeId': relayNodeId,
      'messageHash': messageHash,
      'relayMetadata': relayMetadata,
    });
    return id;
  }

  @override
  Future<MessageId> queueMessageWithIds({
    required ChatId chatId,
    required String content,
    required ChatId recipientId,
    required ChatId senderId,
    MessagePriority priority = MessagePriority.normal,
    MessageId? replyToMessageId,
    List<String> attachments = const [],
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  }) async {
    final id = await super.queueMessageWithIds(
      chatId: chatId,
      content: content,
      recipientId: recipientId,
      senderId: senderId,
      priority: priority,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      isRelayMessage: isRelayMessage,
      relayMetadata: relayMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: relayNodeId,
      messageHash: messageHash,
      persistToStorage: persistToStorage,
    );

    recordedMessages.add({
      'id': id.value,
      'chatId': chatId.value,
      'content': content,
      'recipient': recipientId.value,
      'sender': senderId.value,
      'priority': priority,
      'replyTo': replyToMessageId?.value,
      'persist': persistToStorage,
      'isRelay': isRelayMessage,
      'originalMessageId': originalMessageId,
      'relayNodeId': relayNodeId,
      'messageHash': messageHash,
      'relayMetadata': relayMetadata,
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

  @override
  Future<SpamCheckResult> checkIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    required String currentNodeId,
  }) async => const SpamCheckResult(
    allowed: true,
    spamScore: 0,
    reason: 'stub-allowed',
    checks: [],
  );

  @override
  Future<SpamCheckResult> checkOutgoingRelay({
    required String senderNodeId,
    required int messageSize,
  }) async => const SpamCheckResult(
    allowed: true,
    spamScore: 0,
    reason: 'stub-allowed',
    checks: [],
  );

  @override
  Future<void> recordRelayOperation({
    required String fromNodeId,
    required String toNodeId,
    required String messageHash,
    required int messageSize,
  }) async {}

  @override
  void clearStatistics() {}

  @override
  void dispose() {}
}

class _FakeRelayEngine implements MeshRelayEngine {
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
  String? _currentNodeId;
  Function(RelayDecision decision)? _onRelayDecision;
  Function(RelayStatistics stats)? _onStatsUpdated;
  final OfflineMessageQueueContract _queue;

  _FakeRelayEngine({
    required OfflineMessageQueueContract queue,
    required SpamPreventionManager spamPrevention,
  }) : _queue = queue;

  @override
  Future<void> initialize({
    required String currentNodeId,
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)?
    onDeliverToSelf,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  }) async {
    initializeCount++;
    _currentNodeId = currentNodeId;
    _onRelayDecision = onRelayDecision;
    _onStatsUpdated = onStatsUpdated;
  }

  @override
  Future<RelayProcessingResult> processIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    List<String> availableNextHops = const [],
    ProtocolMessageType? messageType,
  }) async {
    if (availableNextHops.isEmpty) {
      return RelayProcessingResult.dropped('No next hops available');
    }

    final nextHop = availableNextHops.first;
    final nodeId = _currentNodeId ?? fromNodeId;

    await _queue.queueMessage(
      chatId: 'broadcast_relay_$nextHop',
      content: relayMessage.originalContent,
      recipientPublicKey: nextHop,
      senderPublicKey: nodeId,
      priority: relayMessage.relayMetadata.priority,
      isRelayMessage: true,
      relayMetadata: relayMessage.relayMetadata,
      originalMessageId: relayMessage.originalMessageId,
      relayNodeId: nodeId,
      messageHash: relayMessage.relayMetadata.messageHash,
    );

    _onRelayDecision?.call(
      RelayDecision.relayed(
        messageId: relayMessage.originalMessageId,
        nextHopNodeId: nextHop,
        hopCount: relayMessage.relayMetadata.hopCount,
      ),
    );
    _onStatsUpdated?.call(getStatistics());

    return RelayProcessingResult.relayed(nextHop);
  }

  @override
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? encryptedPayload,
    ProtocolMessageType? originalMessageType,
  }) async {
    final senderNodeId = _currentNodeId ?? 'unknown-node';
    final metadata = RelayMetadata.create(
      originalMessageContent: originalContent,
      priority: priority,
      originalSender: senderNodeId,
      finalRecipient: finalRecipientPublicKey,
      currentNodeId: senderNodeId,
    );

    return MeshRelayMessage.createRelay(
      originalMessageId: originalMessageId,
      originalContent: originalContent,
      metadata: metadata,
      relayNodeId: senderNodeId,
      encryptedPayload: encryptedPayload,
      originalMessageType: originalMessageType,
    );
  }

  @override
  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async {
    return false;
  }

  @override
  RelayStatistics getStatistics() => statistics ?? _defaultStats;
}

class _FakeMeshBleService implements IConnectionService {
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
  String? get otherUserName => 'Peer Default';

  @override
  String? get theirEphemeralId => currentSessionIdentifier;

  @override
  String? get theirPersistentKey => currentSessionIdentifier;

  @override
  String? get myPersistentId => 'my-id';

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
  Stream<List<Peripheral>> get discoveredDevices => const Stream.empty();

  @override
  Stream<String> get hintMatches => const Stream.empty();

  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async => null;

  @override
  Stream<SpyModeInfo> get spyModeDetected => const Stream.empty();

  @override
  Stream<String> get identityRevealed => const Stream.empty();

  @override
  Central? get connectedCentral => null;

  @override
  Peripheral? get connectedDevice => null;

  @override
  Stream<BluetoothStateInfo> get bluetoothStateStream => const Stream.empty();

  @override
  Stream<BluetoothStatusMessage> get bluetoothMessageStream =>
      const Stream.empty();

  @override
  bool get isBluetoothReady => true;

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  Future<void> startAsPeripheral() async {}

  @override
  Future<void> startAsCentral() async {}

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {}

  @override
  bool get isAdvertising => false;

  @override
  bool get isPeripheralMTUReady => true;

  @override
  int? get peripheralNegotiatedMTU => 256;

  @override
  Future<void> connectToDevice(Peripheral device) async {}

  @override
  Future<void> disconnect() async {}

  @override
  void startConnectionMonitoring() {}

  @override
  void stopConnectionMonitoring() {}

  @override
  bool get isActivelyReconnecting => false;

  @override
  Future<void> requestIdentityExchange() async {}

  @override
  Future<void> triggerIdentityReExchange() async {}

  @override
  Future<ProtocolMessage?> revealIdentityToFriend() async => null;

  @override
  Future<void> setMyUserName(String name) async {}

  @override
  Future<void> acceptContactRequest() async {}

  @override
  void rejectContactRequest() {}

  @override
  void setContactRequestCompletedListener(
    void Function(bool success) listener,
  ) {}

  @override
  void setContactRequestReceivedListener(
    void Function(String publicKey, String displayName) listener,
  ) {}

  @override
  void setAsymmetricContactListener(
    void Function(String publicKey, String displayName) listener,
  ) {}

  @override
  void setPairingInProgress(bool isInProgress) {}

  @override
  List<BLEServerConnection> get serverConnections => const [];

  @override
  int get clientConnectionCount => activeConnectionCount;

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
      const Stream.empty();

  @override
  Stream<String> get receivedMessages => const Stream.empty();

  @override
  Stream<BinaryPayload> get receivedBinaryStream => const Stream.empty();

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
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) async => 'fake-transfer';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
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
