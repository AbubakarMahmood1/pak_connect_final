import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/bluetooth/handshake_attempt_tracker.dart';

void main() {
  late HandshakeAttemptTracker tracker;

  setUp(() {
    HandshakeAttemptTracker.resetAll();
    tracker = HandshakeAttemptTracker(
      maxAttempts: 3,
      window: const Duration(minutes: 5),
      lockoutDuration: const Duration(minutes: 10),
    );
  });

  tearDown(() {
    HandshakeAttemptTracker.resetAll();
  });

  group('HandshakeAttemptTracker', () {
    test('allows first attempt from unknown peer', () {
      expect(tracker.allowAttempt('peer-A'), isTrue);
    });

    test('allows attempts below max threshold', () {
      tracker.recordFailure('peer-A', 'timeout');
      tracker.recordFailure('peer-A', 'noise failure');
      // 2 failures < 3 max
      expect(tracker.allowAttempt('peer-A'), isTrue);
    });

    test('blocks peer after max failures reached', () {
      tracker.recordFailure('peer-A', 'fail 1');
      tracker.recordFailure('peer-A', 'fail 2');
      tracker.recordFailure('peer-A', 'fail 3');
      expect(tracker.allowAttempt('peer-A'), isFalse);
    });

    test('lockout applied after reaching threshold', () {
      for (var i = 0; i < 3; i++) {
        tracker.recordFailure('peer-B', 'fail $i');
      }
      final remaining = tracker.lockoutRemaining('peer-B');
      expect(remaining, isNotNull);
      expect(remaining!.inMinutes, greaterThanOrEqualTo(9)); // ~10 min
    });

    test('different peers tracked independently', () {
      tracker.recordFailure('peer-A', 'fail 1');
      tracker.recordFailure('peer-A', 'fail 2');
      tracker.recordFailure('peer-A', 'fail 3');

      // peer-A blocked
      expect(tracker.allowAttempt('peer-A'), isFalse);
      // peer-B still allowed
      expect(tracker.allowAttempt('peer-B'), isTrue);
    });

    test('recordSuccess clears failure history', () {
      tracker.recordFailure('peer-A', 'fail 1');
      tracker.recordFailure('peer-A', 'fail 2');
      expect(tracker.failureCount('peer-A'), equals(2));

      tracker.recordSuccess('peer-A');
      expect(tracker.failureCount('peer-A'), equals(0));
      expect(tracker.lockoutRemaining('peer-A'), isNull);
      expect(tracker.allowAttempt('peer-A'), isTrue);
    });

    test('recordSuccess clears lockout', () {
      for (var i = 0; i < 3; i++) {
        tracker.recordFailure('peer-A', 'fail $i');
      }
      expect(tracker.allowAttempt('peer-A'), isFalse);

      tracker.recordSuccess('peer-A');
      expect(tracker.allowAttempt('peer-A'), isTrue);
    });

    test('resetAll clears all tracking state', () {
      tracker.recordFailure('peer-A', 'fail');
      tracker.recordFailure('peer-B', 'fail');
      HandshakeAttemptTracker.resetAll();

      expect(tracker.failureCount('peer-A'), equals(0));
      expect(tracker.failureCount('peer-B'), equals(0));
    });

    test('failureCount returns count within window', () {
      tracker.recordFailure('peer-A', 'fail 1');
      tracker.recordFailure('peer-A', 'fail 2');
      expect(tracker.failureCount('peer-A'), equals(2));
    });

    test('no lockout remaining for clean peer', () {
      expect(tracker.lockoutRemaining('unknown-peer'), isNull);
    });

    test('allowAttempt triggers lockout on threshold crossing', () {
      // Record exactly max failures
      for (var i = 0; i < 3; i++) {
        tracker.recordFailure('peer-C', 'fail $i');
      }

      // First call to allowAttempt after threshold sees the lockout
      expect(tracker.allowAttempt('peer-C'), isFalse);
      expect(tracker.lockoutRemaining('peer-C'), isNotNull);
    });

    test('default parameters are reasonable', () {
      // Use default constructor
      final defaultTracker = HandshakeAttemptTracker();

      // Should allow at least 5 failures before lockout (default maxAttempts=5)
      for (var i = 0; i < 4; i++) {
        defaultTracker.recordFailure('peer-D', 'fail $i');
      }
      expect(defaultTracker.allowAttempt('peer-D'), isTrue);

      defaultTracker.recordFailure('peer-D', 'fail 5');
      expect(defaultTracker.allowAttempt('peer-D'), isFalse);
    });
  });
}
