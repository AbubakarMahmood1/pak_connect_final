import 'dart:async';

import 'package:pak_connect/domain/models/connection_phase.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';

/// Domain contract for BLE handshake orchestration state machine.
abstract class IHandshakeCoordinator {
  Stream<ConnectionPhase> get phaseStream;
  ConnectionPhase get currentPhase;
  bool get isComplete;

  Future<void> startHandshake();
  Future<void> handleReceivedMessage(ProtocolMessage message);
  void dispose();
}
