import 'dart:async';
import 'package:logging/logging.dart';

/// Manages phase timeouts for the handshake flow.
class HandshakeTimeoutManager {
  HandshakeTimeoutManager(
    this._logger, {
    this.phaseTimeout = const Duration(seconds: 10),
  });

  final Logger _logger;
  Duration phaseTimeout;
  Timer? _timeoutTimer;

  /// Start the timeout for the current phase.
  ///
  /// [isComplete] allows callers to guard against late timers after success.
  void startTimeout({
    required String waitingFor,
    required bool Function() isComplete,
    required Future<void> Function(String reason) onTimeout,
  }) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(phaseTimeout, () async {
      if (isComplete()) {
        _logger.info(
          '⏱️ Timer fired but handshake already complete - ignoring',
        );
        return;
      }
      _logger.warning('⏱️ Phase timeout waiting for: $waitingFor');
      await onTimeout('Timeout waiting for $waitingFor');
    });
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void dispose() {
    cancelTimeout();
  }
}
