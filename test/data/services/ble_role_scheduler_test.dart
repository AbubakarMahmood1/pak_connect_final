import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/ble_experiment_metrics_recorder.dart';
import 'package:pak_connect/data/services/ble_role_scheduler.dart';
import 'package:pak_connect/domain/interfaces/i_ble_role_scheduler.dart';

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('BleRoleScheduler', () {
    late BleRoleScheduler scheduler;
    late BleExperimentMetricsRecorder recorder;
    late List<String> transitions;
    late List<String> connectRequests;
    late bool hasActiveLinks;
    late bool canOpenAdditionalLinks;
    late bool handshakeInProgress;

    setUp(() {
      transitions = <String>[];
      connectRequests = <String>[];
      hasActiveLinks = true;
      canOpenAdditionalLinks = true;
      handshakeInProgress = false;
      recorder = BleExperimentMetricsRecorder(
        logger: Logger('test.scheduler.metrics'),
        sessionMode: 'strict_tdm',
      );
      scheduler = BleRoleScheduler(
        logger: Logger('test.scheduler'),
        config: const BleRoleSchedulerConfig(
          scanWindowDuration: Duration(milliseconds: 20),
          advertiseWindowDuration: Duration(milliseconds: 20),
          cooldownDuration: Duration(milliseconds: 10),
          connectLockTimeout: Duration(milliseconds: 40),
          connectedMaintainRecheck: Duration(milliseconds: 10),
        ),
        metricsRecorder: recorder,
        startScanEffector: () async => transitions.add('scan:start'),
        stopScanEffector: () async => transitions.add('scan:stop'),
        startAdvertisingEffector: () async =>
            transitions.add('advertise:start'),
        stopAdvertisingEffector: () async => transitions.add('advertise:stop'),
        connectEffector: (peer) async {
          connectRequests.add(peer.uuid.toString());
        },
        canOpenAdditionalLinks: () => canOpenAdditionalLinks,
        hasActiveLinks: () => hasActiveLinks,
        isHandshakeInProgress: () => handshakeInProgress,
      );
    });

    test(
      'start enters scan window without overlapping advertise start',
      () async {
        await scheduler.start();

        expect(scheduler.snapshot.state, BleRoleSchedulerState.scanWindow);
        expect(transitions, ['advertise:stop', 'scan:stop', 'scan:start']);
      },
    );

    test(
      'outbound connect enters connect lock and calls connect effector',
      () async {
        final peer = _TestPeripheral(
          UUID.fromString('00000000-0000-0000-0000-0000000000aa'),
        );

        await scheduler.start();
        await scheduler.requestOutboundConnect(peer);

        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);
        expect(connectRequests, [peer.uuid.toString()]);
        expect(
          transitions,
          containsAllInOrder(['scan:stop', 'advertise:stop']),
        );
      },
    );

    test('inbound connected enters connect lock', () async {
      await scheduler.start();
      scheduler.reportInboundConnected('peer-inbound');
      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);
    });

    test(
      'handshake ready waits for MTU and notify readiness before releasing connect lock',
      () async {
        final peer = _TestPeripheral(
          UUID.fromString('00000000-0000-0000-0000-0000000000bb'),
        );

        await scheduler.requestOutboundConnect(peer);
        scheduler.reportHandshakeStarted(peer.uuid.toString());
        scheduler.reportHandshakeReady(peer.uuid.toString());
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);

        scheduler.reportMtuReady(peer.uuid.toString(), 185);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);

        scheduler.reportNotifySubscribed(peer.uuid.toString());
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(
          scheduler.snapshot.state,
          isNot(BleRoleSchedulerState.connectLock),
        );
      },
    );

    test('connect lock timeout releases scheduler back into cycling', () async {
      final peer = _TestPeripheral(
        UUID.fromString('00000000-0000-0000-0000-0000000000cc'),
      );

      await scheduler.requestOutboundConnect(peer);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        scheduler.snapshot.state,
        isNot(BleRoleSchedulerState.connectLock),
      );
    });
  });
}
