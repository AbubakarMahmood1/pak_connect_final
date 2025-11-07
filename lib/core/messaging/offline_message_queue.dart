// Comprehensive offline message delivery and queue management system

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../data/database/database_helper.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/enhanced_message.dart';
import '../security/message_security.dart';
import '../models/mesh_relay_models.dart';

/// Comprehensive offline message queue with intelligent retry and delivery management
class OfflineMessageQueue {
  static final _logger = Logger('OfflineMessageQueue');

  static const int _maxRetries = 5;
  static const Duration _initialDelay = Duration(seconds: 2);
  static const Duration _maxDelay = Duration(minutes: 10);

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
  final Map<String, Timer> _activeRetries = {};

  // Bandwidth allocation constant
  static const double _directBandwidthRatio =
      0.8; // 80% for direct, 20% for relay

  // Contact repository for favorites support
  ContactRepository? _contactRepository;

  // Queue hash synchronization
  final Set<String> _deletedMessageIds = {};
  String? _cachedQueueHash;
  DateTime? _lastHashCalculation;

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

  /// Initialize the offline message queue
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
    Function()? onConnectivityCheck,
    ContactRepository? contactRepository,
  }) async {
    this.onMessageQueued = onMessageQueued;
    this.onMessageDelivered = onMessageDelivered;
    this.onMessageFailed = onMessageFailed;
    this.onStatsUpdated = onStatsUpdated;
    this.onSendMessage = onSendMessage;
    this.onConnectivityCheck = onConnectivityCheck;
    _contactRepository = contactRepository;

    await _loadQueueFromStorage();
    await _loadDeletedMessageIds();
    await _performMigrationIfNeeded();
    _startConnectivityMonitoring();
    _startPeriodicCleanup();

    final totalMessages =
        _directMessageQueue.length + _relayMessageQueue.length;
    _logger.info(
      'Offline message queue initialized with $totalMessages pending messages (direct: ${_directMessageQueue.length}, relay: ${_relayMessageQueue.length})${_contactRepository != null ? ' (favorites support enabled)' : ''}',
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

      if (_contactRepository != null) {
        try {
          isFavorite = await _contactRepository!.isContactFavorite(
            recipientPublicKey,
          );
          if (isFavorite) {
            peerLimit = _maxMessagesPerFavorite;

            // Auto-boost priority for favorite contacts (if not already high/urgent)
            if (priority == MessagePriority.normal ||
                priority == MessagePriority.low) {
              priority = MessagePriority.high;
              _logger.fine(
                '⭐ Auto-boosted priority to HIGH for favorite contact ${recipientPublicKey.substring(0, 8)}...',
              );
            }
          }
        } catch (e) {
          _logger.warning(
            'Failed to check favorite status for ${recipientPublicKey.substring(0, 8)}...: $e',
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
          'Queue limit reached for $limitType contact ${recipientPublicKey.substring(0, 8)}...: '
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
        'Message queued [$queueType]: ${messageId.substring(0, 16)}... (priority: ${priority.name}, peer: ${existingMessagesForPeer + 1}/$peerLimit)$favoriteTag',
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
          '⏳ Still waiting for ACK from previous attempt (${timeSinceLastAttempt.inMilliseconds}ms ago) for ${message.id.substring(0, 16)}...',
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
        'Attempting delivery: ${message.id.substring(0, 16)}... (attempt ${message.attempts}/${message.maxRetries})',
      );

      // Note: Skip validation here - sender cannot validate recipient-encrypted messages
      // Validation will be performed by the actual recipient when they decrypt the message
      // This prevents the bug where sender tries to validate content encrypted with recipient's key

      // Attempt actual delivery via callback
      onSendMessage?.call(message.id);

      // Set to awaitingAck status - will be marked delivered when ACK received
      message.status = QueuedMessageStatus.awaitingAck;
      await _saveMessageToStorage(message);

      _logger.info(
        'Message sent, awaiting ACK: ${message.id.substring(0, 16)}...',
      );
    } catch (e) {
      _logger.severe(
        'Delivery attempt failed for ${message.id.substring(0, 16)}...: $e',
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
      'Message delivered successfully [$queueType]: ${messageId.substring(0, 16)}...',
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
      'Delivery failed for ${message.id.substring(0, 16)}...: $reason (attempt ${message.attempts}/${message.maxRetries})',
    );

    // For mesh networking, never permanently fail messages - devices may be offline for long periods
    // Instead, use exponential backoff with increasing delays for persistent retry

    // Calculate exponential backoff delay (cap at 1 hour for very high attempt counts)
    final backoffDelay = _calculateBackoffDelay(message.attempts);

    message.status = QueuedMessageStatus.retrying;
    message.nextRetryAt = DateTime.now().add(backoffDelay);

    await _saveMessageToStorage(message);

    // Schedule retry
    final retryTimer = Timer(backoffDelay, () async {
      if (_isOnline) {
        await _tryDeliveryForMessage(message);
      } else {
        message.status = QueuedMessageStatus.pending;
        await _saveMessageToStorage(message);
      }
    });

    _activeRetries[message.id] = retryTimer;

    _logger.info(
      'Retry scheduled for ${message.id.substring(0, 16)}... in ${backoffDelay.inSeconds}s',
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
          'No queued messages for peer ${peerPublicKey.substring(0, 8)}...',
        );
        return;
      }

      final directCount = peerMessages.where((m) => !m.isRelayMessage).length;
      final relayCount = peerMessages.where((m) => m.isRelayMessage).length;
      _logger.info(
        '📤 Flushing ${peerMessages.length} queued messages for peer ${peerPublicKey.substring(0, 8)}... (direct: $directCount, relay: $relayCount)',
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
          '  Sending queued $queueType message: ${message.id.substring(0, 16)}...',
        );
        await _tryDeliveryForMessage(message);
      }

      // Restore original online state
      _isOnline = wasOnline;

      _logger.info(
        '✅ Queue flush complete for peer ${peerPublicKey.substring(0, 8)}...',
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
          'Cannot change priority: message ${messageId.substring(0, 16)}... not found',
        );
        return false;
      }

      // Don't change if already at desired priority
      if (message.priority == newPriority) {
        _logger.fine(
          'Message ${messageId.substring(0, 16)}... already at priority ${newPriority.name}',
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
        'Changed message ${messageId.substring(0, 16)}... priority [$queueType]: '
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
    // Determine target queue
    final targetQueue = message.isRelayMessage
        ? _relayMessageQueue
        : _directMessageQueue;

    // Find insertion point based on priority
    int insertIndex = 0;
    for (int i = 0; i < targetQueue.length; i++) {
      if (targetQueue[i].priority.index <= message.priority.index) {
        insertIndex = i;
        break;
      }
      insertIndex = i + 1;
    }

    targetQueue.insert(insertIndex, message);

    _logger.fine(
      'Inserted into ${message.isRelayMessage ? "relay" : "direct"} queue at index $insertIndex (queue size: ${targetQueue.length})',
    );
  }

  /// Remove message from queue
  /// PRIORITY 1 FIX: Remove from both queues
  void _removeMessageFromQueue(String messageId) {
    _directMessageQueue.removeWhere((m) => m.id == messageId);
    _relayMessageQueue.removeWhere((m) => m.id == messageId);
  }

  /// Get all messages from both queues (helper for dual-queue operations)
  List<QueuedMessage> _getAllMessages() {
    return [..._directMessageQueue, ..._relayMessageQueue];
  }

  /// Calculate exponential backoff delay
  Duration _calculateBackoffDelay(int attempt) {
    final exponentialDelay = Duration(
      milliseconds: _initialDelay.inMilliseconds * (1 << (attempt - 1)),
    );

    // Cap at maximum delay and add jitter
    final cappedDelay =
        exponentialDelay.inMilliseconds > _maxDelay.inMilliseconds
        ? _maxDelay
        : exponentialDelay;

    // Add random jitter (±25%)
    final jitterRange = cappedDelay.inMilliseconds * 0.25;
    final jitter =
        (DateTime.now().millisecond % (jitterRange * 2)) - jitterRange;

    return Duration(
      milliseconds: (cappedDelay.inMilliseconds + jitter).round(),
    );
  }

  /// Get max retries based on message priority
  int _getMaxRetriesForPriority(MessagePriority priority) {
    switch (priority) {
      case MessagePriority.urgent:
        return _maxRetries + 2;
      case MessagePriority.high:
        return _maxRetries + 1;
      case MessagePriority.normal:
        return _maxRetries;
      case MessagePriority.low:
        return _maxRetries - 1;
    }
  }

  /// Calculate expiry time based on priority
  /// Urgent messages have longer TTL to ensure delivery even with long offline periods
  DateTime _calculateExpiryTime(DateTime queuedAt, MessagePriority priority) {
    Duration ttl;
    switch (priority) {
      case MessagePriority.urgent:
        ttl = Duration(hours: 24); // 24 hours for critical messages
        break;
      case MessagePriority.high:
        ttl = Duration(hours: 12); // 12 hours for important messages
        break;
      case MessagePriority.normal:
        ttl = Duration(hours: 6); // 6 hours for regular messages
        break;
      case MessagePriority.low:
        ttl = Duration(hours: 3); // 3 hours for low priority
        break;
    }
    return queuedAt.add(ttl);
  }

  /// Check if message has expired
  bool _isMessageExpired(QueuedMessage message) {
    if (message.expiresAt == null) return false;
    return DateTime.now().isAfter(message.expiresAt!);
  }

  /// Start connectivity monitoring
  void _startConnectivityMonitoring() {
    _connectivityCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      onConnectivityCheck?.call();
    });
  }

  /// Cancel all active retry timers
  void _cancelAllActiveRetries() {
    for (final timer in _activeRetries.values) {
      timer.cancel();
    }
    _activeRetries.clear();
  }

  /// Cancel retry timer for specific message
  void _cancelRetryTimer(String messageId) {
    _activeRetries[messageId]?.cancel();
    _activeRetries.remove(messageId);
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

  /// Convert QueuedMessage to database row
  Map<String, dynamic> _queuedMessageToDb(QueuedMessage message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'queue_id': message.id,
      'message_id': message.id,
      'chat_id': message.chatId,
      'content': message.content,
      'recipient_public_key': message.recipientPublicKey,
      'sender_public_key': message.senderPublicKey,
      'queued_at': message.queuedAt.millisecondsSinceEpoch,
      'retry_count': message.attempts,
      'max_retries': message.maxRetries,
      'next_retry_at': message.nextRetryAt?.millisecondsSinceEpoch,
      'priority': message.priority.index,
      'status': message.status.index,
      'attempts': message.attempts,
      'last_attempt_at': message.lastAttemptAt?.millisecondsSinceEpoch,
      'delivered_at': message.deliveredAt?.millisecondsSinceEpoch,
      'failed_at': message.failedAt?.millisecondsSinceEpoch,
      'failure_reason': message.failureReason,
      'expires_at': message.expiresAt?.millisecondsSinceEpoch,
      'is_relay_message': message.isRelayMessage ? 1 : 0,
      'original_message_id': message.originalMessageId,
      'relay_node_id': message.relayNodeId,
      'message_hash': message.messageHash,
      'relay_metadata_json': message.relayMetadata != null
          ? jsonEncode(message.relayMetadata!.toJson())
          : null,
      'reply_to_message_id': message.replyToMessageId,
      'attachments_json': message.attachments.isNotEmpty
          ? jsonEncode(message.attachments)
          : null,
      'sender_rate_count': message.senderRateCount,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Convert database row to QueuedMessage
  QueuedMessage _queuedMessageFromDb(Map<String, dynamic> row) {
    return QueuedMessage(
      id: row['message_id'] as String,
      chatId: row['chat_id'] as String,
      content: row['content'] as String,
      recipientPublicKey: row['recipient_public_key'] as String,
      senderPublicKey: row['sender_public_key'] as String,
      priority: MessagePriority.values[row['priority'] as int],
      queuedAt: DateTime.fromMillisecondsSinceEpoch(row['queued_at'] as int),
      maxRetries: row['max_retries'] as int,
      replyToMessageId: row['reply_to_message_id'] as String?,
      attachments: row['attachments_json'] != null
          ? List<String>.from(jsonDecode(row['attachments_json'] as String))
          : [],
      status: QueuedMessageStatus.values[row['status'] as int],
      attempts: row['attempts'] as int,
      lastAttemptAt: row['last_attempt_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['last_attempt_at'] as int)
          : null,
      nextRetryAt: row['next_retry_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['next_retry_at'] as int)
          : null,
      deliveredAt: row['delivered_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['delivered_at'] as int)
          : null,
      failedAt: row['failed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['failed_at'] as int)
          : null,
      failureReason: row['failure_reason'] as String?,
      expiresAt: row['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int)
          : null,
      isRelayMessage: (row['is_relay_message'] as int) == 1,
      relayMetadata: row['relay_metadata_json'] != null
          ? RelayMetadata.fromJson(
              jsonDecode(row['relay_metadata_json'] as String),
            )
          : null,
      originalMessageId: row['original_message_id'] as String?,
      relayNodeId: row['relay_node_id'] as String?,
      messageHash: row['message_hash'] as String?,
      senderRateCount: row['sender_rate_count'] as int? ?? 0,
    );
  }

  /// Load queue from persistent storage
  Future<void> _loadQueueFromStorage() async {
    try {
      final db = await DatabaseHelper.database;
      final List<Map<String, dynamic>> results = await db.query(
        'offline_message_queue',
        orderBy: 'priority DESC, queued_at ASC',
      );

      // PRIORITY 1 FIX: Load into appropriate queue based on isRelayMessage flag
      _directMessageQueue.clear();
      _relayMessageQueue.clear();

      for (final row in results) {
        try {
          final message = _queuedMessageFromDb(row);
          if (message.isRelayMessage) {
            _relayMessageQueue.add(message);
          } else {
            _directMessageQueue.add(message);
          }
        } catch (e) {
          _logger.warning('Failed to parse queued message: $e');
        }
      }

      final totalLoaded =
          _directMessageQueue.length + _relayMessageQueue.length;
      _logger.info(
        'Loaded $totalLoaded messages from storage (direct: ${_directMessageQueue.length}, relay: ${_relayMessageQueue.length})',
      );
    } catch (e) {
      _logger.severe('Failed to load message queue: $e');
    }
  }

  /// Save a single message to persistent storage (optimized for individual updates)
  Future<void> _saveMessageToStorage(QueuedMessage message) async {
    try {
      final db = await DatabaseHelper.database;

      // Use INSERT OR REPLACE for efficiency - updates if exists, inserts if not
      await db.insert(
        'offline_message_queue',
        _queuedMessageToDb(message),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Invalidate hash cache since queue changed
      _cachedQueueHash = null;
      _lastHashCalculation = null;
    } catch (e) {
      _logger.warning(
        'Failed to save message ${message.id.substring(0, 16)}...: $e',
      );
    }
  }

  /// Remove a single message from persistent storage
  Future<void> _deleteMessageFromStorage(String messageId) async {
    try {
      final db = await DatabaseHelper.database;

      await db.delete(
        'offline_message_queue',
        where: 'message_id = ?',
        whereArgs: [messageId],
      );

      // Invalidate hash cache since queue changed
      _cachedQueueHash = null;
      _lastHashCalculation = null;
    } catch (e) {
      _logger.warning(
        'Failed to delete message ${messageId.substring(0, 16)}...: $e',
      );
    }
  }

  /// Save entire queue to persistent storage (used for initial load and bulk operations)
  /// For individual message updates, use _saveMessageToStorage for better performance
  Future<void> _saveQueueToStorage() async {
    try {
      final db = await DatabaseHelper.database;

      // PRIORITY 1 FIX: Save both queues
      // Use transaction for atomic operations
      await db.transaction((txn) async {
        // Clear and reinsert all messages
        await txn.delete('offline_message_queue');

        // Save direct messages
        for (final message in _directMessageQueue) {
          await txn.insert(
            'offline_message_queue',
            _queuedMessageToDb(message),
          );
        }

        // Save relay messages
        for (final message in _relayMessageQueue) {
          await txn.insert(
            'offline_message_queue',
            _queuedMessageToDb(message),
          );
        }
      });

      // Invalidate hash cache since queue changed
      _cachedQueueHash = null;
      _lastHashCalculation = null;
    } catch (e) {
      _logger.warning('Failed to save message queue: $e');
    }
  }

  /// Load deleted message IDs from persistent storage
  Future<void> _loadDeletedMessageIds() async {
    try {
      final db = await DatabaseHelper.database;
      final List<Map<String, dynamic>> results = await db.query(
        'deleted_message_ids',
      );

      _deletedMessageIds.clear();
      for (final row in results) {
        _deletedMessageIds.add(row['message_id'] as String);
      }

      _logger.info('Loaded ${_deletedMessageIds.length} deleted message IDs');
    } catch (e) {
      _logger.severe('Failed to load deleted message IDs: $e');
    }
  }

  /// Save deleted message IDs to persistent storage
  Future<void> _saveDeletedMessageIds() async {
    try {
      final db = await DatabaseHelper.database;

      await db.transaction((txn) async {
        // Clear and reinsert all deleted IDs
        await txn.delete('deleted_message_ids');

        for (final messageId in _deletedMessageIds) {
          await txn.insert('deleted_message_ids', {
            'message_id': messageId,
            'deleted_at': DateTime.now().millisecondsSinceEpoch,
          });
        }
      });
    } catch (e) {
      _logger.warning('Failed to save deleted message IDs: $e');
    }
  }

  // ===== QUEUE HASH SYNCHRONIZATION METHODS =====

  /// Calculate deterministic hash of current queue state
  /// Excludes delivered/expired messages and includes deleted message tracking
  String calculateQueueHash({bool forceRecalculation = false}) {
    if (!forceRecalculation &&
        _cachedQueueHash != null &&
        _lastHashCalculation != null) {
      // Use cache if less than 30 seconds old
      final cacheAge = DateTime.now().difference(_lastHashCalculation!);
      if (cacheAge.inSeconds < 30) {
        return _cachedQueueHash!;
      }
    }

    // PRIORITY 1 FIX: Get syncable messages from both queues
    final syncableMessages = _getAllMessages()
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed,
        )
        .toList();

    // Sort by message ID for consistent ordering
    syncableMessages.sort((a, b) => a.id.compareTo(b.id));

    // Create hash input combining message metadata and deleted IDs
    final hashComponents = <String>[];

    // Add active message metadata
    for (final message in syncableMessages) {
      final messageData = _getMessageHashData(message);
      hashComponents.add(messageData);
    }

    // Add deleted message IDs (sorted for consistency)
    final sortedDeletedIds = _deletedMessageIds.toList()..sort();
    hashComponents.addAll(sortedDeletedIds.map((id) => 'deleted:$id'));

    // Calculate final hash
    final combinedData = hashComponents.join('|');
    final bytes = utf8.encode(combinedData);
    final digest = sha256.convert(bytes);

    // Cache result
    _cachedQueueHash = digest.toString();
    _lastHashCalculation = DateTime.now();

    _logger.fine(
      'Calculated queue hash: ${_cachedQueueHash!.substring(0, 16)}... (${syncableMessages.length} messages, ${_deletedMessageIds.length} deleted)',
    );

    return _cachedQueueHash!;
  }

  /// Get hash data for a specific message
  String _getMessageHashData(QueuedMessage message) {
    return [
      message.id,
      message.status.index.toString(),
      message.queuedAt.millisecondsSinceEpoch.toString(),
      message.priority.index.toString(),
      message.attempts.toString(),
      message.messageHash ?? '',
    ].join(':');
  }

  /// Get queue sync information for mesh networking
  QueueSyncMessage createSyncMessage(String nodeId) {
    // PRIORITY 1 FIX: Get syncable messages from both queues
    final syncableMessages = _getAllMessages()
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed,
        )
        .toList();

    final messageIds = syncableMessages.map((m) => m.id).toList();
    final messageHashes = <String, String>{};

    for (final message in syncableMessages) {
      if (message.messageHash != null) {
        messageHashes[message.id] = message.messageHash!;
      }
    }

    return QueueSyncMessage.createRequest(
      messageIds: messageIds,
      nodeId: nodeId,
      messageHashes: messageHashes.isNotEmpty ? messageHashes : null,
    );
  }

  /// Compare queue hashes to determine if synchronization is needed
  bool needsSynchronization(String otherQueueHash) {
    final currentHash = calculateQueueHash();
    return currentHash != otherQueueHash;
  }

  /// Insert a message received via queue synchronization
  Future<void> addSyncedMessage(QueuedMessage message) async {
    // Skip if message was previously deleted (e.g., aged out)
    if (_deletedMessageIds.contains(message.id)) {
      _logger.fine(
        'Sync skip - message ${message.id.substring(0, 8)}... was deleted locally',
      );
      return;
    }

    // Skip if we already have this message
    final exists = _getAllMessages().any((m) => m.id == message.id);
    if (exists) {
      _logger.fine(
        'Sync skip - message already exists: ${message.id.substring(0, 8)}...',
      );
      return;
    }

    // Normalize status for local retry pipeline
    message.status = QueuedMessageStatus.pending;
    message.attempts = 0;
    message.failureReason = null;
    message.nextRetryAt = null;
    message.lastAttemptAt = null;

    _insertMessageByPriority(message);
    await _saveQueueToStorage();
    _totalQueued++;
    _updateStatistics();

    _logger.info(
      '🔄 Synced new queued message: ${message.id.substring(0, 16)}...',
    );
  }

  /// Get missing messages compared to another queue
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    // PRIORITY 1 FIX: Check both queues
    final currentIds = _getAllMessages()
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed,
        )
        .map((m) => m.id)
        .toSet();

    return otherMessageIds
        .where(
          (id) => !currentIds.contains(id) && !_deletedMessageIds.contains(id),
        )
        .toList();
  }

  /// Get excess messages that the other queue doesn't have
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final otherIdSet = otherMessageIds.toSet();

    // PRIORITY 1 FIX: Get from both queues
    return _getAllMessages()
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed &&
              !otherIdSet.contains(m.id),
        )
        .toList();
  }

  /// Mark message as deleted for sync purposes
  Future<void> markMessageDeleted(String messageId) async {
    _deletedMessageIds.add(messageId);
    await _saveDeletedMessageIds();

    // Remove from active queue if present
    _removeMessageFromQueue(messageId);
    await _saveQueueToStorage();

    _logger.info(
      'Message marked as deleted: ${messageId.length > 16 ? "${messageId.substring(0, 16)}..." : messageId}',
    );
  }

  /// Check if message was deleted
  bool isMessageDeleted(String messageId) {
    return _deletedMessageIds.contains(messageId);
  }

  /// Clean up old deleted message IDs with improved performance
  Future<void> cleanupOldDeletedIds() async {
    final initialCount = _deletedMessageIds.length;

    // Performance-optimized cleanup based on size threshold
    if (_deletedMessageIds.length > _cleanupThreshold) {
      final deletedList = _deletedMessageIds.toList()..sort();
      _deletedMessageIds.clear();
      _deletedMessageIds.addAll(deletedList.take(_maxDeletedIdsToKeep));

      await _saveDeletedMessageIds();
      _logger.info(
        'Cleaned up ${initialCount - _deletedMessageIds.length} old deleted message IDs (performance optimization)',
      );
    }
  }

  /// Invalidate hash cache (call after manual queue modifications)
  void invalidateHashCache() {
    _cachedQueueHash = null;
    _lastHashCalculation = null;
  }

  /// Perform legacy data migration for backward compatibility
  Future<void> _performMigrationIfNeeded() async {
    // Migration from SharedPreferences is handled by MigrationService
    // This method is kept for backward compatibility but does nothing
    _logger.fine('SQLite-based queue - no migration needed');
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
      if (_lastHashCalculation != null) {
        final cacheAge = DateTime.now().difference(_lastHashCalculation!);
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
            'Message ${message.id.substring(0, 16)}... expired (TTL exceeded)',
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
            'Message ${message.id.substring(0, 16)}... expired (TTL exceeded)',
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

    // Delete expired messages from storage
    if (expiredIds.isNotEmpty) {
      final db = await DatabaseHelper.database;
      await db.transaction((txn) async {
        for (final id in expiredIds) {
          await txn.delete(
            'offline_message_queue',
            where: 'message_id = ?',
            whereArgs: [id],
          );
        }
      });

      // Invalidate hash cache
      _cachedQueueHash = null;
      _lastHashCalculation = null;

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
    // PRIORITY 1 FIX: Include both queue stats
    return {
      'totalMessages': _directMessageQueue.length + _relayMessageQueue.length,
      'directMessages': _directMessageQueue.length,
      'relayMessages': _relayMessageQueue.length,
      'deletedIdsCount': _deletedMessageIds.length,
      'hashCacheAge': _lastHashCalculation != null
          ? DateTime.now().difference(_lastHashCalculation!).inSeconds
          : null,
      'hashCached': _cachedQueueHash != null,
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
