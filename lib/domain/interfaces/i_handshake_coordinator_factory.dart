import 'dart:async';

import 'package:pak_connect/domain/interfaces/i_handshake_coordinator.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';

/// Factory contract for creating handshake coordinator instances.
abstract class IHandshakeCoordinatorFactory {
  IHandshakeCoordinator create({
    required String myEphemeralId,
    required String myPublicKey,
    required String myDisplayName,
    required Future<void> Function(ProtocolMessage) sendMessage,
    required Future<void> Function(
      String ephemeralId,
      String displayName,
      String? noisePublicKey,
    )
    onHandshakeComplete,
    Duration? phaseTimeout,
    Function(bool inProgress)? onHandshakeStateChanged,
    bool startAsInitiator = true,
  });
}
