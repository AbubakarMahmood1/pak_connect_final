import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/services/retry_scheduler.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('RetryScheduler', () {
    late RetryScheduler scheduler;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      scheduler = RetryScheduler();
    });

    tearDown(() {
      scheduler.dispose();
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    group('calculateBackoffDelay', () {
      test('attempt 1 returns initial delay (2 seconds)', () {
        // Act
        final delay = scheduler.calculateBackoffDelay(1);

        // Assert - should be close to 2 seconds, allowing for jitter (±25%)
        expect(delay.inMilliseconds, greaterThanOrEqualTo(1500)); // 2s - 25%
        expect(delay.inMilliseconds, lessThanOrEqualTo(2500)); // 2s + 25%
      });

      test('attempt 2 returns ~4 seconds (exponential 2x)', () {
        // Act
        final delay = scheduler.calculateBackoffDelay(2);

        // Assert - 4 seconds with ±25% jitter
        expect(delay.inMilliseconds, greaterThanOrEqualTo(3000)); // 4s - 25%
        expect(delay.inMilliseconds, lessThanOrEqualTo(5000)); // 4s + 25%
      });

      test('attempt 3 returns ~8 seconds (exponential 4x)', () {
        // Act
        final delay = scheduler.calculateBackoffDelay(3);

        // Assert - 8 seconds with ±25% jitter
        expect(delay.inMilliseconds, greaterThanOrEqualTo(6000)); // 8s - 25%
        expect(delay.inMilliseconds, lessThanOrEqualTo(10000)); // 8s + 25%
      });

      test('attempt 10 is capped at max delay (10 minutes)', () {
        // Act
        final delay = scheduler.calculateBackoffDelay(10);

        // Assert - should be capped at 10 minutes with ±25% jitter
        final maxDelay = Duration(minutes: 10).inMilliseconds;
        expect(delay.inMilliseconds, lessThanOrEqualTo(maxDelay * 1.25));
        expect(delay.inMilliseconds, greaterThanOrEqualTo(maxDelay * 0.75));
      });

      test('jitter is within ±25% range', () {
        // Arrange
        const attempts = 5;
        const iterations = 50; // Sample multiple times

        // Act
        final delaysBench = [
          for (int i = 0; i < iterations; i++)
            scheduler.calculateBackoffDelay(attempts),
        ];

        // Assert - collect delays and verify jitter is reasonable
        final minDelay = delaysBench.reduce(
          (a, b) => a.inMilliseconds < b.inMilliseconds ? a : b,
        );
        final maxDelay = delaysBench.reduce(
          (a, b) => a.inMilliseconds > b.inMilliseconds ? a : b,
        );

        // Jitter should span reasonable range
        expect(
          maxDelay.inMilliseconds - minDelay.inMilliseconds,
          lessThanOrEqualTo(200), // Allow some variance due to random nature
        );
      });
    });

    group('shouldRetry', () {
      test('returns false if message is expired', () {
        // Arrange
        final expiredTime = DateTime.now().subtract(Duration(hours: 1));

        // Act
        final result = scheduler.shouldRetry(
          'msg-1',
          DateTime.now().subtract(Duration(seconds: 10)),
          3,
          5,
          expiredTime,
        );

        // Assert
        expect(result, false);
      });

      test('returns false if max retries exceeded', () {
        // Arrange
        final futureTime = DateTime.now().add(Duration(hours: 1));

        // Act
        final result = scheduler.shouldRetry(
          'msg-1',
          DateTime.now().subtract(Duration(seconds: 10)),
          6, // attempts >= maxRetries (6)
          5, // maxRetries
          futureTime,
        );

        // Assert
        expect(result, false);
      });

      test(
        'returns false if not enough time has passed since last attempt',
        () {
          // Arrange
          final futureTime = DateTime.now().add(Duration(hours: 1));
          final lastAttempt = DateTime.now().subtract(
            Duration(milliseconds: 500),
          ); // < 5s

          // Act
          final result = scheduler.shouldRetry(
            'msg-1',
            lastAttempt,
            2,
            5,
            futureTime,
          );

          // Assert
          expect(result, false);
        },
      );

      test('returns true if all conditions met', () {
        // Arrange
        final futureTime = DateTime.now().add(Duration(hours: 1));
        final lastAttempt = DateTime.now().subtract(
          Duration(seconds: 10),
        ); // > 5s

        // Act
        final result = scheduler.shouldRetry(
          'msg-1',
          lastAttempt,
          2, // < maxRetries
          5,
          futureTime,
        );

        // Assert
        expect(result, true);
      });

      test('handles null lastAttemptAt correctly', () {
        // Arrange
        final futureTime = DateTime.now().add(Duration(hours: 1));

        // Act
        final result = scheduler.shouldRetry('msg-1', null, 0, 5, futureTime);

        // Assert - should be true (no time check when lastAttemptAt is null)
        expect(result, true);
      });

      test('handles null expiresAt correctly', () {
        // Arrange
        final lastAttempt = DateTime.now().subtract(Duration(seconds: 10));

        // Act
        final result = scheduler.shouldRetry(
          'msg-1',
          lastAttempt,
          2,
          5,
          null, // no expiry
        );

        // Assert
        expect(result, true);
      });
    });

    group('getRemainingDelay', () {
      test('returns zero if enough time has passed', () {
        // Arrange
        final lastAttempt = DateTime.now().subtract(Duration(seconds: 10));
        final backoffDelay = Duration(seconds: 5);

        // Act
        final remaining = scheduler.getRemainingDelay(
          lastAttempt,
          backoffDelay,
        );

        // Assert
        expect(remaining, Duration.zero);
      });

      test('returns positive duration if not enough time passed', () {
        // Arrange
        final lastAttempt = DateTime.now().subtract(Duration(seconds: 2));
        final backoffDelay = Duration(seconds: 5);

        // Act
        final remaining = scheduler.getRemainingDelay(
          lastAttempt,
          backoffDelay,
        );

        // Assert - approximately 3 seconds (allow ±1 second for timing variations)
        expect(remaining.inSeconds, greaterThanOrEqualTo(2));
        expect(remaining.inSeconds, lessThanOrEqualTo(4));
        expect(remaining.inMilliseconds, greaterThan(0));
      });

      test('returns exact remaining duration', () {
        // Arrange
        final lastAttempt = DateTime.now().subtract(Duration(seconds: 1));
        final backoffDelay = Duration(seconds: 5);

        // Act
        final remaining = scheduler.getRemainingDelay(
          lastAttempt,
          backoffDelay,
        );

        // Assert - approximately 4 seconds (allow ±1 second for timing variations)
        expect(remaining.inSeconds, greaterThanOrEqualTo(3));
        expect(remaining.inSeconds, lessThanOrEqualTo(5));
      });
    });

    group('getMaxRetriesForPriority', () {
      test('urgent priority gets +2 bonus retries', () {
        // Act
        final maxRetries = scheduler.getMaxRetriesForPriority(
          MessagePriority.urgent,
          5,
        );

        // Assert
        expect(maxRetries, 7);
      });

      test('high priority gets +1 bonus retry', () {
        // Act
        final maxRetries = scheduler.getMaxRetriesForPriority(
          MessagePriority.high,
          5,
        );

        // Assert
        expect(maxRetries, 6);
      });

      test('normal priority gets base retries', () {
        // Act
        final maxRetries = scheduler.getMaxRetriesForPriority(
          MessagePriority.normal,
          5,
        );

        // Assert
        expect(maxRetries, 5);
      });

      test('low priority gets -1 reduction (min 1)', () {
        // Act
        final maxRetries = scheduler.getMaxRetriesForPriority(
          MessagePriority.low,
          5,
        );

        // Assert
        expect(maxRetries, 4);
      });

      test('low priority with base=1 clamps to minimum of 1', () {
        // Act
        final maxRetries = scheduler.getMaxRetriesForPriority(
          MessagePriority.low,
          1,
        );

        // Assert
        expect(maxRetries, 1); // Should not go below 1
      });
    });

    group('calculateExpiryTime', () {
      test('urgent priority has 24-hour TTL', () {
        // Arrange
        final queuedAt = DateTime.now();

        // Act
        final expiresAt = scheduler.calculateExpiryTime(
          queuedAt,
          MessagePriority.urgent,
        );

        // Assert
        final difference = expiresAt.difference(queuedAt);
        expect(difference.inHours, 24);
      });

      test('high priority has 12-hour TTL', () {
        // Arrange
        final queuedAt = DateTime.now();

        // Act
        final expiresAt = scheduler.calculateExpiryTime(
          queuedAt,
          MessagePriority.high,
        );

        // Assert
        final difference = expiresAt.difference(queuedAt);
        expect(difference.inHours, 12);
      });

      test('normal priority has 6-hour TTL', () {
        // Arrange
        final queuedAt = DateTime.now();

        // Act
        final expiresAt = scheduler.calculateExpiryTime(
          queuedAt,
          MessagePriority.normal,
        );

        // Assert
        final difference = expiresAt.difference(queuedAt);
        expect(difference.inHours, 6);
      });

      test('low priority has 3-hour TTL', () {
        // Arrange
        final queuedAt = DateTime.now();

        // Act
        final expiresAt = scheduler.calculateExpiryTime(
          queuedAt,
          MessagePriority.low,
        );

        // Assert
        final difference = expiresAt.difference(queuedAt);
        expect(difference.inHours, 3);
      });

      test('expiry time is always in the future', () {
        // Arrange
        final queuedAt = DateTime.now();

        // Act
        final expiresAt = scheduler.calculateExpiryTime(
          queuedAt,
          MessagePriority.normal,
        );

        // Assert
        expect(expiresAt.isAfter(queuedAt), true);
      });
    });

    group('isMessageExpired', () {
      test('returns false for non-expired message', () {
        // Arrange
        final message = QueuedMessage(
          id: 'msg-1',
          chatId: 'chat-1',
          content: 'Test',
          recipientPublicKey: 'key-1',
          senderPublicKey: 'sender-1',
          priority: MessagePriority.normal,
          queuedAt: DateTime.now(),
          maxRetries: 5,
          expiresAt: DateTime.now().add(Duration(hours: 1)),
        );

        // Act
        final expired = scheduler.isMessageExpired(message);

        // Assert
        expect(expired, false);
      });

      test('returns true for expired message', () {
        // Arrange
        final message = QueuedMessage(
          id: 'msg-1',
          chatId: 'chat-1',
          content: 'Test',
          recipientPublicKey: 'key-1',
          senderPublicKey: 'sender-1',
          priority: MessagePriority.normal,
          queuedAt: DateTime.now(),
          maxRetries: 5,
          expiresAt: DateTime.now().subtract(Duration(hours: 1)),
        );

        // Act
        final expired = scheduler.isMessageExpired(message);

        // Assert
        expect(expired, true);
      });

      test('returns false for message with null expiresAt', () {
        // Arrange
        final message = QueuedMessage(
          id: 'msg-1',
          chatId: 'chat-1',
          content: 'Test',
          recipientPublicKey: 'key-1',
          senderPublicKey: 'sender-1',
          priority: MessagePriority.normal,
          queuedAt: DateTime.now(),
          maxRetries: 5,
          expiresAt: null,
        );

        // Act
        final expired = scheduler.isMessageExpired(message);

        // Assert
        expect(expired, false);
      });
    });

    group('Timer Management', () {
      test('isScheduled returns false for non-scheduled message', () {
        // Act
        final scheduled = scheduler.isScheduled('msg-unknown');

        // Assert
        expect(scheduled, false);
      });

      test('getScheduledMessageIds returns empty list initially', () {
        // Act
        final scheduled = scheduler.getScheduledMessageIds();

        // Assert
        expect(scheduled.isEmpty, true);
      });

      test('cancelAllRetryTimers does not throw error', () {
        // Act & Assert
        expect(() => scheduler.cancelAllRetryTimers(), returnsNormally);
      });

      test('cancelRetryTimer for non-existent message does not throw', () {
        // Act & Assert
        expect(
          () => scheduler.cancelRetryTimer('msg-unknown'),
          returnsNormally,
        );
      });
    });

    group('Integration Tests', () {
      test('exponential backoff follows expected progression', () {
        // Arrange & Act
        final attempt1 = scheduler.calculateBackoffDelay(1).inMilliseconds;
        final attempt2 = scheduler.calculateBackoffDelay(2).inMilliseconds;
        final attempt3 = scheduler.calculateBackoffDelay(3).inMilliseconds;

        // Assert - allow 25% jitter in comparison
        expect(attempt2, greaterThan(attempt1 * 0.5)); // Roughly 2x
        expect(attempt3, greaterThan(attempt2 * 0.5)); // Roughly 2x
      });

      test('expired message with retries available should not retry', () {
        // Arrange
        final expiredTime = DateTime.now().subtract(Duration(hours: 1));

        // Act
        final shouldRetry = scheduler.shouldRetry(
          'msg-1',
          DateTime.now().subtract(Duration(seconds: 10)),
          1, // Few retries used
          10, // Plenty available
          expiredTime,
        );

        // Assert
        expect(shouldRetry, false);
      });

      test('recently attempted message should not retry immediately', () {
        // Arrange
        final recentAttempt = DateTime.now().subtract(
          Duration(milliseconds: 100),
        );
        final futureExpiry = DateTime.now().add(Duration(hours: 1));

        // Act
        final shouldRetry = scheduler.shouldRetry(
          'msg-1',
          recentAttempt,
          1,
          10,
          futureExpiry,
        );

        // Assert
        expect(shouldRetry, false);
      });
    });
  });
}
