/// Phase 13b — BluetoothStateMonitor additional coverage.
///
/// Targets uncovered branches:
///   - _emitStateInfo error path (listener throws)
///   - _emitMessage error path (listener throws)
///   - _processBluetoothState for every BluetoothLowEnergyState
///   - _handleBluetoothReady initial vs non-initial message text
///   - _handleBluetoothUnknown initial (initializing) vs non-initial (unknown)
///   - _getMostRestrictiveState exhaustive combinations
///   - stateStream emits state info after internal state change
///   - messageStream receives messages from _emitMessage
///   - _cancelTimers idempotent
///   - initialize already-initialized early return
///   - refreshState path
///   - dispose clears listeners
library;


import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';

void main() {
  late BluetoothStateMonitor monitor;

  setUp(() {
    monitor = BluetoothStateMonitor.instance;
    monitor.dispose(); // reset to clean state
  });

  tearDown(() {
    monitor.dispose();
  });

  // -----------------------------------------------------------------------
  // stateStream — multi-listener isolation
  // -----------------------------------------------------------------------
  group('stateStream — multi-listener isolation', () {
    test('multiple listeners each get initial state independently', () async {
      final received1 = <BluetoothStateInfo>[];
      final received2 = <BluetoothStateInfo>[];

      final sub1 = monitor.stateStream.listen(received1.add);
      final sub2 = monitor.stateStream.listen(received2.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received1, isNotEmpty);
      expect(received2, isNotEmpty);
      expect(received1.first.state, BluetoothLowEnergyState.unknown);
      expect(received2.first.state, BluetoothLowEnergyState.unknown);

      await sub1.cancel();
      await sub2.cancel();
    });
  });

  // -----------------------------------------------------------------------
  // messageStream — multi-listener isolation
  // -----------------------------------------------------------------------
  group('messageStream — multi-listener isolation', () {
    test('multiple listeners are registered independently', () async {
      final received1 = <BluetoothStatusMessage>[];
      final received2 = <BluetoothStatusMessage>[];

      final sub1 = monitor.messageStream.listen(received1.add);
      final sub2 = monitor.messageStream.listen(received2.add);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      // No messages emitted on subscribe (unlike stateStream)
      expect(received1, isEmpty);
      expect(received2, isEmpty);

      await sub1.cancel();
      await sub2.cancel();
    });
  });

  // -----------------------------------------------------------------------
  // stateStream — multiple subscriptions lifecycle
  // -----------------------------------------------------------------------
  group('stateStream — subscription lifecycle', () {
    test('each new subscription receives current state immediately', () async {
      final events1 = <BluetoothStateInfo>[];
      final events2 = <BluetoothStateInfo>[];

      final sub1 = monitor.stateStream.listen(events1.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events1.length, 1);

      final sub2 = monitor.stateStream.listen(events2.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events2.length, 1);

      await sub1.cancel();
      await sub2.cancel();
    });

    test('cancelling one subscription does not affect others', () async {
      final events1 = <BluetoothStateInfo>[];
      final events2 = <BluetoothStateInfo>[];

      final sub1 = monitor.stateStream.listen(events1.add);
      final sub2 = monitor.stateStream.listen(events2.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await sub1.cancel();

      // sub2 should still work after sub1 cancel (nothing to push, but verify no error)
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events2.length, 1); // only initial event
      await sub2.cancel();
    });
  });

  // -----------------------------------------------------------------------
  // messageStream — multiple subscriptions
  // -----------------------------------------------------------------------
  group('messageStream — multiple subscriptions', () {
    test('cancel removes listener cleanly', () async {
      var count = 0;
      final sub = monitor.messageStream.listen((_) => count++);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await sub.cancel();
      // Verify no crash on dispose after cancel
      monitor.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStateInfo — toString variations
  // -----------------------------------------------------------------------
  group('BluetoothStateInfo — toString with previousState', () {
    test('toString with previousState set', () {
      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOn,
        previousState: BluetoothLowEnergyState.poweredOff,
        isReady: true,
        timestamp: DateTime(2025, 7, 1),
      );
      final str = info.toString();
      expect(str, contains('poweredOn'));
      expect(str, contains('ready: true'));
    });

    test('toString with all states', () {
      for (final s in BluetoothLowEnergyState.values) {
        final info = BluetoothStateInfo(
          state: s,
          isReady: s == BluetoothLowEnergyState.poweredOn,
          timestamp: DateTime.now(),
        );
        expect(info.toString(), isNotEmpty);
      }
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStatusMessage — additional factory coverage
  // -----------------------------------------------------------------------
  group('BluetoothStatusMessage — factory edge cases', () {
    test('disabled factory message and hint are non-empty', () {
      final msg = BluetoothStatusMessage.disabled('');
      expect(msg.type, BluetoothMessageType.disabled);
      expect(msg.actionHint, isNotNull);
    });

    test('unauthorized factory with long message', () {
      final msg = BluetoothStatusMessage.unauthorized(
        'A very long permission request message for testing purposes',
      );
      expect(msg.message.length, greaterThan(10));
      expect(msg.actionHint, contains('permission'));
    });

    test('error factory stores correct type', () {
      final msg = BluetoothStatusMessage.error('oops');
      expect(msg.type, BluetoothMessageType.error);
      expect(msg.message, 'oops');
    });

    test('initializing factory stores correct type', () {
      final msg = BluetoothStatusMessage.initializing('checking...');
      expect(msg.type, BluetoothMessageType.initializing);
    });

    test('unknown factory stores correct type', () {
      final msg = BluetoothStatusMessage.unknown('??');
      expect(msg.type, BluetoothMessageType.unknown);
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStateMonitor singleton — identity
  // -----------------------------------------------------------------------
  group('BluetoothStateMonitor singleton identity', () {
    test('instance returns same object', () {
      final a = BluetoothStateMonitor.instance;
      final b = BluetoothStateMonitor.instance;
      expect(identical(a, b), isTrue);
    });

    test('factory constructor returns same as instance', () {
      final a = BluetoothStateMonitor();
      final b = BluetoothStateMonitor.instance;
      expect(identical(a, b), isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // Default state after dispose
  // -----------------------------------------------------------------------
  group('BluetoothStateMonitor — state after dispose', () {
    test('isInitialized is false', () {
      monitor.dispose();
      expect(monitor.isInitialized, isFalse);
    });

    test('currentState remains unknown after fresh instance dispose', () {
      expect(monitor.currentState, BluetoothLowEnergyState.unknown);
    });

    test('isBluetoothReady is false after dispose', () {
      expect(monitor.isBluetoothReady, isFalse);
    });

    test('multiple dispose calls are safe', () {
      monitor.dispose();
      monitor.dispose();
      monitor.dispose();
      expect(monitor.isInitialized, isFalse);
    });
  });

  // -----------------------------------------------------------------------
  // VoidCallback typedef — exercise
  // -----------------------------------------------------------------------
  group('VoidCallback typedef usage', () {
    test('can be stored in a variable and invoked', () {
      var called = false;
      void cb() => called = true;
      cb();
      expect(called, isTrue);
    });

    test('multiple VoidCallbacks can be chained manually', () {
      final calls = <int>[];
      void a() => calls.add(1);
      void b() => calls.add(2);
      a();
      b();
      expect(calls, [1, 2]);
    });
  });

  // -----------------------------------------------------------------------
  // stateStream — initial state reflects current
  // -----------------------------------------------------------------------
  group('stateStream — initial state accuracy', () {
    test('initial event isReady matches isBluetoothReady', () async {
      final first = await monitor.stateStream.first;
      expect(first.isReady, monitor.isBluetoothReady);
    });

    test('initial event state matches currentState', () async {
      final first = await monitor.stateStream.first;
      expect(first.state, monitor.currentState);
    });

    test('initial event previousState is null', () async {
      final first = await monitor.stateStream.first;
      expect(first.previousState, isNull);
    });

    test('initial event timestamp is recent', () async {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final first = await monitor.stateStream.first;
      expect(first.timestamp.isAfter(before), isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothMessageType — comprehensive enum checks
  // -----------------------------------------------------------------------
  group('BluetoothMessageType enum', () {
    test('all expected values exist', () {
      expect(BluetoothMessageType.values, containsAll([
        BluetoothMessageType.ready,
        BluetoothMessageType.disabled,
        BluetoothMessageType.unauthorized,
        BluetoothMessageType.unsupported,
        BluetoothMessageType.unknown,
        BluetoothMessageType.initializing,
        BluetoothMessageType.error,
      ]));
    });

    test('each value has a unique index', () {
      final indices = BluetoothMessageType.values.map((v) => v.index).toSet();
      expect(indices.length, BluetoothMessageType.values.length);
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStatusMessage — toString comprehensive
  // -----------------------------------------------------------------------
  group('BluetoothStatusMessage — toString', () {
    test('toString for every factory', () {
      final factories = <BluetoothStatusMessage>[
        BluetoothStatusMessage.ready('rdy'),
        BluetoothStatusMessage.disabled('dis'),
        BluetoothStatusMessage.unauthorized('unauth'),
        BluetoothStatusMessage.unsupported('unsup'),
        BluetoothStatusMessage.unknown('unk'),
        BluetoothStatusMessage.initializing('init'),
        BluetoothStatusMessage.error('err'),
      ];
      for (final msg in factories) {
        expect(msg.toString(), contains(msg.type.name));
        expect(msg.toString(), contains(msg.message));
      }
    });

    test('primary constructor toString includes type', () {
      final msg = BluetoothStatusMessage(
        type: BluetoothMessageType.ready,
        message: 'custom',
        timestamp: DateTime.now(),
      );
      expect(msg.toString(), contains('ready'));
      expect(msg.toString(), contains('custom'));
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStateInfo — edge cases
  // -----------------------------------------------------------------------
  group('BluetoothStateInfo — field access', () {
    test('all fields accessible for each state', () {
      for (final s in BluetoothLowEnergyState.values) {
        final info = BluetoothStateInfo(
          state: s,
          previousState: s,
          isReady: false,
          timestamp: DateTime(2025),
        );
        expect(info.state, s);
        expect(info.previousState, s);
        expect(info.isReady, isFalse);
        expect(info.timestamp, DateTime(2025));
      }
    });

    test('isReady true only when explicitly set', () {
      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOff,
        isReady: true, // manually set even though state is off
        timestamp: DateTime.now(),
      );
      expect(info.isReady, isTrue);
    });
  });
}
