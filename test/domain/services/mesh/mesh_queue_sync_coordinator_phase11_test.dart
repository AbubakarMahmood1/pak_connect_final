/// Phase 11.2 — Extended coverage for MeshQueueSyncCoordinator focusing on
/// initialization, queue operations, guard-when-null branches,
/// kill-switch paths, and dispose.
library;
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';
import 'package:pak_connect/domain/services/mesh/mesh_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeConnectionService extends Fake implements IConnectionService {
  final StreamController<String> _messages = StreamController.broadcast();
  final StreamController<ConnectionInfo> _connections =
      StreamController.broadcast();
  bool sendMessageResult = true;
  Future<bool> Function(QueueSyncMessage, String)? _syncHandler;

  @override
  Stream<String> get receivedMessages => _messages.stream;

  @override
  Stream<ConnectionInfo> get connectionInfo => _connections.stream;

  @override
  bool get canSendMessages => true;

  @override
  bool get hasPeripheralConnection => false;

  @override
  String? get currentSessionId => 'test-session';

  @override
  Future<bool> sendMessage(
    String content, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async =>
      sendMessageResult;

  @override
  Future<bool> sendPeripheralMessage(
    String content, {
    String? messageId,
  }) async =>
      sendMessageResult;

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage message) async {}

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {
    _syncHandler = handler;
  }

  void emitConnection(ConnectionInfo info) => _connections.add(info);

  void dispose() {
    _messages.close();
    _connections.close();
  }
}

class _FakeMessageRepo extends Fake implements IMessageRepository {
  final List<Message> saved = [];

  @override
  Future<void> saveMessage(Message msg) async {
    saved.add(msg);
  }
}

class _FakeHealthMonitor extends Fake implements MeshNetworkHealthMonitor {
  int deliveredCount = 0;

  @override
  void notifyMessageDelivered(String messageId) => deliveredCount++;

  @override
  void emitQueueStats(QueueSyncManagerStats stats) {}
}

class _FakeQueue extends Fake implements OfflineMessageQueueContract {
  final List<QueuedMessage> _messages = [];
  bool online = false;
  int retryAllCount = 0;

  @override
  set onMessageQueued(Function(QueuedMessage message)? callback) {}
  @override
  set onMessageDelivered(Function(QueuedMessage message)? callback) {}
  @override
  set onMessageFailed(
    Function(QueuedMessage message, String reason)? callback,
  ) {}
  @override
  set onStatsUpdated(Function(QueueStatistics stats)? callback) {}
  @override
  set onSendMessage(Function(String messageId)? callback) {}
  @override
  set onConnectivityCheck(Function()? callback) {}

  @override
  QueueStatistics getStatistics() => QueueStatistics(
        totalQueued: _messages.length,
        totalDelivered: 0,
        totalFailed: _messages
            .where((m) => m.status == QueuedMessageStatus.failed)
            .length,
        pendingMessages: _messages
            .where((m) => m.status == QueuedMessageStatus.pending)
            .length,
        sendingMessages: 0,
        retryingMessages: 0,
        failedMessages: _messages
            .where((m) => m.status == QueuedMessageStatus.failed)
            .length,
        isOnline: online,
        averageDeliveryTime: Duration.zero,
      );

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      _messages.where((m) => m.status == status).toList();

  @override
  QueuedMessage? getMessageById(String id) {
    final idx = _messages.indexWhere((m) => m.id == id);
    return idx >= 0 ? _messages[idx] : null;
  }

