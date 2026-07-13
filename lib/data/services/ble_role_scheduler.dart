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
    required Future<void> Function(Peripheral peer, int attemptId)
    connectEffector,
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
  final Future<void> Function(Peripheral peer, int attemptId) _connectEffector;
  final bool Function() _canOpenAdditionalLinks;
  final bool Function() _hasActiveLinks;
  final bool Function() _isHandshakeInProgress;

  Future<void> _tail = Future<void>.value();
  Timer? _windowTimer;
  bool _isRunning = false;
  bool _nextWindowIsScan = true;
  BleRoleSchedulerState _state = BleRoleSchedulerState.idle;
  String? _activePeerId;
  int? _activeAttemptId;
  int _nextAttemptId = 0;
  final Map<String, _LinkBringupState> _bringupByPeer = {};
  DateTime _lastTransitionAt = DateTime.now();

  @override
  BleRoleSchedulerSnapshot get snapshot => BleRoleSchedulerSnapshot(
    state: _state,
    isRunning: _isRunning,
    lastTransitionAt: _lastTransitionAt,
    nextWindowIsScan: _nextWindowIsScan,
    activePeerId: _activePeerId,
    activeAttemptId: _activeAttemptId,
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
    _activeAttemptId = null;
    _bringupByPeer.clear();
    _windowTimer?.cancel();
    _windowTimer = null;
    await _stopRadios();
    _transitionTo(BleRoleSchedulerState.idle);
  });

  @override
  Future<void> requestOutboundConnect(Peripheral peer) => _serialize(() async {
    _isRunning = true;
    final address = peer.uuid.toString();
    final state = _startAttempt(address);
    _metricsRecorder.recordOutboundConnectRequested(_activePeerId!);
    await _enterConnectLock(
      reason: 'outbound-connect-request',
      attemptId: state.attemptId,
      state: state,
      peer: peer,
    );
  });

  @override
  int reportInboundConnected(String address) {
    // Bind the peer synchronously so an MTU/subscribe callback delivered in
    // the same event turn cannot be discarded while the serialized radio
    // transition is still queued.
    _isRunning = true;
    final state = _startAttempt(address);
    unawaited(
      _serialize(() async {
        if (!_isActiveAttempt(address, state.attemptId, state)) return;
        await _enterConnectLock(
          reason: 'inbound-connected',
          attemptId: state.attemptId,
          state: state,
        );
      }),
    );
    return state.attemptId;
  }

  @override
  void reportMtuReady(String address, int mtu, int attemptId) {
    final state = _acceptedState(address, attemptId, 'mtu-ready');
    if (state == null) return;
    state
      ..connected = true
      ..mtuReady = true
      ..mtu = mtu;
    _completeConnectLockIfReady(address, state, reason: 'mtu-ready');
  }

  @override
  void reportNotifySubscribed(String address, int attemptId) {
    final state = _acceptedState(address, attemptId, 'notify-subscribed');
    if (state == null) return;
    state
      ..connected = true
      ..notifySubscribed = true;
    _completeConnectLockIfReady(address, state, reason: 'notify-subscribed');
  }

  @override
  void reportHandshakeStarted(String address, int attemptId) {
    final state = _acceptedState(address, attemptId, 'handshake-started');
    if (state == null) return;
    state
      ..connected = true
      ..handshakeStarted = true;
  }

  @override
  void reportHandshakeReady(String address, int attemptId) {
    final state = _acceptedState(address, attemptId, 'handshake-ready');
    if (state == null) return;
    if (!state.handshakeStarted) {
      _logger.fine(
        'Strict TDM ignoring handshake-ready before handshake-started for '
        '$address attempt#$attemptId',
      );
      return;
    }
    state
      ..connected = true
      ..handshakeReady = true;
    _completeConnectLockIfReady(address, state, reason: 'handshake-ready');
  }

  void _completeConnectLockIfReady(
    String address,
    _LinkBringupState state, {
    required String reason,
  }) {
    if (!_isActiveAttempt(address, state.attemptId, state)) {
      _logger.fine(
        'Strict TDM ignoring ready state for non-active peer $address '
        '(active=${_activePeerId ?? "none"})',
      );
      return;
    }
    if (!state.isReady) {
      _logger.fine(
        'Strict TDM keeping connect lock for $address after $reason '
        '(mtu=${state.mtuReady}, notify=${state.notifySubscribed}, handshake=${state.handshakeReady})',
      );
      return;
    }
    unawaited(
      _serialize(() async {
        if (!_isActiveAttempt(address, state.attemptId, state)) return;
        if (_state == BleRoleSchedulerState.connectLock ||
            _state == BleRoleSchedulerState.connectedMaintain) {
          await _enterConnectedMaintain(reason: 'link-ready');
        }
      }),
    );
  }

  @override
  void reportDisconnect(String address, String reason, int attemptId) {
    final state = _bringupByPeer[address];
    if (!_isActiveAttempt(address, attemptId, state)) {
      _logger.fine(
        'Strict TDM ignoring disconnect for stale $address attempt#$attemptId',
      );
      return;
    }
    _bringupByPeer.remove(address);
    unawaited(
      _serialize(() async {
        if (!_matchesActiveIdentity(address, attemptId)) return;
        _activePeerId = null;
        _activeAttemptId = null;
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

  _LinkBringupState _startAttempt(String address) {
    final state = _LinkBringupState(++_nextAttemptId)..connected = true;
    _activePeerId = address;
    _activeAttemptId = state.attemptId;
    _bringupByPeer.clear();
    _bringupByPeer[address] = state;
    return state;
  }

  bool _matchesActiveIdentity(String address, int attemptId) =>
      _activePeerId == address && _activeAttemptId == attemptId;

  bool _isActiveAttempt(
    String address,
    int attemptId,
    _LinkBringupState? state,
  ) =>
      state != null &&
      _matchesActiveIdentity(address, attemptId) &&
      identical(_bringupByPeer[address], state) &&
      state.attemptId == attemptId;

  _LinkBringupState? _acceptedState(
    String address,
    int attemptId,
    String milestone,
  ) {
    final state = _bringupByPeer[address];
    if (_isActiveAttempt(address, attemptId, state)) return state;
    _logger.fine(
      'Strict TDM ignoring $milestone for stale/non-active $address '
      'attempt#$attemptId (active=${_activePeerId ?? "none"}'
      '#${_activeAttemptId ?? 0})',
    );
    return null;
  }

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
    required int attemptId,
    required _LinkBringupState state,
    Peripheral? peer,
  }) async {
    final address = _activePeerId;
    if (address == null || !_isActiveAttempt(address, attemptId, state)) return;
    if (!_isRunning) {
      _transitionTo(BleRoleSchedulerState.idle);
      return;
    }
    _windowTimer?.cancel();
    await _stopRadios();
    if (!_isActiveAttempt(address, attemptId, state)) return;
    _transitionTo(BleRoleSchedulerState.connectLock, reason: reason);
    _windowTimer = Timer(
      _config.connectLockTimeout,
      () => unawaited(
        _serialize(() async {
          if (!_isActiveAttempt(address, attemptId, state)) return;
          _bringupByPeer.remove(address);
          _activePeerId = null;
          _activeAttemptId = null;
          await _enterCooldown(reason: 'connect-lock-timeout');
        }),
      ),
    );
    if (peer != null) {
      try {
        await _connectEffector(peer, attemptId);
      } catch (error) {
        _logger.warning(
          'Strict TDM connect lock connect effector failed for ${peer.uuid}: $error',
        );
        _metricsRecorder.recordDisconnect(
          peer.uuid.toString(),
          'connect-lock-connect-failed',
        );
        if (!_isActiveAttempt(address, attemptId, state)) return;
        _bringupByPeer.remove(address);
        _activePeerId = null;
        _activeAttemptId = null;
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
      _activeAttemptId = null;
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
  _LinkBringupState(this.attemptId);

  final int attemptId;
  bool connected = false;
  bool mtuReady = false;
  bool notifySubscribed = false;
  bool handshakeStarted = false;
  bool handshakeReady = false;
  int? mtu;

  bool get isReady =>
      connected && mtuReady && notifySubscribed && handshakeReady;
}
