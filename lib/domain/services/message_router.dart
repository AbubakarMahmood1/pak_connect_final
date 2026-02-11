import 'dart:async';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Routes messages with offline queue support (based on BitChat's MessageRouter)
///
/// **ARCHITECTURE CHANGE**: This is now a thin wrapper around OfflineMessageQueue
/// to maintain backward compatibility while using the unified queue system.
///
/// Previously maintained its own in-memory queue, now delegates to:
/// - OfflineMessageQueue (persistent SQLite queue with priority/retry/relay)
///
/// Key features (delegated):
/// - Automatic offline queueing when peer not connected
/// - Auto-flush when peer comes online
/// - Persistent storage (SQLite)
/// - Priority-based delivery
/// - Intelligent retry with exponential backoff
///
/// BitChat Android equivalent: MessageRouter.kt (lines 12-214)
class MessageRouter {
  static final _logger = Logger('MessageRouter');
  static OfflineMessageQueueContract Function()? _standaloneQueueFactory;
  static Future<OfflineMessageQueueContract> Function()?
  _initializedQueueFactory;

  // Singleton
  static MessageRouter? _instance;
  static MessageRouter get instance {
    if (_instance == null) {
      throw StateError(
        'MessageRouter not initialized. Call initialize() first.',
      );
    }
    return _instance!;
  }

  // Dependencies
  late final IConnectionService _bleService;
  late final OfflineMessageQueueContract _offlineQueue;

  OfflineMessageQueueContract get offlineQueue => _offlineQueue;

  MessageRouter._();

  /// Configure concrete queue factories from infrastructure/bootstrap code.
  static void configureQueueFactories({
    OfflineMessageQueueContract Function()? standaloneQueueFactory,
    Future<OfflineMessageQueueContract> Function()? initializedQueueFactory,
  }) {
    _standaloneQueueFactory = standaloneQueueFactory;
    _initializedQueueFactory = initializedQueueFactory;
  }

  /// Initialize the message router
  static Future<void> initialize(
    IConnectionService bleService, {
    OfflineMessageQueueContract? offlineQueue,
    Future<OfflineMessageQueueContract> Function()? fallbackQueueBuilder,
  }) async {
    if (_instance != null) {
      _logger.warning('MessageRouter already initialized');
      return;
    }

    _instance = MessageRouter._();
    _instance!._bleService = bleService;

    // 🔧 FIX: Direct access to messageQueue (no polling needed)
    // messageQueue is now initialized BEFORE core services in AppCore,
    // so it's guaranteed to be available when BLEService initializes
    _instance!._offlineQueue = await _resolveOfflineQueue(
      providedQueue: offlineQueue,
      fallbackQueueBuilder: fallbackQueueBuilder,
    );

    _logger.info(
      '✅ MessageRouter initialized (delegating to OfflineMessageQueue)',
    );
  }

  /// Send a message with automatic offline queueing
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  ///
  /// Returns MessageRouteResult indicating whether message was:
  /// - Queued (delegated to OfflineMessageQueue - will auto-send when online)
  /// - Failed (critical error)
  Future<MessageRouteResult> sendMessage({
    required String content,
    required String recipientId,
    String? messageId,
    String? recipientName,
  }) async {
    try {
      _logger.info(
        '📨 MessageRouter: Delegating to OfflineMessageQueue for ${recipientId.shortId(8)}...',
      );
      _logger.fine(
        '📶 BLE connected at route time: ${_bleService.isConnected}',
      );

      // Get sender's public key
      final prefs = GetIt.instance<IPreferencesRepository>();
      final senderKey = await prefs.getString('public_key');

      if (senderKey.isEmpty) {
        _logger.severe('❌ No sender public key available');
        return MessageRouteResult.failed(
          messageId ?? Uuid().v4(),
          'No sender public key',
        );
      }

      // Delegate to OfflineMessageQueue (which handles direct send + queueing + retry)
      final queuedMessageId = await _offlineQueue.queueMessage(
        chatId: 'chat_$recipientId',
        content: content,
        recipientPublicKey: recipientId,
        senderPublicKey: senderKey,
        priority: MessagePriority.normal,
      );

      _logger.info(
        '📮 Message queued via OfflineMessageQueue: ${queuedMessageId.shortId()}...',
      );

      return MessageRouteResult.queued(queuedMessageId);
    } catch (e) {
      _logger.severe('❌ Message routing failed: $e');
      final fallbackId = messageId ?? Uuid().v4();
      return MessageRouteResult.failed(fallbackId, e.toString());
    }
  }

  /// Typed overload for MessageId/ChatId callers; unwraps to string at the boundary.
  Future<MessageRouteResult> sendMessageWithIds({
    required String content,
    required ChatId recipientId,
    MessageId? messageId,
    String? recipientName,
  }) => sendMessage(
    content: content,
    recipientId: recipientId.value,
    messageId: messageId?.value,
    recipientName: recipientName,
  );

  /// Flush queued messages for a specific peer
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  ///
  /// Called when:
  /// - Session established (handshake complete)
  /// - Connection restored
  /// - Manual retry
  ///
  /// BitChat equivalent: flushOutboxFor() in MessageRouter.kt (lines 127-156)
  Future<void> flushOutboxFor(String peerId) async {
    _logger.info(
      '📤 MessageRouter: Delegating flush to OfflineMessageQueue for ${peerId.shortId(8)}...',
    );

    try {
      // Delegate to OfflineMessageQueue which has persistent queue + retry logic
      await _offlineQueue.flushQueueForPeer(peerId);
      _logger.info('✅ Flush delegated to OfflineMessageQueue');
    } catch (e) {
      _logger.warning('⚠️ Flush delegation failed: $e');
    }
  }

  Future<void> flushOutboxForId(ChatId peerId) => flushOutboxFor(peerId.value);

  /// Flush all queued messages (for all peers)
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  ///
  /// Useful for:
  /// - Manual retry all
  /// - Network restored event
  ///
  /// BitChat equivalent: flushAllOutbox() in MessageRouter.kt (lines 158-161)
  Future<void> flushAllOutbox() async {
    _logger.info(
      '📤 MessageRouter: Delegating flush all to OfflineMessageQueue...',
    );

    try {
      // Get all pending messages from OfflineMessageQueue
      final pendingMessages = _offlineQueue.getPendingMessages();
      final uniquePeers = pendingMessages
          .map((msg) => msg.recipientPublicKey)
          .toSet();

      if (uniquePeers.isEmpty) {
        _logger.info('No queued messages to flush');
        return;
      }

      _logger.info(
        '📤 Flushing outbox for ${uniquePeers.length} peer(s) via OfflineMessageQueue...',
      );

      for (final peerId in uniquePeers) {
        await _offlineQueue.flushQueueForPeer(peerId);
      }

      _logger.info('✅ Flush all delegated to OfflineMessageQueue');
    } catch (e) {
      _logger.warning('⚠️ Flush all delegation failed: $e');
    }
  }

  /// Get total queued messages across all peers
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  int getTotalQueuedMessages() {
    return _offlineQueue.getPendingMessages().length;
  }

  /// Get statistics
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  Map<String, dynamic> getStatistics() {
    final stats = _offlineQueue.getStatistics();

    return {
      'totalQueued': stats.totalQueued,
      'totalFlushed': stats.totalDelivered,
      'currentQueueSize': stats.pendingMessages,
      'peersWithQueuedMessages': _getPeerCount(),
      'delegatedToOfflineQueue': true, // Mark that this is delegated
    };
  }

  /// Get unique peer count from OfflineMessageQueue
  int _getPeerCount() {
    final pendingMessages = _offlineQueue.getPendingMessages();
    return pendingMessages.map((msg) => msg.recipientPublicKey).toSet().length;
  }

  /// Clear all queued messages (for testing)
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  Future<void> clearAll() async {
    _logger.info(
      'MessageRouter: Delegating clearAll to OfflineMessageQueue...',
    );
    await _offlineQueue.clearQueue();
    _logger.info('Cleared all queued messages via OfflineMessageQueue');
  }

  /// Dispose resources
  void dispose() {
    _logger.info(
      'MessageRouter disposed (queue managed by OfflineMessageQueue)',
    );
  }

  static Future<OfflineMessageQueueContract> _resolveOfflineQueue({
    OfflineMessageQueueContract? providedQueue,
    Future<OfflineMessageQueueContract> Function()? fallbackQueueBuilder,
  }) async {
    if (providedQueue != null) {
      return providedQueue;
    }

    final sharedQueueProvider = _resolveSharedQueueProvider();
    if (sharedQueueProvider != null &&
        (sharedQueueProvider.isInitialized ||
            sharedQueueProvider.isInitializing)) {
      try {
        return sharedQueueProvider.messageQueue;
      } catch (error) {
        _logger.warning(
          'Shared queue provider unavailable during MessageRouter init: $error',
        );
      }
    }

    if (fallbackQueueBuilder != null) {
      _logger.info(
        'MessageRouter using fallback OfflineMessageQueue from builder',
      );
      return fallbackQueueBuilder();
    }

    return createInitializedStandaloneQueue();
  }

  /// Create an uninitialized standalone queue instance.
  /// Used by non-core consumers that need a fallback without importing concrete
  /// queue types directly.
  static OfflineMessageQueueContract createStandaloneQueue() {
    if (_standaloneQueueFactory != null) {
      return _standaloneQueueFactory!();
    }

    final sharedQueueProvider = _resolveSharedQueueProvider();
    if (sharedQueueProvider != null && sharedQueueProvider.isInitialized) {
      return sharedQueueProvider.messageQueue;
    }

    return _FallbackOfflineMessageQueue();
  }

  /// Create and initialize a standalone queue instance.
  static Future<OfflineMessageQueueContract>
  createInitializedStandaloneQueue() async {
    if (_initializedQueueFactory != null) {
      return _initializedQueueFactory!();
    }

    final queue = createStandaloneQueue();
    await queue.initialize();
    return queue;
  }

  static ISharedMessageQueueProvider? _resolveSharedQueueProvider() {
    try {
      final di = GetIt.instance;
      if (di.isRegistered<ISharedMessageQueueProvider>()) {
        return di<ISharedMessageQueueProvider>();
      }
    } catch (_) {
      // Fall through
    }
    return null;
  }
}

/// Lightweight in-memory queue used when no concrete queue factory is wired.
/// This keeps chat flows functional in tests and isolated controllers.
class _FallbackOfflineMessageQueue implements OfflineMessageQueueContract {
  final List<QueuedMessage> _messages = [];
  final Set<String> _deletedMessageIds = <String>{};
  bool _isOnline = false;
  int _totalQueued = 0;
  int _totalDelivered = 0;
  int _totalFailed = 0;

  Function(QueuedMessage message)? _onMessageQueued;
  Function(QueuedMessage message)? _onMessageDelivered;
  Function(QueuedMessage message, String reason)? _onMessageFailed;
  Function(QueueStatistics stats)? _onStatsUpdated;
  Function(String messageId)? _onSendMessage;
  Function()? _onConnectivityCheck;

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
  set onSendMessage(Function(String messageId)? callback) {
    _onSendMessage = callback;
  }

  @override
  set onConnectivityCheck(Function()? callback) {
    _onConnectivityCheck = callback;
  }

  @override
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
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
    final now = DateTime.now();
    final id = Uuid().v4();
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

    _messages.add(message);
    _totalQueued++;
    _onMessageQueued?.call(message);
    _emitStats();

    if (_isOnline) {
      _onSendMessage?.call(message.id);
      message.status = QueuedMessageStatus.awaitingAck;
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
    final before = _messages.length;
    _messages.removeWhere((m) => m.chatId == chatId);
    _emitStats();
    return before - _messages.length;
  }

  @override
  Future<void> setOnline() async {
    _isOnline = true;
    _onConnectivityCheck?.call();
  }

  @override
  void setOffline() {
    _isOnline = false;
  }

  @override
  Future<void> markMessageDelivered(String messageId) async {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final message = _messages[index];
    message.status = QueuedMessageStatus.delivered;
    message.deliveredAt = DateTime.now();
    _messages.removeAt(index);
    _totalDelivered++;
    _onMessageDelivered?.call(message);
    _emitStats();
  }

  @override
  Future<void> markMessageFailed(String messageId, String reason) async {
    final message = _messages.where((m) => m.id == messageId).firstOrNull;
    if (message == null) return;
    message.status = QueuedMessageStatus.failed;
    message.failureReason = reason;
    message.failedAt = DateTime.now();
    _totalFailed++;
    _onMessageFailed?.call(message, reason);
    _emitStats();
  }

  @override
  QueueStatistics getStatistics() {
    final pending = _messages
        .where((m) => m.status == QueuedMessageStatus.pending)
        .length;
    final sending = _messages
        .where((m) => m.status == QueuedMessageStatus.sending)
        .length;
    final retrying = _messages
        .where((m) => m.status == QueuedMessageStatus.retrying)
        .length;
    final failed = _messages
        .where((m) => m.status == QueuedMessageStatus.failed)
        .length;

    final oldestPending = _messages
        .where((m) => m.status == QueuedMessageStatus.pending)
        .fold<QueuedMessage?>(null, (oldest, current) {
          if (oldest == null || current.queuedAt.isBefore(oldest.queuedAt)) {
            return current;
          }
          return oldest;
        });

    return QueueStatistics(
      totalQueued: _totalQueued,
      totalDelivered: _totalDelivered,
      totalFailed: _totalFailed,
      pendingMessages: pending,
      sendingMessages: sending,
      retryingMessages: retrying,
      failedMessages: failed,
      isOnline: _isOnline,
      oldestPendingMessage: oldestPending,
      averageDeliveryTime: Duration.zero,
      directQueueSize: _messages.where((m) => !m.isRelayMessage).length,
      relayQueueSize: _messages.where((m) => m.isRelayMessage).length,
    );
  }

  @override
  Future<void> retryFailedMessages() async {
    for (final message in _messages) {
      if (message.status == QueuedMessageStatus.failed) {
        message.status = QueuedMessageStatus.pending;
        message.failureReason = null;
        message.failedAt = null;
      }
    }
    _emitStats();
  }

  @override
  Future<void> retryFailedMessagesForChat(String chatId) async {
    for (final message in _messages.where((m) => m.chatId == chatId)) {
      if (message.status == QueuedMessageStatus.failed) {
        message.status = QueuedMessageStatus.pending;
        message.failureReason = null;
        message.failedAt = null;
      }
    }
    _emitStats();
  }

  @override
  Future<void> clearQueue() async {
    _messages.clear();
    _emitStats();
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      _messages.where((m) => m.status == status).toList();

  @override
  QueuedMessage? getMessageById(String messageId) =>
      _messages.where((m) => m.id == messageId).firstOrNull;

  @override
  List<QueuedMessage> getPendingMessages() =>
      getMessagesByStatus(QueuedMessageStatus.pending);

  @override
  Future<void> removeMessage(String messageId) async {
    _messages.removeWhere((m) => m.id == messageId);
    _emitStats();
  }

  @override
  Future<void> flushQueueForPeer(String peerPublicKey) async {
    if (!_isOnline) return;
    for (final message in _messages.where(
      (m) =>
          m.recipientPublicKey == peerPublicKey &&
          m.status == QueuedMessageStatus.pending,
    )) {
      message.status = QueuedMessageStatus.awaitingAck;
      _onSendMessage?.call(message.id);
    }
    _emitStats();
  }

  @override
  Future<bool> changePriority(
    String messageId,
    MessagePriority newPriority,
  ) async {
    final message = _messages.where((m) => m.id == messageId).firstOrNull;
    if (message == null) return false;
    message.priority = newPriority;
    return true;
  }

  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    final activeIds = _messages.map((m) => m.id).toList()..sort();
    final deleted = _deletedMessageIds.toList()..sort();
    return [...activeIds, ...deleted].join(':');
  }

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return QueueSyncMessage.createRequest(
      messageIds: _messages.map((m) => m.id).toList(),
      nodeId: nodeId,
      queueHash: calculateQueueHash(),
    );
  }

  @override
  bool needsSynchronization(String otherQueueHash) =>
      calculateQueueHash() != otherQueueHash;

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    if (_deletedMessageIds.contains(message.id)) return;
    if (_messages.any((m) => m.id == message.id)) return;
    _messages.add(message);
    _emitStats();
  }

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    final local = _messages.map((m) => m.id).toSet();
    return otherMessageIds.where((id) => !local.contains(id)).toList();
  }

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final other = otherMessageIds.toSet();
    return _messages.where((m) => !other.contains(m.id)).toList();
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    _deletedMessageIds.add(messageId);
    _messages.removeWhere((m) => m.id == messageId);
    _emitStats();
  }

  @override
  bool isMessageDeleted(String messageId) =>
      _deletedMessageIds.contains(messageId);

  @override
  Future<void> cleanupOldDeletedIds() async {
    // No-op for in-memory fallback.
  }

  @override
  void invalidateHashCache() {}

  @override
  Map<String, dynamic> getPerformanceStats() => {
    'totalMessages': _messages.length,
    'deletedIdsCount': _deletedMessageIds.length,
    'isOnline': _isOnline,
  };

  @override
  void dispose() {}

  void _emitStats() {
    _onStatsUpdated?.call(getStatistics());
  }
}

