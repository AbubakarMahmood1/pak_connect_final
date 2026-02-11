// ignore_for_file: annotate_overrides
// Comprehensive offline message delivery and queue management system

import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';
import 'package:pak_connect/domain/interfaces/i_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/utils/app_logger.dart';
import '../services/queue_sync_coordinator.dart';
import '../services/queue_policy_manager.dart';
import '../services/queue_bandwidth_allocator.dart';
import 'offline_queue_store.dart';
import 'offline_queue_scheduler.dart';
import 'offline_queue_sync.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import '../../domain/values/id_types.dart';

/// Comprehensive offline message queue with intelligent retry and delivery management
class OfflineMessageQueue implements OfflineMessageQueueContract {
  static final _logger = Logger('OfflineMessageQueue');

  static const int _maxRetries = 5;

  // Performance optimization constants
  static const int _maxDeletedIdsToKeep = 5000;

  // Queue management
  // PRIORITY 1 FIX: Dual-queue system to prevent relay flooding
  // Direct messages (user-initiated): 80% bandwidth priority
  // Relay messages (mesh forwarding): 20% bandwidth allocation
  final List<QueuedMessage> _directMessageQueue =
      []; // Direct messages (high priority)
  final List<QueuedMessage> _relayMessageQueue =
      []; // Relay messages (controlled bandwidth)

  final IMessageQueueRepository? _initialQueueRepository;
  final IQueuePersistenceManager? _initialQueuePersistenceManager;
  final IRetryScheduler? _initialRetryScheduler;

  late final QueueStore _store = QueueStore(
    directMessageQueue: _directMessageQueue,
    relayMessageQueue: _relayMessageQueue,
    deletedMessageIds: _deletedMessageIds,
    queueRepository: _initialQueueRepository,
    queuePersistenceManager: _initialQueuePersistenceManager,
  );

  late final QueueScheduler _queueScheduler = QueueScheduler(
    retryScheduler: _initialRetryScheduler,
  );

  late final IQueueSyncCoordinator _syncCoordinator = QueueSyncCoordinator(
    repository: _repo,
    deletedMessageIds: _deletedMessageIds,
  );

  late final QueueSync _queueSync = QueueSync(
    coordinator: _syncCoordinator,
    deletedMessageIds: _deletedMessageIds,
    getAllMessages: _getAllMessages,
    logger: _logger,
    onSyncedMessageAdded: () {
      _totalQueued++;
      _updateStatistics();
    },
  );

  late final QueuePolicyManager _policy = QueuePolicyManager(
    repositoryProvider: _repositoryProvider,
  );

  late final QueueBandwidthAllocator _bandwidth = QueueBandwidthAllocator();

  // Repository provider for favorites support
  IRepositoryProvider? _repositoryProvider;
  IDatabaseProvider? _databaseProvider;

  // Queue hash synchronization
  final Set<MessageId> _deletedMessageIds = {};

  // Connection monitoring
  bool _isOnline = false;

  // Statistics
  int _totalQueued = 0;
  int _totalDelivered = 0;
  final int _totalFailed = 0;

  // Callbacks
  Function(QueuedMessage message)? onMessageQueued;
  Function(QueuedMessage message)? onMessageDelivered;
  Function(QueuedMessage message, String reason)? onMessageFailed;
  Function(QueueStatistics stats)? onStatsUpdated;
  Function(String messageId)? onSendMessage;
  Function()? onConnectivityCheck;

  OfflineMessageQueue({
    IMessageQueueRepository? queueRepository,
    IQueuePersistenceManager? queuePersistenceManager,
    IRetryScheduler? retryScheduler,
  }) : _initialQueueRepository = queueRepository,
       _initialQueuePersistenceManager = queuePersistenceManager,
       _initialRetryScheduler = retryScheduler;

  IMessageQueueRepository get _repo => _store.repo;

