import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart'
    show ScanningSource;
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult, QueueSyncResponse;
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';
import 'package:pak_connect/domain/services/mesh/mesh_queue_sync_coordinator.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  group('MeshQueueSyncCoordinator', () {
    late _TestMeshBleService bleService;
    late _FakeMessageRepository messageRepository;
    late MeshNetworkHealthMonitor monitor;
    late _InMemoryQueue queue;
    late _FakeQueueSyncManager fakeManager;
    late MeshQueueSyncCoordinator coordinator;
    late int statusRefreshes;
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUp(() async {
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      bleService = _TestMeshBleService();
      messageRepository = _FakeMessageRepository();
      monitor = MeshNetworkHealthMonitor();
      queue = _InMemoryQueue();
      fakeManager = _FakeQueueSyncManager();
      statusRefreshes = 0;

      coordinator = MeshQueueSyncCoordinator(
        bleService: bleService,
        messageRepository: messageRepository,
        healthMonitor: monitor,
        queueSyncManagerFactory: (queue, nodeId) => fakeManager,
      );

      await coordinator.initialize(
        nodeId: 'node-integration',
        messageQueue: queue,
        onStatusChanged: () => statusRefreshes++,
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

    test('retryMessage triggers immediate delivery + persistence', () async {
      bleService.simulateConnection(peerId: 'peer-1');
      queue.setOffline();
      final deliveryIds = <String>[];
      final deliverySub = monitor.messageDeliveryStream.listen(deliveryIds.add);

      final messageId = await coordinator.queueDirectMessage(
        chatId: 'chat',
        content: 'hello',
        recipientPublicKey: 'peer-1',
        senderPublicKey: 'node-integration',
      );
      final queued = queue.getMessageById(messageId)!;
      queued.status = QueuedMessageStatus.failed;
      await queue.setOnline();
      expect(bleService.sentMessages, isEmpty);

      final success = await coordinator.retryMessage(messageId);
      expect(success, isTrue);

      // The BLE send result represents a completed protocol ACK.
      await Future<void>.delayed(Duration.zero);

      expect(messageRepository.savedMessages.length, 1);
      expect(messageRepository.savedMessages.single.id.value, messageId);
      expect(deliveryIds, contains(messageId));
      expect(statusRefreshes, greaterThan(0));

      await deliverySub.cancel();
    });

    test('syncWithPeers delegates to queue sync manager', () async {
      final results = await coordinator.syncWithPeers(['peer-sync']);
      expect(results.containsKey('peer-sync'), isTrue);
      expect(fakeManager.forcedSyncTargets.single, ['peer-sync']);
    });

    test('queue sync response is sent back to requesting peer', () async {
      coordinator.enableQueueSyncHandling();
      bleService.simulateConnection(
        peerId: 'peer-requester',
        deviceAddress: 'device-requester',
      );
      final responseMessage = QueueSyncMessage.createResponse(
        messageIds: const ['message-a'],
        nodeId: 'node-integration',
        stats: QueueSyncStats(
          totalMessages: 1,
          pendingMessages: 0,
          failedMessages: 0,
          lastSyncTime: DateTime.fromMillisecondsSinceEpoch(1),
          successRate: 1,
        ),
      );
      fakeManager.nextSyncRequestResponse = QueueSyncResponse.success(
        responseMessage: responseMessage,
        missingMessages: const [],
        excessMessages: const [],
      );

      final request = QueueSyncMessage.createRequest(
        messageIds: const ['message-a'],
        nodeId: 'peer-requester',
        queueHash: 'peer-request-hash',
      );

      final handled = await bleService.invokeQueueSyncHandlerForTest(
        request,
        'device-requester',
      );

      expect(handled, isTrue);
      expect(bleService.sentQueueSyncPeerIds, ['device-requester']);
    });

    test('connection monitoring toggles queue online/offline', () async {
      coordinator.startConnectionMonitoring();

      bleService.simulateConnection(peerId: 'peer-online');
      await Future<void>.delayed(Duration.zero);
      expect(queue.isOnline, isTrue);

      bleService.simulateDisconnection();
      await Future<void>.delayed(Duration.zero);
      expect(queue.isOnline, isFalse);
      expect(statusRefreshes, greaterThanOrEqualTo(2));
    });

    test('reprocessPendingDeliveries flushes a backgrounded backlog to the '
        'connected peer', () async {
      bleService.simulateConnection(peerId: 'peer-resume');
      // Enqueue while offline so it stays pending (mimics a message queued
      // while the app was backgrounded and delivery timers were suspended).
      queue.setOffline();
      await coordinator.queueDirectMessage(
        chatId: 'chat',
        content: 'backlogged',
        recipientPublicKey: 'peer-resume',
        senderPublicKey: 'node-integration',
      );
      expect(bleService.sentMessages, isEmpty);

      await coordinator.reprocessPendingDeliveries();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        bleService.sentMessages,
        contains('backlogged'),
        reason: 'resume must push the pending backlog, not wait on timers',
      );
    });

    test(
      'resume delivery accepts the connected peer persistent alias',
      () async {
        bleService.simulateConnection(
          peerId: 'session-b',
          ephemeralId: 'ephemeral-b',
          persistentKey: 'persistent-b',
        );
        queue.setOffline();
        await coordinator.queueDirectMessage(
          chatId: 'chat',
          content: 'persistent backlog',
          recipientPublicKey: 'persistent-b',
          senderPublicKey: 'node-integration',
        );
        await coordinator.queueDirectMessage(
          chatId: 'chat',
          content: 'different peer backlog',
          recipientPublicKey: 'persistent-c',
          senderPublicKey: 'node-integration',
        );

        await coordinator.reprocessPendingDeliveries();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(bleService.sentMessages, contains('persistent backlog'));
        expect(
          bleService.sentMessages,
          isNot(contains('different peer backlog')),
        );
      },
    );

    test(
      'reprocessPendingDeliveries no-ops when there is no usable link',
      () async {
        // No simulateConnection → canSendMessages is false.
        queue.setOffline();
        await coordinator.queueDirectMessage(
          chatId: 'chat',
          content: 'stranded',
          recipientPublicKey: 'peer-absent',
          senderPublicKey: 'node-integration',
        );

        await coordinator.reprocessPendingDeliveries();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(bleService.sentMessages, isEmpty);
      },
    );

    test(
      'sync response is processed even right after a request from same peer',
      () async {
        coordinator.enableQueueSyncHandling();
        bleService.simulateConnection(peerId: 'peer-x');

        final request = QueueSyncMessage.createRequest(
          messageIds: const ['message-a'],
          nodeId: 'peer-x',
          queueHash: 'request-hash',
        );
        await bleService.invokeQueueSyncHandlerForTest(request, 'peer-x');

        fakeManager.pendingSyncTargets.add('peer-x');

        final response = QueueSyncMessage.createResponse(
          messageIds: const ['message-a'],
          nodeId: 'peer-x',
          stats: QueueSyncStats(
            totalMessages: 1,
            pendingMessages: 0,
            failedMessages: 0,
            lastSyncTime: DateTime.fromMillisecondsSinceEpoch(1),
            successRate: 1,
          ),
        );
        final handled = await bleService.invokeQueueSyncHandlerForTest(
          response,
          'peer-x',
        );

        expect(
          handled,
          isTrue,
          reason: 'responses must never be dropped by the request debounce',
        );
        expect(fakeManager.processedResponseNodeIds, hasLength(1));
      },
    );

    test(
      'handling an inbound request does not debounce our own outbound sync',
      () async {
        coordinator.enableQueueSyncHandling();
        coordinator.startConnectionMonitoring();

        final request = QueueSyncMessage.createRequest(
          messageIds: const [],
          nodeId: 'peer-x',
          queueHash: 'request-hash',
        );
        await bleService.invokeQueueSyncHandlerForTest(request, 'peer-x');

        bleService.simulateConnection(
          peerId: 'peer-x',
          deviceAddress: 'device-x',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          fakeManager.initiatedSyncs,
          contains('device-x'),
          reason:
              'connection-triggered sync must use the concrete BLE address '
              'and inbound request debounce must not suppress it',
        );
      },
    );
  });

  group('MeshQueueSyncCoordinator with real QueueSyncManager', () {
    late _TestMeshBleService bleService;
    late _FakeMessageRepository messageRepository;
    late MeshNetworkHealthMonitor monitor;
    late _InMemoryQueue queue;
    late MeshQueueSyncCoordinator coordinator;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      bleService = _TestMeshBleService();
      messageRepository = _FakeMessageRepository();
      monitor = MeshNetworkHealthMonitor();
      queue = _InMemoryQueue();

      coordinator = MeshQueueSyncCoordinator(
        bleService: bleService,
        messageRepository: messageRepository,
        healthMonitor: monitor,
      );

      await coordinator.initialize(
        nodeId: 'node-a',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      coordinator.enableQueueSyncHandling();
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    test(
      'initiated sync completes from the exact target device address',
      () async {
        bleService.simulateConnection(
          peerId: 'session-b',
          deviceAddress: 'device-b',
        );
        bleService.sendQueueSyncOverride = (message, peerId) async {
          if (message.syncType == QueueSyncType.request) {
            expect(peerId, 'device-b');
            final response = QueueSyncMessage.createResponse(
              messageIds: const [],
              nodeId: 'peer-node-b',
              syncId: message.syncId,
              stats: QueueSyncStats(
                totalMessages: 0,
                pendingMessages: 0,
                failedMessages: 0,
                lastSyncTime: DateTime.fromMillisecondsSinceEpoch(1),
                successRate: 1,
              ),
            );
            unawaited(
              bleService.invokeQueueSyncHandlerForTest(response, 'device-b'),
            );
          }
          return true;
        };

        final stopwatch = Stopwatch()..start();
        final results = await coordinator.syncWithPeers(['device-b']);
        stopwatch.stop();

        final result = results['device-b'];
        expect(result, isNotNull);
        expect(
          result!.success,
          isTrue,
          reason: 'sync should complete on the bound route: ${result.error}',
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 10)),
          reason: 'sync must not run into the 15s response timeout',
        );
      },
    );

    test(
      'matching token from a different concrete sender cannot complete sync',
      () async {
        bleService.simulateConnection(
          peerId: 'session-a',
          deviceAddress: 'device-a',
        );
        final requestCaptured = Completer<QueueSyncMessage>();
        bleService.sendQueueSyncOverride = (message, peerId) async {
          if (message.syncType == QueueSyncType.request &&
              !requestCaptured.isCompleted) {
            requestCaptured.complete(message);
          }
          return true;
        };

        var completed = false;
        final syncFuture = coordinator.syncWithPeers(['device-a'])
          ..then((_) => completed = true);
        final request = await requestCaptured.future;

        final forged = QueueSyncMessage.createResponse(
          messageIds: const [],
          nodeId: 'claimed-device-a',
          syncId: 'wrong-token',
          stats: QueueSyncStats(
            totalMessages: 0,
            pendingMessages: 0,
            failedMessages: 0,
            lastSyncTime: DateTime.fromMillisecondsSinceEpoch(1),
            successRate: 1,
          ),
        );
        expect(
          await bleService.invokeQueueSyncHandlerForTest(forged, 'device-a'),
          isFalse,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(completed, isFalse);

        final correlated = QueueSyncMessage.createResponse(
          messageIds: const [],
          nodeId: 'malicious-claimed-node',
          syncId: request.syncId,
          stats: QueueSyncStats(
            totalMessages: 0,
            pendingMessages: 0,
            failedMessages: 0,
            lastSyncTime: DateTime.fromMillisecondsSinceEpoch(1),
            successRate: 1,
          ),
        );
        expect(
          await bleService.invokeQueueSyncHandlerForTest(
            correlated,
            'device-b',
          ),
          isFalse,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(completed, isFalse);

        expect(
          await bleService.invokeQueueSyncHandlerForTest(
            correlated,
            'device-a',
          ),
          isTrue,
        );

        final results = await syncFuture;
        expect(results['device-a']?.success, isTrue);
      },
    );

    test('initiated sync fails fast when transport reports no route', () async {
      bleService.simulateConnection(
        peerId: 'session-b',
        deviceAddress: 'device-b',
      );
      bleService.sendQueueSyncOverride = (message, peerId) async => false;

      final stopwatch = Stopwatch()..start();
      final results = await coordinator.syncWithPeers(['device-b']);
      stopwatch.stop();

      final result = results['device-b'];
      expect(result, isNotNull);
      expect(result!.success, isFalse);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'a send with no route must fail fast, not wait for timeout',
      );
    });

    test('sync-triggered delivery is rejected when requester is not the exact '
        'sole transport route', () async {
      bleService.simulateConnection(peerId: 'session-b');
      queue.setOffline();
      final messageId = await coordinator.queueDirectMessage(
        chatId: 'chat',
        content: 'queued-payload',
        recipientPublicKey: 'session-b',
        senderPublicKey: 'node-a',
      );
      bleService.sendQueueSyncOverride = (message, peerId) async => true;

      final request = QueueSyncMessage.createRequest(
        messageIds: const [],
        nodeId: 'peer-node-b',
        queueHash: 'different-hash',
      );
      final handled = await bleService.invokeQueueSyncHandlerForTest(
        request,
        'hint-b',
      );
      expect(handled, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bleService.sentMessages, isNot(contains('queued-payload')));
      expect(
        queue.getMessageById(messageId)?.status,
        isNot(QueuedMessageStatus.delivered),
      );
    });

    test(
      'sync-triggered delivery is rejected with multiple active routes',
      () async {
        bleService.simulateConnection(
          peerId: 'session-b',
          deviceAddress: 'device-b',
        );
        bleService._activeDeviceAddresses.add('device-c');
        queue.setOffline();
        await coordinator.queueDirectMessage(
          chatId: 'chat',
          content: 'must-not-cross-link',
          recipientPublicKey: 'session-b',
          senderPublicKey: 'node-a',
        );
        bleService.sendQueueSyncOverride = (message, peerId) async => true;

        final request = QueueSyncMessage.createRequest(
          messageIds: const [],
          nodeId: 'peer-node-b',
          queueHash: 'different-hash',
        );
        expect(
          await bleService.invokeQueueSyncHandlerForTest(request, 'device-b'),
          isFalse,
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bleService.sentMessages, isNot(contains('must-not-cross-link')));
      },
    );
  });
}

