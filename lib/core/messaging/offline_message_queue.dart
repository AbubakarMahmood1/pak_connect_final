// Comprehensive offline message delivery and queue management system

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import '../interfaces/i_repository_provider.dart';
import '../../domain/entities/enhanced_message.dart';
import '../security/message_security.dart';
import '../models/mesh_relay_models.dart';
import '../interfaces/i_database_provider.dart';
import '../interfaces/i_message_queue_repository.dart';
import '../interfaces/i_queue_persistence_manager.dart';
import '../interfaces/i_retry_scheduler.dart';
import '../interfaces/i_queue_sync_coordinator.dart';
import '../services/message_queue_repository.dart';
import '../services/queue_persistence_manager.dart';
import '../services/retry_scheduler.dart';
import '../services/queue_sync_coordinator.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Comprehensive offline message queue with intelligent retry and delivery management
class OfflineMessageQueue {
  static final _logger = Logger('OfflineMessageQueue');

  static const int _maxRetries = 5;

  // Performance optimization constants
  static const int _maxDeletedIdsToKeep = 5000;
  static const int _cleanupThreshold = 10000;

  // Per-peer queue limits (favorites-based store-and-forward)
  static const int _maxMessagesPerFavorite = 500;
  static const int _maxMessagesPerRegular = 100;

  // Queue management
  // PRIORITY 1 FIX: Dual-queue system to prevent relay flooding
  // Direct messages (user-initiated): 80% bandwidth priority
  // Relay messages (mesh forwarding): 20% bandwidth allocation
  final List<QueuedMessage> _directMessageQueue =
      []; // Direct messages (high priority)
  final List<QueuedMessage> _relayMessageQueue =
      []; // Relay messages (controlled bandwidth)
  IMessageQueueRepository? _queueRepository;
  IQueuePersistenceManager? _queuePersistenceManager;
  IRetryScheduler? _retryScheduler;
  IQueueSyncCoordinator? _queueSyncCoordinator;

  // Bandwidth allocation constant
  static const double _directBandwidthRatio =
      0.8; // 80% for direct, 20% for relay

  // Repository provider for favorites support
  IRepositoryProvider? _repositoryProvider;
  IDatabaseProvider? _databaseProvider;

  // Queue hash synchronization
  final Set<String> _deletedMessageIds = {};

