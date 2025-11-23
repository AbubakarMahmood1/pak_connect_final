import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

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

  Timer? _monitoringTimer;
  bool _isMonitoring = false;
  int _monitoringInterval;
  int _reconnectAttempts = 0;
  bool _messageOperationInProgress = false;
  bool _pairingInProgress = false;
  bool _handshakeInProgress = false;
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
  }) : _logger = logger,
       _centralManager = centralManager,
       _monitoringInterval = minInterval;

  bool get isMonitoring => _isMonitoring;
  bool get isActivelyReconnecting =>
      _isMonitoring && _monitorState == ConnectionMonitorState.reconnecting;
  bool get isHealthChecking =>
      _isMonitoring && _monitorState == ConnectionMonitorState.healthChecking;
  bool get isReconnection => _isReconnection;

  void start() {
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
    _reconnectAttempts = 0;
    onMonitoringChanged?.call(false);
    _logger.info('Monitoring stopped');
  }

  void startHealthChecks() {
    if (!hasBleConnection()) {
      _logger.fine('⏸️ Skipping health checks - no client link to monitor');
      return;
    }
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
    }
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

        final nextInterval =
            (_monitoringInterval * 12 ~/ 10).clamp(minInterval, maxInterval)
                as int;
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
          .timeout(Duration(seconds: 3));

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