class _InMemoryQueue extends InMemoryOfflineMessageQueue {}

class _FakeQueueSyncManager implements QueueSyncManagerContract {
  final List<List<String>> forcedSyncTargets = [];
  final List<String> initiatedSyncs = [];
  final List<String> processedResponseNodeIds = [];
  final List<String> failedPendingSyncs = [];
  final Set<String> pendingSyncTargets = {};
  QueueSyncResponse? nextSyncRequestResponse;

  @override
  Future<void> initialize({
    Function(QueueSyncMessage message, String fromNodeId)? onSyncRequest,
    Function(List<QueuedMessage> messages, String toNodeId)? onSendMessages,
    Function(String nodeId, QueueSyncResult result)? onSyncCompleted,
    Function(String nodeId, String error)? onSyncFailed,
  }) async {}

  @override
  QueueSyncManagerStats getStats() => const QueueSyncManagerStats(
    totalSyncRequests: 0,
    successfulSyncs: 0,
    failedSyncs: 0,
    messagesTransferred: 0,
    activeSyncs: 0,
    successRate: 0,
    recentSyncCount: 0,
  );

  @override
  Future<Map<String, QueueSyncResult>> forceSyncAll(
    List<String> nodeIds,
  ) async {
    forcedSyncTargets.add(nodeIds);
    return {
      for (final node in nodeIds)
        node: QueueSyncResult.success(
          messagesReceived: 0,
          messagesUpdated: 0,
          messagesSkipped: 0,
          finalHash: 'hash',
          syncDuration: Duration.zero,
        ),
    };
  }

