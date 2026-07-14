// Comprehensive offline message delivery and queue management system

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';
import 'package:pak_connect/domain/interfaces/i_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/utils/app_logger.dart';
import '../services/message_queue_repository.dart';
import '../services/queue_persistence_manager.dart';
import '../services/queue_sync_coordinator.dart';
import '../services/queue_policy_manager.dart';
import '../services/queue_bandwidth_allocator.dart';
import 'offline_queue_store.dart';
import 'offline_queue_scheduler.dart';
import 'offline_queue_sync.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import '../../domain/values/id_types.dart';
import 'offline_message_queue_platform_bootstrap.dart';

export '../../domain/messaging/offline_message_queue_contract.dart'
    show
        OfflineQueuePrepareSendCallback,
        OfflineQueuePreparedSend,
        OfflineQueuePreparedSendDisposition,
        OfflineQueueSendCallback,
        OfflineQueueSendDisposition;

part 'offline_message_queue_maintenance_helper.dart';

/// Comprehensive offline message queue with intelligent retry and delivery management
class OfflineMessageQueue implements OfflineMessageQueueContract {
  static final _logger = Logger('OfflineMessageQueue');
  static IRepositoryProvider? _defaultRepositoryProvider;

  static const int _maxRetries = 5;
  static const Duration _ackTimeout = Duration(seconds: 5);
  static const Duration _finalizationRetryBaseDelay = Duration(
    milliseconds: 50,
  );
  static const Duration _finalizationRetryMaxDelay = Duration(seconds: 5);

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
  final bool _allowVolatileStorage;

  late final QueueStore _store = QueueStore(
    directMessageQueue: _directMessageQueue,
    relayMessageQueue: _relayMessageQueue,
    deletedMessageIds: _deletedMessageIds,
    queueRepository: _initialQueueRepository,
    queuePersistenceManager: _initialQueuePersistenceManager,
    allowVolatileStorage: _allowVolatileStorage,
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
  late final _OfflineMessageQueueMaintenanceHelper _maintenanceHelper =
      _OfflineMessageQueueMaintenanceHelper(this);

  // Repository provider for favorites support
  IRepositoryProvider? _repositoryProvider;
  IDatabaseProvider? _databaseProvider;

  // Queue hash synchronization
  final Set<MessageId> _deletedMessageIds = {};

  // Connection monitoring
  bool _isOnline = false;
  bool _disposed = false;
  int _deliveryGeneration = 0;

  /// Serializes durable queue transitions. Transport callbacks are deliberately
  /// awaited outside this lock so slow BLE work cannot block queue mutations.
  final Lock _mutationLock = Lock();
  final Set<String> _deliveryInFlightIds = <String>{};
  final Map<String, Timer> _staggerTimers = <String, Timer>{};
  final Map<String, _PendingDeliveryFinalization>
  _pendingDeliveryFinalizations = <String, _PendingDeliveryFinalization>{};
  final Map<String, Timer> _finalizationRetryTimers = <String, Timer>{};

  // Statistics
  int _totalQueued = 0;
  int _totalDelivered = 0;
  int _totalFailed = 0;

  // Callbacks
  Function(QueuedMessage message)? onMessageQueued;
  Function(QueuedMessage message)? onMessageDelivered;
  Function(QueuedMessage message, String reason)? onMessageFailed;
  Function(QueueStatistics stats)? onStatsUpdated;
  OfflineQueueSendCallback? onSendMessage;
  Function()? onConnectivityCheck;

  OfflineMessageQueue({
    IMessageQueueRepository? queueRepository,
    IQueuePersistenceManager? queuePersistenceManager,
    IRetryScheduler? retryScheduler,
    bool allowVolatileStorage = false,
  }) : _initialQueueRepository = queueRepository,
       _initialQueuePersistenceManager = queuePersistenceManager,
       _initialRetryScheduler = retryScheduler,
       _allowVolatileStorage = allowVolatileStorage;

  static void configureDefaultRepositoryProvider(
    IRepositoryProvider repositoryProvider,
  ) {
    _defaultRepositoryProvider = repositoryProvider;
  }

  static void clearDefaultRepositoryProvider() {
    _defaultRepositoryProvider = null;
  }

  static bool get hasDefaultRepositoryProvider =>
      _defaultRepositoryProvider != null;

  IMessageQueueRepository get _repo => _store.repo;

  /// Initialize the offline message queue
  @override
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    OfflineQueueSendCallback? onSendMessage,
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
    } else if (_defaultRepositoryProvider != null) {
      _repositoryProvider = _defaultRepositoryProvider;
    } else {
      _logger.warning(
        'ℹ️ IRepositoryProvider not registered - favorites-based limits disabled',
      );
      _repositoryProvider = null;
    }

    await ensureOfflineQueueDatabaseFactoryReady();

    if (databaseProvider != null) {
      _databaseProvider = databaseProvider;
      MessageQueueRepository.configureDefaultDatabaseProvider(databaseProvider);
      QueuePersistenceManager.configureDefaultDatabaseProvider(
        databaseProvider,
      );
    } else if (_databaseProvider == null &&
        (MessageQueueRepository.hasDefaultDatabaseProvider ||
            QueuePersistenceManager.hasDefaultDatabaseProvider)) {
      // Database access will resolve through repository/persistence defaults.
      _databaseProvider = null;
    }

    _store.setDatabaseProvider(_databaseProvider);
    await _store.initializePersistence(logger: _logger);
    await _queueSync.initialize();
    _startConnectivityMonitoring();
    _startPeriodicCleanup();

