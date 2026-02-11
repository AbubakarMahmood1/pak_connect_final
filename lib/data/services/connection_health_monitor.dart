import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';

enum ConnectionMonitorState { idle, healthChecking, reconnecting }

class ConnectionHealthMonitor {
  final Logger _logger;
  final CentralManager _centralManager;
  final int maxReconnectAttempts;
  final int minInterval;
  final int maxInterval;
  final int healthCheckInterval;
  final Peripheral? Function() getConnectedDevice;
  final GATTCharacteristic? Function() getMessageCharacteristic;
  final bool Function() hasBleConnection;
  final Future<void> Function({bool keepMonitoring}) clearConnectionState;
  final Future<Peripheral?> Function({Duration timeout}) scanForSpecificDevice;
  final Future<void> Function(Peripheral device) connectToDevice;
  final bool Function() hasViableRelayConnection;
  final void Function(bool active)? onMonitoringChanged;
  final void Function(bool isReconnection)? onReconnectionFlagChanged;
  final bool Function()? _hasActiveClientLink;
  final bool Function()? _isCollisionResolving;
  final bool Function()? _hasPendingClientConnection;

  Timer? _monitoringTimer;
  bool _isMonitoring = false;
  int _monitoringInterval;
  DateTime? _healthCheckGraceUntil;
  int _reconnectAttempts = 0;
  bool _messageOperationInProgress = false;
  bool _pairingInProgress = false;
  bool _handshakeInProgress = false;
  bool _awaitingHandshake = false;
  bool _isReconnection = false;
  ConnectionMonitorState _monitorState = ConnectionMonitorState.idle;

  ConnectionHealthMonitor({
    required Logger logger,
    required CentralManager centralManager,
    required this.minInterval,
    required this.maxInterval,
    required this.maxReconnectAttempts,
    required this.healthCheckInterval,
    required this.getConnectedDevice,
    required this.getMessageCharacteristic,
    required this.hasBleConnection,
    required this.clearConnectionState,
    required this.scanForSpecificDevice,
    required this.connectToDevice,
    required this.hasViableRelayConnection,
    this.onMonitoringChanged,
    this.onReconnectionFlagChanged,
    bool Function()? hasActiveClientLink,
    bool Function()? isCollisionResolving,
    bool Function()? hasPendingClientConnection,
  }) : _logger = logger,
       _centralManager = centralManager,
       _monitoringInterval = minInterval,
       _hasActiveClientLink = hasActiveClientLink,
       _isCollisionResolving = isCollisionResolving,
       _hasPendingClientConnection = hasPendingClientConnection;

  bool get isMonitoring => _isMonitoring;
  bool get isActivelyReconnecting =>
      _isMonitoring && _monitorState == ConnectionMonitorState.reconnecting;
  bool get isHealthChecking =>
      _isMonitoring && _monitorState == ConnectionMonitorState.healthChecking;
  bool get isReconnection => _isReconnection;
  bool get isHandshakeInProgress => _handshakeInProgress;
  bool get awaitingHandshake => _awaitingHandshake;

  void start() {
    if (KillSwitches.disableHealthChecks) {
      _logger.warning('⚠️ Health checks disabled via kill switch');
      return;
    }
    if (_isMonitoring) return;

    _isMonitoring = true;
    _monitorState = hasBleConnection()
        ? ConnectionMonitorState.healthChecking
        : ConnectionMonitorState.reconnecting;
    _monitoringInterval = minInterval;
    _reconnectAttempts = 0;
    _scheduleNextCheck();
    onMonitoringChanged?.call(true);
    _logger.info('Monitoring started in ${_monitorState.name} mode');
  }

  void stop() {
    _isMonitoring = false;
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _monitorState = ConnectionMonitorState.idle;
    _monitoringInterval = minInterval;
    _healthCheckGraceUntil = null;
    _awaitingHandshake = false;
    _reconnectAttempts = 0;
    onMonitoringChanged?.call(false);
    _logger.info('Monitoring stopped');
  }

