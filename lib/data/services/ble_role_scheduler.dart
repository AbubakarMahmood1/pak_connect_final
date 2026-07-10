import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_ble_experiment_metrics_recorder.dart';
import 'package:pak_connect/domain/interfaces/i_ble_role_scheduler.dart';

class BleRoleScheduler implements IBleRoleScheduler {
  BleRoleScheduler({
    required Logger logger,
    required BleRoleSchedulerConfig config,
    required IBleExperimentMetricsRecorder metricsRecorder,
    required Future<void> Function() startScanEffector,
    required Future<void> Function() stopScanEffector,
    required Future<void> Function() startAdvertisingEffector,
    required Future<void> Function() stopAdvertisingEffector,
    required Future<void> Function(Peripheral peer) connectEffector,
    required bool Function() canOpenAdditionalLinks,
    required bool Function() hasActiveLinks,
    required bool Function() isHandshakeInProgress,
  }) : _logger = logger,
       _config = config,
       _metricsRecorder = metricsRecorder,
       _startScanEffector = startScanEffector,
       _stopScanEffector = stopScanEffector,
       _startAdvertisingEffector = startAdvertisingEffector,
       _stopAdvertisingEffector = stopAdvertisingEffector,
       _connectEffector = connectEffector,
       _canOpenAdditionalLinks = canOpenAdditionalLinks,
       _hasActiveLinks = hasActiveLinks,
       _isHandshakeInProgress = isHandshakeInProgress;

  final Logger _logger;
  final BleRoleSchedulerConfig _config;
  final IBleExperimentMetricsRecorder _metricsRecorder;
  final Future<void> Function() _startScanEffector;
  final Future<void> Function() _stopScanEffector;
  final Future<void> Function() _startAdvertisingEffector;
  final Future<void> Function() _stopAdvertisingEffector;
  final Future<void> Function(Peripheral peer) _connectEffector;
  final bool Function() _canOpenAdditionalLinks;
  final bool Function() _hasActiveLinks;
  final bool Function() _isHandshakeInProgress;

  Future<void> _tail = Future<void>.value();
  Timer? _windowTimer;
  bool _isRunning = false;
  bool _nextWindowIsScan = true;
  BleRoleSchedulerState _state = BleRoleSchedulerState.idle;
  String? _activePeerId;
  final Map<String, _LinkBringupState> _bringupByPeer = {};
  DateTime _lastTransitionAt = DateTime.now();

  @override
  BleRoleSchedulerSnapshot get snapshot => BleRoleSchedulerSnapshot(
    state: _state,
    isRunning: _isRunning,
    lastTransitionAt: _lastTransitionAt,
    nextWindowIsScan: _nextWindowIsScan,
    activePeerId: _activePeerId,
  );

  @override
  Future<void> start() => _serialize(() async {
    _isRunning = true;
    _nextWindowIsScan = true;
    if (_state == BleRoleSchedulerState.connectLock) {
      _logger.fine(
        'Strict TDM scheduler already in connectLock; keeping lock.',
      );
      return;
    }
    await _enterScanWindow(reason: 'start');
  });

  @override
  Future<void> stop() => _serialize(() async {
    _isRunning = false;
    _activePeerId = null;
    _bringupByPeer.clear();
    _windowTimer?.cancel();
    _windowTimer = null;
    await _stopRadios();
    _transitionTo(BleRoleSchedulerState.idle);
  });

  @override
  Future<void> requestOutboundConnect(Peripheral peer) => _serialize(() async {
    _isRunning = true;
    _activePeerId = peer.uuid.toString();
    _stateFor(_activePeerId!).connected = true;
    _metricsRecorder.recordOutboundConnectRequested(_activePeerId!);
    await _enterConnectLock(reason: 'outbound-connect-request', peer: peer);
  });

  @override
  void reportInboundConnected(String address) {
    unawaited(
      _serialize(() async {
        _isRunning = true;
        _activePeerId = address;
        _stateFor(address).connected = true;
        await _enterConnectLock(reason: 'inbound-connected');
      }),
    );
  }

  @override
  void reportMtuReady(String address, int mtu) {
    _activePeerId ??= address;
    final state = _stateFor(address)
      ..connected = true
      ..mtuReady = true
      ..mtu = mtu;
    _completeConnectLockIfReady(address, state, reason: 'mtu-ready');
  }

  @override
  void reportNotifySubscribed(String address) {
    _activePeerId ??= address;
    final state = _stateFor(address)
      ..connected = true
      ..notifySubscribed = true;
    _completeConnectLockIfReady(address, state, reason: 'notify-subscribed');
  }

  @override
  void reportHandshakeStarted(String address) {
    _activePeerId ??= address;
    _stateFor(address)
      ..connected = true
      ..handshakeStarted = true;
  }

  @override
  void reportHandshakeReady(String address) {
    _activePeerId ??= address;
    final state = _stateFor(address)
      ..connected = true
      ..handshakeStarted = true
      ..handshakeReady = true;
    _completeConnectLockIfReady(address, state, reason: 'handshake-ready');
  }

  void _completeConnectLockIfReady(
    String address,
    _LinkBringupState state, {
    required String reason,
  }) {
    if (!state.isReady) {
      _logger.fine(
        'Strict TDM keeping connect lock for $address after $reason '
        '(mtu=${state.mtuReady}, notify=${state.notifySubscribed}, handshake=${state.handshakeReady})',
      );
      return;
    }
    unawaited(
      _serialize(() async {
        if (_state == BleRoleSchedulerState.connectLock ||
            _state == BleRoleSchedulerState.connectedMaintain) {
          await _enterConnectedMaintain(reason: 'link-ready');
        }
      }),
    );
  }

