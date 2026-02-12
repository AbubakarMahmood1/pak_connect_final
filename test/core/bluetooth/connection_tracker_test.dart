import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/ble_connection_tracker.dart';

void main() {
  group('BleConnectionTracker', () {
    test('backs off repeat attempts and clears state on reset', () {
      fakeAsync((async) {
        final tracker = BleConnectionTracker();

        expect(tracker.canAttempt('aa:bb'), isTrue);
        tracker.markAttempt('aa:bb');
        expect(tracker.canAttempt('aa:bb'), isFalse);

        tracker.clear();
        expect(tracker.canAttempt('aa:bb'), isTrue);

        tracker.markAttempt('aa:bb');
        tracker.addConnection(address: 'aa:bb', isClient: true, rssi: null);
        expect(tracker.isConnected('aa:bb'), isTrue);

        tracker.removeConnection('aa:bb');
        expect(tracker.isConnected('aa:bb'), isFalse);
      });
    });

    test('enforces retry delay and expires stale attempts', () {
      var now = DateTime(2025, 1, 1, 0, 0, 0);
      final tracker = BleConnectionTracker(now: () => now);

      tracker.markAttempt('cc:dd');
      expect(tracker.pendingAttemptCount('cc:dd'), equals(1));
      expect(tracker.retryBackoffRemaining('cc:dd'), Duration(seconds: 5));
      expect(
        tracker.nextAllowedAttemptAt('cc:dd'),
        DateTime(2025, 1, 1, 0, 0, 5),
      );
      expect(tracker.canAttempt('cc:dd'), isFalse);

      now = now.add(Duration(seconds: 4));
      expect(tracker.canAttempt('cc:dd'), isFalse); // still backing off
      expect(tracker.retryBackoffRemaining('cc:dd'), Duration(seconds: 1));
      expect(tracker.pendingAttemptCount('cc:dd'), equals(1));

      now = now.add(Duration(seconds: 2));
      expect(tracker.canAttempt('cc:dd'), isTrue); // retry window opened
      expect(tracker.retryBackoffRemaining('cc:dd'), Duration.zero);

      tracker.markAttempt('cc:dd');
      expect(tracker.pendingAttemptCount('cc:dd'), equals(2));
      now = now.add(Duration(seconds: 13)); // beyond expiry window
      expect(tracker.canAttempt('cc:dd'), isTrue);
      expect(tracker.retryBackoffRemaining('cc:dd'), isNull);
      expect(tracker.nextAllowedAttemptAt('cc:dd'), isNull);
      expect(tracker.pendingAttemptCount('cc:dd'), equals(0));
    });

    test('enforces post-disconnect cooldown when enabled', () {
      if (!BleConnectionTracker.isPostDisconnectCooldownEnabled) {
        return;
      }

      var now = DateTime(2025, 1, 1, 12, 0, 0);
      final tracker = BleConnectionTracker(now: () => now);

      tracker.addConnection(address: 'ee:ff', isClient: true, rssi: null);
      tracker.removeConnection('ee:ff');

      expect(tracker.canAttempt('ee:ff'), isFalse);
      expect(
        tracker.disconnectCooldownRemaining('ee:ff'),
        BleConnectionTracker.postDisconnectCooldown,
      );
      expect(
        tracker.disconnectCooldownUntil('ee:ff'),
        DateTime(2025, 1, 1, 12, 0, 3),
      );

      now = now.add(Duration(seconds: 2));
      expect(tracker.canAttempt('ee:ff'), isFalse);
      expect(
        tracker.disconnectCooldownRemaining('ee:ff'),
        Duration(seconds: 1),
      );

      now = now.add(Duration(seconds: 2));
      expect(tracker.canAttempt('ee:ff'), isTrue);
      expect(tracker.disconnectCooldownRemaining('ee:ff'), isNull);
      expect(tracker.disconnectCooldownUntil('ee:ff'), isNull);
    });
  });
}