  void startHealthChecks() {
    if (KillSwitches.disableHealthChecks) {
      _logger.warning('⚠️ Health checks disabled via kill switch');
      return;
    }
    if (!hasBleConnection()) {
      _logger.fine('⏸️ Skipping health checks - no client link to monitor');
      return;
    }

    // Add a grace window after a fresh connection to avoid racing the handshake.
    _healthCheckGraceUntil = DateTime.now().add(const Duration(seconds: 10));
    _awaitingHandshake = true;
    if (!_isMonitoring) {
      start();
    }
  }

  void setPairingInProgress(bool inProgress) {
    _pairingInProgress = inProgress;
    if (inProgress) {
      _logger.info('⏸️ Pausing health checks during pairing');
    } else {
      _logger.info('▶️ Resuming health checks after pairing');
    }
  }

  void setHandshakeInProgress(bool inProgress) {
    _handshakeInProgress = inProgress;
    if (inProgress) {
      _logger.info('🤝 Handshake started - pausing health checks');
    } else {
      _logger.info('⏹️ Handshake ended - resuming health checks');
      _awaitingHandshake = false;
      _healthCheckGraceUntil = null;
    }
  }

  void setAwaitingHandshake(bool awaiting) {
    _awaitingHandshake = awaiting;
    _logger.fine(
      '🤝 Awaiting handshake flag set to $awaiting '
      '(handshakeInProgress=$_handshakeInProgress)',
    );
  }

  void markHandshakeComplete() {
    _awaitingHandshake = false;
    _healthCheckGraceUntil = DateTime.now().add(const Duration(seconds: 10));
    _logger.fine(
      '🤝 Handshake complete - health checks may proceed after grace',
    );
  }

  void resetHandshakeFlags() {
    _handshakeInProgress = false;
    _awaitingHandshake = false;
    _healthCheckGraceUntil = null;
  }

  void setMessageOperationInProgress(bool inProgress) {
    _messageOperationInProgress = inProgress;
    if (inProgress) {
      _logger.fine('💬 Message operation started - pausing health checks');
    } else {
      _logger.fine('✅ Message operation completed - resuming health checks');
    }
  }

  void triggerImmediateReconnection() {
    if (_isCollisionResolving?.call() ?? false) {
      _logger.fine(
        '⏸️ Suppressing immediate reconnection while collision resolution is in flight',
      );
      return;
    }
    if (_hasActiveClientLink?.call() ?? false) {
      _logger.fine(
        '⏸️ Suppressing immediate reconnection because a client link is active',
      );
      return;
    }
    if (_hasPendingClientConnection?.call() ?? false) {
      _logger.fine(
        '⏸️ Suppressing immediate reconnection because a client dial is pending',
      );
      return;
    }
    _monitorState = ConnectionMonitorState.reconnecting;
    _monitoringInterval = minInterval;
    _scheduleNextCheck();
    _logger.info('Triggering immediate reconnection...');
  }

  void _scheduleNextCheck() {
    _monitoringTimer?.cancel();
    if (!_isMonitoring) return;

    _monitoringTimer = Timer(
      Duration(milliseconds: _monitoringInterval),
      () async {
        if (!_isMonitoring) return;

        switch (_monitorState) {
          case ConnectionMonitorState.healthChecking:
            await _performHealthCheck();
            break;
          case ConnectionMonitorState.reconnecting:
            await _attemptReconnection();
            break;
          case ConnectionMonitorState.idle:
            return;
        }

        final nextInterval = (_monitoringInterval * 12 ~/ 10).clamp(
          minInterval,
          maxInterval,
        );
        _monitoringInterval = nextInterval;

        if (_isMonitoring) {
          _scheduleNextCheck();
        }
      },
    );
  }

