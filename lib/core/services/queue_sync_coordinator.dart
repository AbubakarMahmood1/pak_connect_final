import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_queue_sync_coordinator.dart';
import '../../core/interfaces/i_message_queue_repository.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/models/mesh_relay_models.dart';

/// Queue synchronization coordinator for peer-to-peer sync
///
/// Responsibility: Peer synchronization logic
/// - Calculate queue hashes for comparison
/// - Create sync messages for peers
/// - Merge synced messages
/// - Track deleted message IDs
/// - No database I/O (delegates to MessageQueueRepository)
class QueueSyncCoordinator implements IQueueSyncCoordinator {
  static final _logger = Logger('QueueSyncCoordinator');

  // Configuration
  static const int _maxDeletedIdsToKeep = 1000;
  static const int _cleanupThreshold = 800;
  static const Duration _cacheExpiry = Duration(seconds: 30);

  // Dependencies
  final IMessageQueueRepository? _repository;

  // Caching
  String? _cachedQueueHash;
  DateTime? _lastHashCalculation;

  // Deleted message tracking
  final Set<String> _deletedMessageIds = {};

  // Statistics
  int _syncRequestsCount = 0;

  QueueSyncCoordinator({IMessageQueueRepository? repository})
    : _repository = repository;

  /// Load initial sync state from storage
  Future<void> initialize({required Set<String> deletedIds}) async {
    _deletedMessageIds.addAll(deletedIds);
    _logger.info(
      '🔄 QueueSyncCoordinator initialized with ${_deletedMessageIds.length} deleted IDs',
    );
  }

  @override
  String calculateQueueHash({bool forceRecalculation = false}) {
    if (!forceRecalculation &&
        _cachedQueueHash != null &&
        _lastHashCalculation != null) {
      // Use cache if not expired
      final cacheAge = DateTime.now().difference(_lastHashCalculation!);
      if (cacheAge < _cacheExpiry) {
        return _cachedQueueHash!;
      }
    }

    // Get messages from repository
    final allMessages = _repository?.getAllMessages() ?? [];
    final syncableMessages = allMessages
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed,
        )
        .toList();

    // Sort for consistent ordering
    syncableMessages.sort((a, b) => a.id.compareTo(b.id));

    // Create hash components
    final hashComponents = <String>[];

    // Add message metadata
    for (final message in syncableMessages) {
      final messageData = _getMessageHashData(message);
      hashComponents.add(messageData);
    }

    // Add deleted message IDs (sorted)
    final sortedDeletedIds = _deletedMessageIds.toList()..sort();
    hashComponents.addAll(sortedDeletedIds.map((id) => 'deleted:$id'));

    // Calculate hash
    final combinedData = hashComponents.join('|');
    final bytes = utf8.encode(combinedData);
    final digest = sha256.convert(bytes);

    // Cache result
    _cachedQueueHash = digest.toString();
    _lastHashCalculation = DateTime.now();

    _logger.fine(
      'Calculated queue hash with ${syncableMessages.length} messages, ${_deletedMessageIds.length} deleted',
    );

    return _cachedQueueHash!;
  }

  /// Get hash data for a message
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

  @override
  QueueSyncMessage createSyncMessage(String nodeId) {
    _syncRequestsCount++;

    // Get messages from repository
    final allMessages = _repository?.getAllMessages() ?? [];
    final syncableMessages = allMessages
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

  @override
  bool needsSynchronization(String otherQueueHash) {
    final currentHash = calculateQueueHash();
    return currentHash != otherQueueHash;
  }

  @override
  Future<void> addSyncedMessage(QueuedMessage message) async {
    // Skip if previously deleted
    if (_deletedMessageIds.contains(message.id)) {
      _logger.fine('Sync skip - message was deleted locally');
      return;
    }

    // Skip if already exists
    final allMessages = _repository?.getAllMessages() ?? [];
    if (allMessages.any((m) => m.id == message.id)) {
      _logger.fine('Sync skip - message already exists');
      return;
    }

    // Normalize for retry pipeline
    message.status = QueuedMessageStatus.pending;
    message.attempts = 0;
    message.failureReason = null;
    message.nextRetryAt = null;
    message.lastAttemptAt = null;

    // Add to repository
    await _repository?.saveMessageToStorage(message);
    invalidateHashCache();

    _logger.info('🔄 Synced new message: ${_previewId(message.id)}...');
  }

  @override
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    final allMessages = _repository?.getAllMessages() ?? [];
    final currentIds = allMessages
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

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final otherIdSet = otherMessageIds.toSet();
    final allMessages = _repository?.getAllMessages() ?? [];

    return allMessages
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed &&
              !otherIdSet.contains(m.id),
        )
        .toList();
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    _deletedMessageIds.add(messageId);
    invalidateHashCache();

    _logger.info('Message marked deleted: ${_previewId(messageId)}...');
  }

  @override
  bool isMessageDeleted(String messageId) {
    return _deletedMessageIds.contains(messageId);
  }

  @override
  Future<void> cleanupOldDeletedIds() async {
    final initialCount = _deletedMessageIds.length;

    if (_deletedMessageIds.length > _cleanupThreshold) {
      final deletedList = _deletedMessageIds.toList()..sort();
      _deletedMessageIds.clear();
      _deletedMessageIds.addAll(deletedList.take(_maxDeletedIdsToKeep));

      _logger.info(
        'Cleaned up ${initialCount - _deletedMessageIds.length} old deleted IDs',
      );
    }
  }

  @override
  void invalidateHashCache() {
    _cachedQueueHash = null;
    _lastHashCalculation = null;
  }

  @override
  int getDeletedMessageCount() {
    return _deletedMessageIds.length;
  }

  @override
  Set<String> getDeletedMessageIds() {
    return Set.from(_deletedMessageIds);
  }

  @override
  bool isDeletedIdCapacityExceeded() {
    return _deletedMessageIds.length >= _cleanupThreshold;
  }

  @override
  SyncCoordinatorStats getSyncStatistics() {
    final cacheValid =
        _cachedQueueHash != null &&
        _lastHashCalculation != null &&
        DateTime.now().difference(_lastHashCalculation!) < _cacheExpiry;

    final allMessages = _repository?.getAllMessages() ?? [];
    final activeCount = allMessages
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed,
        )
        .length;

    final currentHash = calculateQueueHash();

    return SyncCoordinatorStats(
      activeMessageCount: activeCount,
      deletedMessageCount: _deletedMessageIds.length,
      deletedIdSetSize: _deletedMessageIds.length,
      currentHash: currentHash,
      lastHashTime: _lastHashCalculation,
      isCachValid: cacheValid,
      syncRequestsCount: _syncRequestsCount,
    );
  }

  @override
  Future<void> resetSyncState() async {
    _cachedQueueHash = null;
    _lastHashCalculation = null;
    _deletedMessageIds.clear();
    _syncRequestsCount = 0;

    _logger.warning('🔄 Sync state reset - may require re-synchronization');
  }

  String _previewId(String value, [int length = 8]) {
    if (value.length <= length) {
      return value;
    }
    return value.substring(0, length);
  }
}
