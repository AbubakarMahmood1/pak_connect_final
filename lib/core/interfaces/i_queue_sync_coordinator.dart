import '../../domain/entities/queued_message.dart';
import '../../core/models/mesh_relay_models.dart';

/// Interface for queue synchronization coordination between peers
///
/// Responsibility: Peer-to-peer queue state synchronization
/// - Calculate queue hashes for comparison
/// - Create sync messages for remote peers
/// - Merge synced messages into local queue
/// - Track and manage deleted messages
/// - No database I/O (delegates to MessageQueueRepository)
abstract class IQueueSyncCoordinator {
  /// Calculate SHA256 hash of current queue state
  ///
  /// Includes active messages and deleted message tracking.
  /// Uses cache for 30 seconds to avoid recalculation.
  ///
  /// Parameters:
  /// - forceRecalculation: Ignore cache and recalculate
  ///
  /// Returns: SHA256 hash of queue state for comparison
  String calculateQueueHash({bool forceRecalculation = false});

  /// Create sync request message for remote peer
  ///
  /// Includes message IDs and hashes for peer comparison.
  /// Used to initiate queue synchronization.
  ///
  /// Parameters:
  /// - nodeId: Public key of node requesting sync
  ///
  /// Returns: QueueSyncMessage with current queue state
  QueueSyncMessage createSyncMessage(String nodeId);

  /// Check if queue differs from peer's queue
  ///
  /// Compares hashes to determine if synchronization needed.
  ///
  /// Parameters:
  /// - otherQueueHash: Hash of peer's queue
  ///
  /// Returns: true if queues differ
  bool needsSynchronization(String otherQueueHash);

  /// Add message received via peer synchronization
  ///
  /// Validates message is not deleted locally, and doesn't exist.
  /// Normalizes message status and attempts for local retry.
  ///
  /// Parameters:
  /// - message: QueuedMessage from peer
  ///
  /// Returns: Future that completes when message added
  Future<bool> addSyncedMessage(QueuedMessage message);

  /// Get message IDs we don't have that peer has
  ///
  /// Used to request missing messages from peer.
  ///
  /// Parameters:
  /// - otherMessageIds: List of message IDs peer has
  ///
  /// Returns: List of IDs we need
  List<String> getMissingMessageIds(List<String> otherMessageIds);

  /// Get messages peer doesn't have that we do
  ///
  /// Used to send excess messages to peer.
  ///
  /// Parameters:
  /// - otherMessageIds: List of message IDs peer has
  ///
  /// Returns: List of messages peer needs
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds);

  /// Mark message as deleted for synchronization
  ///
  /// Tracks deletion so it propagates to other peers.
  /// Prevents re-adding deleted messages.
  ///
  /// Parameters:
  /// - messageId: Message to mark as deleted
  ///
  /// Returns: Future that completes when marked
  Future<void> markMessageDeleted(String messageId);

  /// Check if message was deleted
  ///
  /// Parameters:
  /// - messageId: Message to check
  ///
  /// Returns: true if message was deleted
  bool isMessageDeleted(String messageId);

  /// Clean up old deleted message IDs
  ///
  /// Keeps only the most recent deletions to avoid unbounded growth.
  /// Periodically removes old entries (>5 minutes old).
  ///
  /// Returns: Future that completes when cleanup done
  Future<void> cleanupOldDeletedIds();

  /// Invalidate hash cache after manual queue changes
  ///
  /// Called when queue is modified outside normal sync flow.
  void invalidateHashCache();

  /// Get number of deleted message IDs tracked
  ///
  /// Returns: Count of deleted messages being tracked
  int getDeletedMessageCount();

  /// Get all deleted message IDs
  ///
  /// Returns: Set of deleted message IDs
  Set<String> getDeletedMessageIds();

  /// Check if deleted ID tracking is at capacity
  ///
  /// Returns: true if cleanup threshold reached
  bool isDeletedIdCapacityExceeded();

  /// Get queue synchronization coordinator statistics
  ///
  /// Returns: Statistics about current sync coordinator state
  SyncCoordinatorStats getSyncStatistics();

  /// Reset all synchronization state
  ///
  /// Used for testing and recovery scenarios.
  Future<void> resetSyncState();

  /// Initialize coordinator with existing deleted IDs (when restoring from storage)
  Future<void> initialize({required Set<String> deletedIds});
}

/// Queue synchronization coordinator statistics
class SyncCoordinatorStats {
  /// Number of messages in sync queue
  final int activeMessageCount;

  /// Number of deleted message IDs tracked
  final int deletedMessageCount;

  /// Size of deleted ID set
  final int deletedIdSetSize;

  /// Current queue hash
  final String currentHash;

  /// Time of last hash calculation
  final DateTime? lastHashTime;

  /// Is hash cache valid
  final bool isCachValid;

  /// Number of sync requests since startup
  final int syncRequestsCount;

  SyncCoordinatorStats({
    required this.activeMessageCount,
    required this.deletedMessageCount,
    required this.deletedIdSetSize,
    required this.currentHash,
    this.lastHashTime,
    this.isCachValid = true,
    this.syncRequestsCount = 0,
  });

  @override
  String toString() =>
      '''SyncCoordinatorStats(
    active: $activeMessageCount,
    deleted: $deletedMessageCount,
    cache: $isCachValid,
    syncs: $syncRequestsCount
  )''';
}
