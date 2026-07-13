import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import '../../domain/entities/queued_message.dart';
import '../../domain/entities/queue_enums.dart';
import '../../domain/models/mesh_relay_models.dart';
import '../../domain/values/id_types.dart';

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
  static const int _maxDeletedIdsToKeep = 800;
  static const int _cleanupThreshold = 1000;
  static const Duration _cacheExpiry = Duration(seconds: 30);

  // Dependencies
  final IMessageQueueRepository? _repository;

  // Caching
  String? _cachedQueueHash;
  DateTime? _lastHashCalculation;

  // Deleted message tracking
  final Set<MessageId> _deletedMessageIds;

  // Statistics
  int _syncRequestsCount = 0;

  QueueSyncCoordinator({
    IMessageQueueRepository? repository,
    Set<MessageId>? deletedMessageIds,
  }) : _repository = repository,
       _deletedMessageIds = deletedMessageIds ?? {};

  /// Load initial sync state from storage
  @override
  Future<void> initialize({required Set<String> deletedIds}) async {
    _deletedMessageIds.addAll(deletedIds.map(MessageId.new));
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
    final sortedDeletedIds = _deletedMessageIds.map((id) => id.value).toList()
      ..sort();
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

    final messageIds = syncableMessages.map((m) => MessageId(m.id)).toList();
    final messageHashes = <MessageId, String>{};

    for (final message in syncableMessages) {
      if (message.messageHash != null) {
        messageHashes[MessageId(message.id)] = message.messageHash!;
      }
    }

    return QueueSyncMessage.createRequestWithIds(
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
  Future<bool> addSyncedMessage(QueuedMessage message) async {
    final repository = _repository;
    if (repository == null) {
      throw StateError(
        'Queue synchronization requires a durable message queue repository',
      );
    }

    // Skip if previously deleted
    if (_deletedMessageIds.contains(MessageId(message.id))) {
      _logger.fine('Sync skip - message was deleted locally');
      return false;
    }

    // Skip if already exists
    final allMessages = repository.getAllMessages();
    if (allMessages.any((m) => m.id == message.id)) {
      _logger.fine('Sync skip - message already exists');
      return false;
    }

    // Normalize a detached candidate for the retry pipeline. Callers may reuse
    // their received DTO, so durable admission must not mutate it on failure.
    final candidate = _detachedCopy(message)
      ..status = QueuedMessageStatus.pending
      ..attempts = 0
      ..failureReason = null
      ..failedAt = null
      ..nextRetryAt = null
      ..lastAttemptAt = null;

    // Persist before publishing to the in-memory queue. A failed sync write
    // must not create a ghost message that can be delivered but not reloaded.
    await repository.saveMessageToStorage(candidate);
    repository.insertMessageByPriority(candidate);
    invalidateHashCache();

    _logger.info('🔄 Synced new message: ${_previewId(message.id)}...');
    return true;
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
        .map((m) => MessageId(m.id))
        .toSet();

    final otherIds = otherMessageIds
        .map((id) => MessageId(id.toString()))
        .toSet();

    return otherIds
        .where(
          (id) => !currentIds.contains(id) && !_deletedMessageIds.contains(id),
        )
        .map((id) => id.value)
        .toList();
  }

  @override
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final otherIdSet = otherMessageIds
        .map((id) => MessageId(id.toString()))
        .toSet();
    final allMessages = _repository?.getAllMessages() ?? [];

    return allMessages
        .where(
          (m) =>
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed &&
              !otherIdSet.contains(MessageId(m.id)),
        )
        .toList();
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    final msgId = MessageId(messageId);
    final repository = _repository;
    if (repository != null) {
      await repository.markMessagesDeleted([msgId.value]);
    }
    // The production repository shares this set and has already published the
    // tombstone after commit. Keep the coordinator correct for detached test
    // repositories and its explicitly in-memory mode as well.
    _deletedMessageIds.add(msgId);
    invalidateHashCache();

    _logger.info('Message marked deleted: ${_previewId(messageId)}...');
  }

  @override
  bool isMessageDeleted(String messageId) {
    return _deletedMessageIds.contains(MessageId(messageId));
  }

  @override
  Future<void> cleanupOldDeletedIds() async {
    final initialCount = _deletedMessageIds.length;

    if (_deletedMessageIds.length > _cleanupThreshold) {
      final repository = _repository;
      final retained = repository != null
          ? await repository.pruneDeletedMessageIds(_maxDeletedIdsToKeep)
          : _deletedMessageIds
                .skip(_deletedMessageIds.length - _maxDeletedIdsToKeep)
                .map((id) => id.value)
                .toSet();

      _deletedMessageIds
        ..clear()
        ..addAll(retained.map(MessageId.new));
      invalidateHashCache();

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
    return _deletedMessageIds.map((id) => id.value).toSet();
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
    await _repository?.saveDeletedIdsSnapshotToStorage(const <String>[]);
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
      relayMetadata: message.relayMetadata == null
          ? null
          : RelayMetadata.fromJson(
              Map<String, dynamic>.from(message.relayMetadata!.toJson()),
            ),
      originalMessageId: message.originalMessageId,
      relayNodeId: message.relayNodeId,
      messageHash: message.messageHash,
      senderRateCount: message.senderRateCount,
    );
  }
}
