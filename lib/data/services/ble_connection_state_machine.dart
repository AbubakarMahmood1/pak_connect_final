import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

import '../../domain/models/connection_state.dart';

class BleConnectionStateMachine {
  BleConnectionStateMachine({
    required Logger logger,
    required Peripheral? Function() connectedDeviceProvider,
    required void Function(ConnectionInfo info) onStateChanged,
  }) : _logger = logger,
       _connectedDeviceProvider = connectedDeviceProvider,
       _onStateChanged = onStateChanged;

  final Logger _logger;
  final Peripheral? Function() _connectedDeviceProvider;
  final void Function(ConnectionInfo info) _onStateChanged;

  ChatConnectionState _state = ChatConnectionState.disconnected;

  ChatConnectionState get state => _state;
  bool get isReady => _state == ChatConnectionState.ready;

  void update(ChatConnectionState newState, {String? error}) {
    if (_state == newState) {
      return;
    }

    _state = newState;
    final info = ConnectionInfo(
      state: newState,
      deviceId: _connectedDeviceProvider()?.uuid.toString(),
      displayName: null,
      error: error,
    );

    _onStateChanged(info);
    _logger.info('Connection state: ${newState.name}');
  }
}