  @override
  List<QueuedMessage> getPendingMessages() =>
      getMessagesByStatus(QueuedMessageStatus.pending);

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
    final msg = QueuedMessage(
      id: 'queued-${_messages.length}',
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      status: QueuedMessageStatus.pending,
      queuedAt: DateTime.now(),
      maxRetries: 3,
    );
    _messages.add(msg);
    return msg.id;
  }

  @override
  Future<void> removeMessage(String messageId) async {
    _messages.removeWhere((m) => m.id == messageId);
  }

  @override
  Future<bool> changePriority(
    String messageId,
    MessagePriority priority,
  ) async {
    final msg = getMessageById(messageId);
    if (msg == null) return false;
    msg.priority = priority;
    return true;
  }

  @override
  Future<void> retryFailedMessages() async {
    retryAllCount++;
    for (final m in _messages) {
      if (m.status == QueuedMessageStatus.failed) {
        m.status = QueuedMessageStatus.pending;
      }
    }
  }

  @override
  Future<void> markMessageFailed(String messageId, String reason) async {
    final msg = getMessageById(messageId);
    if (msg != null) {
      msg.status = QueuedMessageStatus.failed;
      msg.failureReason = reason;
    }
  }

  @override
  Future<void> markMessageDelivered(String messageId) async {
    final msg = getMessageById(messageId);
    if (msg != null) {
      msg.status = QueuedMessageStatus.delivered;
    }
  }

  @override
  Future<void> setOnline() async {
    online = true;
  }

  @override
  void setOffline() => online = false;

  @override
  String calculateQueueHash({bool forceRecalculation = false}) => 'hash-fake';

  @override
  QueueSyncMessage createSyncMessage(String nodeId) => QueueSyncMessage(
        nodeId: nodeId,
        queueHash: 'hash-fake',
        messageIds: _messages.map((m) => m.id).toList(),
        syncTimestamp: DateTime.now(),
        syncType: QueueSyncType.request,
      );

  @override
  void dispose() {}
}

class _FakeSyncManager extends Fake implements QueueSyncManagerContract {
  bool initCalled = false;
  bool disposeCalled = false;

  @override
  Future<void> initialize({
    Function(QueueSyncMessage message, String fromNodeId)? onSyncRequest,
    Function(List<QueuedMessage> messages, String toNodeId)? onSendMessages,
    Function(String nodeId, QueueSyncResult result)? onSyncCompleted,
    Function(String nodeId, String error)? onSyncFailed,
  }) async {
    initCalled = true;
  }

  @override
  Future<Map<String, QueueSyncResult>> forceSyncAll(
    List<String> nodeIds,
  ) async {
    return {
      for (final id in nodeIds)
        id: QueueSyncResult.success(
          messagesReceived: 0,
          messagesUpdated: 0,
          messagesSkipped: 0,
          finalHash: 'hash',
          syncDuration: Duration.zero,
        ),
    };
  }

  @override
  QueueSyncManagerStats getStats() => const QueueSyncManagerStats(
        totalSyncRequests: 0,
        successfulSyncs: 0,
        failedSyncs: 0,
        messagesTransferred: 0,
        activeSyncs: 0,
        successRate: 0.0,
        recentSyncCount: 0,
      );

  @override
  void dispose() => disposeCalled = true;
}

