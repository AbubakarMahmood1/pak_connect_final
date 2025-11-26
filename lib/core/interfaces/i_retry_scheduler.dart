import 'dart:async';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/queued_message.dart';
import '../../domain/entities/queue_enums.dart';

/// Interface for retry scheduling and exponential backoff logic
///
/// Responsibility: Pure timing and retry decision logic
/// - Calculate exponential backoff delays
/// - Determine retry eligibility
/// - Manage retry timing
/// - No database or network I/O
abstract class IRetryScheduler {
  /// Calculate exponential backoff delay for given attempt count
  ///
  /// Uses formula: initialDelay * (2 ^ (attempt - 1))
  /// Capped at maxDelay and includes random jitter (±25%)
  ///
  /// Parameters:
  /// - attempt: Current retry attempt number (1-based)
  ///
  /// Returns: Duration to wait before next retry
  Duration calculateBackoffDelay(int attempt);

  /// Determine if message should be retried
  ///
  /// Checks:
  /// - Has not exceeded max retry count
  /// - Enough time has passed since last attempt
  /// - Not expired by TTL
  ///
  /// Parameters:
  /// - messageId: Message to check
  /// - lastAttemptAt: Timestamp of last attempt
  /// - attempts: Current attempt count
  /// - maxRetries: Maximum allowed retries
  /// - expiresAt: Message expiry time
  ///
  /// Returns: true if message should be retried
  bool shouldRetry(
    String messageId,
    DateTime? lastAttemptAt,
    int attempts,
    int maxRetries,
    DateTime? expiresAt,
  );

  /// Get remaining delay until next retry
  ///
  /// Returns time that must pass before this message should be retried.
  /// Returns Duration.zero if ready to retry now.
  ///
  /// Parameters:
  /// - lastAttemptAt: Timestamp of last attempt
  /// - backoffDelay: Calculated backoff delay
  ///
  /// Returns: Duration until next retry is eligible
  Duration getRemainingDelay(DateTime lastAttemptAt, Duration backoffDelay);

  /// Get maximum retry attempts for given priority
  ///
  /// Higher priority messages get more retry attempts.
  /// Urgent: maxRetries + 2
  /// High: maxRetries + 1
  /// Normal: maxRetries (default 5)
  /// Low: maxRetries - 1
  ///
  /// Parameters:
  /// - priority: Message priority level
  /// - baseMaxRetries: Base maximum retry count
  ///
  /// Returns: Adjusted maximum retries for this priority
  int getMaxRetriesForPriority(MessagePriority priority, int baseMaxRetries);

  /// Calculate expiry time based on message priority and queue time
  ///
  /// TTL (Time To Live) is priority-based:
  /// - Urgent: 24 hours
  /// - High: 12 hours
  /// - Normal: 6 hours
  /// - Low: 3 hours
  ///
  /// Parameters:
  /// - queuedAt: When message was queued
  /// - priority: Message priority level
  ///
  /// Returns: DateTime when message expires
  DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority);

  /// Check if message has exceeded its TTL expiry time
  ///
  /// Parameters:
  /// - message: Message to check
  ///
  /// Returns: true if message has expired
  bool isMessageExpired(QueuedMessage message);

  /// Register a retry timer for a message
  ///
  /// Internal method to track active retry timers.
  /// Enables cancellation if message is delivered or removed.
  ///
  /// Parameters:
  /// - messageId: Message ID being retried
  /// - callback: Function to call when retry delay elapses
  /// - delay: Backoff delay before retrying
  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  );

  /// Cancel retry timer for specific message
  ///
  /// Parameters:
  /// - messageId: Message to cancel retry for
  void cancelRetryTimer(String messageId);

  /// Cancel all active retry timers
  ///
  /// Called on disconnect or queue clear.
  void cancelAllRetryTimers();

  /// Get list of currently scheduled message IDs
  ///
  /// Returns: List of message IDs with active retry timers
  List<String> getScheduledMessageIds();

  /// Check if message is scheduled for retry
  ///
  /// Parameters:
  /// - messageId: Message to check
  ///
  /// Returns: true if message has a scheduled retry timer
  bool isScheduled(String messageId);
}
