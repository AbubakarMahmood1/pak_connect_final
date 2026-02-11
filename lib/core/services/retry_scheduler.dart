import 'dart:async';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';
import '../../domain/values/id_types.dart';

/// Retry scheduling service with exponential backoff logic
///
/// Responsibility: Pure timing and retry decision logic
/// - Calculate exponential backoff delays
/// - Determine retry eligibility
/// - Manage retry timing
/// - No database or network I/O
class RetryScheduler implements IRetryScheduler {
  static final _logger = Logger('RetryScheduler');

  // Configuration constants
  static const Duration _initialDelay = Duration(seconds: 2);
  static const Duration _maxDelay = Duration(minutes: 10);

  // Active retry timers
  final Map<MessageId, Timer> _activeRetries = {};

  /// Calculate exponential backoff delay
  @override
  Duration calculateBackoffDelay(int attempt) {
    // Guard against invalid attempt values (e.g., 0 from first failure callbacks)
    final safeAttempt = attempt < 1 ? 1 : attempt;

    // Exponential formula: initialDelay * (2 ^ (attempt - 1))
    final exponentialDelay = Duration(
      milliseconds: _initialDelay.inMilliseconds * (1 << (safeAttempt - 1)),
    );

    // Cap at maximum delay
    final cappedDelay =
        exponentialDelay.inMilliseconds > _maxDelay.inMilliseconds
        ? _maxDelay
        : exponentialDelay;

    // Add random jitter (±25%) for distributed load
    final jitterRange = cappedDelay.inMilliseconds * 0.25;
    final jitter =
        (DateTime.now().millisecond % (jitterRange * 2)) - jitterRange;

    final finalDelay = Duration(
      milliseconds: (cappedDelay.inMilliseconds + jitter).round(),
    );

    _logger.fine(
      'Calculated backoff for attempt $attempt: ${finalDelay.inSeconds}s '
      '(exponential: ${exponentialDelay.inSeconds}s, jitter: ${jitter.toStringAsFixed(0)}ms)',
    );

    return finalDelay;
  }

  /// Determine if message should be retried
  @override
  bool shouldRetry(
    String messageId,
    DateTime? lastAttemptAt,
    int attempts,
    int maxRetries,
    DateTime? expiresAt,
  ) {
    // Check if expired
    if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
      _logger.fine('Message $messageId expired - no retry');
      return false;
    }

    // Check if max retries exceeded
    if (attempts >= maxRetries) {
      _logger.fine(
        'Message $messageId exceeded max retries ($attempts/$maxRetries)',
      );
      return false;
    }

    // Check if enough time has passed
    if (lastAttemptAt != null) {
      final timeSinceLastAttempt = DateTime.now().difference(lastAttemptAt);
      const ackTimeout = Duration(seconds: 5);

      if (timeSinceLastAttempt < ackTimeout) {
        _logger.fine(
          'Message $messageId still waiting for ACK (${timeSinceLastAttempt.inMilliseconds}ms ago)',
        );
        return false;
      }
    }

    return true;
  }

  /// Get remaining delay until next retry
  @override
  Duration getRemainingDelay(DateTime lastAttemptAt, Duration backoffDelay) {
    final timeSinceAttempt = DateTime.now().difference(lastAttemptAt);
    final remaining = backoffDelay - timeSinceAttempt;

    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Get maximum retries for priority
  @override
  int getMaxRetriesForPriority(MessagePriority priority, int baseMaxRetries) {
    switch (priority) {
      case MessagePriority.urgent:
        return baseMaxRetries + 2; // Extra generous for urgent
      case MessagePriority.high:
        return baseMaxRetries + 1; // One extra attempt
      case MessagePriority.normal:
        return baseMaxRetries; // Default
      case MessagePriority.low:
        return (baseMaxRetries - 1).clamp(1, baseMaxRetries); // Fewer attempts
    }
  }

  /// Calculate expiry time based on priority
  @override
  DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority) {
    Duration ttl;
    switch (priority) {
      case MessagePriority.urgent:
        ttl = Duration(hours: 24); // 24 hours for critical
        break;
      case MessagePriority.high:
        ttl = Duration(hours: 12); // 12 hours for important
        break;
      case MessagePriority.normal:
        ttl = Duration(hours: 6); // 6 hours for regular
        break;
      case MessagePriority.low:
        ttl = Duration(hours: 3); // 3 hours for low priority
        break;
    }
    return queuedAt.add(ttl);
  }

  /// Check if message has expired
  @override
  bool isMessageExpired(QueuedMessage message) {
    if (message.expiresAt == null) return false;
    return DateTime.now().isAfter(message.expiresAt!);
  }

  /// Register retry timer
  @override
  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  ) {
    final id = MessageId(messageId);
    // Cancel existing timer if any
    _activeRetries[id]?.cancel();

    _activeRetries[id] = Timer(delay, () async {
      _activeRetries.remove(id);
      await callback();
    });

    _logger.fine(
      'Registered retry timer for message $messageId (delay: ${delay.inMilliseconds}ms)',
    );
  }

  /// Cancel retry timer for specific message
  @override
  void cancelRetryTimer(String messageId) {
    final id = MessageId(messageId);
    _activeRetries[id]?.cancel();
    _activeRetries.remove(id);
    _logger.fine('Cancelled retry timer for message $messageId');
  }

  /// Cancel all active retry timers
  @override
  void cancelAllRetryTimers() {
    for (final timer in _activeRetries.values) {
      timer.cancel();
    }
    _activeRetries.clear();
    _logger.info('Cancelled all ${_activeRetries.length} retry timers');
  }

  /// Get list of scheduled message IDs
  @override
  List<String> getScheduledMessageIds() {
    return _activeRetries.keys.map((id) => id.value).toList();
  }

  /// Check if message is scheduled
  @override
  bool isScheduled(String messageId) {
    return _activeRetries.containsKey(MessageId(messageId));
  }

  /// Dispose all timers
  void dispose() {
    cancelAllRetryTimers();
    _logger.info('RetryScheduler disposed');
  }
}