    final allMessages = _getAllMessages();
    final directCount = allMessages
        .where((message) => !message.isRelayMessage)
        .length;
    final relayCount = allMessages.length - directCount;
    _logger.info(
      'Offline message queue initialized with ${allMessages.length} pending messages (direct: $directCount, relay: $relayCount)${_repositoryProvider != null ? ' (favorites support enabled)' : ''}',
    );
  }

  /// Queue a message for offline delivery
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
    try {
      if (!persistToStorage && !isRelayMessage) {
        throw const MessageQueueException(
          'Direct messages require durable queue storage',
        );
      }

      // Apply favorites-based priority boost
      final boostResult = await _policy.applyFavoritesPriorityBoost(
        recipientPublicKey: recipientPublicKey,
        currentPriority: priority,
      );
      // Use boosted priority without mutating parameter
      final effectivePriority = boostResult.priority;

      late QueueLimitValidation validation;

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
        attachments: List<String>.of(attachments),
        attempts: 0,
        maxRetries: _getMaxRetriesForPriority(effectivePriority),
        expiresAt: _calculateExpiryTime(now, effectivePriority),
        isRelayMessage: isRelayMessage,
        relayMetadata: _copyRelayMetadata(relayMetadata),
        originalMessageId: originalMessageId,
        relayNodeId: relayNodeId,
        messageHash: messageHash,
      );

      await _mutationLock.synchronized(() async {
        if (_disposed) {
          throw const MessageQueueException('Offline queue is disposed');
        }
        // Capacity validation and publication share one mutation critical
        // section so concurrent admissions cannot both observe the same final
        // slot for a peer.
        validation = await _policy.validateQueueLimit(
          recipientPublicKey: recipientPublicKey,
          allMessages: _getAllMessages(),
        );
        if (!validation.isValid) {
          _logger.warning(
            'Queue limit reached for ${validation.limitType} contact '
            '${recipientPublicKey.shortId(8)}...: '
            '${validation.currentCount}/${validation.limit} messages',
          );
          throw MessageQueueException(validation.errorMessage);
        }

        // Durable admission is persistence-first and serialized with clear and
        // delete. A failed write must not leave a ghost visible to workers.
        if (persistToStorage) {
          await _saveMessageToStorage(queuedMessage);
        } else {
          _logger.fine(
            '🧭 Relay message queued without persistence: ${messageId.shortId(8)}...',
          );
        }

        // dispose() is synchronous and may run while the durable write above
        // is awaiting I/O. Roll back that row before returning instead of
        // publishing a queue item after disposal.
        if (_disposed) {
          if (persistToStorage) {
            await _transitionStateIfCurrent(
              expected: queuedMessage,
              replacement: null,
            );
          }
          throw const MessageQueueException('Offline queue is disposed');
        }

        _insertMessageByPriority(queuedMessage);
        invalidateHashCache();
        _totalQueued++;
      });

      if (!_disposed) {
        _notifyObserver(
          'onMessageQueued',
          () => onMessageQueued?.call(queuedMessage),
        );
        _updateStatistics();
      }

      final favoriteTag = boostResult.isFavorite ? ' ⭐' : '';
      final queueType = queuedMessage.isRelayMessage ? 'relay' : 'direct';
      _logger.info(
        'Message queued [$queueType]: ${messageId.shortId()}... (priority: ${effectivePriority.name}, peer: ${validation.currentCount + 1}/${validation.limit})$favoriteTag',
      );

      // Attempt immediate delivery if online
      if (_isOnline) {
        unawaited(_tryDeliveryForMessage(queuedMessage));
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

  /// Remove all queued messages for a specific chat (used when a chat is deleted)
  @override
  Future<int> removeMessagesForChat(String chatId) async {
    final toRemove = await _mutationLock.synchronized(() async {
      if (_disposed) return <String>{};
      final ids = _getAllMessages()
          .where((message) => message.chatId == chatId)
          .map((message) => message.id)
          .toSet();
      if (ids.isEmpty) return ids;

      await _store.markMessagesDeleted(ids);
      for (final id in ids) {
        _cancelPendingDeliveryFinalization(id);
        _queueScheduler.cancelRetryTimer(id);
        _cancelStaggerTimer(id);
      }
      invalidateHashCache();
      return ids;
    });

    if (toRemove.isNotEmpty) {
      _logger.info(
        '🧹 Removed ${toRemove.length} queued messages for chat: ${chatId.shortId(8)}...',
      );
    }

    return toRemove.length;
  }

  /// Mark connection as online and attempt delivery of queued messages
  @override
  Future<void> setOnline() async {
    final ackWaits = <({QueuedMessage message, Duration delay})>[];
    final retryWaits = <({QueuedMessage message, Duration delay})>[];
    await _mutationLock.synchronized(() async {
      if (_disposed) return;

      _isOnline = true;
      final now = DateTime.now();
      for (final message in _getAllMessages()) {
        if (message.status == QueuedMessageStatus.sending &&
            _deliveryInFlightIds.contains(message.id)) {
          continue;
        }
        if (message.status == QueuedMessageStatus.retrying &&
            message.nextRetryAt != null &&
            message.nextRetryAt!.isAfter(now)) {
          retryWaits.add((
            message: message,
            delay: message.nextRetryAt!.difference(now),
          ));
          continue;
        }

        if (message.status == QueuedMessageStatus.sending ||
            message.status == QueuedMessageStatus.retrying) {
          final candidate = _detachedCopy(message)
            ..status = QueuedMessageStatus.pending
            ..nextRetryAt = null;
          final transition = await _transitionStateIfCurrent(
            expected: message,
            replacement: candidate,
          );
          if (transition.applied) {
            _applyMutableState(message, transition.current ?? candidate);
          } else {
            _reconcileLiveMessageWithDurableState(message, transition.current);
            final current = transition.current;
            if (current?.status == QueuedMessageStatus.retrying) {
              final retryAt = current!.nextRetryAt;
              retryWaits.add((
                message: message,
                delay: retryAt == null
                    ? Duration.zero
                    : _remainingDelayUntil(retryAt),
              ));
            } else if (current?.status == QueuedMessageStatus.awaitingAck) {
              final lastAttemptAt = current!.lastAttemptAt;
              ackWaits.add((
                message: message,
                delay: lastAttemptAt == null
                    ? Duration.zero
                    : _remainingDelayUntil(lastAttemptAt.add(_ackTimeout)),
              ));
            }
          }
          continue;
        }

        if (message.status != QueuedMessageStatus.awaitingAck) continue;
        final lastAttemptAt = message.lastAttemptAt;
        final elapsed = lastAttemptAt == null
            ? _ackTimeout
            : now.difference(lastAttemptAt);
        if (lastAttemptAt == null || elapsed >= _ackTimeout) {
          final candidate = _detachedCopy(message)
            ..status = QueuedMessageStatus.pending
            ..nextRetryAt = null;
          final transition = await _transitionStateIfCurrent(
            expected: message,
            replacement: candidate,
          );
          if (transition.applied) {
            _applyMutableState(message, transition.current ?? candidate);
          } else {
            _reconcileLiveMessageWithDurableState(message, transition.current);
          }
        } else {
          ackWaits.add((message: message, delay: _ackTimeout - elapsed));
        }
      }
    });

    if (_disposed) return;
    for (final wait in ackWaits) {
      _scheduleAckTimeout(wait.message, wait.delay);
    }
    for (final wait in retryWaits) {
      _scheduleRetry(wait.message, wait.delay);
    }

    final allMessages = _getAllMessages();
    final directCount = allMessages
        .where((message) => !message.isRelayMessage)
        .length;
    final relayCount = allMessages.length - directCount;
    _logger.info(
      'Connection online - attempting delivery of ${allMessages.length} queued messages (direct: $directCount, relay: $relayCount)',
    );
    await _processQueue();
  }

  /// Mark connection as offline
  @override
  void setOffline() {
    if (_isOnline) {
      _isOnline = false;
      _deliveryGeneration++;
      _logger.info('Connection offline - queuing future messages');
      _cancelAllActiveRetries();
      _cancelAllStaggerTimers();
    }
  }

  /// Process the entire message queue
  /// PRIORITY 1 FIX: 80/20 bandwidth allocation (direct vs relay)
  Future<void> _processQueue() async {
    if (_disposed || !_isOnline) return;
    final allMessages = _getAllMessages();
    final directMessages = allMessages
        .where((message) => !message.isRelayMessage)
        .toList(growable: false);
    final relayMessages = allMessages
        .where((message) => message.isRelayMessage)
        .toList(growable: false);
    final totalDirect = directMessages.length;
    final totalRelay = relayMessages.length;

    if (totalDirect == 0 && totalRelay == 0) return;

    // Create delivery schedule with 80/20 bandwidth allocation
    final schedule = _bandwidth.createDeliverySchedule(
      directQueue: directMessages,
      relayQueue: relayMessages,
    );

    if (schedule.isEmpty) return;

    // Execute scheduled deliveries
    for (final scheduledMessage in schedule.schedule) {
      _scheduleStaggeredDelivery(scheduledMessage);
    }

    _logger.info(
      'Queue processing scheduled: direct=${schedule.directCount}, relay=${schedule.relayCount} (total slots: ${schedule.totalScheduled})',
    );
  }

  /// Attempt delivery for a specific message
  Future<OfflineQueueSendDisposition?> _tryDeliveryForMessage(
    QueuedMessage message,
  ) async {
    final callback = onSendMessage;
    final attempt = await _admitDeliveryAttempt(
      message,
      tryStart: callback == null
          ? () => throw StateError('No queue transport callback configured')
          : () => callback(message.id),
      transportInvoked: callback != null,
    );
    return attempt?.outcome;
  }

  Future<_AdmittedDeliveryAttempt?> _admitDeliveryAttempt(
    QueuedMessage message, {
    required FutureOr<OfflineQueueSendDisposition>? Function() tryStart,
    required bool transportInvoked,
  }) async {
    QueuedMessage? preAttemptState;
    try {
      final admitted = await _mutationLock.synchronized(() async {
        if (_disposed || !_isOnline) return false;
        final deliveryGeneration = _deliveryGeneration;
        final live = _findLiveMessage(message.id);
        if (!identical(live, message) ||
            message.status != QueuedMessageStatus.pending ||
            _deliveryInFlightIds.contains(message.id)) {
          return false;
        }

        preAttemptState = _detachedCopy(message);
        final candidate = _detachedCopy(message)
          ..status = QueuedMessageStatus.sending
          ..attempts = message.attempts + 1
          ..lastAttemptAt = DateTime.now()
          ..nextRetryAt = null
          ..failedAt = null
          ..failureReason = null;
        final admission = await _transitionStateIfCurrent(
          expected: message,
          replacement: candidate,
        );
        if (!admission.applied) {
          _reconcileLiveMessageWithDurableState(message, admission.current);
          return false;
        }
        if (_disposed ||
            !_isOnline ||
            deliveryGeneration != _deliveryGeneration) {
          final rollback = await _transitionStateIfCurrent(
            expected: candidate,
            replacement: preAttemptState!,
          );
          if (!rollback.applied) {
            _reconcileLiveMessageWithDurableState(message, rollback.current);
          }
          return false;
        }
        _applyMutableState(message, admission.current ?? candidate);
        _deliveryInFlightIds.add(message.id);
        return true;
      });
      if (!admitted) return null;

      _logger.fine(
        'Attempting delivery: ${message.id.shortId()}... (attempt ${message.attempts}/${message.maxRetries})',
      );

      // Note: Skip validation here - sender cannot validate recipient-encrypted messages
      // Validation will be performed by the actual recipient when they decrypt the message
      // This prevents the bug where sender tries to validate content encrypted with recipient's key

      FutureOr<OfflineQueueSendDisposition>? startedOutcome;
      try {
        startedOutcome = tryStart();
      } catch (error) {
        await _executeDeliveryAttempt(
          message: message,
          preAttemptState: preAttemptState!,
          startedOutcome: OfflineQueueSendDisposition.failed,
          transportInvoked: false,
          synchronousStartError: error,
        );
        return null;
      }

      if (startedOutcome == null) {
        await _executeDeliveryAttempt(
          message: message,
          preAttemptState: preAttemptState!,
          startedOutcome: OfflineQueueSendDisposition.deferred,
          transportInvoked: false,
        );
        return null;
      }

      final outcome = _executeDeliveryAttempt(
        message: message,
        preAttemptState: preAttemptState!,
        startedOutcome: startedOutcome,
        transportInvoked: transportInvoked,
      );
      return _AdmittedDeliveryAttempt(outcome);
    } catch (e, stackTrace) {
      _logger.severe(
        'Delivery admission failed for ${message.id.shortId()}...: $e',
        e,
        stackTrace,
      );
      return null;
    }
  }

  Future<OfflineQueueSendDisposition?> _executeDeliveryAttempt({
    required QueuedMessage message,
    required QueuedMessage preAttemptState,
    required FutureOr<OfflineQueueSendDisposition> startedOutcome,
    required bool transportInvoked,
    Object? synchronousStartError,
  }) async {
    Object? sendError = synchronousStartError;
    var disposition = OfflineQueueSendDisposition.failed;
    if (synchronousStartError == null) {
      try {
        disposition = await startedOutcome;
        if (disposition == OfflineQueueSendDisposition.failed) {
          sendError = StateError('Transport rejected queued message');
        }
      } catch (error) {
        sendError = error;
      }
    }

    try {
      await _mutationLock.synchronized(() async {
        final live = _findLiveMessage(message.id);
        if (!identical(live, message) ||
            message.status != QueuedMessageStatus.sending) {
          _deliveryInFlightIds.remove(message.id);
          return;
        }

        final finalization = _createDeliveryFinalization(
          message: message,
          preAttemptState: preAttemptState,
          disposition: disposition,
          sendError: sendError,
        );
        _pendingDeliveryFinalizations[message.id] = finalization;
        await _attemptDeliveryFinalizationLocked(finalization);
      });
    } catch (error, stackTrace) {
      await _mutationLock.synchronized(() {
        if (!_pendingDeliveryFinalizations.containsKey(message.id)) {
          _deliveryInFlightIds.remove(message.id);
        }
      });
      _logger.severe(
        'Delivery outcome finalization failed for '
        '${message.id.shortId()}...: $error',
        error,
        stackTrace,
      );
    }

    return transportInvoked ? disposition : null;
  }

  /// Handle successful message delivery (called by BLE service)
  @override
  Future<void> markMessageDelivered(String messageId) async {
    await _mutationLock.synchronized(() async {
      if (_disposed) return;
      final message = _findLiveMessage(messageId);
      if (message == null) return;
      await _markMessageDeliveredLocked(message);
    });
  }

  /// Handle failed message delivery (called by BLE service)
  @override
  Future<void> markMessageFailed(String messageId, String reason) async {
    await _mutationLock.synchronized(() async {
      if (_disposed) return;
      final message = _findLiveMessage(messageId);
      if (message == null) return;
      await _transitionDeliveryFailureLocked(
        message,
        reason,
        ignoreAckCooldown: true,
      );
    });
  }

  /// Handle delivery failure with intelligent retry
  Future<void> _transitionDeliveryFailureLocked(
    QueuedMessage message,
    String reason, {
    required bool ignoreAckCooldown,
  }) async {
    if (message.status == QueuedMessageStatus.failed) {
      return;
    }
    _logger.warning(
      'Delivery failed for ${message.id.shortId()}...: $reason (attempt ${message.attempts}/${message.maxRetries})',
    );

    // Check retry policy (max retries + expiry) before scheduling another attempt
    final canRetry = _queueScheduler.shouldRetry(
      message.id,
      ignoreAckCooldown ? null : message.lastAttemptAt,
      message.attempts,
      message.maxRetries,
      message.expiresAt,
    );

    if (!canRetry) {
      final candidate = _detachedCopy(message)
        ..status = QueuedMessageStatus.failed
        ..failureReason = reason
        ..failedAt = DateTime.now()
        ..nextRetryAt = null;
      final transition = await _transitionStateIfCurrent(
        expected: message,
        replacement: candidate,
      );
      if (!transition.applied) {
        _reconcileLiveMessageWithDurableState(message, transition.current);
        return;
      }
      _applyMutableState(message, transition.current ?? candidate);
      _cancelRetryTimer(MessageId(message.id));
      _totalFailed++;
      _notifyObserver(
        'onMessageFailed',
        () => onMessageFailed?.call(message, reason),
      );
      _updateStatistics();

      _logger.info(
        'Message permanently failed: ${message.id.shortId()}... '
        '(attempt ${message.attempts}/${message.maxRetries})',
      );
      return;
    }

    // Calculate exponential backoff delay (cap at 1 hour for very high attempt counts)
    final backoffDelay = _calculateBackoffDelay(message.attempts);

    final candidate = _detachedCopy(message)
      ..status = QueuedMessageStatus.retrying
      ..nextRetryAt = DateTime.now().add(backoffDelay)
      ..failureReason = reason;
    final transition = await _transitionStateIfCurrent(
      expected: message,
      replacement: candidate,
    );
    if (!transition.applied) {
      _reconcileLiveMessageWithDurableState(message, transition.current);
      return;
    }
    _applyMutableState(message, transition.current ?? candidate);

    if (_isOnline) {
      _scheduleRetry(message, backoffDelay);
    }

    _logger.info(
      'Retry scheduled for ${message.id.shortId()}... in ${backoffDelay.inSeconds}s',
    );
  }

  /// Get current queue statistics
  @override
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
      directQueueSize: allMessages
          .where((message) => !message.isRelayMessage)
          .length,
      relayQueueSize: allMessages
          .where((message) => message.isRelayMessage)
          .length,
    );
  }

  /// Retry all failed messages
  @override
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
      await retryMessage(message.id);
    }
  }

  /// Retry failed messages for a specific chat without touching other chats
  @override
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
      await retryMessage(message.id);
    }
  }

  @override
  Future<bool> retryMessage(String messageId) async {
    QueuedMessage? message;
    var shouldDeliver = false;
    final accepted = await _mutationLock.synchronized(() async {
      if (_disposed ||
          _deliveryInFlightIds.contains(messageId) ||
          _pendingDeliveryFinalizations.containsKey(messageId)) {
        return false;
      }
      final live = _findLiveMessage(messageId);
      if (live == null) return false;

      final candidate = _detachedCopy(live)
        ..status = QueuedMessageStatus.pending
        ..attempts = 0
        ..lastAttemptAt = null
        ..nextRetryAt = null
        ..deliveredAt = null
        ..failedAt = null
        ..failureReason = null;
      final transition = await _transitionStateIfCurrent(
        expected: live,
        replacement: candidate,
      );
      if (!transition.applied) {
        _reconcileLiveMessageWithDurableState(live, transition.current);
        return false;
      }
      _applyMutableState(live, transition.current ?? candidate);
      _cancelRetryTimer(MessageId(messageId));
      _cancelStaggerTimer(messageId);
      message = live;
      shouldDeliver = _isOnline;
      return true;
    });

    if (!accepted) return false;
    if (shouldDeliver && message != null) {
      await _tryDeliveryForMessage(message!);
    }
    _updateStatistics();
    return true;
  }

  /// Clear all messages from queue
  @override
  Future<void> clearQueue() async {
    await _mutationLock.synchronized(() async {
      if (_disposed) return;
      await _store.saveQueueSnapshotToStorage(const <QueuedMessage>[]);
      _cancelAllActiveRetries();
      _cancelAllStaggerTimers();
      _cancelAllPendingDeliveryFinalizations();
      _deliveryInFlightIds.clear();
      _store.clearInMemoryQueues();
      invalidateHashCache();
    });

    _logger.info('Message queues cleared (direct and relay)');
    _updateStatistics();
  }

  /// Get messages by status
  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    // PRIORITY 1 FIX: Search both queues
    return _getAllMessages().where((m) => m.status == status).toList();
  }

  /// Get message by ID
  @override
  QueuedMessage? getMessageById(String messageId) {
    // PRIORITY 1 FIX: Search both queues
    return _getAllMessages().where((m) => m.id == messageId).firstOrNull;
  }

  /// Get all pending messages (convenience method)
  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  /// Remove specific message from queue
  @override
  Future<void> removeMessage(String messageId) async {
    await _mutationLock.synchronized(() async {
      if (_disposed || _findLiveMessage(messageId) == null) return;
      final id = MessageId(messageId);
      await _deleteMessageFromStorage(id.value);
      _cancelPendingDeliveryFinalization(messageId);
      _cancelRetryTimer(id);
      _cancelStaggerTimer(messageId);
      _removeMessageFromQueue(id);
    });
  }

  /// Flush queue for specific peer (trigger immediate delivery)
  ///
  /// Called when handshake completes or peer comes online.
  /// Only processes pending messages for the specified peer.
  @override
  Future<void> flushQueueForPeer(String peerPublicKey) async {
    if (_disposed || !_isOnline) {
      _logger.fine(
        'Peer flush skipped while queue is offline/disposed: ${peerPublicKey.shortId(8)}...',
      );
      return;
    }
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

      _logger.info(
        '✅ Queue flush complete for peer ${peerPublicKey.shortId(8)}...',
      );
    } catch (e) {
      _logger.severe('Failed to flush queue for peer $peerPublicKey: $e');
    }
  }

  @override
  Future<Set<String>> attemptMessages(
    Iterable<String> messageIds, {
    OfflineQueuePrepareSendCallback? prepareSend,
  }) async {
    if (_disposed || !_isOnline) return <String>{};

    final attemptedIds = <String>{};
    for (final messageId in messageIds.toSet()) {
      if (_disposed || !_isOnline) break;
      final message = _findLiveMessage(messageId);
      if (message == null) continue;

      if (prepareSend != null) {
        final prepared = await prepareSend(messageId);
        if (prepared == null) continue;
        final attempt = await _admitDeliveryAttempt(
          message,
          tryStart: () {
            final outcome = prepared.tryStart();
            return outcome?.then(
              (disposition) => disposition.asSendDisposition,
            );
          },
          transportInvoked: true,
        );
        if (attempt != null) {
          attemptedIds.add(messageId);
          unawaited(attempt.outcome);
        }
        continue;
      }

      final disposition = await _tryDeliveryForMessage(message);
      if (disposition != null &&
          disposition != OfflineQueueSendDisposition.deferred) {
        attemptedIds.add(messageId);
      }
    }
    return attemptedIds;
  }

  /// Change priority of a queued message
  /// Returns true if successful, false if message not found
  @override
  Future<bool> changePriority(
    String messageId,
    MessagePriority newPriority,
  ) async {
    try {
      return await _mutationLock.synchronized(() async {
        if (_disposed) return false;
        final message = _findLiveMessage(messageId);
        if (message == null) {
          _logger.warning(
            'Cannot change priority: message ${messageId.shortId()}... not found',
          );
          return false;
        }

        if (message.priority == newPriority) {
          return true;
        }

        final oldPriority = message.priority;
        final candidate = _detachedCopy(message)..priority = newPriority;
        final transition = await _transitionStateIfCurrent(
          expected: message,
          replacement: candidate,
          includePriority: true,
        );
        if (!transition.applied) {
          _reconcileLiveMessageWithDurableState(message, transition.current);
          return false;
        }
        _applyMutableState(message, transition.current ?? candidate);

        // Reinsert through the repository so injected and default stores keep
        // the same priority/FIFO order.
        _repo.removeMessageFromQueue(messageId);
        _repo.insertMessageByPriority(message);

        final queueType = message.isRelayMessage ? 'relay' : 'direct';
        _logger.info(
          'Changed message ${messageId.shortId()}... priority [$queueType]: '
          '${oldPriority.name} → ${newPriority.name}',
        );
        return true;
      });
    } catch (e) {
      _logger.severe('Failed to change message priority: $e');
      return false;
    }
  }

  // Private methods

  QueuedMessage? _findLiveMessage(String messageId) {
    return _getAllMessages()
        .where((message) => message.id == messageId)
        .firstOrNull;
  }

  QueuedMessage _detachedCopy(QueuedMessage message) {
    return QueuedMessage(
      id: message.id,
      chatId: message.chatId,
      content: message.content,
      recipientPublicKey: message.recipientPublicKey,
      senderPublicKey: message.senderPublicKey,
      priority: message.priority,
      queuedAt: message.queuedAt,
      maxRetries: message.maxRetries,
      replyToMessageId: message.replyToMessageId,
      attachments: List<String>.of(message.attachments),
      status: message.status,
      attempts: message.attempts,
      lastAttemptAt: message.lastAttemptAt,
      nextRetryAt: message.nextRetryAt,
      deliveredAt: message.deliveredAt,
      failedAt: message.failedAt,
      failureReason: message.failureReason,
      expiresAt: message.expiresAt,
      isRelayMessage: message.isRelayMessage,
      relayMetadata: _copyRelayMetadata(message.relayMetadata),
      originalMessageId: message.originalMessageId,
      relayNodeId: message.relayNodeId,
      messageHash: message.messageHash,
      senderRateCount: message.senderRateCount,
    );
  }

  void _applyMutableState(QueuedMessage live, QueuedMessage candidate) {
    live
      ..priority = candidate.priority
      ..status = candidate.status
      ..attempts = candidate.attempts
      ..lastAttemptAt = candidate.lastAttemptAt
      ..nextRetryAt = candidate.nextRetryAt
      ..deliveredAt = candidate.deliveredAt
      ..failedAt = candidate.failedAt
      ..failureReason = candidate.failureReason;
  }

  RelayMetadata? _copyRelayMetadata(RelayMetadata? metadata) {
    if (metadata == null) return null;
    return RelayMetadata.fromJson(Map<String, dynamic>.from(metadata.toJson()));
  }

  _PendingDeliveryFinalization _createDeliveryFinalization({
    required QueuedMessage message,
    required QueuedMessage preAttemptState,
    required OfflineQueueSendDisposition disposition,
    required Object? sendError,
  }) {
    final expectedState = _detachedCopy(message);
    switch (disposition) {
      case OfflineQueueSendDisposition.deferred:
        return _PendingDeliveryFinalization(
          message: message,
          expectedState: expectedState,
          candidate: _detachedCopy(preAttemptState),
          disposition: disposition,
        );
      case OfflineQueueSendDisposition.failed:
        final reason = sendError?.toString() ?? 'Transport delivery failed';
        final canRetry = _queueScheduler.shouldRetry(
          message.id,
          null,
          message.attempts,
          message.maxRetries,
          message.expiresAt,
        );
        if (!canRetry) {
          final candidate = _detachedCopy(message)
            ..status = QueuedMessageStatus.failed
            ..failureReason = reason
            ..failedAt = DateTime.now()
            ..nextRetryAt = null;
          return _PendingDeliveryFinalization(
            message: message,
            expectedState: expectedState,
            candidate: candidate,
            disposition: disposition,
            failureReason: reason,
            terminalFailure: true,
          );
        }

        final backoffDelay = _calculateBackoffDelay(message.attempts);
        final candidate = _detachedCopy(message)
          ..status = QueuedMessageStatus.retrying
          ..nextRetryAt = DateTime.now().add(backoffDelay)
          ..failureReason = reason;
        return _PendingDeliveryFinalization(
          message: message,
          expectedState: expectedState,
          candidate: candidate,
          disposition: disposition,
          failureReason: reason,
        );
      case OfflineQueueSendDisposition.awaitingAck:
        final candidate = _detachedCopy(message)
          ..status = QueuedMessageStatus.awaitingAck
          ..nextRetryAt = null;
        return _PendingDeliveryFinalization(
          message: message,
          expectedState: expectedState,
          candidate: candidate,
          disposition: disposition,
        );
      case OfflineQueueSendDisposition.delivered:
        final candidate = _detachedCopy(message)
          ..status = QueuedMessageStatus.delivered
          ..deliveredAt = DateTime.now()
          ..nextRetryAt = null
          ..failureReason = null;
        return _PendingDeliveryFinalization(
          message: message,
          expectedState: expectedState,
          candidate: candidate,
          disposition: disposition,
        );
    }
  }

  Future<void> _attemptDeliveryFinalizationLocked(
    _PendingDeliveryFinalization finalization,
  ) async {
    final message = finalization.message;
    if (!identical(_pendingDeliveryFinalizations[message.id], finalization)) {
      return;
    }

    final live = _findLiveMessage(message.id);
    if (!identical(live, message) ||
        message.status != QueuedMessageStatus.sending) {
      _cancelPendingDeliveryFinalization(message.id);
      return;
    }

    try {
      final transition = await _transitionStateIfCurrent(
        expected: finalization.expectedState,
        replacement:
            finalization.disposition == OfflineQueueSendDisposition.delivered
            ? null
            : finalization.candidate,
      );
      if (!transition.applied) {
        _pendingDeliveryFinalizations.remove(message.id);
        _cancelDeliveryFinalizationTimer(message.id);
        _deliveryInFlightIds.remove(message.id);
        _reconcileLiveMessageWithDurableState(message, transition.current);
        _logger.fine(
          'Skipped stale delivery finalization for '
          '${message.id.shortId()}...; durable ownership moved',
        );
        return;
      }
      final durable = transition.current;
      if (durable != null) {
        // Delivery CAS intentionally leaves unrelated priority edits intact.
        finalization.candidate.priority = durable.priority;
      }
    } catch (error, stackTrace) {
      finalization.persistenceFailures++;
      _logger.warning(
        'Durable delivery finalization failed for '
        '${message.id.shortId()}...; retrying storage only: $error',
        error,
        stackTrace,
      );
      _scheduleDeliveryFinalizationRetry(finalization);
      return;
    }

    if (!identical(_pendingDeliveryFinalizations[message.id], finalization)) {
      return;
    }

    _pendingDeliveryFinalizations.remove(message.id);
    _cancelDeliveryFinalizationTimer(message.id);
    _deliveryInFlightIds.remove(message.id);
    if (_disposed) {
      _publishDisposedDeliveryFinalization(finalization);
    } else {
      _publishDeliveryFinalization(finalization);
    }
  }

  void _publishDisposedDeliveryFinalization(
    _PendingDeliveryFinalization finalization,
  ) {
    final message = finalization.message;
    _applyMutableState(message, finalization.candidate);
    if (finalization.disposition == OfflineQueueSendDisposition.delivered) {
      _removeMessageFromQueue(MessageId(message.id));
    }
    _logger.fine(
      'Delivery outcome finalized in storage after disposal: '
      '${message.id.shortId()}... (${finalization.disposition.name})',
    );
  }

  void _publishDeliveryFinalization(_PendingDeliveryFinalization finalization) {
    final message = finalization.message;
    final candidate = finalization.candidate;
    _applyMutableState(message, candidate);

    switch (finalization.disposition) {
      case OfflineQueueSendDisposition.deferred:
        _logger.fine(
          'Delivery deferred without consuming an attempt: '
          '${message.id.shortId()}...',
        );
      case OfflineQueueSendDisposition.failed:
        final reason = finalization.failureReason!;
        if (finalization.terminalFailure) {
          _cancelRetryTimer(MessageId(message.id));
          _totalFailed++;
          _notifyObserver(
            'onMessageFailed',
            () => onMessageFailed?.call(message, reason),
          );
          _updateStatistics();
          _logger.info(
            'Message permanently failed: ${message.id.shortId()}... '
            '(attempt ${message.attempts}/${message.maxRetries})',
          );
          return;
        }

        final retryAt = candidate.nextRetryAt!;
        final remainingDelay = _remainingDelayUntil(retryAt);
        if (_isOnline) {
          _scheduleRetry(message, remainingDelay);
        }
        _logger.info(
          'Retry scheduled for ${message.id.shortId()}... in '
          '${remainingDelay.inSeconds}s',
        );
      case OfflineQueueSendDisposition.awaitingAck:
        if (_isOnline) {
          final lastAttemptAt = candidate.lastAttemptAt;
          final ackDeadline = lastAttemptAt == null
              ? DateTime.now()
              : lastAttemptAt.add(_ackTimeout);
          _scheduleAckTimeout(message, _remainingDelayUntil(ackDeadline));
        }
        _logger.info(
          'Relay message sent, awaiting ACK: ${message.id.shortId()}...',
        );
      case OfflineQueueSendDisposition.delivered:
        _cancelRetryTimer(MessageId(message.id));
        _cancelStaggerTimer(message.id);
        _removeMessageFromQueue(MessageId(message.id));
        _totalDelivered++;
        _notifyObserver(
          'onMessageDelivered',
          () => onMessageDelivered?.call(message),
        );
        _updateStatistics();
        final queueType = message.isRelayMessage ? 'relay' : 'direct';
        _logger.info(
          'Message delivered successfully [$queueType]: '
          '${message.id.shortId()}...',
        );
    }
  }

  Duration _remainingDelayUntil(DateTime deadline) {
    final now = DateTime.now();
    return deadline.isAfter(now) ? deadline.difference(now) : Duration.zero;
  }

  void _scheduleDeliveryFinalizationRetry(
    _PendingDeliveryFinalization finalization,
  ) {
    final messageId = finalization.message.id;
    if (!identical(_pendingDeliveryFinalizations[messageId], finalization) ||
        _finalizationRetryTimers.containsKey(messageId)) {
      return;
    }

    var delayMilliseconds = _finalizationRetryBaseDelay.inMilliseconds;
    final doublings = finalization.persistenceFailures > 1
        ? finalization.persistenceFailures - 1
        : 0;
    for (var i = 0; i < doublings && delayMilliseconds < 5000; i++) {
      delayMilliseconds *= 2;
    }
    if (delayMilliseconds > _finalizationRetryMaxDelay.inMilliseconds) {
      delayMilliseconds = _finalizationRetryMaxDelay.inMilliseconds;
    }

    late final Timer timer;
    timer = Timer(Duration(milliseconds: delayMilliseconds), () {
      if (identical(_finalizationRetryTimers[messageId], timer)) {
        _finalizationRetryTimers.remove(messageId);
      }
      unawaited(
        _mutationLock.synchronized(() async {
          await _attemptDeliveryFinalizationLocked(finalization);
        }),
      );
    });
    _finalizationRetryTimers[messageId] = timer;
  }

  void _cancelDeliveryFinalizationTimer(String messageId) {
    _finalizationRetryTimers.remove(messageId)?.cancel();
  }

  void _cancelPendingDeliveryFinalization(String messageId) {
    _pendingDeliveryFinalizations.remove(messageId);
    _cancelDeliveryFinalizationTimer(messageId);
    _deliveryInFlightIds.remove(messageId);
  }

  void _cancelAllPendingDeliveryFinalizations() {
    for (final timer in _finalizationRetryTimers.values) {
      timer.cancel();
    }
    _finalizationRetryTimers.clear();
    _pendingDeliveryFinalizations.clear();
  }

  Future<void> _markMessageDeliveredLocked(QueuedMessage message) async {
    final candidate = _detachedCopy(message)
      ..status = QueuedMessageStatus.delivered
      ..deliveredAt = DateTime.now()
      ..nextRetryAt = null
      ..failureReason = null;

    // Deletion is the durable delivery commit. Publish removal only after it
    // succeeds so a failed write cannot lose the retryable live message.
    final transition = await _transitionStateIfCurrent(
      expected: message,
      replacement: null,
    );
    if (!transition.applied) {
      _reconcileLiveMessageWithDurableState(message, transition.current);
      return;
    }
    _applyMutableState(message, candidate);
    _cancelPendingDeliveryFinalization(message.id);
    _cancelRetryTimer(MessageId(message.id));
    _cancelStaggerTimer(message.id);
    _removeMessageFromQueue(MessageId(message.id));

    _totalDelivered++;
    _notifyObserver(
      'onMessageDelivered',
      () => onMessageDelivered?.call(message),
    );
    _updateStatistics();

    final queueType = message.isRelayMessage ? 'relay' : 'direct';
    _logger.info(
      'Message delivered successfully [$queueType]: ${message.id.shortId()}...',
    );
  }

  void _scheduleStaggeredDelivery(ScheduledMessage scheduledMessage) {
    final message = scheduledMessage.message;
    _cancelStaggerTimer(message.id);
    late final Timer timer;
    timer = Timer(scheduledMessage.delay, () {
      if (identical(_staggerTimers[message.id], timer)) {
        _staggerTimers.remove(message.id);
      }
      if (_disposed || !_isOnline) return;
      unawaited(_tryDeliveryForMessage(message));
    });
    _staggerTimers[message.id] = timer;
  }

  void _notifyObserver(String name, dynamic Function() observer) {
    try {
      final result = observer();
      if (result is Future) {
        unawaited(
          result.catchError((Object error, StackTrace stackTrace) {
            _logger.warning(
              'Offline queue observer $name failed: $error',
              error,
              stackTrace,
            );
          }),
        );
      }
    } catch (error, stackTrace) {
      _logger.warning(
        'Offline queue observer $name failed: $error',
        error,
        stackTrace,
      );
    }
  }

  void _cancelStaggerTimer(String messageId) {
    _staggerTimers.remove(messageId)?.cancel();
  }

  void _cancelAllStaggerTimers() {
    for (final timer in _staggerTimers.values) {
      timer.cancel();
    }
    _staggerTimers.clear();
  }

  void _scheduleRetry(QueuedMessage message, Duration delay) {
    if (_disposed || !_isOnline) return;
    _queueScheduler.registerRetryTimer(message.id, delay, () async {
      try {
        var shouldDeliver = false;
        await _mutationLock.synchronized(() async {
          if (_disposed) return;
          final live = _findLiveMessage(message.id);
          if (!identical(live, message) ||
              message.status != QueuedMessageStatus.retrying ||
              _deliveryInFlightIds.contains(message.id)) {
            return;
          }

          final candidate = _detachedCopy(message)
            ..status = QueuedMessageStatus.pending
            ..nextRetryAt = null;
          final transition = await _transitionStateIfCurrent(
            expected: message,
            replacement: candidate,
          );
          if (!transition.applied) {
            _reconcileLiveMessageWithDurableState(message, transition.current);
            return;
          }
          _applyMutableState(message, transition.current ?? candidate);
          shouldDeliver = _isOnline;
        });
        if (shouldDeliver) {
          await _tryDeliveryForMessage(message);
        }
      } catch (error, stackTrace) {
        _logger.severe(
          'Retry transition failed for ${message.id.shortId()}...: $error',
          error,
          stackTrace,
        );
      }
    });
  }

  void _scheduleAckTimeout(QueuedMessage message, Duration delay) {
    if (_disposed || !_isOnline) return;
    _queueScheduler.registerRetryTimer(message.id, delay, () async {
      try {
        await _mutationLock.synchronized(() async {
          if (_disposed) return;
          final live = _findLiveMessage(message.id);
          if (!identical(live, message) ||
              message.status != QueuedMessageStatus.awaitingAck) {
            return;
          }
          await _transitionDeliveryFailureLocked(
            message,
            'ACK timeout',
            ignoreAckCooldown: true,
          );
        });
      } catch (error, stackTrace) {
        _logger.severe(
          'ACK timeout transition failed for ${message.id.shortId()}...: $error',
          error,
          stackTrace,
        );
      }
    });
  }

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
  void _startConnectivityMonitoring() =>
      _maintenanceHelper.startConnectivityMonitoring();

  /// Cancel all active retry timers
  void _cancelAllActiveRetries() => _maintenanceHelper.cancelAllActiveRetries();

  /// Cancel retry timer for specific message
  void _cancelRetryTimer(MessageId messageId) =>
      _maintenanceHelper.cancelRetryTimer(messageId);

  /// Calculate average delivery time
  Duration _calculateAverageDeliveryTime() =>
      _maintenanceHelper.calculateAverageDeliveryTime();

  /// Update statistics and notify listeners
  void _updateStatistics() => _maintenanceHelper.updateStatistics();

  /// Save a single message to persistent storage (optimized for individual updates)
  Future<void> _saveMessageToStorage(QueuedMessage message) =>
      _maintenanceHelper.saveMessageToStorage(message);

  /// Remove a single message from persistent storage
  Future<void> _deleteMessageFromStorage(String messageId) =>
      _maintenanceHelper.deleteMessageFromStorage(messageId);

  Future<QueueStateTransitionResult> _transitionStateIfCurrent({
    required QueuedMessage expected,
    required QueuedMessage? replacement,
    bool includePriority = false,
  }) async {
    final repository = _repo;
    if (repository is IConditionalMessageQueueRepository) {
      return (repository as IConditionalMessageQueueRepository)
          .transitionStateIfCurrent(
            expected: expected,
            replacement: replacement,
            includePriority: includePriority,
          );
    }

    // Explicit in-memory/test repositories do not share durable ownership.
    // Preserve their existing behavior while production storage uses CAS.
    if (replacement == null) {
      await _deleteMessageFromStorage(expected.id);
    } else {
      await _saveMessageToStorage(replacement);
    }
    return QueueStateTransitionResult(applied: true, current: replacement);
  }

  void _reconcileLiveMessageWithDurableState(
    QueuedMessage live,
    QueuedMessage? durable,
  ) {
    _cancelPendingDeliveryFinalization(live.id);
    _cancelRetryTimer(MessageId(live.id));
    _cancelStaggerTimer(live.id);
    if (durable == null) {
      _removeMessageFromQueue(MessageId(live.id));
    } else {
      final priorityChanged = live.priority != durable.priority;
      _applyMutableState(live, durable);
      if (priorityChanged) {
        _repo.removeMessageFromQueue(live.id);
        _repo.insertMessageByPriority(live);
      }
    }
    invalidateHashCache();
  }

  // ===== QUEUE HASH SYNCHRONIZATION METHODS =====

  /// Calculate deterministic hash of current queue state
  /// Excludes delivered/expired messages and includes deleted message tracking
  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    return _queueSync.calculateQueueHash(
      forceRecalculation: forceRecalculation,
    );
  }

  /// Get queue sync information for mesh networking
  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    return _queueSync.createSyncMessage(nodeId);
  }

  /// Compare queue hashes to determine if synchronization is needed
  @override
  bool needsSynchronization(String otherQueueHash) {
    return _queueSync.needsSynchronization(otherQueueHash);
  }

  /// Insert a message received via queue synchronization
  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    await _mutationLock.synchronized(() async {
      if (_disposed) return;
      await _queueSync.addSyncedMessage(message);
    });
  }

  /// Get missing messages compared to another queue
  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    return _queueSync.getMissingMessageIds(otherMessageIds);
  }

  /// Get excess messages that the other queue doesn't have
  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    return _queueSync.getExcessMessages(otherMessageIds);
  }

  /// Mark message as deleted for sync purposes
  @override
  Future<void> markMessageDeleted(String messageId) async {
    await _mutationLock.synchronized(() async {
      if (_disposed) return;
      await _queueSync.markMessageDeleted(messageId);
      _cancelPendingDeliveryFinalization(messageId);
      _cancelRetryTimer(MessageId(messageId));
      _cancelStaggerTimer(messageId);
    });
  }

  /// Check if message was deleted
  @override
  bool isMessageDeleted(String messageId) {
    return _queueSync.isMessageDeleted(messageId);
  }

  /// Clean up old deleted message IDs with improved performance
  @override
  Future<void> cleanupOldDeletedIds() async {
    await _mutationLock.synchronized(() async {
      if (_disposed) return;
      await _queueSync.cleanupOldDeletedIds();
    });
  }

  /// Invalidate hash cache (call after manual queue modifications)
  @override
  void invalidateHashCache() {
    _queueSync.invalidateHashCache();
  }

  /// Start periodic cleanup for performance optimization
  void _startPeriodicCleanup() => _maintenanceHelper.startPeriodicCleanup();

  /// Perform periodic maintenance tasks
  Future<void> _performPeriodicMaintenance() =>
      _maintenanceHelper.performPeriodicMaintenance();

  /// Runs the same maintenance pass used by the six-hour scheduler.
  @visibleForTesting
  Future<void> performPeriodicMaintenanceForTesting() =>
      _performPeriodicMaintenance();

  /// Get performance statistics
  @override
  Map<String, dynamic> getPerformanceStats() =>
      _maintenanceHelper.getPerformanceStats();

  /// Dispose of resources
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isOnline = false;
    _deliveryGeneration++;
    _cancelAllStaggerTimers();
    _maintenanceHelper.dispose();
  }
}

class _AdmittedDeliveryAttempt {
  const _AdmittedDeliveryAttempt(this.outcome);

  final Future<OfflineQueueSendDisposition?> outcome;
}

class _PendingDeliveryFinalization {
  _PendingDeliveryFinalization({
    required this.message,
    required this.expectedState,
    required this.candidate,
    required this.disposition,
    this.failureReason,
    this.terminalFailure = false,
  });

  final QueuedMessage message;
  final QueuedMessage expectedState;
  final QueuedMessage candidate;
  final OfflineQueueSendDisposition disposition;
  final String? failureReason;
  final bool terminalFailure;
  int persistenceFailures = 0;
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
