import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/offline_queue_facade.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class _SpyOfflineMessageQueue extends OfflineMessageQueue {
  final Map<String, QueuedMessage> _messages = <String, QueuedMessage>{};
  final Set<String> _deleted = <String>{};

  int initializeCalls = 0;
  int setOnlineCalls = 0;
  int setOfflineCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
    Function()? onConnectivityCheck,
    IRepositoryProvider? repositoryProvider,
    IDatabaseProvider? databaseProvider,
  }) async {
    initializeCalls++;
    this.onMessageQueued = onMessageQueued;
    this.onMessageDelivered = onMessageDelivered;
    this.onMessageFailed = onMessageFailed;
    this.onStatsUpdated = onStatsUpdated;
    this.onSendMessage = onSendMessage;
    this.onConnectivityCheck = onConnectivityCheck;
  }

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
    final id = 'msg-${_messages.length + 1}';
    final message = QueuedMessage(
      id: id,
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      queuedAt: DateTime.now(),
      maxRetries: 3,
      attachments: attachments,
      replyToMessageId: replyToMessageId,
      isRelayMessage: isRelayMessage,
      relayMetadata: relayMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: relayNodeId,
      messageHash: messageHash,
    );
    _messages[id] = message;
    onMessageQueued?.call(message);
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
    final id = await queueMessage(
      chatId: chatId.value,
      content: content,
      recipientPublicKey: recipientId.value,
      senderPublicKey: senderId.value,
      priority: priority,
      replyToMessageId: replyToMessageId?.value,
      attachments: attachments,
      isRelayMessage: isRelayMessage,
      relayMetadata: relayMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: relayNodeId,
      messageHash: messageHash,
      persistToStorage: persistToStorage,
    );
    return MessageId(id);
  }

  @override
  Future<int> removeMessagesForChat(String chatId) async {
    final toRemove = _messages.values
        .where((message) => message.chatId == chatId)
        .map((message) => message.id)
        .toList();
    for (final id in toRemove) {
      _messages.remove(id);
    }
    return toRemove.length;
  }

  @override
  Future<void> setOnline() async {
    setOnlineCalls++;
  }

  @override
  void setOffline() {
    setOfflineCalls++;
  }

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
      message.status = QueuedMessageStatus.failed;
      message.failureReason = reason;
      onMessageFailed?.call(message, reason);
    }
  }

  @override
  QueueStatistics getStatistics() {
    final pending = _messages.values
        .where((m) => m.status == QueuedMessageStatus.pending)
        .length;
    final failed = _messages.values
        .where((m) => m.status == QueuedMessageStatus.failed)
        .length;
    return QueueStatistics(
      totalQueued: _messages.length,
      totalDelivered: _messages.values
          .where((m) => m.status == QueuedMessageStatus.delivered)
          .length,
      totalFailed: failed,
      pendingMessages: pending,
      sendingMessages: 0,
      retryingMessages: 0,
      failedMessages: failed,
      isOnline: setOnlineCalls > setOfflineCalls,
      averageDeliveryTime: Duration.zero,
      directQueueSize: _messages.length,
      relayQueueSize: 0,
    );
  }

  @override
  Future<void> retryFailedMessages() async {}

  @override
  Future<void> retryFailedMessagesForChat(String chatId) async {}

  @override
  Future<void> clearQueue() async {
    _messages.clear();
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return _messages.values.where((m) => m.status == status).toList();
  }

  @override
  QueuedMessage? getMessageById(String messageId) {
    return _messages[messageId];
  }

  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  @override
  Future<void> removeMessage(String messageId) async {
    _messages.remove(messageId);
  }

  @override
  Future<void> flushQueueForPeer(String peerPublicKey) async {
    _messages.removeWhere(
      (_, message) => message.recipientPublicKey == peerPublicKey,
    );
  }

  @override
  Future<bool> changePriority(
    String messageId,
    MessagePriority newPriority,
  ) async {
    final message = _messages[messageId];
    if (message == null) return false;
    message.priority = newPriority;
    return true;
  }

  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    final ids = _messages.keys.toList()..sort();
    return ids.join('|');
  }

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return QueueSyncMessage.createRequest(
      messageIds: _messages.keys.toList(),
      nodeId: nodeId,
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) {
    return calculateQueueHash() != otherQueueHash;
  }

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    _messages[message.id] = message;
  }

  @override
  List<String> getMissingMessageIds(List<String> peerMessageIds) {
    return peerMessageIds.where((id) => !_messages.containsKey(id)).toList();
  }

  @override
  List<QueuedMessage> getExcessMessages(List<String> peerMessageIds) {
    return _messages.values
        .where((message) => !peerMessageIds.contains(message.id))
        .toList();
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    _deleted.add(messageId);
  }

  @override
  bool isMessageDeleted(String messageId) {
    return _deleted.contains(messageId);
  }

  @override
  Future<void> cleanupOldDeletedIds() async {
    _deleted.clear();
  }

  @override
  void invalidateHashCache() {}

  @override
  Map<String, dynamic> getPerformanceStats() {
    return <String, dynamic>{
      'queued': _messages.length,
      'deleted': _deleted.length,
      'onlineCalls': setOnlineCalls,
      'offlineCalls': setOfflineCalls,
    };
  }

  @override
  void dispose() {
    disposeCalls++;
  }
}