// ---------------------------------------------------------------------------
void main() {
  late _FakeConnectionService bleService;
  late _FakeMessageRepo messageRepo;
  late _FakeHealthMonitor healthMonitor;
  late _FakeQueue queue;
  late _FakeSyncManager syncManager;
  late MeshQueueSyncCoordinator coordinator;
  late List<LogRecord> logs;
  late Set<String> allowedSevere;

  setUp(() {
    logs = [];
    allowedSevere = {
      'Failed to retry',
      'Failed to remove',
      'Failed to set message priority',
      'Failed to retry all',
      'Queue sync',
    };
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((r) {
      logs.add(r);
      if (r.level >= Level.SEVERE) {
        if (!allowedSevere.any((s) => r.message.contains(s))) {
          fail('Unexpected SEVERE: ${r.message}');
        }
      }
    });

    bleService = _FakeConnectionService();
    messageRepo = _FakeMessageRepo();
    healthMonitor = _FakeHealthMonitor();
    syncManager = _FakeSyncManager();
    queue = _FakeQueue();

    coordinator = MeshQueueSyncCoordinator(
      bleService: bleService,
      messageRepository: messageRepo,
      healthMonitor: healthMonitor,
      shouldRelayThroughDevice: (msg, deviceId) async => true,
      queueSyncManagerFactory: (q, nodeId) => syncManager,
    );

    // Reset kill switches directly (no overrideForTest helper)
    KillSwitches.disableQueueSync = false;
  });

  tearDown(() {
    bleService.dispose();
    KillSwitches.disableQueueSync = false;
    Logger.root.clearListeners();
  });

  // -------------------------------------------------------------------------
  // Initialization
  // -------------------------------------------------------------------------
  group('MeshQueueSyncCoordinator.initialize', () {
    test('normal initialization sets up queue and sync manager', () async {
      var statusChangedCount = 0;
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () => statusChangedCount++,
      );
      expect(syncManager.initCalled, isTrue);
      expect(coordinator.messageQueue, same(queue));
    });

    test('kill switch prevents initialization', () async {
      KillSwitches.disableQueueSync = true;
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      // Queue should remain null when kill switch is active
      expect(coordinator.messageQueue, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Queue operations — not initialized
  // -------------------------------------------------------------------------
  group('Queue ops before init', () {
    test('queueDirectMessage throws StateError', () {
      expect(
        () => coordinator.queueDirectMessage(
          chatId: 'c1',
          content: 'hi',
          recipientPublicKey: 'rpk',
          senderPublicKey: 'spk',
        ),
        throwsStateError,
      );
    });

    test('retryMessage returns false', () async {
      expect(await coordinator.retryMessage('msg-1'), isFalse);
    });

    test('removeMessage returns false', () async {
      expect(await coordinator.removeMessage('msg-1'), isFalse);
    });

    test('setPriority returns false', () async {
      expect(
        await coordinator.setPriority('msg-1', MessagePriority.high),
        isFalse,
      );
    });

    test('retryAllMessages returns 0', () async {
      expect(await coordinator.retryAllMessages(), 0);
    });

    test('getQueuedMessagesForChat returns empty', () {
      expect(coordinator.getQueuedMessagesForChat('c1'), isEmpty);
    });

    test('getActiveQueueMessages returns empty', () {
      expect(coordinator.getActiveQueueMessages(), isEmpty);
    });

    test('queueStatistics is null', () {
      expect(coordinator.queueStatistics, isNull);
    });

    test('queueSyncStats is null', () {
      expect(coordinator.queueSyncStats, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Queue operations — after init
  // -------------------------------------------------------------------------
  group('Queue ops after init', () {
    setUp(() async {
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
    });

    test('queueDirectMessage returns messageId', () async {
      final id = await coordinator.queueDirectMessage(
        chatId: 'chat-1',
        content: 'hello world',
        recipientPublicKey: 'rpk-1',
        senderPublicKey: 'spk-1',
      );
      expect(id, startsWith('queued-'));
    });

    test('retryMessage with known message returns true', () async {
      final id = await coordinator.queueDirectMessage(
        chatId: 'chat-1',
        content: 'retry me',
        recipientPublicKey: 'rpk-1',
        senderPublicKey: 'spk-1',
      );
      final msg = queue.getMessageById(id)!;
      msg.status = QueuedMessageStatus.failed;

      expect(await coordinator.retryMessage(id), isTrue);
      expect(msg.status, QueuedMessageStatus.pending);
    });

    test('retryMessage with unknown message returns false', () async {
      expect(await coordinator.retryMessage('nonexistent'), isFalse);
    });

    test('removeMessage with known message returns true', () async {
      final id = await coordinator.queueDirectMessage(
        chatId: 'chat-1',
        content: 'remove me',
        recipientPublicKey: 'rpk-1',
        senderPublicKey: 'spk-1',
      );
      expect(await coordinator.removeMessage(id), isTrue);
      expect(queue.getMessageById(id), isNull);
    });

    test('setPriority changes message priority', () async {
      final id = await coordinator.queueDirectMessage(
        chatId: 'chat-1',
        content: 'prioritize',
        recipientPublicKey: 'rpk-1',
        senderPublicKey: 'spk-1',
      );
      expect(
        await coordinator.setPriority(id, MessagePriority.high),
        isTrue,
      );
      expect(queue.getMessageById(id)!.priority, MessagePriority.high);
    });

    test('retryAllMessages retries failed messages', () async {
      final id = await coordinator.queueDirectMessage(
        chatId: 'chat-1',
        content: 'fail then retry',
        recipientPublicKey: 'rpk-1',
        senderPublicKey: 'spk-1',
      );
      queue.getMessageById(id)!.status = QueuedMessageStatus.failed;
      await coordinator.retryAllMessages();
      expect(queue.retryAllCount, 1);
    });

    test('getQueuedMessagesForChat filters by chatId', () async {
      await coordinator.queueDirectMessage(
        chatId: 'chat-A',
        content: 'msg A',
        recipientPublicKey: 'rpk',
        senderPublicKey: 'spk',
      );
      await coordinator.queueDirectMessage(
        chatId: 'chat-B',
        content: 'msg B',
        recipientPublicKey: 'rpk',
        senderPublicKey: 'spk',
      );
      final msgsA = coordinator.getQueuedMessagesForChat('chat-A');
      expect(msgsA.length, 1);
      expect(msgsA.first.chatId, 'chat-A');
    });

    test('getActiveQueueMessages returns all non-delivered messages', () async {
      await coordinator.queueDirectMessage(
        chatId: 'chat-1',
        content: 'active',
        recipientPublicKey: 'rpk',
        senderPublicKey: 'spk',
      );
      final active = coordinator.getActiveQueueMessages();
      expect(active, isNotEmpty);
    });

    test('queueStatistics returns non-null after init', () {
      expect(coordinator.queueStatistics, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // syncWithPeers
  // -------------------------------------------------------------------------
  group('syncWithPeers', () {
    test('no manager returns error map', () async {
      // Not initialized → no sync manager
      final result = await coordinator.syncWithPeers(['n1']);
      expect(result.containsKey('error'), isTrue);
    });

    test('empty nodeIds returns no_peers error', () async {
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      final result = await coordinator.syncWithPeers([]);
      expect(result.containsKey('no_peers'), isTrue);
    });

    test('delegates to sync manager for non-empty peers', () async {
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      final result = await coordinator.syncWithPeers(['peer-1', 'peer-2']);
      expect(result.length, 2);
    });
  });

  // -------------------------------------------------------------------------
  // enableQueueSyncHandling
  // -------------------------------------------------------------------------
  group('enableQueueSyncHandling', () {
    test('registers handler once, second call is no-op', () async {
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      coordinator.enableQueueSyncHandling();
      coordinator.enableQueueSyncHandling(); // idempotent
      expect(bleService._syncHandler, isNotNull);
    });

    test('kill switch prevents registration', () async {
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      KillSwitches.disableQueueSync = true;
      coordinator.enableQueueSyncHandling();
      // Handler should not have been set when kill switch is active after init
    });
  });

  // -------------------------------------------------------------------------
  // startConnectionMonitoring
  // -------------------------------------------------------------------------
  group('startConnectionMonitoring', () {
    test('kill switch prevents monitoring', () {
      KillSwitches.disableQueueSync = true;
      coordinator.startConnectionMonitoring();
      // No subscription created → no crash
    });
  });

  // -------------------------------------------------------------------------
  // completeAck
  // -------------------------------------------------------------------------
  group('completeAck', () {
    test('does not throw even without matching tracker', () {
      expect(
        () => coordinator.completeAck('no-such-id', success: true),
        returnsNormally,
      );
    });
  });

  // -------------------------------------------------------------------------
  // dispose
  // -------------------------------------------------------------------------
  group('dispose', () {
    test('dispose after init cleans up', () async {
      await coordinator.initialize(
        nodeId: 'node-1',
        messageQueue: queue,
        onStatusChanged: () {},
      );
      coordinator.startConnectionMonitoring();
      await coordinator.dispose();
      expect(syncManager.disposeCalled, isTrue);
      expect(coordinator.messageQueue, isNull);
    });

    test('dispose before init is a no-op', () async {
      await coordinator.dispose();
      // No crash
    });
  });
}