  @override
  void reportDisconnect(String address, String reason) {
    _bringupByPeer.remove(address);
    unawaited(
      _serialize(() async {
        if (_activePeerId == address) {
          _activePeerId = null;
        }
        if (!_isRunning) {
          _transitionTo(BleRoleSchedulerState.idle);
          return;
        }
        if (_state == BleRoleSchedulerState.connectLock ||
            _state == BleRoleSchedulerState.connectedMaintain) {
          await _enterCooldown(reason: 'disconnect:$reason');
        }
      }),
    );
  }

  Future<void> _serialize(Future<void> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.catchError((_) {});
    return future;
  }

  _LinkBringupState _stateFor(String address) =>
      _bringupByPeer.putIfAbsent(address, _LinkBringupState.new);

  Future<void> _enterScanWindow({required String reason}) async {
    if (!_isRunning) {
      _transitionTo(BleRoleSchedulerState.idle);
      return;
    }
    _windowTimer?.cancel();
    await _stopAdvertisingEffector();
    await _stopScanEffector();
    _transitionTo(BleRoleSchedulerState.scanWindow, reason: reason);
    await _startScanEffector();
    _nextWindowIsScan = false;
    _windowTimer = Timer(
      _config.scanWindowDuration,
      () => unawaited(
        _serialize(() => _enterCooldown(reason: 'scan-window-complete')),
      ),
    );
  }

  Future<void> _enterAdvertiseWindow({required String reason}) async {
    if (!_isRunning) {
      _transitionTo(BleRoleSchedulerState.idle);
      return;
    }
    _windowTimer?.cancel();
    await _stopScanEffector();
    await _stopAdvertisingEffector();
    _transitionTo(BleRoleSchedulerState.advertiseWindow, reason: reason);
    await _startAdvertisingEffector();
    _nextWindowIsScan = true;
    _windowTimer = Timer(
      _config.advertiseWindowDuration,
      () => unawaited(
        _serialize(() => _enterCooldown(reason: 'advertise-window-complete')),
      ),
    );
  }

  Future<void> _enterConnectLock({
    required String reason,
    Peripheral? peer,
  }) async {
    if (!_isRunning) {
      _transitionTo(BleRoleSchedulerState.idle);
      return;
    }
    _windowTimer?.cancel();
    await _stopRadios();
    _transitionTo(BleRoleSchedulerState.connectLock, reason: reason);
    _windowTimer = Timer(
      _config.connectLockTimeout,
      () => unawaited(
        _serialize(() => _enterCooldown(reason: 'connect-lock-timeout')),
      ),
    );
    if (peer != null) {
      try {
        await _connectEffector(peer);
      } catch (error) {
        _logger.warning(
          'Strict TDM connect lock connect effector failed for ${peer.uuid}: $error',
        );
        _metricsRecorder.recordDisconnect(
          peer.uuid.toString(),
          'connect-lock-connect-failed',
        );
        _activePeerId = null;
        await _enterCooldown(reason: 'connect-lock-connect-failed');
      }
    }
  }

  Future<void> _enterConnectedMaintain({required String reason}) async {
    if (!_isRunning) {
      _transitionTo(BleRoleSchedulerState.idle);
      return;
    }
    _windowTimer?.cancel();
    await _stopRadios();
    _transitionTo(BleRoleSchedulerState.connectedMaintain, reason: reason);

    if (!_hasActiveLinks()) {
      _activePeerId = null;
      await _enterCooldown(reason: 'connected-maintain-no-links');
      return;
    }

    _windowTimer = Timer(
      _config.connectedMaintainRecheck,
      () => unawaited(
        _serialize(() async {
          if (!_isRunning) {
            _transitionTo(BleRoleSchedulerState.idle);
            return;
          }
          if (_isHandshakeInProgress() || !_canOpenAdditionalLinks()) {
            await _enterConnectedMaintain(reason: 'connected-maintain-recheck');
            return;
          }
          await _enterCooldown(reason: 'connected-maintain-release');
        }),
      ),
    );
  }

  Future<void> _enterCooldown({required String reason}) async {
    if (!_isRunning) {
      _transitionTo(BleRoleSchedulerState.idle);
      return;
    }
    _windowTimer?.cancel();
    await _stopRadios();
    _transitionTo(BleRoleSchedulerState.cooldown, reason: reason);
    _windowTimer = Timer(
      _config.cooldownDuration,
      () => unawaited(
        _serialize(() async {
          if (!_isRunning) {
            _transitionTo(BleRoleSchedulerState.idle);
            return;
          }
          if (_nextWindowIsScan) {
            await _enterScanWindow(reason: 'cooldown->scan');
          } else {
            await _enterAdvertiseWindow(reason: 'cooldown->advertise');
          }
        }),
      ),
    );
  }

  Future<void> _stopRadios() async {
    await _stopScanEffector();
    await _stopAdvertisingEffector();
  }

  void _transitionTo(BleRoleSchedulerState nextState, {String? reason}) {
    _state = nextState;
    _lastTransitionAt = DateTime.now();
    if (reason != null) {
      _logger.info('Strict TDM state -> ${nextState.name} ($reason)');
    } else {
      _logger.info('Strict TDM state -> ${nextState.name}');
    }
  }
}

class _LinkBringupState {
  bool connected = false;
  bool mtuReady = false;
  bool notifySubscribed = false;
  bool handshakeStarted = false;
  bool handshakeReady = false;
  int? mtu;

  bool get isReady =>
      connected && mtuReady && notifySubscribed && handshakeReady;
}
