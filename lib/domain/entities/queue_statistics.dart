/// Queue statistics entity
///
/// Extracted from offline_message_queue.dart for better separation of concerns.
/// Provides metrics and health information about the message queue.

import 'queued_message.dart';

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