  /// Initialize the offline message queue
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
    this.onMessageQueued = onMessageQueued;
    this.onMessageDelivered = onMessageDelivered;
    this.onMessageFailed = onMessageFailed;
    this.onStatsUpdated = onStatsUpdated;
    this.onSendMessage = onSendMessage;
    this.onConnectivityCheck = onConnectivityCheck;
    if (repositoryProvider != null) {
      _repositoryProvider = repositoryProvider;
    } else if (GetIt.instance.isRegistered<IRepositoryProvider>()) {
      _repositoryProvider = GetIt.instance<IRepositoryProvider>();
    } else {
      _logger.warning(
        'ℹ️ IRepositoryProvider not registered - favorites-based limits disabled',
      );
      _repositoryProvider = null;
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      // Ensure sqflite_common_ffi is initialized for desktop/test environments
      if (sqflite_common.databaseFactory != sqflite_ffi.databaseFactoryFfi) {
        sqflite_ffi.sqfliteFfiInit();
        sqflite_common.databaseFactory = sqflite_ffi.databaseFactoryFfi;
      }
    }

    if (databaseProvider != null) {
      _databaseProvider = databaseProvider;
    } else if (_databaseProvider == null &&
        GetIt.instance.isRegistered<IDatabaseProvider>()) {
      _databaseProvider = GetIt.instance<IDatabaseProvider>();
    }

    _store.setDatabaseProvider(_databaseProvider);
    await _store.initializePersistence(logger: _logger);
    await _queueSync.initialize();
    _startConnectivityMonitoring();
    _startPeriodicCleanup();

