import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import 'package:pak_connect/domain/models/binary_payload.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart'
    show RelayStatistics;
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';
import 'package:pak_connect/domain/services/mesh/mesh_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/services/mesh/mesh_relay_coordinator.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart';

@GenerateNiceMocks([
  MockSpec<IConnectionService>(),
  MockSpec<IBLEMessageHandlerFacade>(),
  MockSpec<IRepositoryProvider>(),
  MockSpec<ISharedMessageQueueProvider>(),
  MockSpec<IMessageRepository>(),
  MockSpec<MeshRelayCoordinator>(),
  MockSpec<MeshNetworkHealthMonitor>(),
  MockSpec<MeshQueueSyncCoordinator>(),
  MockSpec<ChatManagementService>(),
  MockSpec<OfflineMessageQueueContract>(),
])
import 'mesh_networking_service_phase12_test.mocks.dart';

const _emptyQueueStats = QueueStatistics(
  totalQueued: 0,
  totalDelivered: 0,
  totalFailed: 0,
  pendingMessages: 0,
  sendingMessages: 0,
  retryingMessages: 0,
  failedMessages: 0,
  isOnline: false,
  averageDeliveryTime: Duration.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockIConnectionService mockBleService;
  late MockIBLEMessageHandlerFacade mockMessageHandler;
  late MockIRepositoryProvider mockRepositoryProvider;
  late MockISharedMessageQueueProvider mockSharedQueueProvider;
  late MockIMessageRepository mockMessageRepository;
  late MockMeshRelayCoordinator mockRelayCoordinator;
  late MockMeshNetworkHealthMonitor mockHealthMonitor;
  late MockMeshQueueSyncCoordinator mockQueueCoordinator;
  late MockChatManagementService mockChatManagement;
  late MockOfflineMessageQueueContract mockMessageQueue;

  late MeshNetworkingService service;

  void stubForInitialize() {
    when(mockSharedQueueProvider.isInitialized).thenReturn(true);
    when(mockSharedQueueProvider.messageQueue).thenReturn(mockMessageQueue);
    when(mockMessageQueue.getStatistics()).thenReturn(_emptyQueueStats);
    when(mockQueueCoordinator.initialize(
      nodeId: anyNamed('nodeId'),
      messageQueue: anyNamed('messageQueue'),
      onStatusChanged: anyNamed('onStatusChanged'),
    )).thenAnswer((_) async {});
    when(mockRelayCoordinator.initialize(
      nodeId: anyNamed('nodeId'),
      messageQueue: anyNamed('messageQueue'),
      spamPrevention: anyNamed('spamPrevention'),
    )).thenAnswer((_) async {});
    when(mockMessageHandler.initializeRelaySystem(
      currentNodeId: anyNamed('currentNodeId'),
      onRelayDecisionMade: anyNamed('onRelayDecisionMade'),
      onRelayStatsUpdated: anyNamed('onRelayStatsUpdated'),
    )).thenAnswer((_) async {});
    when(mockBleService.isBluetoothReady).thenReturn(true);
  }

  /// Initialize service and drain the event loop so fire-and-forget async
  /// operations (cleanupStaleTransfers, loadPendingBinarySends) complete.
  Future<void> initializeService({String nodeId = 'test-node'}) async {
    stubForInitialize();
    await service.initialize(nodeId: nodeId);
    // Let unawaited futures (MediaTransferStore cleanup, etc.) settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  setUp(() {
    // Mock path_provider to prevent MissingPluginException in fire-and-forget
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getApplicationDocumentsDirectory') {
          return '.';
        }
        return null;
      },
    );

    mockBleService = MockIConnectionService();
    mockMessageHandler = MockIBLEMessageHandlerFacade();
    mockRepositoryProvider = MockIRepositoryProvider();
    mockSharedQueueProvider = MockISharedMessageQueueProvider();
    mockMessageRepository = MockIMessageRepository();
    mockRelayCoordinator = MockMeshRelayCoordinator();
    mockHealthMonitor = MockMeshNetworkHealthMonitor();
    mockQueueCoordinator = MockMeshQueueSyncCoordinator();
    mockChatManagement = MockChatManagementService();
    mockMessageQueue = MockOfflineMessageQueueContract();

    when(mockRepositoryProvider.messageRepository)
        .thenReturn(mockMessageRepository);

    // Stub health monitor streams
    when(mockHealthMonitor.meshStatus).thenAnswer(
      (_) => Stream<MeshNetworkStatus>.empty(),
    );
    when(mockHealthMonitor.relayStats).thenAnswer(
      (_) => Stream<RelayStatistics>.empty(),
    );
    when(mockHealthMonitor.queueStats).thenAnswer(
      (_) => Stream<QueueSyncManagerStats>.empty(),
    );
    when(mockHealthMonitor.messageDeliveryStream).thenAnswer(
      (_) => Stream<String>.empty(),
    );

    // Stub connection info stream & current info
    when(mockBleService.connectionInfo).thenAnswer(
      (_) => StreamController<ConnectionInfo>.broadcast().stream,
    );
    when(mockBleService.currentConnectionInfo).thenReturn(
      const ConnectionInfo(isConnected: false, isReady: false),
    );
    when(mockBleService.receivedBinaryStream).thenAnswer(
      (_) => StreamController<BinaryPayload>.broadcast().stream,
    );
    when(mockBleService.identityRevealed).thenAnswer(
      (_) => StreamController<String>.broadcast().stream,
    );
    when(mockBleService.isConnected).thenReturn(false);

    // Stub queue coordinator
    when(mockQueueCoordinator.getActiveQueueMessages()).thenReturn([]);
    when(mockQueueCoordinator.queueStatistics).thenReturn(null);
    when(mockQueueCoordinator.queueSyncStats).thenReturn(null);

    // Stub relay coordinator
    when(mockRelayCoordinator.relayStatistics).thenReturn(null);

    service = MeshNetworkingService(
      bleService: mockBleService,
      messageHandler: mockMessageHandler,
      chatManagementService: mockChatManagement,
      repositoryProvider: mockRepositoryProvider,
      sharedQueueProvider: mockSharedQueueProvider,
      relayCoordinator: mockRelayCoordinator,
      healthMonitor: mockHealthMonitor,
      queueCoordinator: mockQueueCoordinator,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      service.dispose();
    } catch (_) {}
    // Drain any remaining micro-tasks from unawaited futures.
    await Future<void>.delayed(Duration.zero);
  });

  // =================================================================
  // GROUP 1: Construction & Initialization
  // =================================================================
  group('Construction & initialization', () {
    test('creates with all dependencies', () {
      expect(service, isNotNull);
      expect(service.relayCoordinator, same(mockRelayCoordinator));
      expect(service.queueCoordinator, same(mockQueueCoordinator));
      expect(service.healthMonitor, same(mockHealthMonitor));
    });

    test('broadcastInitialStatus called during construction', () {
      verify(mockHealthMonitor.broadcastInitialStatus()).called(1);
    });

    test('schedulePostFrameStatusUpdate called during construction', () {
      verify(
        mockHealthMonitor.schedulePostFrameStatusUpdate(
          isInitialized: anyNamed('isInitialized'),
          nodeIdProvider: anyNamed('nodeIdProvider'),
          queueSnapshotProvider: anyNamed('queueSnapshotProvider'),
          statisticsProvider: anyNamed('statisticsProvider'),
          isConnectedProvider: anyNamed('isConnectedProvider'),
        ),
      ).called(1);
    });

    test('initialize sets node ID and initializes core components', () async {
      await initializeService(nodeId: 'test-node-123');

      verify(mockQueueCoordinator.initialize(
        nodeId: 'test-node-123',
        messageQueue: anyNamed('messageQueue'),
        onStatusChanged: anyNamed('onStatusChanged'),
      )).called(1);
    });

    test('dispose cleans up coordinators and health monitor', () {
      service.dispose();

      verify(mockRelayCoordinator.dispose()).called(1);
      verify(mockHealthMonitor.dispose()).called(1);

      // Recreate to avoid tearDown errors
      service = MeshNetworkingService(
        bleService: mockBleService,
        messageHandler: mockMessageHandler,
        chatManagementService: mockChatManagement,
        repositoryProvider: mockRepositoryProvider,
        sharedQueueProvider: mockSharedQueueProvider,
        relayCoordinator: mockRelayCoordinator,
        healthMonitor: mockHealthMonitor,
        queueCoordinator: mockQueueCoordinator,
      );
    });
  });

  // =================================================================
  // GROUP 2: Send Operations
  // =================================================================
  group('Send operations', () {
    test('sendMeshMessage returns error when not initialized', () async {
      final result = await service.sendMeshMessage(
        content: 'hello',
        recipientPublicKey: 'recipient-key',
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('not initialized'));
    });

    test('sendMeshMessage delegates to relay coordinator when not direct',
        () async {
      await initializeService(nodeId: 'my-node');

      when(mockBleService.currentConnectionInfo).thenReturn(
        const ConnectionInfo(isConnected: false, isReady: false),
      );
      when(mockRelayCoordinator.sendRelayMessage(
        content: anyNamed('content'),
        recipientPublicKey: anyNamed('recipientPublicKey'),
        chatId: anyNamed('chatId'),
        priority: anyNamed('priority'),
      )).thenAnswer(
        (_) async => MeshSendResult.relay('msg-1', 'next-hop-1'),
      );

      final result = await service.sendMeshMessage(
        content: 'hello world',
        recipientPublicKey: 'recipient-abc',
      );

      expect(result.isSuccess, isTrue);
      expect(result.isRelay, isTrue);
      verify(mockRelayCoordinator.sendRelayMessage(
        content: 'hello world',
        recipientPublicKey: 'recipient-abc',
        chatId: anyNamed('chatId'),
        priority: MessagePriority.normal,
      )).called(1);
    });

    test('sendMeshMessage with high priority passes priority through',
        () async {
      await initializeService(nodeId: 'my-node');

      when(mockBleService.currentConnectionInfo).thenReturn(
        const ConnectionInfo(isConnected: false, isReady: false),
      );
      when(mockRelayCoordinator.sendRelayMessage(
        content: anyNamed('content'),
        recipientPublicKey: anyNamed('recipientPublicKey'),
        chatId: anyNamed('chatId'),
        priority: anyNamed('priority'),
      )).thenAnswer(
        (_) async => MeshSendResult.relay('msg-2', 'next-hop-2'),
      );

      await service.sendMeshMessage(
        content: 'urgent message',
        recipientPublicKey: 'recipient-xyz',
        priority: MessagePriority.high,
      );

      verify(mockRelayCoordinator.sendRelayMessage(
        content: 'urgent message',
        recipientPublicKey: 'recipient-xyz',
        chatId: anyNamed('chatId'),
        priority: MessagePriority.high,
      )).called(1);
    });

    test('retryBinaryMedia delegates to bleService', () async {
      when(mockBleService.retryBinaryMedia(
        transferId: anyNamed('transferId'),
        recipientId: anyNamed('recipientId'),
        originalType: anyNamed('originalType'),
      )).thenAnswer((_) async => true);

      final result = await service.retryBinaryMedia(
        transferId: 'transfer-1',
        recipientId: 'recipient-1',
        originalType: 1,
      );

      expect(result, isTrue);
      verify(mockBleService.retryBinaryMedia(
        transferId: 'transfer-1',
        recipientId: 'recipient-1',
        originalType: 1,
      )).called(1);
    });

    test('sendMeshMessage direct delivery when connected to recipient',
        () async {
      await initializeService(nodeId: 'my-node');

      when(mockBleService.currentConnectionInfo).thenReturn(
        const ConnectionInfo(isConnected: true, isReady: true),
      );
      when(mockBleService.currentSessionId).thenReturn('recipient-key');

      when(mockQueueCoordinator.queueDirectMessage(
        chatId: anyNamed('chatId'),
        content: anyNamed('content'),
        recipientPublicKey: anyNamed('recipientPublicKey'),
        senderPublicKey: anyNamed('senderPublicKey'),
      )).thenAnswer((_) async => 'direct-msg-id');

      final result = await service.sendMeshMessage(
        content: 'direct hello',
        recipientPublicKey: 'recipient-key',
      );

      expect(result.isSuccess, isTrue);
      expect(result.isDirect, isTrue);
      expect(result.messageId, 'direct-msg-id');
    });
  });

  // =================================================================
  // GROUP 3: Queue Management
  // =================================================================
  group('Queue management', () {
    test('syncQueuesWithPeers delegates to coordinator and relay', () async {
      when(mockRelayCoordinator.getAvailableNextHops())
          .thenAnswer((_) async => ['peer-1', 'peer-2']);

      final syncResult = QueueSyncResult.success(
        messagesReceived: 1,
        messagesUpdated: 0,
        messagesSkipped: 0,
        finalHash: 'abc123',
        syncDuration: const Duration(milliseconds: 100),
      );
      when(mockQueueCoordinator.syncWithPeers(any))
          .thenAnswer((_) async => {'peer-1': syncResult});

      final results = await service.syncQueuesWithPeers();

      expect(results, isNotEmpty);
      expect(results['peer-1']?.success, isTrue);
      verify(mockRelayCoordinator.getAvailableNextHops()).called(1);
      verify(mockQueueCoordinator.syncWithPeers(['peer-1', 'peer-2']))
          .called(1);
    });

    test('retryMessage delegates to queue coordinator', () async {
      when(mockQueueCoordinator.retryMessage('msg-1'))
          .thenAnswer((_) async => true);

      final result = await service.retryMessage('msg-1');

      expect(result, isTrue);
      verify(mockQueueCoordinator.retryMessage('msg-1')).called(1);
    });

    test('removeMessage delegates to queue coordinator', () async {
      when(mockQueueCoordinator.removeMessage('msg-2'))
          .thenAnswer((_) async => true);

      final result = await service.removeMessage('msg-2');

      expect(result, isTrue);
      verify(mockQueueCoordinator.removeMessage('msg-2')).called(1);
    });

    test('setPriority delegates to queue coordinator', () async {
      when(mockQueueCoordinator.setPriority('msg-3', MessagePriority.urgent))
          .thenAnswer((_) async => true);

      final result =
          await service.setPriority('msg-3', MessagePriority.urgent);

      expect(result, isTrue);
      verify(
        mockQueueCoordinator.setPriority('msg-3', MessagePriority.urgent),
      ).called(1);
    });

    test('retryAllMessages delegates to queue coordinator', () async {
      when(mockQueueCoordinator.retryAllMessages())
          .thenAnswer((_) async => 5);

      final count = await service.retryAllMessages();

      expect(count, 5);
      verify(mockQueueCoordinator.retryAllMessages()).called(1);
    });

    test('getQueuedMessagesForChat returns coordinator results', () {
      when(mockQueueCoordinator.getQueuedMessagesForChat('chat-1'))
          .thenReturn([]);

      final messages = service.getQueuedMessagesForChat('chat-1');

      expect(messages, isEmpty);
      verify(mockQueueCoordinator.getQueuedMessagesForChat('chat-1'))
          .called(1);
    });
  });

  // =================================================================
  // GROUP 4: Statistics & Streams
  // =================================================================
  group('Statistics & streams', () {
    test('getNetworkStatistics aggregates from coordinators', () {
      when(mockRelayCoordinator.relayStatistics).thenReturn(null);
      when(mockQueueCoordinator.queueStatistics).thenReturn(null);
      when(mockQueueCoordinator.queueSyncStats).thenReturn(null);

      final stats = service.getNetworkStatistics();

      expect(stats.nodeId, 'unknown');
      expect(stats.isInitialized, isFalse);
      expect(stats.spamPreventionActive, isFalse);
    });

    test('refreshMeshStatus calls broadcastMeshStatus on health monitor', () {
      clearInteractions(mockHealthMonitor);

      when(mockHealthMonitor.meshStatus).thenAnswer(
        (_) => Stream<MeshNetworkStatus>.empty(),
      );
      when(mockHealthMonitor.relayStats).thenAnswer(
        (_) => Stream<RelayStatistics>.empty(),
      );
      when(mockHealthMonitor.queueStats).thenAnswer(
        (_) => Stream<QueueSyncManagerStats>.empty(),
      );
      when(mockHealthMonitor.messageDeliveryStream).thenAnswer(
        (_) => Stream<String>.empty(),
      );

      service.refreshMeshStatus();

      verify(mockHealthMonitor.broadcastMeshStatus(
        isInitialized: anyNamed('isInitialized'),
        currentNodeId: anyNamed('currentNodeId'),
        isConnected: anyNamed('isConnected'),
        statistics: anyNamed('statistics'),
        queueMessages: anyNamed('queueMessages'),
      )).called(1);
    });

    test('meshStatus stream returns health monitor stream', () {
      final controller = StreamController<MeshNetworkStatus>.broadcast();
      when(mockHealthMonitor.meshStatus).thenAnswer((_) => controller.stream);

      service.dispose();
      service = MeshNetworkingService(
        bleService: mockBleService,
        messageHandler: mockMessageHandler,
        chatManagementService: mockChatManagement,
        repositoryProvider: mockRepositoryProvider,
        sharedQueueProvider: mockSharedQueueProvider,
        relayCoordinator: mockRelayCoordinator,
        healthMonitor: mockHealthMonitor,
        queueCoordinator: mockQueueCoordinator,
      );

      expect(service.meshStatus, isNotNull);
      controller.close();
    });

    test('binaryPayloadStream is available', () {
      expect(service.binaryPayloadStream, isNotNull);
    });
  });

  // =================================================================
  // GROUP 5: Binary Handling
  // =================================================================
  group('Binary handling', () {
    test('setBinaryPayloadHandler accepts callback', () {
      service.setBinaryPayloadHandler((event) {});
      service.setBinaryPayloadHandler(null);
    });

    test('getPendingBinaryTransfers returns empty initially', () {
      final transfers = service.getPendingBinaryTransfers();
      expect(transfers, isEmpty);
    });

    test('retryBinaryMedia returns false on failure', () async {
      when(mockBleService.retryBinaryMedia(
        transferId: anyNamed('transferId'),
        recipientId: anyNamed('recipientId'),
        originalType: anyNamed('originalType'),
      )).thenAnswer((_) async => false);

      final result = await service.retryBinaryMedia(
        transferId: 'bad-transfer',
      );

      expect(result, isFalse);
    });
  });

  // =================================================================
  // GROUP 6: Debug/Testing Methods
  // =================================================================
  group('Debug/testing methods', () {
    test('pendingBinarySendCount is zero initially', () {
      expect(service.pendingBinarySendCount, 0);
    });

    test('debugHasInitialSyncScheduled returns false for unknown peer', () {
      expect(service.debugHasInitialSyncScheduled('unknown-peer'), isFalse);
    });

    test('debugHandleAnnounceForSync registers peer for sync', () {
      service.debugHandleAnnounceForSync('new-peer');
      expect(service.debugHasInitialSyncScheduled('new-peer'), isTrue);
    });

    test('debugHandleIdentityForSync registers peer for sync', () {
      service.debugHandleIdentityForSync('identity-peer');
      expect(service.debugHasInitialSyncScheduled('identity-peer'), isTrue);
    });
  });

  // =================================================================
  // GROUP 7: Error Handling
  // =================================================================
  group('Error handling', () {
    test('sendMeshMessage catches exceptions and returns error result',
        () async {
      await initializeService(nodeId: 'err-node');

      when(mockBleService.currentConnectionInfo).thenReturn(
        const ConnectionInfo(isConnected: false, isReady: false),
      );
      when(mockRelayCoordinator.sendRelayMessage(
        content: anyNamed('content'),
        recipientPublicKey: anyNamed('recipientPublicKey'),
        chatId: anyNamed('chatId'),
        priority: anyNamed('priority'),
      )).thenThrow(Exception('relay failed'));

      final result = await service.sendMeshMessage(
        content: 'test',
        recipientPublicKey: 'some-key',
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('Failed to send'));
    });

    test('initialize does not re-initialize when already initialized',
        () async {
      await initializeService(nodeId: 'node-1');

      clearInteractions(mockQueueCoordinator);
      when(mockQueueCoordinator.getActiveQueueMessages()).thenReturn([]);
      when(mockQueueCoordinator.queueStatistics).thenReturn(null);
      when(mockQueueCoordinator.queueSyncStats).thenReturn(null);

      await service.initialize(nodeId: 'node-2');

      verifyNever(mockQueueCoordinator.initialize(
        nodeId: 'node-2',
        messageQueue: anyNamed('messageQueue'),
        onStatusChanged: anyNamed('onStatusChanged'),
      ));
    });
  });
}