// NOTE: QueuedMessage is now defined in offline_message_queue.dart
// This wrapper previously had its own QueuedMessage class, but now delegates
// to OfflineMessageQueue which has a more comprehensive QueuedMessage model

/// Result of message routing attempt
class MessageRouteResult {
  final String messageId;
  final MessageRouteStatus status;
  final String? errorMessage;

  MessageRouteResult._({
    required this.messageId,
    required this.status,
    this.errorMessage,
  });

  factory MessageRouteResult.sentDirectly(String messageId) =>
      MessageRouteResult._(
        messageId: messageId,
        status: MessageRouteStatus.sentDirectly,
      );

  factory MessageRouteResult.queued(String messageId) => MessageRouteResult._(
    messageId: messageId,
    status: MessageRouteStatus.queued,
  );

  factory MessageRouteResult.failed(String messageId, String error) =>
      MessageRouteResult._(
        messageId: messageId,
        status: MessageRouteStatus.failed,
        errorMessage: error,
      );

  /// Typed factories to keep value-object callers on the happy path.
  factory MessageRouteResult.sentDirectlyId(MessageId messageId) =>
      MessageRouteResult.sentDirectly(messageId.value);

  factory MessageRouteResult.queuedId(MessageId messageId) =>
      MessageRouteResult.queued(messageId.value);

  factory MessageRouteResult.failedId(MessageId messageId, String error) =>
      MessageRouteResult.failed(messageId.value, error);

  bool get isSuccess => status != MessageRouteStatus.failed;
  bool get isQueued => status == MessageRouteStatus.queued;
  bool get isSentDirectly => status == MessageRouteStatus.sentDirectly;
  MessageId get messageIdValue => MessageId(messageId);
}

/// Message routing status
enum MessageRouteStatus {
  /// Message sent directly (peer connected)
  sentDirectly,

  /// Message queued (peer offline - will auto-send when online)
  queued,

  /// Message routing failed (critical error)
  failed,
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
