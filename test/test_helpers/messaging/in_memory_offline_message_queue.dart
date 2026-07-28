import 'dart:async';

import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class InMemoryOfflineMessageQueue implements OfflineMessageQueueContract {
  InMemoryOfflineMessageQueue();

  final Map<String, QueuedMessage> _messagesById = <String, QueuedMessage>{};
  final Set<String> _deletedMessageIds = <String>{};

  int _counter = 0;
  bool _isOnline = true;
  int _totalQueued = 0;
  int _totalDelivered = 0;
  int _totalFailed = 0;

  bool get isOnline => _isOnline;

  Function(QueuedMessage message)? _onMessageQueued;
  Function(QueuedMessage message)? _onMessageDelivered;
  Function(QueuedMessage message, String reason)? _onMessageFailed;
  Function(QueueStatistics stats)? _onStatsUpdated;
  OfflineQueueSendCallback? _onSendMessage;

  @override
  set onMessageQueued(Function(QueuedMessage message)? callback) {
    _onMessageQueued = callback;
  }

  @override
  set onMessageDelivered(Function(QueuedMessage message)? callback) {
    _onMessageDelivered = callback;
  }

  @override
  set onMessageFailed(
    Function(QueuedMessage message, String reason)? callback,
  ) {
    _onMessageFailed = callback;
  }

  @override
  set onStatsUpdated(Function(QueueStatistics stats)? callback) {
    _onStatsUpdated = callback;
  }

  @override
  set onSendMessage(OfflineQueueSendCallback? callback) {
    _onSendMessage = callback;
  }

  @override
  set onConnectivityCheck(Function()? callback) {
    // Not needed in this in-memory test queue.
  }

  @override
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    OfflineQueueSendCallback? onSendMessage,
    Function()? onConnectivityCheck,
  }) async {
    this.onMessageQueued = onMessageQueued;
    this.onMessageDelivered = onMessageDelivered;
    this.onMessageFailed = onMessageFailed;
    this.onStatsUpdated = onStatsUpdated;
    this.onSendMessage = onSendMessage;
    this.onConnectivityCheck = onConnectivityCheck;
    _emitStats();
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
    final id = 'msg_${_counter++}';
    final now = DateTime.now();
    final message = QueuedMessage(
      id: id,
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      queuedAt: now,
      maxRetries: 5,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      isRelayMessage: isRelayMessage,
      relayMetadata: relayMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: relayNodeId,
      messageHash: messageHash,
    );

    _messagesById[id] = message;
    _totalQueued++;
    _onMessageQueued?.call(message);
    _emitStats();

    if (_isOnline) {
      await _attemptDelivery(message);
    }

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
    final before = _messagesById.length;
    _messagesById.removeWhere((_, message) => message.chatId == chatId);
    _emitStats();
    return before - _messagesById.length;
  }

  @override
  Future<void> setOnline() async {
    if (_isOnline) return;
    _isOnline = true;
    final now = DateTime.now();
    for (final message in List<QueuedMessage>.of(_messagesById.values)) {
      if (message.status == QueuedMessageStatus.sending) {
        message.status = QueuedMessageStatus.pending;
        message.nextRetryAt = null;
      } else if (message.status == QueuedMessageStatus.retrying &&
          (message.nextRetryAt == null || !message.nextRetryAt!.isAfter(now))) {
        message.status = QueuedMessageStatus.pending;
        message.nextRetryAt = null;
      }
      if (message.status == QueuedMessageStatus.pending) {
        await _attemptDelivery(message);
      }
    }
    _emitStats();
  }

  @override
  void setOffline() {
    _isOnline = false;
    _emitStats();
  }

  @override
  Future<void> markMessageDelivered(String messageId) async {
    final message = _messagesById.remove(messageId);
    if (message == null) {
      return;
    }
    message
      ..status = QueuedMessageStatus.delivered
      ..deliveredAt = DateTime.now();
    _totalDelivered++;
    _onMessageDelivered?.call(message);
    _emitStats();
  }

  @override
  Future<void> markMessageFailed(String messageId, String reason) async {
    final message = _messagesById[messageId];
    if (message == null) {
      return;
    }
    message
      ..status = QueuedMessageStatus.failed
      ..failureReason = reason
      ..failedAt = DateTime.now();
    _totalFailed++;
    _onMessageFailed?.call(message, reason);
    _emitStats();
  }

  @override
  QueueStatistics getStatistics() {
    final values = _messagesById.values;
    final pending = values
        .where((message) => message.status == QueuedMessageStatus.pending)
        .length;
    final sending = values
        .where((message) => message.status == QueuedMessageStatus.sending)
        .length;
    final retrying = values
        .where((message) => message.status == QueuedMessageStatus.retrying)
        .length;
    final failed = values
        .where((message) => message.status == QueuedMessageStatus.failed)
        .length;

    return QueueStatistics(
      totalQueued: _totalQueued,
      totalDelivered: _totalDelivered,
      totalFailed: _totalFailed,
      pendingMessages: pending,
      sendingMessages: sending,
      retryingMessages: retrying,
      failedMessages: failed,
      isOnline: _isOnline,
      averageDeliveryTime: Duration.zero,
      directQueueSize: values
          .where((message) => !message.isRelayMessage)
          .length,
      relayQueueSize: values.where((message) => message.isRelayMessage).length,
    );
  }

  @override
  Future<void> retryFailedMessages() async {
    for (final message in _messagesById.values) {
      if (message.status == QueuedMessageStatus.failed) {
        message
          ..status = QueuedMessageStatus.pending
          ..failureReason = null
          ..failedAt = null;
      }
    }
    _emitStats();
  }

  @override
  Future<void> retryFailedMessagesForChat(String chatId) async {
    for (final message in _messagesById.values) {
      if (message.chatId == chatId &&
          message.status == QueuedMessageStatus.failed) {
        message
          ..status = QueuedMessageStatus.pending
          ..failureReason = null
          ..failedAt = null;
      }
    }
    _emitStats();
  }

  @override
  Future<bool> retryMessage(String messageId) async {
    final message = _messagesById[messageId];
    if (message == null || message.status == QueuedMessageStatus.sending) {
      return false;
    }
    message
      ..status = QueuedMessageStatus.pending
      ..attempts = 0
      ..lastAttemptAt = null
      ..nextRetryAt = null
      ..deliveredAt = null
      ..failedAt = null
      ..failureReason = null;
    if (_isOnline) {
      await _attemptDelivery(message);
    }
    _emitStats();
    return true;
  }

  @override
  Future<Set<String>> attemptMessages(
    Iterable<String> messageIds, {
    OfflineQueuePrepareSendCallback? prepareSend,
  }) async {
    final attempted = <String>{};
    for (final messageId in messageIds.toSet()) {
      final message = _messagesById[messageId];
      if (message == null) continue;
      if (prepareSend != null) {
        final prepared = await prepareSend(messageId);
        if (prepared == null) continue;
        if (_startPreparedDelivery(message, prepared)) {
          attempted.add(messageId);
        }
        continue;
      }
      final disposition = await _attemptDelivery(message);
      if (disposition != null &&
          disposition != OfflineQueueSendDisposition.deferred) {
        attempted.add(messageId);
      }
    }
    return attempted;
  }

  @override
  Future<void> clearQueue() async {
    _messagesById.clear();
    _emitStats();
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return _messagesById.values
        .where((message) => message.status == status)
        .toList(growable: false);
  }

  @override
  QueuedMessage? getMessageById(String messageId) {
    return _messagesById[messageId];
  }

  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  @override
  Future<void> removeMessage(String messageId) async {
    _messagesById.remove(messageId);
    _emitStats();
  }

  @override
  Future<void> flushQueueForPeer(String peerPublicKey) async {
    if (!_isOnline) {
      return;
    }
    for (final message in List<QueuedMessage>.of(_messagesById.values)) {
      if (message.recipientPublicKey == peerPublicKey &&
          message.status == QueuedMessageStatus.pending) {
        await _attemptDelivery(message);
      }
    }
    _emitStats();
  }

  @override
  Future<bool> changePriority(
    String messageId,
    MessagePriority newPriority,
  ) async {
    final message = _messagesById[messageId];
    if (message == null) {
      return false;
    }
    message.priority = newPriority;
    return true;
  }

  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    final active = _messagesById.keys.toList()..sort();
    final deleted = _deletedMessageIds.toList()..sort();
    return [...active, ...deleted].join(':');
  }

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return QueueSyncMessage.createRequest(
      messageIds: _messagesById.keys.toList(growable: false),
      nodeId: nodeId,
      queueHash: calculateQueueHash(),
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) {
    return calculateQueueHash() != otherQueueHash;
  }

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    if (_deletedMessageIds.contains(message.id)) {
      return;
    }
    _messagesById.putIfAbsent(message.id, () => message);
    _emitStats();
  }

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    final localIds = _messagesById.keys.toSet();
    return otherMessageIds
        .where((id) => !localIds.contains(id))
        .toList(growable: false);
  }

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final otherIds = otherMessageIds.toSet();
    return _messagesById.values
        .where((message) => !otherIds.contains(message.id))
        .toList(growable: false);
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    _deletedMessageIds.add(messageId);
    _messagesById.remove(messageId);
    _emitStats();
  }

  @override
  bool isMessageDeleted(String messageId) {
    return _deletedMessageIds.contains(messageId);
  }

  @override
  Future<void> cleanupOldDeletedIds() async {}

  @override
  void invalidateHashCache() {}

  @override
  Map<String, dynamic> getPerformanceStats() {
    return <String, dynamic>{
      'totalMessages': _messagesById.length,
      'deletedIdsCount': _deletedMessageIds.length,
      'isOnline': _isOnline,
    };
  }

  @override
  void dispose() {}

  Future<OfflineQueueSendDisposition?> _attemptDelivery(
    QueuedMessage message,
  ) async {
    if (!_isOnline ||
        !identical(_messagesById[message.id], message) ||
        message.status != QueuedMessageStatus.pending) {
      return null;
    }
    final previousAttempts = message.attempts;
    final previousLastAttemptAt = message.lastAttemptAt;
    message
      ..status = QueuedMessageStatus.sending
      ..attempts = message.attempts + 1
      ..lastAttemptAt = DateTime.now();

    return _finishDelivery(
      message,
      previousAttempts: previousAttempts,
      previousLastAttemptAt: previousLastAttemptAt,
      execute: () =>
          _onSendMessage?.call(message.id) ??
          OfflineQueueSendDisposition.failed,
    );
  }

  bool _startPreparedDelivery(
    QueuedMessage message,
    OfflineQueuePreparedSend prepared,
  ) {
    if (!_isOnline ||
        !identical(_messagesById[message.id], message) ||
        message.status != QueuedMessageStatus.pending) {
      return false;
    }
    final previousAttempts = message.attempts;
    final previousLastAttemptAt = message.lastAttemptAt;
    message
      ..status = QueuedMessageStatus.sending
      ..attempts = message.attempts + 1
      ..lastAttemptAt = DateTime.now();
    Future<OfflineQueuePreparedSendDisposition>? startedOutcome;
    try {
      startedOutcome = prepared.tryStart();
    } catch (error) {
      unawaited(
        _finishDelivery(
          message,
          previousAttempts: previousAttempts,
          previousLastAttemptAt: previousLastAttemptAt,
          execute: () => throw error,
        ),
      );
      return false;
    }
    final admittedOutcome = startedOutcome;
    if (admittedOutcome == null) {
      message
        ..status = QueuedMessageStatus.pending
        ..attempts = previousAttempts
        ..lastAttemptAt = previousLastAttemptAt;
      return false;
    }
    unawaited(
      _finishDelivery(
        message,
        previousAttempts: previousAttempts,
        previousLastAttemptAt: previousLastAttemptAt,
        execute: () => admittedOutcome.then(
          (disposition) => disposition.asSendDisposition,
        ),
      ),
    );
    return true;
  }

  Future<OfflineQueueSendDisposition> _finishDelivery(
    QueuedMessage message, {
    required int previousAttempts,
    required DateTime? previousLastAttemptAt,
    required FutureOr<OfflineQueueSendDisposition> Function() execute,
  }) async {
    var disposition = OfflineQueueSendDisposition.failed;
    try {
      disposition = await execute();
    } catch (_) {
      disposition = OfflineQueueSendDisposition.failed;
    }
    if (!identical(_messagesById[message.id], message) ||
        message.status != QueuedMessageStatus.sending) {
      return disposition;
    }
    switch (disposition) {
      case OfflineQueueSendDisposition.deferred:
        message
          ..status = QueuedMessageStatus.pending
          ..attempts = previousAttempts
          ..lastAttemptAt = previousLastAttemptAt;
      case OfflineQueueSendDisposition.failed:
        message
          ..status = QueuedMessageStatus.retrying
          ..failureReason = 'Transport rejected queued message';
      case OfflineQueueSendDisposition.awaitingAck:
        message.status = QueuedMessageStatus.awaitingAck;
      case OfflineQueueSendDisposition.delivered:
        await markMessageDelivered(message.id);
    }
    return disposition;
  }

  void _emitStats() {
    _onStatsUpdated?.call(getStatistics());
  }
}