  @override
  Future<QueueSyncResult> initiateSync(String targetNodeId) async {
    initiatedSyncs.add(targetNodeId);
    return QueueSyncResult.success(
      messagesReceived: 0,
      messagesUpdated: 0,
      messagesSkipped: 0,
      finalHash: 'hash',
      syncDuration: Duration.zero,
    );
  }

  @override
  Future<QueueSyncResponse> handleSyncRequest(
    QueueSyncMessage syncMessage,
    String fromNodeId,
  ) async {
    return nextSyncRequestResponse ?? QueueSyncResponse.alreadySynced();
  }

  @override
  Future<QueueSyncResult> processSyncResponse(
    QueueSyncMessage responseMessage,
    List<QueuedMessage> receivedMessages,
    String fromNodeId,
  ) async {
    processedResponseNodeIds.add(fromNodeId);
    return QueueSyncResult.success(
      messagesReceived: receivedMessages.length,
      messagesUpdated: 0,
      messagesSkipped: 0,
      finalHash: 'hash',
      syncDuration: Duration.zero,
    );
  }

  @override
  bool hasPendingSyncWith(String nodeId) => pendingSyncTargets.contains(nodeId);

  @override
  bool canAcceptSyncResponse(
    QueueSyncMessage responseMessage,
    String fromNodeId,
  ) => hasPendingSyncWith(fromNodeId);

