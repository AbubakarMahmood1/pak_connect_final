import 'dart:async';

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
    late List<int> connectAttemptIds;
    Completer<void>? connectGate;
    Completer<void>? connectEntered;
    bool connectShouldFail = false;

    setUp(() {
      transitions = <String>[];
      connectRequests = <String>[];
      connectAttemptIds = <int>[];
      connectGate = null;
      connectEntered = null;
      connectShouldFail = false;
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
        connectEffector: (peer, attemptId) async {
          connectRequests.add(peer.uuid.toString());
          connectAttemptIds.add(attemptId);
          connectEntered?.complete();
          await connectGate?.future;
          if (connectShouldFail) throw StateError('connect failed');
        },
        canOpenAdditionalLinks: () => canOpenAdditionalLinks,
        hasActiveLinks: () => hasActiveLinks,
        isHandshakeInProgress: () => handshakeInProgress,
      );
    });

    tearDown(() async {
      await scheduler.stop();
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
        expect(connectAttemptIds, [scheduler.snapshot.activeAttemptId]);
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
        final attemptId = scheduler.snapshot.activeAttemptId!;
        scheduler.reportHandshakeStarted(peer.uuid.toString(), attemptId);
        scheduler.reportHandshakeReady(peer.uuid.toString(), attemptId);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);

        scheduler.reportMtuReady(peer.uuid.toString(), 185, attemptId);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);

        scheduler.reportNotifySubscribed(peer.uuid.toString(), attemptId);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(
          scheduler.snapshot.state,
          isNot(BleRoleSchedulerState.connectLock),
        );
      },
    );

    test(
      'milestones from a non-active peer cannot release connect lock',
      () async {
        final activePeer = _TestPeripheral(
          UUID.fromString('00000000-0000-0000-0000-0000000000d1'),
        );
        const unrelatedPeer = '00000000-0000-0000-0000-0000000000d2';

        await scheduler.requestOutboundConnect(activePeer);
        final attemptId = scheduler.snapshot.activeAttemptId!;
        scheduler.reportMtuReady(unrelatedPeer, 185, attemptId);
        scheduler.reportNotifySubscribed(unrelatedPeer, attemptId);
        scheduler.reportHandshakeStarted(unrelatedPeer, attemptId);
        scheduler.reportHandshakeReady(unrelatedPeer, attemptId);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(scheduler.snapshot.activePeerId, activePeer.uuid.toString());
        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);
      },
    );

    test('a new attempt for the same peer requires fresh milestones', () async {
      final peer = _TestPeripheral(
        UUID.fromString('00000000-0000-0000-0000-0000000000e1'),
      );
      final address = peer.uuid.toString();

      await scheduler.requestOutboundConnect(peer);
      final firstAttemptId = scheduler.snapshot.activeAttemptId!;
      scheduler.reportMtuReady(address, 185, firstAttemptId);
      scheduler.reportNotifySubscribed(address, firstAttemptId);
      scheduler.reportHandshakeStarted(address, firstAttemptId);
      scheduler.reportHandshakeReady(address, firstAttemptId);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(scheduler.snapshot.state, BleRoleSchedulerState.connectedMaintain);

      await scheduler.requestOutboundConnect(peer);
      final secondAttemptId = scheduler.snapshot.activeAttemptId!;
      expect(secondAttemptId, isNot(firstAttemptId));
      scheduler.reportMtuReady(address, 185, firstAttemptId);
      scheduler.reportNotifySubscribed(address, firstAttemptId);
      scheduler.reportHandshakeStarted(address, firstAttemptId);
      scheduler.reportHandshakeReady(address, firstAttemptId);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);
    });

    test(
      'queued timeout from an old attempt cannot clear inbound takeover',
      () async {
        final outbound = _TestPeripheral(
          UUID.fromString('00000000-0000-0000-0000-0000000000f1'),
        );
        connectGate = Completer<void>();
        connectEntered = Completer<void>();

        final outboundFuture = scheduler.requestOutboundConnect(outbound);
        await connectEntered!.future;
        final outboundAttemptId = connectAttemptIds.single;
        final inboundAttemptId = scheduler.reportInboundConnected(
          'peer-inbound',
        );
        expect(inboundAttemptId, isNot(outboundAttemptId));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        connectGate!.complete();
        await outboundFuture;
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(scheduler.snapshot.activePeerId, 'peer-inbound');
        expect(scheduler.snapshot.activeAttemptId, inboundAttemptId);
        expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);
      },
    );

    test('old connect failure cannot clear inbound takeover', () async {
      final outbound = _TestPeripheral(
        UUID.fromString('00000000-0000-0000-0000-0000000000f2'),
      );
      connectGate = Completer<void>();
      connectEntered = Completer<void>();
      connectShouldFail = true;

      final outboundFuture = scheduler.requestOutboundConnect(outbound);
      await connectEntered!.future;
      final inboundAttemptId = scheduler.reportInboundConnected('peer-inbound');
      connectGate!.complete();
      await outboundFuture;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(scheduler.snapshot.activePeerId, 'peer-inbound');
      expect(scheduler.snapshot.activeAttemptId, inboundAttemptId);
      expect(scheduler.snapshot.state, BleRoleSchedulerState.connectLock);
    });

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
      expect(scheduler.snapshot.activePeerId, isNull);
    });
  });
}