void main() {
  group('OfflineQueueFacade', () {
    late _SpyOfflineMessageQueue queue;
    late OfflineQueueFacade facade;

    setUp(() {
      queue = _SpyOfflineMessageQueue();
      facade = OfflineQueueFacade(queue: queue);
    });

    test(
      'lazy getters initialize sub-services and expose underlying queue',
      () {
        final repo = facade.queueRepository;
        final retry = facade.retryScheduler;
        final sync = facade.syncCoordinator;
        final persistence = facade.persistenceManager;

        expect(repo, isNotNull);
        expect(retry, isNotNull);
        expect(sync, isNotNull);
        expect(persistence, isNotNull);
        expect(identical(repo, facade.queueRepository), isTrue);
        expect(identical(retry, facade.retryScheduler), isTrue);
        expect(identical(sync, facade.syncCoordinator), isTrue);
        expect(identical(persistence, facade.persistenceManager), isTrue);
        expect(facade.queue, same(queue));
      },
    );

    test('delegates queue lifecycle and operations', () async {
      final queuedEvents = <String>[];
      final deliveredEvents = <String>[];
      final failedEvents = <String>[];

      facade.onMessageQueued = (message) => queuedEvents.add(message.id);
      facade.onMessageDelivered = (message) => deliveredEvents.add(message.id);
      facade.onMessageFailed = (message, reason) {
        failedEvents.add('${message.id}|$reason');
      };

      await facade.initialize(
        onMessageQueued: (message) => queuedEvents.add(message.id),
        onMessageDelivered: (message) => deliveredEvents.add(message.id),
        onMessageFailed: (message, reason) {
          failedEvents.add('${message.id}|$reason');
        },
      );
      expect(queue.initializeCalls, 1);

      final queuedId = await facade.queueMessage(
        chatId: 'chat-1',
        content: 'hello',
        recipientPublicKey: 'peer-A',
        senderPublicKey: 'me',
        priority: MessagePriority.high,
      );
      final queuedTypedId = await facade.queueMessageWithIds(
        chatId: const ChatId('chat-typed'),
        content: 'typed hello',
        recipientId: const ChatId('peer-B'),
        senderId: const ChatId('me-typed'),
        priority: MessagePriority.normal,
      );

      expect(queuedId, isNotEmpty);
      expect(queuedTypedId.value, isNotEmpty);
      expect(queuedEvents, isNotEmpty);

      await facade.markMessageDelivered(queuedId);
      await facade.markMessageFailed(queuedTypedId.value, 'network');
      expect(deliveredEvents, contains(queuedId));
      expect(failedEvents.single, contains('network'));

      final stats = facade.getStatistics();
      expect(stats.totalQueued, 2);

      await facade.setOnline();
      facade.setOffline();
      expect(queue.setOnlineCalls, 1);
      expect(queue.setOfflineCalls, 1);

      await facade.retryFailedMessages();
      await facade.retryFailedMessagesForChat('chat-typed');

      final pending = facade.getPendingMessages();
      final failed = facade.getMessagesByStatus(QueuedMessageStatus.failed);
      final fetched = facade.getMessageById(queuedTypedId.value);
      expect(pending, isEmpty);
      expect(failed, isNotEmpty);
      expect(fetched, isNotNull);

      await facade.changePriority(queuedTypedId.value, MessagePriority.urgent);
      await facade.flushQueueForPeer('peer-B');
      final removedForChat = await facade.removeMessagesForChat('chat-1');
      expect(removedForChat, 1);

      await facade.addSyncedMessage(
        QueuedMessage(
          id: 'synced-1',
          chatId: 'sync-chat',
          content: 'synced',
          recipientPublicKey: 'peer-sync',
          senderPublicKey: 'me',
          priority: MessagePriority.normal,
          queuedAt: DateTime.now(),
          maxRetries: 3,
        ),
      );

      final hash = facade.calculateQueueHash(forceRecalculation: true);
      final syncMessage = facade.createSyncMessage('node-1');
      expect(hash, isNotEmpty);
      expect(syncMessage.nodeId, 'node-1');
      expect(facade.needsSynchronization('different-hash'), isTrue);

      final missing = facade.getMissingMessageIds(<String>['unknown-id']);
      final excess = facade.getExcessMessages(<String>['unknown-id']);
      expect(missing, ['unknown-id']);
      expect(excess, isNotEmpty);

      await facade.markMessageDeleted('deleted-1');
      expect(facade.isMessageDeleted('deleted-1'), isTrue);
      await facade.cleanupOldDeletedIds();
      expect(facade.isMessageDeleted('deleted-1'), isFalse);

      facade.invalidateHashCache();
      final perf = facade.getPerformanceStats();
      expect(perf['onlineCalls'], 1);
      expect(perf['offlineCalls'], 1);

      await facade.removeMessage('synced-1');
      await facade.clearQueue();

      facade.dispose();
      expect(queue.disposeCalls, 1);
    });
  });
}