    final totalMessages =
        _directMessageQueue.length + _relayMessageQueue.length;
    _logger.info(
      'Offline message queue initialized with $totalMessages pending messages (direct: ${_directMessageQueue.length}, relay: ${_relayMessageQueue.length})${_repositoryProvider != null ? ' (favorites support enabled)' : ''}',
    );
  }

  /// Queue a message for offline delivery
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
    try {
      // Apply favorites-based priority boost
      final boostResult = await _policy.applyFavoritesPriorityBoost(
        recipientPublicKey: recipientPublicKey,
        currentPriority: priority,
      );
      // Use boosted priority without mutating parameter
      final effectivePriority = boostResult.priority;

      // Validate per-peer queue limits
      final validation = await _policy.validateQueueLimit(
        recipientPublicKey: recipientPublicKey,
        allMessages: _getAllMessages(),
      );

      if (!validation.isValid) {
        _logger.warning(
          'Queue limit reached for ${validation.limitType} contact ${recipientPublicKey.shortId(8)}...: '
          '${validation.currentCount}/${validation.limit} messages',
        );
        throw MessageQueueException(validation.errorMessage);
      }

      // Generate secure message ID with nonce tracking
      final messageId = await MessageSecurity.generateSecureMessageId(
        senderPublicKey: senderPublicKey,
        content: content,
        recipientPublicKey: recipientPublicKey,
      );

      final now = DateTime.now();
      final queuedMessage = QueuedMessage(
        id: messageId,
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: senderPublicKey,
        priority: effectivePriority,
        queuedAt: now,
        replyToMessageId: replyToMessageId,
        attachments: attachments,
        attempts: 0,
        maxRetries: _getMaxRetriesForPriority(effectivePriority),
        expiresAt: _calculateExpiryTime(now, effectivePriority),
        isRelayMessage: isRelayMessage,
        relayMetadata: relayMetadata,
        originalMessageId: originalMessageId,
        relayNodeId: relayNodeId,
        messageHash: messageHash,
      );

      // Add to queue with priority ordering
      // PRIORITY 1 FIX: Route to appropriate queue (direct vs relay)
      _insertMessageByPriority(queuedMessage);

      if (persistToStorage) {
        await _saveMessageToStorage(queuedMessage);
      } else {
        _logger.fine(
          '🧭 Relay message queued without persistence: ${messageId.shortId(8)}...',
        );
      }

      _totalQueued++;
      onMessageQueued?.call(queuedMessage);
      _updateStatistics();

      final favoriteTag = boostResult.isFavorite ? ' ⭐' : '';
      final queueType = queuedMessage.isRelayMessage ? 'relay' : 'direct';
      _logger.info(
        'Message queued [$queueType]: ${messageId.shortId()}... (priority: ${effectivePriority.name}, peer: ${validation.currentCount + 1}/${validation.limit})$favoriteTag',
      );

      // Attempt immediate delivery if online
      if (_isOnline) {
        _tryDeliveryForMessage(queuedMessage);
      }

      return messageId;
    } catch (e) {
      _logger.severe('Failed to queue message: $e');
      if (e is MessageQueueException) {
        rethrow;
      }
      throw MessageQueueException('Failed to queue message: $e');
    }
  }

  /// Typed overload: wraps ChatId/MessageId inputs while emitting string payloads on storage/transport boundaries.
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

  /// Remove all queued messages for a specific chat (used when a chat is deleted)
  Future<int> removeMessagesForChat(String chatId) async {
    final toRemove = <String>{};
    for (final message in List<QueuedMessage>.from(_directMessageQueue)) {
      if (message.chatId == chatId) {
        toRemove.add(message.id);
      }
    }
    for (final message in List<QueuedMessage>.from(_relayMessageQueue)) {
      if (message.chatId == chatId) {
        toRemove.add(message.id);
      }
    }

    for (final id in toRemove) {
      _queueScheduler.cancelRetryTimer(id);
      await _repo.markMessageDeleted(id);
    }

    if (toRemove.isNotEmpty) {
      _logger.info(
        '🧹 Removed ${toRemove.length} queued messages for chat: ${chatId.shortId(8)}...',
      );
    }

    return toRemove.length;
  }

  /// Mark connection as online and attempt delivery of queued messages
  Future<void> setOnline() async {
    if (!_isOnline) {
      _isOnline = true;
      final totalMessages =
          _directMessageQueue.length + _relayMessageQueue.length;
      _logger.info(
        'Connection online - attempting delivery of $totalMessages queued messages (direct: ${_directMessageQueue.length}, relay: ${_relayMessageQueue.length})',
      );
      await _processQueue();
    }
  }

  /// Mark connection as offline
  void setOffline() {
    if (_isOnline) {
      _isOnline = false;
      _logger.info('Connection offline - queuing future messages');
      _cancelAllActiveRetries();
    }
  }

  /// Process the entire message queue
  /// PRIORITY 1 FIX: 80/20 bandwidth allocation (direct vs relay)
  Future<void> _processQueue() async {
    final totalDirect = _directMessageQueue.length;
    final totalRelay = _relayMessageQueue.length;

    if (totalDirect == 0 && totalRelay == 0) return;

    // Create delivery schedule with 80/20 bandwidth allocation
    final schedule = _bandwidth.createDeliverySchedule(
      directQueue: _directMessageQueue,
      relayQueue: _relayMessageQueue,
    );

    if (schedule.isEmpty) return;

    // Execute scheduled deliveries
    for (final scheduledMessage in schedule.schedule) {
      Timer(scheduledMessage.delay, () {
        if (_isOnline) {
          _tryDeliveryForMessage(scheduledMessage.message);
        }
      });
    }

    _logger.info(
      'Queue processing scheduled: direct=${schedule.directCount}, relay=${schedule.relayCount} (total slots: ${schedule.totalScheduled})',
    );
  }

  /// Attempt delivery for a specific message
  Future<void> _tryDeliveryForMessage(QueuedMessage message) async {
    // 🔧 FIX BUG #2: Check if we're still waiting for ACK from previous attempt
    // This prevents concurrent retries that re-encrypt with new nonce, creating mixed chunks
    const Duration ackTimeout = Duration(seconds: 5);

    if (message.status == QueuedMessageStatus.awaitingAck &&
        message.lastAttemptAt != null) {
      final timeSinceLastAttempt = DateTime.now().difference(
        message.lastAttemptAt!,
      );
      if (timeSinceLastAttempt < ackTimeout) {
        _logger.info(
          '⏳ Still waiting for ACK from previous attempt (${timeSinceLastAttempt.inMilliseconds}ms ago) for ${message.id.shortId()}...',
        );
        return; // Don't retry yet - wait for ACK timeout
      }
    }

    if (message.status != QueuedMessageStatus.pending) return;

    try {
      message.status = QueuedMessageStatus.sending;
      message.attempts++;
      message.lastAttemptAt = DateTime.now();

      await _saveMessageToStorage(message);

      _logger.fine(
        'Attempting delivery: ${message.id.shortId()}... (attempt ${message.attempts}/${message.maxRetries})',
      );

      // Note: Skip validation here - sender cannot validate recipient-encrypted messages
      // Validation will be performed by the actual recipient when they decrypt the message
      // This prevents the bug where sender tries to validate content encrypted with recipient's key

      // Attempt actual delivery via callback
      onSendMessage?.call(message.id);

      // Set to awaitingAck status - will be marked delivered when ACK received
      message.status = QueuedMessageStatus.awaitingAck;
      await _saveMessageToStorage(message);

      _logger.info('Message sent, awaiting ACK: ${message.id.shortId()}...');
    } catch (e) {
      _logger.severe(
        'Delivery attempt failed for ${message.id.shortId()}...: $e',
      );
      await _handleDeliveryFailure(message, e.toString());
    }
  }

  /// Handle successful message delivery (called by BLE service)
  Future<void> markMessageDelivered(String messageId) async {
    final id = MessageId(messageId);
    // PRIORITY 1 FIX: Search both queues
    final message = _getAllMessages()
        .where((m) => MessageId(m.id) == id)
        .firstOrNull;
    if (message == null) return;

    message.status = QueuedMessageStatus.delivered;
    message.deliveredAt = DateTime.now();

    _cancelRetryTimer(id);
    _removeMessageFromQueue(id);

    await _deleteMessageFromStorage(id.value);

    _totalDelivered++;
    onMessageDelivered?.call(message);
    _updateStatistics();

    final queueType = message.isRelayMessage ? 'relay' : 'direct';
    _logger.info(
      'Message delivered successfully [$queueType]: ${messageId.shortId()}...',
    );
  }

  /// Handle failed message delivery (called by BLE service)
  Future<void> markMessageFailed(String messageId, String reason) async {
    final id = MessageId(messageId);
    // PRIORITY 1 FIX: Search both queues
    final message = _getAllMessages()
        .where((m) => MessageId(m.id) == id)
        .firstOrNull;
    if (message == null) return;

    await _handleDeliveryFailure(message, reason);
  }

  /// Handle delivery failure with intelligent retry
  Future<void> _handleDeliveryFailure(
    QueuedMessage message,
    String reason,
  ) async {
    _logger.warning(
      'Delivery failed for ${message.id.shortId()}...: $reason (attempt ${message.attempts}/${message.maxRetries})',
    );

    // For mesh networking, never permanently fail messages - devices may be offline for long periods
    // Instead, use exponential backoff with increasing delays for persistent retry

    // Calculate exponential backoff delay (cap at 1 hour for very high attempt counts)
    final backoffDelay = _calculateBackoffDelay(message.attempts);

    message.status = QueuedMessageStatus.retrying;
    message.nextRetryAt = DateTime.now().add(backoffDelay);

    await _saveMessageToStorage(message);

    // Schedule retry via scheduler
    _queueScheduler.registerRetryTimer(message.id, backoffDelay, () async {
      if (_isOnline) {
        await _tryDeliveryForMessage(message);
      } else {
        message.status = QueuedMessageStatus.pending;
        await _saveMessageToStorage(message);
      }
    });

    _logger.info(
      'Retry scheduled for ${message.id.shortId()}... in ${backoffDelay.inSeconds}s',
    );
  }

  /// Get current queue statistics
  QueueStatistics getStatistics() {
    // PRIORITY 1 FIX: Aggregate from both queues
    final allMessages = _getAllMessages();

    final pending = allMessages
        .where((m) => m.status == QueuedMessageStatus.pending)
        .length;
    final sending = allMessages
        .where((m) => m.status == QueuedMessageStatus.sending)
        .length;
    final retrying = allMessages
        .where((m) => m.status == QueuedMessageStatus.retrying)
        .length;
    final failed = allMessages
        .where((m) => m.status == QueuedMessageStatus.failed)
        .length;

    final oldestPending = allMessages
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
      averageDeliveryTime: _calculateAverageDeliveryTime(),
      directQueueSize: _directMessageQueue.length, // NEW: Track queue sizes
      relayQueueSize: _relayMessageQueue.length, // NEW: Track queue sizes
    );
  }

  /// Retry all failed messages
  Future<void> retryFailedMessages() async {
    // PRIORITY 1 FIX: Search both queues
    final failedMessages = _getAllMessages()
        .where((m) => m.status == QueuedMessageStatus.failed)
        .toList();

    if (failedMessages.isEmpty) {
      _logger.info('No failed messages to retry');
      return;
    }

    _logger.info('Retrying ${failedMessages.length} failed messages');

    for (final message in failedMessages) {
      message.status = QueuedMessageStatus.pending;
      message.attempts = 0;
      message.failureReason = null;
      message.failedAt = null;
      message.nextRetryAt = null;
    }

    await _saveQueueToStorage();

    if (_isOnline) {
      await _processQueue();
    }
  }

  /// Retry failed messages for a specific chat without touching other chats
  Future<void> retryFailedMessagesForChat(String chatId) async {
    final failedMessages = _getAllMessages()
        .where(
          (m) => m.status == QueuedMessageStatus.failed && m.chatId == chatId,
        )
        .toList();

    if (failedMessages.isEmpty) {
      _logger.info('No failed messages to retry for chat $chatId');
      return;
    }

    _logger.info(
      'Retrying ${failedMessages.length} failed messages for chat $chatId',
    );

    for (final message in failedMessages) {
      message.status = QueuedMessageStatus.pending;
      message.attempts = 0;
      message.failureReason = null;
      message.failedAt = null;
      message.nextRetryAt = null;
    }

    await _saveQueueToStorage();

    if (_isOnline) {
      await _processQueue();
    }
  }

  /// Clear all messages from queue
  Future<void> clearQueue() async {
    _cancelAllActiveRetries();
    _store.clearInMemoryQueues();
    await _saveQueueToStorage();

    _logger.info('Message queues cleared (direct and relay)');
    _updateStatistics();
  }

  /// Get messages by status
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    // PRIORITY 1 FIX: Search both queues
    return _getAllMessages().where((m) => m.status == status).toList();
  }

  /// Get message by ID
  QueuedMessage? getMessageById(String messageId) {
    // PRIORITY 1 FIX: Search both queues
    return _getAllMessages().where((m) => m.id == messageId).firstOrNull;
  }

  /// Get all pending messages (convenience method)
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  /// Remove specific message from queue
  Future<void> removeMessage(String messageId) async {
    final id = MessageId(messageId);
    _cancelRetryTimer(id);
    _removeMessageFromQueue(id);
    await _deleteMessageFromStorage(id.value);
  }

  /// Flush queue for specific peer (trigger immediate delivery)
  ///
  /// Called when handshake completes or peer comes online.
  /// Only processes pending messages for the specified peer.
  Future<void> flushQueueForPeer(String peerPublicKey) async {
    try {
      // PRIORITY 1 FIX: Flush from both queues
      final peerMessages = _getAllMessages()
          .where(
            (m) =>
                m.recipientPublicKey == peerPublicKey &&
                m.status == QueuedMessageStatus.pending,
          )
          .toList();

      if (peerMessages.isEmpty) {
        _logger.fine(
          'No queued messages for peer ${peerPublicKey.shortId(8)}...',
        );
        return;
      }

      final directCount = peerMessages.where((m) => !m.isRelayMessage).length;
      final relayCount = peerMessages.where((m) => m.isRelayMessage).length;
      _logger.info(
        '📤 Flushing ${peerMessages.length} queued messages for peer ${peerPublicKey.shortId(8)}... (direct: $directCount, relay: $relayCount)',
      );

      // Mark peer as online temporarily for delivery
      final wasOnline = _isOnline;
      _isOnline = true;

      // Process messages with small delays to avoid overwhelming connection
      for (int i = 0; i < peerMessages.length; i++) {
        final message = peerMessages[i];

        // Small delay between messages
        if (i > 0) {
          await Future.delayed(Duration(milliseconds: 50));
        }

        final queueType = message.isRelayMessage ? 'relay' : 'direct';
        _logger.fine(
          '  Sending queued $queueType message: ${message.id.shortId()}...',
        );
        await _tryDeliveryForMessage(message);
      }

      // Restore original online state
      _isOnline = wasOnline;

      _logger.info(
        '✅ Queue flush complete for peer ${peerPublicKey.shortId(8)}...',
      );
    } catch (e) {
      _logger.severe('Failed to flush queue for peer $peerPublicKey: $e');
    }
  }

  /// Change priority of a queued message
  /// Returns true if successful, false if message not found
  Future<bool> changePriority(
    String messageId,
    MessagePriority newPriority,
  ) async {
    try {
      // PRIORITY 1 FIX: Search both queues
      final message = _getAllMessages()
          .where((m) => m.id == messageId)
          .firstOrNull;
      if (message == null) {
        _logger.warning(
          'Cannot change priority: message ${messageId.shortId()}... not found',
        );
        return false;
      }

      // Don't change if already at desired priority
      if (message.priority == newPriority) {
        _logger.fine(
          'Message ${messageId.shortId()}... already at priority ${newPriority.name}',
        );
        return true;
      }

      final oldPriority = message.priority;
      message.priority = newPriority;

      // Re-sort appropriate queue to maintain priority ordering
      final targetQueue = message.isRelayMessage
          ? _relayMessageQueue
          : _directMessageQueue;
      targetQueue.sort((a, b) {
        final priorityCompare = b.priority.index.compareTo(a.priority.index);
        if (priorityCompare != 0) return priorityCompare;
        return a.queuedAt.compareTo(b.queuedAt); // Secondary sort by queue time
      });

      await _saveMessageToStorage(message);

      final queueType = message.isRelayMessage ? 'relay' : 'direct';
      _logger.info(
        'Changed message ${messageId.shortId()}... priority [$queueType]: '
        '${oldPriority.name} → ${newPriority.name}',
      );

      return true;
    } catch (e) {
      _logger.severe('Failed to change message priority: $e');
      return false;
    }
  }

  // Private methods

  /// Insert message into queue by priority
  /// PRIORITY 1 FIX: Route to appropriate queue based on message type
  void _insertMessageByPriority(QueuedMessage message) {
    _store.insertMessageByPriority(message);
  }

  /// Remove message from queue
  /// PRIORITY 1 FIX: Remove from both queues
  void _removeMessageFromQueue(MessageId messageId) {
    _store.removeMessageFromQueue(messageId.value);
  }

  /// Get all messages from both queues (helper for dual-queue operations)
  List<QueuedMessage> _getAllMessages() {
    return _store.getAllMessages();
  }

  /// Calculate exponential backoff delay
  Duration _calculateBackoffDelay(int attempt) {
    return _queueScheduler.calculateBackoffDelay(attempt);
  }

  /// Get max retries based on message priority
  int _getMaxRetriesForPriority(MessagePriority priority) {
    return _queueScheduler.getMaxRetriesForPriority(priority, _maxRetries);
  }

  /// Calculate expiry time based on priority
  /// Urgent messages have longer TTL to ensure delivery even with long offline periods
  DateTime _calculateExpiryTime(DateTime queuedAt, MessagePriority priority) {
    return _queueScheduler.calculateExpiryTime(queuedAt, priority);
  }

  /// Check if message has expired
  bool _isMessageExpired(QueuedMessage message) {
    return _queueScheduler.isMessageExpired(message);
  }

  /// Start connectivity monitoring
  void _startConnectivityMonitoring() {
    _queueScheduler.startConnectivityMonitoring(
      onConnectivityCheck: () {
        onConnectivityCheck?.call();
      },
    );
  }

  /// Cancel all active retry timers
  void _cancelAllActiveRetries() {
    _queueScheduler.cancelAllRetryTimers();
  }

  /// Cancel retry timer for specific message
  void _cancelRetryTimer(MessageId messageId) {
    _queueScheduler.cancelRetryTimer(messageId.value);
  }

  /// Calculate average delivery time
  Duration _calculateAverageDeliveryTime() {
    // PRIORITY 1 FIX: Calculate across both queues
    final deliveredMessages = _getAllMessages()
        .where(
          (m) =>
              m.status == QueuedMessageStatus.delivered &&
              m.deliveredAt != null,
        )
        .toList();

    if (deliveredMessages.isEmpty) return Duration.zero;

    final totalTime = deliveredMessages
        .map((m) => m.deliveredAt!.difference(m.queuedAt))
        .fold<Duration>(Duration.zero, (sum, duration) => sum + duration);

    return Duration(
      milliseconds: totalTime.inMilliseconds ~/ deliveredMessages.length,
    );
  }

  /// Update statistics and notify listeners
  void _updateStatistics() {
    final stats = getStatistics();
    onStatsUpdated?.call(stats);
  }

  /// Save a single message to persistent storage (optimized for individual updates)
  Future<void> _saveMessageToStorage(QueuedMessage message) async {
    await _store.saveMessageToStorage(message);
    invalidateHashCache();
  }

  /// Remove a single message from persistent storage
  Future<void> _deleteMessageFromStorage(String messageId) async {
    await _store.deleteMessageFromStorage(messageId);
    invalidateHashCache();
  }

  /// Save entire queue to persistent storage (used for initial load and bulk operations)
  /// For individual message updates, use _saveMessageToStorage for better performance
  Future<void> _saveQueueToStorage() async {
    await _store.saveQueueToStorage();
    invalidateHashCache();
  }

  // ===== QUEUE HASH SYNCHRONIZATION METHODS =====

  /// Calculate deterministic hash of current queue state
  /// Excludes delivered/expired messages and includes deleted message tracking
  String calculateQueueHash({bool forceRecalculation = false}) {
    return _queueSync.calculateQueueHash(
      forceRecalculation: forceRecalculation,
    );
  }

  /// Get queue sync information for mesh networking
  QueueSyncMessage createSyncMessage(String nodeId) {
    return _queueSync.createSyncMessage(nodeId);
  }

  /// Compare queue hashes to determine if synchronization is needed
  bool needsSynchronization(String otherQueueHash) {
    return _queueSync.needsSynchronization(otherQueueHash);
  }

  /// Insert a message received via queue synchronization
  Future<void> addSyncedMessage(QueuedMessage message) async {
    await _queueSync.addSyncedMessage(message);
  }

  /// Get missing messages compared to another queue
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    return _queueSync.getMissingMessageIds(otherMessageIds);
  }

  /// Get excess messages that the other queue doesn't have
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    return _queueSync.getExcessMessages(otherMessageIds);
  }

  /// Mark message as deleted for sync purposes
  Future<void> markMessageDeleted(String messageId) async {
    await _queueSync.markMessageDeleted(messageId);
  }

  /// Check if message was deleted
  bool isMessageDeleted(String messageId) {
    return _queueSync.isMessageDeleted(messageId);
  }

  /// Clean up old deleted message IDs with improved performance
  Future<void> cleanupOldDeletedIds() async {
    await _queueSync.cleanupOldDeletedIds();
  }

  /// Invalidate hash cache (call after manual queue modifications)
  void invalidateHashCache() {
    _queueSync.invalidateHashCache();
  }

  /// Start periodic cleanup for performance optimization
  void _startPeriodicCleanup() {
    _queueScheduler.startPeriodicCleanup(
      onPeriodicMaintenance: _performPeriodicMaintenance,
    );
  }

  /// Perform periodic maintenance tasks
  Future<void> _performPeriodicMaintenance() async {
    final startedAt = DateTime.now();
    try {
      _logger.info(AppLogger.event(type: 'offline_queue_maintenance_started'));

      // Clean up old deleted IDs
      await cleanupOldDeletedIds();

      // Clean up expired messages (older than 30 days)
      await _cleanupExpiredMessages();

      // Optimize storage if needed
      await _optimizeStorage();

      // Invalidate old hash cache
      final lastHashTime = _queueSync.getSyncStatistics().lastHashTime;
      if (lastHashTime != null) {
        final cacheAge = DateTime.now().difference(lastHashTime);
        if (cacheAge.inHours > 1) {
          invalidateHashCache();
        }
      }

      _logger.info(
        AppLogger.event(
          type: 'offline_queue_maintenance_completed',
          duration: DateTime.now().difference(startedAt),
        ),
      );
    } catch (e) {
      _logger.warning(
        AppLogger.event(
          type: 'offline_queue_maintenance_failed',
          duration: DateTime.now().difference(startedAt),
          fields: {'error': e},
        ),
      );
    }
  }

  /// Clean up expired messages for performance
  /// Removes both TTL-expired messages and old delivered/failed messages
  Future<void> _cleanupExpiredMessages() async {
    final cutoffDate = DateTime.now().subtract(Duration(days: 30));
    int ttlExpiredCount = 0;
    int oldMessagesCount = 0;

    final expiredIds = <String>[];

    // PRIORITY 1 FIX: Clean both queues
    _directMessageQueue.removeWhere((message) {
      // Remove messages that have exceeded their TTL
      if (message.status == QueuedMessageStatus.pending ||
          message.status == QueuedMessageStatus.retrying) {
        if (_isMessageExpired(message)) {
          ttlExpiredCount++;
          expiredIds.add(message.id);
          _logger.info(
            'Message ${message.id.shortId()}... expired (TTL exceeded)',
          );
          return true;
        }
      }

      // Remove old delivered or failed messages
      if (message.status == QueuedMessageStatus.delivered ||
          message.status == QueuedMessageStatus.failed) {
        final messageAge =
            message.deliveredAt ?? message.failedAt ?? message.queuedAt;
        if (messageAge.isBefore(cutoffDate)) {
          oldMessagesCount++;
          expiredIds.add(message.id);
          return true;
        }
      }
      return false;
    });

    _relayMessageQueue.removeWhere((message) {
      // Remove messages that have exceeded their TTL
      if (message.status == QueuedMessageStatus.pending ||
          message.status == QueuedMessageStatus.retrying) {
        if (_isMessageExpired(message)) {
          ttlExpiredCount++;
          expiredIds.add(message.id);
          _logger.info(
            'Message ${message.id.shortId()}... expired (TTL exceeded)',
          );
          return true;
        }
      }

      // Remove old delivered or failed messages
      if (message.status == QueuedMessageStatus.delivered ||
          message.status == QueuedMessageStatus.failed) {
        final messageAge =
            message.deliveredAt ?? message.failedAt ?? message.queuedAt;
        if (messageAge.isBefore(cutoffDate)) {
          oldMessagesCount++;
          expiredIds.add(message.id);
          return true;
        }
      }
      return false;
    });

    // Persist removal to storage
    if (expiredIds.isNotEmpty) {
      await _saveQueueToStorage();

      _logger.info(
        'Cleaned up ${expiredIds.length} expired messages '
        '(TTL: $ttlExpiredCount, Old: $oldMessagesCount)',
      );
    }
  }

  /// Optimize storage by defragmenting data
  Future<void> _optimizeStorage() async {
    try {
      // Force a complete save to optimize storage structure
      await _saveQueueToStorage();

      // Check if we need to compact deleted IDs
      if (_deletedMessageIds.length > _maxDeletedIdsToKeep * 2) {
        await cleanupOldDeletedIds();
      }

      _logger.fine('Storage optimization completed');
    } catch (e) {
      _logger.warning('Storage optimization failed: $e');
    }
  }

  /// Get performance statistics
  Map<String, dynamic> getPerformanceStats() {
    final syncStats = _queueSync.getSyncStatistics();
    // PRIORITY 1 FIX: Include both queue stats
    return {
      'totalMessages': _directMessageQueue.length + _relayMessageQueue.length,
      'directMessages': _directMessageQueue.length,
      'relayMessages': _relayMessageQueue.length,
      'deletedIdsCount': _deletedMessageIds.length,
      'hashCacheAge': syncStats.lastHashTime != null
          ? DateTime.now().difference(syncStats.lastHashTime!).inSeconds
          : null,
      'hashCached': syncStats.isCachValid,
      'memoryOptimized': _deletedMessageIds.length <= _maxDeletedIdsToKeep,
    };
  }

  /// Dispose of resources
  void dispose() {
    _queueScheduler.dispose();
    _logger.info('Offline message queue disposed');
  }
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