  // Connection monitoring
  bool _isOnline = false;
  Timer? _connectivityCheckTimer;

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
  }) : _queueRepository = queueRepository,
       _queuePersistenceManager = queuePersistenceManager,
       _retryScheduler = retryScheduler;

  IMessageQueueRepository get _repo {
    _queueRepository ??= MessageQueueRepository(
      directMessageQueue: _directMessageQueue,
      relayMessageQueue: _relayMessageQueue,
      deletedMessageIds: _deletedMessageIds,
      databaseProvider: _databaseProvider,
    );
    return _queueRepository!;
  }

  IQueuePersistenceManager get _persistenceManager {
    if (_queuePersistenceManager != null) return _queuePersistenceManager!;

    final hasDbProvider =
        _databaseProvider != null ||
        GetIt.instance.isRegistered<IDatabaseProvider>();

    _queuePersistenceManager = hasDbProvider
        ? QueuePersistenceManager(databaseProvider: _databaseProvider)
        : _NoopQueuePersistenceManager();
    return _queuePersistenceManager!;
  }

  IRetryScheduler get _scheduler {
    _retryScheduler ??= RetryScheduler();
    return _retryScheduler!;
  }

  IQueueSyncCoordinator get _sync {
    final repo = _repo;
    _queueSyncCoordinator ??= QueueSyncCoordinator(
      repository: repo,
      deletedMessageIds: _deletedMessageIds,
    );
    return _queueSyncCoordinator!;
  }

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
      if (sqflite_common.databaseFactoryOrNull == null) {
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

    final hasDbProvider =
        _databaseProvider != null ||
        GetIt.instance.isRegistered<IDatabaseProvider>();

    if (!hasDbProvider) {
      _queuePersistenceManager = _NoopQueuePersistenceManager();
      _queueRepository = _InMemoryQueueRepository(
        directMessageQueue: _directMessageQueue,
        relayMessageQueue: _relayMessageQueue,
        deletedMessageIds: _deletedMessageIds,
      );
      _logger.warning(
        '⚠️ No database provider found; using in-memory queue for this run',
      );
    } else {
      // Ensure persistence dependencies are ready before touching storage
      try {
        await _persistenceManager.createQueueTablesIfNotExist();
        await _loadQueueFromStorage();
        await _loadDeletedMessageIds();
      } catch (e) {
        _logger.warning(
          '⚠️ Persistence unavailable, falling back to in-memory queue: $e',
        );
        _queuePersistenceManager = _NoopQueuePersistenceManager();
        _queueRepository = _InMemoryQueueRepository(
          directMessageQueue: _directMessageQueue,
          relayMessageQueue: _relayMessageQueue,
          deletedMessageIds: _deletedMessageIds,
        );
      }
    }

    await _sync.initialize(deletedIds: _deletedMessageIds);
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
  }) async {
    try {
      // Check if recipient is a favorite and apply favorites-based benefits
      bool isFavorite = false;
      int peerLimit =
          _maxMessagesPerRegular; // Default limit for regular contacts

      if (_repositoryProvider != null) {
        try {
          isFavorite = await _repositoryProvider!.contactRepository
              .isContactFavorite(recipientPublicKey);
          if (isFavorite) {
            peerLimit = _maxMessagesPerFavorite;

            // Auto-boost priority for favorite contacts (if not already high/urgent)
            if (priority == MessagePriority.normal ||
                priority == MessagePriority.low) {
              priority = MessagePriority.high;
              _logger.fine(
                '⭐ Auto-boosted priority to HIGH for favorite contact ${recipientPublicKey.shortId(8)}...',
              );
            }
          }
        } catch (e) {
          _logger.warning(
            'Failed to check favorite status for ${recipientPublicKey.shortId(8)}...: $e',
          );
          // Continue with default values if check fails
        }
      }

      // Check per-peer queue limits
      // PRIORITY 1 FIX: Count across both queues
      final existingMessagesForPeer = _getAllMessages()
          .where(
            (m) =>
                m.recipientPublicKey == recipientPublicKey &&
                m.status != QueuedMessageStatus.delivered &&
                m.status != QueuedMessageStatus.failed,
          )
          .length;

      if (existingMessagesForPeer >= peerLimit) {
        final limitType = isFavorite ? 'favorite' : 'regular';
        _logger.warning(
          'Queue limit reached for $limitType contact ${recipientPublicKey.shortId(8)}...: '
          '$existingMessagesForPeer/$peerLimit messages',
        );
        throw MessageQueueException(
          'Per-peer queue limit reached: $existingMessagesForPeer/$peerLimit messages for $limitType contact',
        );
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
        priority: priority,
        queuedAt: now,
        replyToMessageId: replyToMessageId,
        attachments: attachments,
        attempts: 0,
        maxRetries: _getMaxRetriesForPriority(priority),
        expiresAt: _calculateExpiryTime(now, priority),
      );

      // Add to queue with priority ordering
      // PRIORITY 1 FIX: Route to appropriate queue (direct vs relay)
      _insertMessageByPriority(queuedMessage);

      await _saveMessageToStorage(queuedMessage);

      _totalQueued++;
      onMessageQueued?.call(queuedMessage);
      _updateStatistics();

      final favoriteTag = isFavorite ? ' ⭐' : '';
      final queueType = queuedMessage.isRelayMessage ? 'relay' : 'direct';
      _logger.info(
        'Message queued [$queueType]: ${messageId.shortId()}... (priority: ${priority.name}, peer: ${existingMessagesForPeer + 1}/$peerLimit)$favoriteTag',
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

    _logger.info(
      'Processing message queues: direct=$totalDirect (80%), relay=$totalRelay (20%)',
    );

    // Sort both queues by priority and timestamp
    _directMessageQueue.sort((a, b) {
      final priorityComparison = b.priority.index.compareTo(a.priority.index);
      if (priorityComparison != 0) return priorityComparison;
      return a.queuedAt.compareTo(b.queuedAt);
    });

    _relayMessageQueue.sort((a, b) {
      final priorityComparison = b.priority.index.compareTo(a.priority.index);
      if (priorityComparison != 0) return priorityComparison;
      return a.queuedAt.compareTo(b.queuedAt);
    });

    // Calculate bandwidth allocation
    // For every 10 messages, process 8 direct + 2 relay (80/20 ratio)
    final totalSlots = totalDirect + totalRelay;
    final directSlots = (totalSlots * _directBandwidthRatio).ceil();

    int directProcessed = 0;
    int relayProcessed = 0;
    int slotIndex = 0;

    // Interleaved processing with bandwidth allocation
    while (directProcessed < totalDirect || relayProcessed < totalRelay) {
      // Determine which queue to process from
      final shouldProcessDirect =
          directProcessed < totalDirect &&
          (relayProcessed >= totalRelay || directProcessed < directSlots);

      if (shouldProcessDirect && directProcessed < totalDirect) {
        final message = _directMessageQueue[directProcessed];
        if (message.status == QueuedMessageStatus.pending) {
          // Stagger deliveries to prevent network congestion
          final delay = Duration(milliseconds: slotIndex * 100);
          Timer(delay, () {
            if (_isOnline) {
              _tryDeliveryForMessage(message);
            }
          });
        }
        directProcessed++;
        slotIndex++;
      } else if (relayProcessed < totalRelay) {
        final message = _relayMessageQueue[relayProcessed];
        if (message.status == QueuedMessageStatus.pending) {
          // Stagger deliveries to prevent network congestion
          final delay = Duration(milliseconds: slotIndex * 100);
          Timer(delay, () {
            if (_isOnline) {
              _tryDeliveryForMessage(message);
            }
          });
        }
        relayProcessed++;
        slotIndex++;
      } else {
        // Both queues exhausted
        break;
      }
    }

    _logger.info(
      'Queue processing scheduled: direct=$directProcessed, relay=$relayProcessed (total slots: $slotIndex)',
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
    // PRIORITY 1 FIX: Search both queues
    final message = _getAllMessages()
        .where((m) => m.id == messageId)
        .firstOrNull;
    if (message == null) return;

    message.status = QueuedMessageStatus.delivered;
    message.deliveredAt = DateTime.now();

    _cancelRetryTimer(messageId);
    _removeMessageFromQueue(messageId);

    await _deleteMessageFromStorage(messageId);

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
    // PRIORITY 1 FIX: Search both queues
    final message = _getAllMessages()
        .where((m) => m.id == messageId)
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
    _scheduler.registerRetryTimer(message.id, backoffDelay, () async {
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

  /// Clear all messages from queue
  Future<void> clearQueue() async {
    _cancelAllActiveRetries();
    // PRIORITY 1 FIX: Clear both queues
    _directMessageQueue.clear();
    _relayMessageQueue.clear();
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
    _cancelRetryTimer(messageId);
    _removeMessageFromQueue(messageId);
    await _deleteMessageFromStorage(messageId);
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
    _repo.insertMessageByPriority(message);
  }

  /// Remove message from queue
  /// PRIORITY 1 FIX: Remove from both queues
  void _removeMessageFromQueue(String messageId) {
    _repo.removeMessageFromQueue(messageId);
  }

  /// Get all messages from both queues (helper for dual-queue operations)
  List<QueuedMessage> _getAllMessages() {
    return _repo.getAllMessages();
  }

  /// Calculate exponential backoff delay
  Duration _calculateBackoffDelay(int attempt) {
    return _scheduler.calculateBackoffDelay(attempt);
  }

  /// Get max retries based on message priority
  int _getMaxRetriesForPriority(MessagePriority priority) {
    return _scheduler.getMaxRetriesForPriority(priority, _maxRetries);
  }

  /// Calculate expiry time based on priority
  /// Urgent messages have longer TTL to ensure delivery even with long offline periods
  DateTime _calculateExpiryTime(DateTime queuedAt, MessagePriority priority) {
    return _scheduler.calculateExpiryTime(queuedAt, priority);
  }

  /// Check if message has expired
  bool _isMessageExpired(QueuedMessage message) {
    return _scheduler.isMessageExpired(message);
  }

  /// Start connectivity monitoring
  void _startConnectivityMonitoring() {
    _connectivityCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      onConnectivityCheck?.call();
    });
  }

  /// Cancel all active retry timers
  void _cancelAllActiveRetries() {
    _scheduler.cancelAllRetryTimers();
  }

  /// Cancel retry timer for specific message
  void _cancelRetryTimer(String messageId) {
    _scheduler.cancelRetryTimer(messageId);
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

  /// Load queue from persistent storage
  Future<void> _loadQueueFromStorage() async {
    await _repo.loadQueueFromStorage();
  }

  /// Save a single message to persistent storage (optimized for individual updates)
  Future<void> _saveMessageToStorage(QueuedMessage message) async {
    await _repo.saveMessageToStorage(message);
    invalidateHashCache();
  }

  /// Remove a single message from persistent storage
  Future<void> _deleteMessageFromStorage(String messageId) async {
    await _repo.deleteMessageFromStorage(messageId);
    invalidateHashCache();
  }

  /// Save entire queue to persistent storage (used for initial load and bulk operations)
  /// For individual message updates, use _saveMessageToStorage for better performance
  Future<void> _saveQueueToStorage() async {
    await _repo.saveQueueToStorage();
    invalidateHashCache();
  }

  /// Load deleted message IDs from persistent storage
  Future<void> _loadDeletedMessageIds() async {
    await _repo.loadDeletedMessageIds();
  }

  // ===== QUEUE HASH SYNCHRONIZATION METHODS =====

  /// Calculate deterministic hash of current queue state
  /// Excludes delivered/expired messages and includes deleted message tracking
  String calculateQueueHash({bool forceRecalculation = false}) {
    return _sync.calculateQueueHash(forceRecalculation: forceRecalculation);
  }

  /// Get queue sync information for mesh networking
  QueueSyncMessage createSyncMessage(String nodeId) {
    return _sync.createSyncMessage(nodeId);
  }

  /// Compare queue hashes to determine if synchronization is needed
  bool needsSynchronization(String otherQueueHash) {
    return _sync.needsSynchronization(otherQueueHash);
  }

  /// Insert a message received via queue synchronization
  Future<void> addSyncedMessage(QueuedMessage message) async {
    // Skip if message was previously deleted (e.g., aged out)
    if (_deletedMessageIds.contains(message.id)) {
      _logger.fine(
        'Sync skip - message ${message.id.shortId(8)}... was deleted locally',
      );
      return;
    }

    // Skip if we already have this message
    final exists = _getAllMessages().any((m) => m.id == message.id);
    if (exists) {
      _logger.fine(
        'Sync skip - message already exists: ${message.id.shortId(8)}...',
      );
      return;
    }

    final added = await _sync.addSyncedMessage(message);
    if (added) {
      _totalQueued++;
      _updateStatistics();
    }
  }

  /// Get missing messages compared to another queue
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    return _sync.getMissingMessageIds(otherMessageIds);
  }

  /// Get excess messages that the other queue doesn't have
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    return _sync.getExcessMessages(otherMessageIds);
  }

  /// Mark message as deleted for sync purposes
  Future<void> markMessageDeleted(String messageId) async {
    await _sync.markMessageDeleted(messageId);
  }

  /// Check if message was deleted
  bool isMessageDeleted(String messageId) {
    return _sync.isMessageDeleted(messageId);
  }

  /// Clean up old deleted message IDs with improved performance
  Future<void> cleanupOldDeletedIds() async {
    await _sync.cleanupOldDeletedIds();
  }

  /// Invalidate hash cache (call after manual queue modifications)
  void invalidateHashCache() {
    _sync.invalidateHashCache();
  }

  /// Start periodic cleanup for performance optimization
  void _startPeriodicCleanup() {
    Timer.periodic(Duration(hours: 6), (timer) {
      _performPeriodicMaintenance();
    });
  }

  /// Perform periodic maintenance tasks
  Future<void> _performPeriodicMaintenance() async {
    try {
      _logger.info('Starting periodic queue maintenance...');

      // Clean up old deleted IDs
      await cleanupOldDeletedIds();

      // Clean up expired messages (older than 30 days)
      await _cleanupExpiredMessages();

      // Optimize storage if needed
      await _optimizeStorage();

      // Invalidate old hash cache
      final lastHashTime = _sync.getSyncStatistics().lastHashTime;
      if (lastHashTime != null) {
        final cacheAge = DateTime.now().difference(lastHashTime);
        if (cacheAge.inHours > 1) {
          invalidateHashCache();
        }
      }

      _logger.info('Periodic queue maintenance completed');
    } catch (e) {
      _logger.warning('Periodic maintenance failed: $e');
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
    final syncStats = _sync.getSyncStatistics();
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
    _connectivityCheckTimer?.cancel();
    _cancelAllActiveRetries();
    _logger.info('Offline message queue disposed');
  }
}

/// Queued message with delivery tracking
class QueuedMessage {
  final String id;
  final String chatId;
  final String content;
  final String recipientPublicKey;
  final String senderPublicKey;
  MessagePriority priority; // Mutable to allow priority changes
  final DateTime queuedAt;
  final String? replyToMessageId;
  final List<String> attachments;
  final int maxRetries;

  // Delivery tracking
  QueuedMessageStatus status;
  int attempts;
  DateTime? lastAttemptAt;
  DateTime? nextRetryAt;
  DateTime? deliveredAt;
  DateTime? failedAt;
  String? failureReason;

  /// Expiry timestamp - messages expire if not delivered by this time
  /// TTL is priority-based: urgent=24h, high=12h, normal=6h, low=3h
  final DateTime? expiresAt;

  // Mesh relay fields (optional for backward compatibility)
  /// Indicates if this is a relay message
  final bool isRelayMessage;

  /// Relay metadata for mesh routing (only present for relay messages)
  final RelayMetadata? relayMetadata;

  /// Original message ID (for relay messages, different from relay wrapper ID)
  final String? originalMessageId;

  /// Node that created this relay (current relay node's public key)
  final String? relayNodeId;

  /// Message hash for deduplication across the mesh
  final String? messageHash;

  /// Rate limiting: sender's message count in current time window
  final int senderRateCount;

  QueuedMessage({
    required this.id,
    required this.chatId,
    required this.content,
    required this.recipientPublicKey,
    required this.senderPublicKey,
    required this.priority,
    required this.queuedAt,
    required this.maxRetries,
    this.replyToMessageId,
    this.attachments = const [],
    this.status = QueuedMessageStatus.pending,
    this.attempts = 0,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.deliveredAt,
    this.failedAt,
    this.failureReason,
    this.expiresAt,
    // Relay-specific fields
    this.isRelayMessage = false,
    this.relayMetadata,
    this.originalMessageId,
    this.relayNodeId,
    this.messageHash,
    this.senderRateCount = 0,
  });

  /// Create a relay message from a MeshRelayMessage
  factory QueuedMessage.fromRelayMessage({
    required MeshRelayMessage relayMessage,
    required String chatId,
    required int maxRetries,
    QueuedMessageStatus status = QueuedMessageStatus.pending,
  }) {
    final queuedAt = relayMessage.relayedAt;
    final priority = relayMessage.relayMetadata.priority;

    // Calculate expiry time based on priority
    Duration ttl;
    switch (priority) {
      case MessagePriority.urgent:
        ttl = Duration(hours: 24);
        break;
      case MessagePriority.high:
        ttl = Duration(hours: 12);
        break;
      case MessagePriority.normal:
        ttl = Duration(hours: 6);
        break;
      case MessagePriority.low:
        ttl = Duration(hours: 3);
        break;
    }

    return QueuedMessage(
      id: '${relayMessage.originalMessageId}_relay_${DateTime.now().millisecondsSinceEpoch}',
      chatId: chatId,
      content: relayMessage.originalContent,
      recipientPublicKey: relayMessage.relayMetadata.finalRecipient,
      senderPublicKey: relayMessage.relayMetadata.originalSender,
      priority: priority,
      queuedAt: queuedAt,
      maxRetries: maxRetries,
      status: status,
      expiresAt: queuedAt.add(ttl),
      // Relay-specific fields
      isRelayMessage: true,
      relayMetadata: relayMessage.relayMetadata,
      originalMessageId: relayMessage.originalMessageId,
      relayNodeId: relayMessage.relayNodeId,
      messageHash: relayMessage.relayMetadata.messageHash,
      senderRateCount: relayMessage.relayMetadata.senderRateCount,
    );
  }

  /// Check if message can be relayed further
  bool get canRelay =>
      isRelayMessage && relayMetadata != null && relayMetadata!.canRelay;

  /// Get relay hop count
  int get relayHopCount => relayMetadata?.hopCount ?? 0;

  /// Check if this message has exceeded TTL
  bool get hasExceededTTL =>
      relayMetadata != null && relayMetadata!.hopCount >= relayMetadata!.ttl;

  /// Create next hop relay message
  QueuedMessage createNextHopRelay(String nextRelayNodeId) {
    if (!canRelay || relayMetadata == null) {
      throw RelayException('Cannot create next hop: message cannot be relayed');
    }

    final nextMetadata = relayMetadata!.nextHop(nextRelayNodeId);

    return QueuedMessage(
      id: '${originalMessageId}_relay_${DateTime.now().millisecondsSinceEpoch}',
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      queuedAt: DateTime.now(),
      maxRetries: maxRetries,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      // Relay-specific fields
      isRelayMessage: true,
      relayMetadata: nextMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: nextRelayNodeId,
      messageHash: messageHash,
      senderRateCount: senderRateCount,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'id': id,
    'chatId': chatId,
    'content': content,
    'recipientPublicKey': recipientPublicKey,
    'senderPublicKey': senderPublicKey,
    'priority': priority.index,
    'queuedAt': queuedAt.millisecondsSinceEpoch,
    'maxRetries': maxRetries,
    'replyToMessageId': replyToMessageId,
    'attachments': attachments,
    'status': status.index,
    'attempts': attempts,
    'lastAttemptAt': lastAttemptAt?.millisecondsSinceEpoch,
    'nextRetryAt': nextRetryAt?.millisecondsSinceEpoch,
    'deliveredAt': deliveredAt?.millisecondsSinceEpoch,
    'failedAt': failedAt?.millisecondsSinceEpoch,
    'failureReason': failureReason,
    // Relay-specific fields (for backward compatibility, only include if present)
    'isRelayMessage': isRelayMessage,
    if (relayMetadata != null) 'relayMetadata': relayMetadata!.toJson(),
    if (originalMessageId != null) 'originalMessageId': originalMessageId,
    if (relayNodeId != null) 'relayNodeId': relayNodeId,
    if (messageHash != null) 'messageHash': messageHash,
    'senderRateCount': senderRateCount,
  };

  /// Create from JSON
  factory QueuedMessage.fromJson(Map<String, dynamic> json) => QueuedMessage(
    id: json['id'],
    chatId: json['chatId'],
    content: json['content'],
    recipientPublicKey: json['recipientPublicKey'],
    senderPublicKey: json['senderPublicKey'],
    priority: MessagePriority.values[json['priority']],
    queuedAt: DateTime.fromMillisecondsSinceEpoch(json['queuedAt']),
    maxRetries: json['maxRetries'],
    replyToMessageId: json['replyToMessageId'],
    attachments: List<String>.from(json['attachments'] ?? []),
    status: QueuedMessageStatus.values[json['status']],
    attempts: json['attempts'] ?? 0,
    lastAttemptAt: json['lastAttemptAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastAttemptAt'])
        : null,
    nextRetryAt: json['nextRetryAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['nextRetryAt'])
        : null,
    deliveredAt: json['deliveredAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['deliveredAt'])
        : null,
    failedAt: json['failedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['failedAt'])
        : null,
    failureReason: json['failureReason'],
    // Relay-specific fields (backward compatible - default to false/null if not present)
    isRelayMessage: json['isRelayMessage'] ?? false,
    relayMetadata: json['relayMetadata'] != null
        ? RelayMetadata.fromJson(json['relayMetadata'])
        : null,
    originalMessageId: json['originalMessageId'],
    relayNodeId: json['relayNodeId'],
    messageHash: json['messageHash'],
    senderRateCount: json['senderRateCount'] ?? 0,
  );
}

/// Queue message status
enum QueuedMessageStatus {
  pending,
  sending,
  awaitingAck, // Waiting for final recipient ACK in mesh relay
  retrying,
  delivered,
  failed,
}

/// Queue statistics
class QueueStatistics {
  final int totalQueued;
  final int totalDelivered;
  final int totalFailed;
  final int pendingMessages;
  final int sendingMessages;
  final int retryingMessages;
  final int failedMessages;
  final bool isOnline;
  final QueuedMessage? oldestPendingMessage;
  final Duration averageDeliveryTime;

  // PRIORITY 1 FIX: Add queue size tracking
  final int directQueueSize;
  final int relayQueueSize;

  const QueueStatistics({
    required this.totalQueued,
    required this.totalDelivered,
    required this.totalFailed,
    required this.pendingMessages,
    required this.sendingMessages,
    required this.retryingMessages,
    required this.failedMessages,
    required this.isOnline,
    this.oldestPendingMessage,
    required this.averageDeliveryTime,
    this.directQueueSize = 0, // Default for backward compatibility
    this.relayQueueSize = 0, // Default for backward compatibility
  });

  /// Get delivery success rate
  double get successRate {
    final totalAttempted = totalDelivered + totalFailed;
    return totalAttempted > 0 ? totalDelivered / totalAttempted : 0.0;
  }

  /// Get queue health score (0.0 - 1.0)
  double get queueHealthScore {
    final totalActive = pendingMessages + sendingMessages + retryingMessages;
    final healthFactors = [
      successRate, // Delivery success rate
      isOnline ? 1.0 : 0.5, // Connection status
      totalActive < 10 ? 1.0 : (10 / totalActive), // Queue congestion
      failedMessages < 5 ? 1.0 : (5 / failedMessages), // Failed message ratio
    ];

    return healthFactors.reduce((a, b) => a + b) / healthFactors.length;
  }

  @override
  String toString() =>
      'QueueStats(pending: $pendingMessages, success: ${(successRate * 100).toStringAsFixed(1)}%, health: ${(queueHealthScore * 100).toStringAsFixed(1)}%)';
}

/// Exception for queue operations
class MessageQueueException implements Exception {
  final String message;
  const MessageQueueException(this.message);

  @override
  String toString() => 'MessageQueueException: $message';
}

/// In-memory repository fallback for environments without SQLite (e.g., unit tests).
class _InMemoryQueueRepository implements IMessageQueueRepository {
  final List<QueuedMessage> directMessageQueue;
  final List<QueuedMessage> relayMessageQueue;
  final Set<String> deletedMessageIds;

  _InMemoryQueueRepository({
    List<QueuedMessage>? directMessageQueue,
    List<QueuedMessage>? relayMessageQueue,
    Set<String>? deletedMessageIds,
  }) : directMessageQueue = directMessageQueue ?? [],
       relayMessageQueue = relayMessageQueue ?? [],
       deletedMessageIds = deletedMessageIds ?? {};

  @override
  Future<void> loadQueueFromStorage() async {}

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {}

  @override
  Future<void> deleteMessageFromStorage(String messageId) async {}

  @override
  Future<void> saveQueueToStorage() async {}

  @override
  Future<void> loadDeletedMessageIds() async {}

  @override
  Future<void> saveDeletedMessageIds() async {}

  @override
  QueuedMessage? getMessageById(String messageId) {
    return getAllMessages().where((m) => m.id == messageId).firstOrNull;
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return getAllMessages().where((m) => m.status == status).toList();
  }

  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  @override
  Future<void> removeMessage(String messageId) async {
    removeMessageFromQueue(messageId);
  }

  @override
  QueuedMessage? getOldestPendingMessage() {
    final pending = getPendingMessages();
    pending.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return pending.isEmpty ? null : pending.first;
  }

  @override
  List<QueuedMessage> getAllMessages() {
    return [...directMessageQueue, ...relayMessageQueue];
  }

  @override
  void insertMessageByPriority(QueuedMessage message) {
    final targetQueue = message.isRelayMessage
        ? relayMessageQueue
        : directMessageQueue;
    int insertIndex = 0;
    for (int i = 0; i < targetQueue.length; i++) {
      if (targetQueue[i].priority.index <= message.priority.index) {
        insertIndex = i;
        break;
      }
      insertIndex = i + 1;
    }
    targetQueue.insert(insertIndex, message);
  }

  @override
  void removeMessageFromQueue(String messageId) {
    directMessageQueue.removeWhere((m) => m.id == messageId);
    relayMessageQueue.removeWhere((m) => m.id == messageId);
  }

  @override
  bool isMessageDeleted(String messageId) {
    return deletedMessageIds.contains(messageId);
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    deletedMessageIds.add(messageId);
    removeMessageFromQueue(messageId);
  }

  @override
  Map<String, dynamic> queuedMessageToDb(QueuedMessage message) => {};

  @override
  QueuedMessage queuedMessageFromDb(Map<String, dynamic> row) {
    throw UnimplementedError(
      'In-memory repository does not deserialize DB rows',
    );
  }
}

/// No-op persistence manager for environments without SQLite.
class _NoopQueuePersistenceManager implements IQueuePersistenceManager {
  @override
  Future<bool> createQueueTablesIfNotExist() async => true;

  @override
  Future<void> migrateQueueSchema({
    required int oldVersion,
    required int newVersion,
  }) async {}

  @override
  Future<Map<String, dynamic>> getQueueTableStats() async => {
    'tableCount': 0,
    'rowCount': 0,
  };

  @override
  Future<void> vacuumQueueTables() async {}

  @override
  Future<String?> backupQueueData() async => null;

  @override
  Future<bool> restoreQueueData(String backupPath) async => true;

  @override
  Future<Map<String, dynamic>> getQueueTableHealth() async => {
    'ok': true,
    'rowCount': 0,
  };

  @override
  Future<int> ensureQueueConsistency() async => 0;
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
