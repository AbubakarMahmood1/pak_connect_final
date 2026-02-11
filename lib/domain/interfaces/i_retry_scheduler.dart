import 'dart:async';

import 'package:pak_connect/domain/entities/queued_message.dart';

/// Interface for retry scheduling and exponential backoff logic.
///
/// Responsibility: Pure timing and retry decision logic.
abstract class IRetryScheduler {
  /// Calculate exponential backoff delay for given attempt count.
  Duration calculateBackoffDelay(int attempt);

  /// Determine if message should be retried.
  bool shouldRetry(
    String messageId,
    DateTime? lastAttemptAt,
    int attempts,
    int maxRetries,
    DateTime? expiresAt,
  );

  /// Get remaining delay until next retry.
  Duration getRemainingDelay(DateTime lastAttemptAt, Duration backoffDelay);

  /// Get maximum retry attempts for given priority.
  int getMaxRetriesForPriority(MessagePriority priority, int baseMaxRetries);

  /// Calculate expiry time based on message priority and queue time.
  DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority);

  /// Check if message has exceeded its TTL expiry time.
  bool isMessageExpired(QueuedMessage message);

  /// Register a retry timer for a message.
  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  );

  /// Cancel retry timer for specific message.
  void cancelRetryTimer(String messageId);

  /// Cancel all active retry timers.
  void cancelAllRetryTimers();

  /// Get list of currently scheduled message IDs.
  List<String> getScheduledMessageIds();

  /// Check if message is scheduled for retry.
  bool isScheduled(String messageId);
}