  @override
  void failPendingSync(String nodeId, String reason) {
    failedPendingSyncs.add(nodeId);
  }

  @override
  void cancelAllSyncs({String? reason}) {}

  @override
  void dispose() {}
}

class _TestMeshBleService implements IConnectionService {
  final _connectionController = StreamController<ConnectionInfo>.broadcast();
  final StreamController<BinaryPayload> _binaryController =
      StreamController<BinaryPayload>.broadcast();
  ConnectionInfo _connectionInfo = const ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'disconnected',
  );
  String? _currentSessionId;
  String? _ephemeralId;
  String? _persistentKey;
  final List<String> _activeDeviceAddresses = [];
  bool _canSend = false;
  bool _hasPeripheral = false;
  Future<bool> Function(QueueSyncMessage, String)? _queueSyncHandler;
  final List<String?> sentQueueSyncPeerIds = [];
  final List<String> sentMessages = [];
  Future<bool> Function(QueueSyncMessage message, String? peerId)?
  sendQueueSyncOverride;

  void simulateConnection({
    required String peerId,
    String? deviceAddress,
    String? ephemeralId,
    String? persistentKey,
  }) {
    _currentSessionId = peerId;
    _ephemeralId = ephemeralId ?? peerId;
    _persistentKey = persistentKey ?? peerId;
    _activeDeviceAddresses
      ..clear()
      ..add(deviceAddress ?? peerId);
    _canSend = true;
    _hasPeripheral = false;
    _connectionInfo = ConnectionInfo(
      isConnected: true,
      isReady: true,
      statusMessage: 'Connected to $peerId',
    );
    _connectionController.add(_connectionInfo);
  }

  void simulateDisconnection() {
    _currentSessionId = null;
    _ephemeralId = null;
    _persistentKey = null;
    _activeDeviceAddresses.clear();
    _canSend = false;
    _connectionInfo = const ConnectionInfo(
      isConnected: false,
      isReady: false,
      statusMessage: 'Disconnected',
    );
    _connectionController.add(_connectionInfo);
  }

  @override
  Stream<ConnectionInfo> get connectionInfo => _connectionController.stream;

  @override
  ConnectionInfo get currentConnectionInfo => _connectionInfo;

  @override
  String? get currentSessionId => _currentSessionId;

  @override
  String? get otherUserName => _currentSessionId ?? 'peer';

  @override
  String? get theirEphemeralId => _ephemeralId;

  @override
  String? get theirPersistentKey => _persistentKey;

  @override
  String? get myPersistentId => 'my-id';

  @override
  bool get canSendMessages => _canSend;

  @override
  bool get hasPeripheralConnection => _hasPeripheral;

  @override
  bool get isPeripheralMode => _hasPeripheral;

  @override
  bool get isConnected => _connectionInfo.isConnected;

  @override
  bool get canAcceptMoreConnections => true;

  @override
  int get activeConnectionCount => _currentSessionId == null ? 0 : 1;

  @override
  int get maxCentralConnections => 3;

  @override
  List<String> get activeConnectionDeviceIds =>
      List.unmodifiable(_activeDeviceAddresses);

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
  Future<void> disconnect() async {
    simulateDisconnection();
  }

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
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges => const Stream.empty();

  @override
  Future<String> getMyEphemeralId() async => 'ephemeral';

  @override
  Future<String> getMyPublicKey() async => 'public';

  @override
  String? get theirPersistentPublicKey => null;

  @override
  Stream<BinaryPayload> get receivedBinaryStream => _binaryController.stream;

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {
    _queueSyncHandler = handler;
  }

  Future<bool> invokeQueueSyncHandlerForTest(
    QueueSyncMessage message,
    String fromDeviceAddress,
  ) async {
    final handler = _queueSyncHandler;
    if (handler == null) return false;
    return handler(message, fromDeviceAddress);
  }

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    if (_canSend) {
      sentMessages.add(message);
    }
    return _canSend;
  }

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async => _canSend;

  @override
  Future<bool> sendProtocolMessage(ProtocolMessage message) async => _canSend;

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
  Future<bool> sendQueueSyncMessage(
    QueueSyncMessage message, {
    String? peerId,
  }) async {
    sentQueueSyncPeerIds.add(peerId);
    final override = sendQueueSyncOverride;
    if (override != null) {
      return override(message, peerId);
    }
    if (_queueSyncHandler != null && _activeDeviceAddresses.isNotEmpty) {
      await _queueSyncHandler!(message, _activeDeviceAddresses.first);
    }
    return true;
  }

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {}

  @override
  Future<void> stopScanning() async {}

  void dispose() {
    _connectionController.close();
    _binaryController.close();
  }
}

class _FakeMessageRepository implements IMessageRepository {
  final List<Message> savedMessages = [];

  @override
  Future<void> saveMessage(Message message) async => savedMessages.add(message);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
