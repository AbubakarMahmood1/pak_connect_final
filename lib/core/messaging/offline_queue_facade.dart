import 'package:logging/logging.dart';
import '../interfaces/i_offline_message_queue.dart';
import '../interfaces/i_message_queue_repository.dart';
import '../interfaces/i_retry_scheduler.dart';
import '../interfaces/i_queue_sync_coordinator.dart';
import '../interfaces/i_queue_persistence_manager.dart';
import '../services/message_queue_repository.dart';
import '../services/retry_scheduler.dart';
import '../services/queue_sync_coordinator.dart';
import '../services/queue_persistence_manager.dart';
import 'offline_message_queue.dart';

/// Facade for offline message queue with lazy initialization of sub-services
/// Provides 100% backward compatibility with existing OfflineMessageQueue API
/// while enabling gradual migration to extracted services
class OfflineQueueFacade implements IOfflineMessageQueue {
  static final _logger = Logger('OfflineQueueFacade');

  // Core queue implementation
  final OfflineMessageQueue _queue;

  // Extracted services (lazy-initialized)
  late IMessageQueueRepository _queueRepository;
  late IRetryScheduler _retryScheduler;
  late IQueueSyncCoordinator _syncCoordinator;
  late IQueuePersistenceManager _persistenceManager;

  bool _initialized = false;

  OfflineQueueFacade({OfflineMessageQueue? queue})
    : _queue = queue ?? OfflineMessageQueue();

  // ===== LAZY GETTERS =====

  /// Get message queue repository (lazy initialized)
  IMessageQueueRepository get queueRepository {
    if (!_initialized) _initializeServices();
    return _queueRepository;
  }

  /// Get retry scheduler (lazy initialized)
  IRetryScheduler get retryScheduler {
    if (!_initialized) _initializeServices();
    return _retryScheduler;
  }

  /// Get queue sync coordinator (lazy initialized)
  IQueueSyncCoordinator get syncCoordinator {
    if (!_initialized) _initializeServices();
    return _syncCoordinator;
  }

  /// Get persistence manager (lazy initialized)
  IQueuePersistenceManager get persistenceManager {
    if (!_initialized) _initializeServices();
    return _persistenceManager;
  }

  /// Expose underlying queue for legacy consumers while facade is introduced.
  OfflineMessageQueue get queue => _queue;

  /// Initialize all sub-services (called once)
  void _initializeServices() {
    if (_initialized) return;

    _logger.info('🔧 Initializing OfflineQueueFacade sub-services...');

    try {
      _queueRepository = MessageQueueRepository();
      _retryScheduler = RetryScheduler();
      _syncCoordinator = QueueSyncCoordinator();
      _persistenceManager = QueuePersistenceManager();

      _initialized = true;
      _logger.info('✅ OfflineQueueFacade sub-services initialized');
    } catch (e) {
      _logger.warning('⚠️ Failed to initialize sub-services: $e');
      // Continue without them - facade still works with core queue
    }
  }

  // ===== DELEGATION: INITIALIZATION =====

  @override
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
    Function()? onConnectivityCheck,
  }) async {
    _initializeServices();
    await _queue.initialize(
      onMessageQueued: onMessageQueued,
      onMessageDelivered: onMessageDelivered,
      onMessageFailed: onMessageFailed,
      onStatsUpdated: onStatsUpdated,
      onSendMessage: onSendMessage,
      onConnectivityCheck: onConnectivityCheck,
    );
    _logger.info('✅ OfflineQueueFacade initialized');
  }

  // ===== DELEGATION: QUEUE MANAGEMENT =====

  @override
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const [],
  }) async {
    return _queue.queueMessage(
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
    );
  }

  @override
  Future<void> setOnline() => _queue.setOnline();

  @override
  void setOffline() => _queue.setOffline();

  @override
  void markMessageDelivered(String messageId) =>
      _queue.markMessageDelivered(messageId);

  @override
  void markMessageFailed(String messageId, String reason) =>
      _queue.markMessageFailed(messageId, reason);

  @override
  QueueStatistics getStatistics() => _queue.getStatistics();

  @override
  Future<void> retryFailedMessages() => _queue.retryFailedMessages();

  @override
  Future<void> clearQueue() => _queue.clearQueue();

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      _queue.getMessagesByStatus(status);

  @override
  QueuedMessage? getMessageById(String messageId) =>
      _queue.getMessageById(messageId);

  @override
  List<QueuedMessage> getPendingMessages() => _queue.getPendingMessages();

  @override
  Future<void> removeMessage(String messageId) =>
      _queue.removeMessage(messageId);

  @override
  Future<void> flushQueueForPeer(String recipientPublicKey) =>
      _queue.flushQueueForPeer(recipientPublicKey);

  @override
  Future<bool> changePriority(String messageId, MessagePriority newPriority) =>
      _queue.changePriority(messageId, newPriority);

  // ===== DELEGATION: SYNCHRONIZATION =====

  @override
  String calculateQueueHash({bool forceRecalculation = false}) =>
      _queue.calculateQueueHash(forceRecalculation: forceRecalculation);

  @override
  QueueSyncMessage createSyncMessage(String nodeId) =>
      _queue.createSyncMessage(nodeId);

  @override
  bool needsSynchronization(String peerKey) =>
      _queue.needsSynchronization(peerKey);

  @override
  void addSyncedMessage(QueuedMessage message) =>
      _queue.addSyncedMessage(message);

  @override
  List<String> getMissingMessageIds(List<String> peerMessageIds) =>
      _queue.getMissingMessageIds(peerMessageIds);

  @override
  List<QueuedMessage> getExcessMessages(List<String> peerMessageIds) =>
      _queue.getExcessMessages(peerMessageIds);

  // ===== DELEGATION: DELETED MESSAGE TRACKING =====

  @override
  void markMessageDeleted(String messageId) =>
      _queue.markMessageDeleted(messageId);

  @override
  bool isMessageDeleted(String messageId) => _queue.isMessageDeleted(messageId);

  @override
  Future<void> cleanupOldDeletedIds() => _queue.cleanupOldDeletedIds();

  @override
  void invalidateHashCache() => _queue.invalidateHashCache();

  // ===== DELEGATION: STATISTICS & MAINTENANCE =====

  @override
  Map<String, dynamic> getPerformanceStats() => _queue.getPerformanceStats();

  @override
  void dispose() {
    _queue.dispose();
    _logger.info('✅ OfflineQueueFacade disposed');
  }
}
