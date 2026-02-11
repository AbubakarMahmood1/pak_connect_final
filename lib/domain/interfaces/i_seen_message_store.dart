/// Interface for seen message store (mesh relay deduplication)
///
/// Abstracts message tracking to prevent duplicate relay operations.
/// Tracks messages in two categories: DELIVERED and READ
abstract class ISeenMessageStore {
  /// Initialize backing storage and caches.
  Future<void> initialize();

  /// Check if message was already delivered (relayed)
  bool hasDelivered(String messageId);

  /// Check if message was already read
  bool hasRead(String messageId);

  /// Mark message as delivered (processed by relay)
  Future<void> markDelivered(String messageId);

  /// Mark message as read
  Future<void> markRead(String messageId);

  /// Get store statistics (for monitoring relay deduplication)
  Map<String, dynamic> getStatistics();

  /// Clear all seen messages (testing only)
  Future<void> clear();

  /// Perform maintenance (cleanup old entries per LRU policy)
  Future<void> performMaintenance();
}
