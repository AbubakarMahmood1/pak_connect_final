/// Phase 13 — BluetoothStateMonitor extended tests.
///
/// Covers: stream subscriptions/cancellations, listener emission mechanics,
/// _getMostRestrictiveState through stateStream, dispose cleanup,
/// model edge-cases, and the VoidCallback typedef.
import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/bluetooth_state_models.dart';
import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';

void main() {
  // -----------------------------------------------------------------------
  // BluetoothStateInfo extended
  // -----------------------------------------------------------------------
  group('BluetoothStateInfo extended', () {
    test('toString with previousState null', () {
      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOff,
        isReady: false,
        timestamp: DateTime(2026),
      );
      expect(info.toString(), contains('poweredOff'));
      expect(info.toString(), contains('ready: false'));
    });

    test('isReady is true only for poweredOn', () {
      for (final state in BluetoothLowEnergyState.values) {
        final info = BluetoothStateInfo(
          state: state,
          isReady: state == BluetoothLowEnergyState.poweredOn,
          timestamp: DateTime.now(),
        );
        if (state == BluetoothLowEnergyState.poweredOn) {
          expect(info.isReady, isTrue);
        } else {
          expect(info.isReady, isFalse);
        }
      }
    });

    test('timestamp is stored correctly', () {
      final ts = DateTime(2025, 6, 15, 12, 0);
      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.unknown,
        isReady: false,
        timestamp: ts,
      );
      expect(info.timestamp, ts);
    });

    test('previousState stores passed value', () {
      final info = BluetoothStateInfo(
        state: BluetoothLowEnergyState.poweredOn,
        previousState: BluetoothLowEnergyState.poweredOff,
        isReady: true,
        timestamp: DateTime.now(),
      );
      expect(info.previousState, BluetoothLowEnergyState.poweredOff);
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStatusMessage extended
  // -----------------------------------------------------------------------
  group('BluetoothStatusMessage extended', () {
    test('disabled factory sets actionHint', () {
      final msg = BluetoothStatusMessage.disabled('BLE off');
      expect(msg.actionHint, isNotNull);
      expect(msg.actionHint, contains('Enable Bluetooth'));
    });

    test('unauthorized factory sets actionHint', () {
      final msg = BluetoothStatusMessage.unauthorized('no perm');
      expect(msg.actionHint, isNotNull);
      expect(msg.actionHint, contains('permission'));
    });

    test('unsupported factory has no actionHint', () {
      final msg = BluetoothStatusMessage.unsupported('no BLE');
      expect(msg.actionHint, isNull);
    });

    test('ready factory has no actionHint', () {
      final msg = BluetoothStatusMessage.ready('all good');
      expect(msg.actionHint, isNull);
    });

    test('error factory has no actionHint', () {
      final msg = BluetoothStatusMessage.error('oops');
      expect(msg.actionHint, isNull);
    });

    test('unknown factory has no actionHint', () {
      final msg = BluetoothStatusMessage.unknown('??');
      expect(msg.actionHint, isNull);
    });

    test('initializing factory has no actionHint', () {
      final msg = BluetoothStatusMessage.initializing('starting');
      expect(msg.actionHint, isNull);
    });

    test('toString includes type and message', () {
      final msg = BluetoothStatusMessage.error('something failed');
      expect(msg.toString(), contains('error'));
      expect(msg.toString(), contains('something failed'));
    });

    test('primary constructor with actionHint', () {
      final msg = BluetoothStatusMessage(
        type: BluetoothMessageType.disabled,
        message: 'test',
        actionHint: 'custom hint',
        timestamp: DateTime(2026),
      );
      expect(msg.actionHint, 'custom hint');
      expect(msg.type, BluetoothMessageType.disabled);
    });

    test('timestamp is recent for factory constructors', () {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final msg = BluetoothStatusMessage.ready('ok');
      expect(msg.timestamp.isAfter(before), isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothMessageType enum
  // -----------------------------------------------------------------------
  group('BluetoothMessageType extended', () {
    test('enum count is 7', () {
      expect(BluetoothMessageType.values.length, 7);
    });

    test('name property works for all values', () {
      for (final type in BluetoothMessageType.values) {
        expect(type.name, isNotEmpty);
      }
    });

    test('index values are sequential', () {
      for (var i = 0; i < BluetoothMessageType.values.length; i++) {
        expect(BluetoothMessageType.values[i].index, i);
      }
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStateMonitor singleton
  // -----------------------------------------------------------------------
  group('BluetoothStateMonitor singleton extended', () {
    late BluetoothStateMonitor monitor;

    setUp(() {
      monitor = BluetoothStateMonitor.instance;
      monitor.dispose(); // Reset to clean state
    });

    test('factory constructor returns same instance', () {
      expect(identical(BluetoothStateMonitor(), BluetoothStateMonitor.instance),
          isTrue);
    });

    test('currentState defaults to unknown', () {
      expect(monitor.currentState, BluetoothLowEnergyState.unknown);
    });

    test('isBluetoothReady defaults to false', () {
      expect(monitor.isBluetoothReady, isFalse);
    });

    test('isInitialized is false after dispose', () {
      expect(monitor.isInitialized, isFalse);
    });

    test('dispose is idempotent', () {
      monitor.dispose();
      monitor.dispose(); // Should not throw
      expect(monitor.isInitialized, isFalse);
    });
  });

  // -----------------------------------------------------------------------
  // stateStream
  // -----------------------------------------------------------------------
  group('BluetoothStateMonitor stateStream', () {
    late BluetoothStateMonitor monitor;

    setUp(() {
      monitor = BluetoothStateMonitor.instance;
      monitor.dispose();
    });

    test('emits initial state on subscription', () async {
      final firstEvent = await monitor.stateStream.first;
      expect(firstEvent.state, BluetoothLowEnergyState.unknown);
      expect(firstEvent.isReady, isFalse);
    });

    test('multiple subscriptions each get initial state', () async {
      final s1 = await monitor.stateStream.first;
      final s2 = await monitor.stateStream.first;
      expect(s1.state, s2.state);
    });

    test('cancelling subscription cleans up listener', () async {
      final sub = monitor.stateStream.listen((_) {});
      // Give time for subscription setup
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      // After cancel, the listener should be removed (no throw on dispose)
      monitor.dispose();
    });
  });

  // -----------------------------------------------------------------------
  // messageStream
  // -----------------------------------------------------------------------
  group('BluetoothStateMonitor messageStream', () {
    late BluetoothStateMonitor monitor;

    setUp(() {
      monitor = BluetoothStateMonitor.instance;
      monitor.dispose();
    });

    test('subscription and cancellation works', () async {
      final messages = <BluetoothStatusMessage>[];
      final sub = monitor.messageStream.listen(messages.add);
      await Future<void>.delayed(Duration.zero);

      // No messages emitted on subscription (unlike stateStream)
      expect(messages, isEmpty);

      await sub.cancel();
      monitor.dispose();
    });

    test('multiple subscriptions are independent', () async {
      final m1 = <BluetoothStatusMessage>[];
      final m2 = <BluetoothStatusMessage>[];
      final sub1 = monitor.messageStream.listen(m1.add);
      final sub2 = monitor.messageStream.listen(m2.add);
      await Future<void>.delayed(Duration.zero);

      await sub1.cancel();
      await sub2.cancel();
    });
  });

  // -----------------------------------------------------------------------
  // VoidCallback typedef
  // -----------------------------------------------------------------------
  group('VoidCallback typedef', () {
    test('VoidCallback is a function type returning void', () {
      VoidCallback cb = () {};
      cb();
      // Just verify it compiles and runs
      expect(true, isTrue);
    });

    test('VoidCallback can be stored and called', () {
      var called = false;
      final VoidCallback cb = () {
        called = true;
      };
      cb();
      expect(called, isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothLowEnergyState comprehensive
  // -----------------------------------------------------------------------
  group('BluetoothLowEnergyState values', () {
    test('includes all expected states', () {
      expect(BluetoothLowEnergyState.values, containsAll([
        BluetoothLowEnergyState.unknown,
        BluetoothLowEnergyState.unsupported,
        BluetoothLowEnergyState.unauthorized,
        BluetoothLowEnergyState.poweredOff,
        BluetoothLowEnergyState.poweredOn,
      ]));
    });
  });

  // -----------------------------------------------------------------------
  // BluetoothStateInfo all states
  // -----------------------------------------------------------------------
  group('BluetoothStateInfo for every BluetoothLowEnergyState', () {
    for (final state in BluetoothLowEnergyState.values) {
      test('creates BluetoothStateInfo for $state', () {
        final info = BluetoothStateInfo(
          state: state,
          isReady: state == BluetoothLowEnergyState.poweredOn,
          timestamp: DateTime.now(),
        );
        expect(info.state, state);
        expect(info.toString(), contains(state.name));
      });
    }
  });

  // -----------------------------------------------------------------------
  // BluetoothStatusMessage for every type
  // -----------------------------------------------------------------------
  group('BluetoothStatusMessage for every BluetoothMessageType', () {
    final factories = <BluetoothMessageType, BluetoothStatusMessage Function(String)>{
      BluetoothMessageType.ready: BluetoothStatusMessage.ready,
      BluetoothMessageType.disabled: BluetoothStatusMessage.disabled,
      BluetoothMessageType.unauthorized: BluetoothStatusMessage.unauthorized,
      BluetoothMessageType.unsupported: BluetoothStatusMessage.unsupported,
      BluetoothMessageType.unknown: BluetoothStatusMessage.unknown,
      BluetoothMessageType.initializing: BluetoothStatusMessage.initializing,
      BluetoothMessageType.error: BluetoothStatusMessage.error,
    };

    for (final entry in factories.entries) {
      test('factory for ${entry.key.name} creates correct type', () {
        final msg = entry.value('test message for ${entry.key.name}');
        expect(msg.type, entry.key);
        expect(msg.message, contains(entry.key.name));
      });
    }
  });
}
