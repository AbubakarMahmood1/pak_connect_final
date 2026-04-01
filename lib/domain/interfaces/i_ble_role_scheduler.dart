import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

enum BleRoleSchedulerState {
  idle,
  scanWindow,
  advertiseWindow,
  connectLock,
  connectedMaintain,
  cooldown,
}

final class BleRoleSchedulerConfig {
  const BleRoleSchedulerConfig({
    this.scanWindowDuration = const Duration(seconds: 3),
    this.advertiseWindowDuration = const Duration(seconds: 3),
    this.cooldownDuration = const Duration(milliseconds: 500),
    this.connectLockTimeout = const Duration(seconds: 8),
    this.connectedMaintainRecheck = const Duration(seconds: 1),
  });

  final Duration scanWindowDuration;
  final Duration advertiseWindowDuration;
  final Duration cooldownDuration;
  final Duration connectLockTimeout;
  final Duration connectedMaintainRecheck;
}

final class BleRoleSchedulerSnapshot {
  const BleRoleSchedulerSnapshot({
    required this.state,
    required this.isRunning,
    required this.lastTransitionAt,
    required this.nextWindowIsScan,
    this.activePeerId,
  });

  final BleRoleSchedulerState state;
  final bool isRunning;
  final DateTime lastTransitionAt;
  final bool nextWindowIsScan;
  final String? activePeerId;
}

abstract interface class IBleRoleScheduler {
  Future<void> start();
  Future<void> stop();
  Future<void> requestOutboundConnect(Peripheral peer);
  void reportInboundConnected(String address);
  void reportMtuReady(String address, int mtu);
  void reportNotifySubscribed(String address);
  void reportHandshakeStarted(String address);
  void reportHandshakeReady(String address);
  void reportDisconnect(String address, String reason);
  BleRoleSchedulerSnapshot get snapshot;
}