  Future<void> _performHealthCheck() async {
    if (_pairingInProgress || _handshakeInProgress) {
      _logger.info(
        '⏸️ Skipping health check - ${_pairingInProgress ? "pairing" : "handshake"} in progress',
      );
      return;
    }

    if (_messageOperationInProgress ||
        !hasBleConnection() ||
        getMessageCharacteristic() == null ||
        getConnectedDevice() == null) {
      _logger.fine(
        '⏸️ Skipping health check - no active connection or message in progress',
      );
      return;
    }

    if (_healthCheckGraceUntil != null &&
        DateTime.now().isBefore(_healthCheckGraceUntil!)) {
      _logger.fine('⏸️ Skipping health check - grace window after connect');
      return;
    }

    if (_awaitingHandshake) {
      _logger.fine('⏸️ Skipping health check - awaiting handshake completion');
      return;
    }

    try {
      final pingData = Uint8List.fromList([0x00]);
      final device = getConnectedDevice()!;
      final characteristic = getMessageCharacteristic()!;

      _logger.fine('💓 Sending health check ping...');

      await _centralManager
          .writeCharacteristic(
            device,
            characteristic,
            value: pingData,
            type: GATTCharacteristicWriteType.withResponse,
          )
          .timeout(const Duration(seconds: 8));

      _logger.info(
        '✅ Health check passed (interval: ${_monitoringInterval}ms)',
      );
    } catch (e) {
      _logger.warning('❌ Health check failed: $e');
      _monitorState = ConnectionMonitorState.reconnecting;
      _monitoringInterval = minInterval;

      try {
        final device = getConnectedDevice();
        if (device != null) {
          await _centralManager.disconnect(device);
        }
      } catch (_) {}

      await clearConnectionState(keepMonitoring: true);
      _isReconnection = true;
      onReconnectionFlagChanged?.call(true);
    }
  }

  Future<void> _attemptReconnection() async {
    if (_isCollisionResolving?.call() ?? false) {
      _logger.fine(
        '⏸️ Skipping reconnection attempt during collision resolution',
      );
      return;
    }

    if (_hasActiveClientLink?.call() ?? false) {
      _logger.fine(
        '⏸️ Skipping reconnection attempt because a client link is already active',
      );
      _reconnectAttempts = 0;
      _monitorState = ConnectionMonitorState.healthChecking;
      _monitoringInterval = healthCheckInterval;
      return;
    }

    if (_hasPendingClientConnection?.call() ?? false) {
      _logger.fine(
        '⏸️ Skipping reconnection attempt because a client dial is pending',
      );
      return;
    }

    if (_reconnectAttempts >= maxReconnectAttempts) {
      _logger.warning(
        '❌ Max reconnection attempts reached ($_reconnectAttempts/$maxReconnectAttempts)',
      );
      stop();
      return;
    }

    if (hasViableRelayConnection()) {
      _logger.info(
        '🔄 Maintaining current connection for relay - not reconnecting',
      );
      _reconnectAttempts = 0;
      _monitorState = ConnectionMonitorState.healthChecking;
      _monitoringInterval = healthCheckInterval;
      return;
    }

    _reconnectAttempts++;
    _logger.info(
      '🔄 Reconnect attempt $_reconnectAttempts/$maxReconnectAttempts',
    );

    try {
      final foundDevice = await scanForSpecificDevice(
        timeout: Duration(seconds: 8),
      );

      if (foundDevice != null) {
        _logger.info('✅ Found device for reconnection');
        _isReconnection = true;
        onReconnectionFlagChanged?.call(true);
        await connectToDevice(foundDevice);

        _reconnectAttempts = 0;
        _monitorState = ConnectionMonitorState.healthChecking;
        _monitoringInterval = minInterval;
        _isReconnection = false;
        onReconnectionFlagChanged?.call(false);
        _logger.info('✅ Reconnection successful');
      } else {
        _logger.warning('⚠️ No device found for reconnection');
      }
    } catch (e) {
      _logger.warning('❌ Reconnection failed: $e');
    }
  }
}
