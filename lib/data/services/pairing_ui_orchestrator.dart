import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/models/protocol_message.dart';

/// Small helper to keep UI-oriented pairing orchestration out of the flow controller.
class PairingUiOrchestrator {
  PairingUiOrchestrator({Logger? logger})
    : _logger = logger ?? Logger('PairingUiOrchestrator');

  final Logger _logger;
  Timer? _cleanupTimer;

  void triggerPairingPopup(
    String ephemeralId,
    String displayName,
    void Function(String ephemeralId, String displayName)?
    onPairingRequestReceived,
  ) {
    _logger.info('🔔 Triggering pairing request popup for user');
    onPairingRequestReceived?.call(ephemeralId, displayName);
  }

  void scheduleStateClear(Duration delay, void Function() clearState) {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(delay, clearState);
  }

  void sendCancel(
    String? reason,
    void Function(ProtocolMessage message)? onSendPairingCancel,
  ) {
    final message = ProtocolMessage.pairingCancel(
      reason: reason ?? 'User cancelled',
    );
    onSendPairingCancel?.call(message);
  }

  void dispose() {
    _cleanupTimer?.cancel();
  }
}
