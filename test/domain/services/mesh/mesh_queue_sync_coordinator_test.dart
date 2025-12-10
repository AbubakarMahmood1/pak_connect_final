import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/interfaces/i_ble_discovery_service.dart'
    show ScanningSource;
import 'package:pak_connect/core/interfaces/i_message_repository.dart';
import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/core/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult, QueueSyncResponse;
import 'package:pak_connect/core/models/connection_info.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/spy_mode_info.dart';
import 'package:pak_connect/core/bluetooth/bluetooth_state_monitor.dart';
import 'package:pak_connect/core/models/ble_server_connection.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';
import 'package:pak_connect/domain/services/mesh/mesh_queue_sync_coordinator.dart';
import 'package:logging/logging.dart';

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
        shouldRelayThroughDevice: (_, __) async => false,
        queueSyncManagerFactory: (queue, nodeId) => fakeManager,
      );

      await coordinator.initialize(
        nodeId: 'node-integration',
        messageQueue: queue,
        onStatusChanged: () => statusRefreshes++,
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

    test('retryMessage triggers immediate delivery + persistence', () async {
      bleService.simulateConnection(peerId: 'peer-1');
      final deliveryIds = <String>[];
      final deliverySub = monitor.messageDeliveryStream.listen(deliveryIds.add);

      final messageId = await coordinator.queueDirectMessage(
        chatId: 'chat',
        content: 'hello',
        recipientPublicKey: 'peer-1',
        senderPublicKey: 'node-integration',
      );

      final success = await coordinator.retryMessage(messageId);
      expect(success, isTrue);

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
  });
}

class _InMemoryQueue extends OfflineMessageQueue {
  final Map<String, QueuedMessage> _messages = {};
  bool _online = true;
  int _counter = 0;

  bool get isOnline => _online;

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
    final id = 'msg_${_counter++}';
    final queued = QueuedMessage(
      id: id,
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      queuedAt: DateTime.now(),
      maxRetries: 3,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      isRelayMessage: isRelayMessage,
      relayMetadata: relayMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: relayNodeId,
      messageHash: messageHash,
    );
    _messages[id] = queued;
    onMessageQueued?.call(queued);
    return id;
  }

  @override
  QueuedMessage? getMessageById(String messageId) => _messages[messageId];

  @override
  Future<void> markMessageDelivered(String messageId) async {
    final message = _messages[messageId];
    if (message != null) {
      message.status = QueuedMessageStatus.delivered;
      onMessageDelivered?.call(message);
    }
  }

  @override
  Future<void> markMessageFailed(String messageId, String reason) async {
    final message = _messages[messageId];
    if (message != null) {
      message
        ..status = QueuedMessageStatus.failed
        ..failureReason = reason;
      onMessageFailed?.call(message, reason);
    }
  }

  @override
  Future<void> removeMessage(String messageId) async {
    _messages.remove(messageId);
    onStatsUpdated?.call(getStatistics());
  }

  @override
  Future<bool> changePriority(
    String messageId,
    MessagePriority priority,
  ) async {
    final message = _messages[messageId];
    if (message == null) return false;
    message.priority = priority;
    return true;
  }

  @override
  Future<void> retryFailedMessages() async {
    for (final message in _messages.values) {
      if (message.status == QueuedMessageStatus.failed) {
        message.status = QueuedMessageStatus.pending;
      }
    }
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      _messages.values.where((m) => m.status == status).toList();

  @override
  QueueStatistics getStatistics() {
    final pending = getMessagesByStatus(QueuedMessageStatus.pending).length;
    final sending = getMessagesByStatus(QueuedMessageStatus.sending).length;
    final retrying = getMessagesByStatus(QueuedMessageStatus.retrying).length;
    final failed = getMessagesByStatus(QueuedMessageStatus.failed).length;

    return QueueStatistics(
      totalQueued: _messages.length,
      totalDelivered: 0,
      totalFailed: failed,
      pendingMessages: pending,
      sendingMessages: sending,
      retryingMessages: retrying,
      failedMessages: failed,
      isOnline: _online,
      averageDeliveryTime: Duration.zero,
    );
  }

  @override
  Future<void> setOnline() async {
    _online = true;
  }

  @override
  Future<void> setOffline() async {
    _online = false;
  }
}

class _FakeQueueSyncManager implements QueueSyncManagerContract {
  final List<List<String>> forcedSyncTargets = [];

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
  Future<QueueSyncResult> initiateSync(String targetNodeId) async =>
      QueueSyncResult.success(
        messagesReceived: 0,
        messagesUpdated: 0,
        messagesSkipped: 0,
        finalHash: 'hash',
        syncDuration: Duration.zero,
      );

  @override
  Future<QueueSyncResponse> handleSyncRequest(
    QueueSyncMessage syncMessage,
    String fromNodeId,
  ) async {
    return QueueSyncResponse.alreadySynced();
  }

  @override
  Future<QueueSyncResult> processSyncResponse(
    QueueSyncMessage responseMessage,
    List<QueuedMessage> receivedMessages,
    String fromNodeId,
  ) async => QueueSyncResult.success(
    messagesReceived: receivedMessages.length,
    messagesUpdated: 0,
    messagesSkipped: 0,
    finalHash: 'hash',
    syncDuration: Duration.zero,
  );

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
  bool _canSend = false;
  bool _hasPeripheral = false;
  Future<bool> Function(QueueSyncMessage, String)? _queueSyncHandler;

  void simulateConnection({required String peerId}) {
    _currentSessionId = peerId;
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
  String? get theirEphemeralId => _currentSessionId;

  @override
  String? get theirPersistentKey => _currentSessionId;

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
      _currentSessionId == null ? [] : [_currentSessionId!];

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

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async => _canSend;

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async => _canSend;

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
  Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {
    if (_queueSyncHandler != null && _currentSessionId != null) {
      await _queueSyncHandler!(message, _currentSessionId!);
    }
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
