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
      expect(tracker.canAttempt('cc:dd'), isFalse);

      now = now.add(Duration(seconds: 4));
      expect(tracker.canAttempt('cc:dd'), isFalse); // still backing off

      now = now.add(Duration(seconds: 2));
      expect(tracker.canAttempt('cc:dd'), isTrue); // retry window opened

      tracker.markAttempt('cc:dd');
      now = now.add(Duration(seconds: 13)); // beyond expiry window
      expect(tracker.canAttempt('cc:dd'), isTrue);
    });
  });
}
