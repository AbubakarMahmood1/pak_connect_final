import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';

/// Interface for queue synchronization coordination between peers.
///
/// Responsibility: Peer-to-peer queue state synchronization
/// - Calculate queue hashes for comparison
/// - Create sync messages for remote peers
/// - Merge synced messages into local queue
/// - Track and manage deleted messages
/// - No database I/O (delegates to MessageQueueRepository)
abstract class IQueueSyncCoordinator {
  /// Calculate SHA256 hash of current queue state.
  ///
  /// Includes active messages and deleted message tracking.
  /// Uses cache for 30 seconds to avoid recalculation.
  String calculateQueueHash({bool forceRecalculation = false});

  /// Create sync request message for remote peer.
  ///
  /// Includes message IDs and hashes for peer comparison.
  QueueSyncMessage createSyncMessage(String nodeId);

  /// Check if queue differs from peer's queue.
  bool needsSynchronization(String otherQueueHash);

  /// Add message received via peer synchronization.
  Future<bool> addSyncedMessage(QueuedMessage message);

  /// Get message IDs we don't have that peer has.
  List<String> getMissingMessageIds(List<String> otherMessageIds);

  /// Get messages peer doesn't have that we do.
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds);

  /// Mark message as deleted for synchronization.
  Future<void> markMessageDeleted(String messageId);

  /// Check if message was deleted.
  bool isMessageDeleted(String messageId);

  /// Clean up old deleted message IDs.
  Future<void> cleanupOldDeletedIds();

  /// Invalidate hash cache after manual queue changes.
  void invalidateHashCache();

  /// Get number of deleted message IDs tracked.
  int getDeletedMessageCount();

  /// Get all deleted message IDs.
  Set<String> getDeletedMessageIds();

  /// Check if deleted ID tracking is at capacity.
  bool isDeletedIdCapacityExceeded();

  /// Get queue synchronization coordinator statistics.
  SyncCoordinatorStats getSyncStatistics();

  /// Reset all synchronization state.
  Future<void> resetSyncState();

  /// Initialize coordinator with existing deleted IDs.
  Future<void> initialize({required Set<String> deletedIds});
}

/// Queue synchronization coordinator statistics.
class SyncCoordinatorStats {
  /// Number of messages in sync queue.
  final int activeMessageCount;

  /// Number of deleted message IDs tracked.
  final int deletedMessageCount;

  /// Size of deleted ID set.
  final int deletedIdSetSize;

  /// Current queue hash.
  final String currentHash;

  /// Time of last hash calculation.
  final DateTime? lastHashTime;

  /// Is hash cache valid.
  final bool isCachValid;

  /// Number of sync requests since startup.
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
