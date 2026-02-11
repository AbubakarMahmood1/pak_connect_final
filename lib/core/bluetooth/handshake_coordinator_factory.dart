import 'package:pak_connect/domain/interfaces/i_handshake_coordinator_factory.dart';
import 'package:pak_connect/domain/interfaces/i_handshake_coordinator.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';

import 'handshake_coordinator.dart';

/// Core adapter that constructs [HandshakeCoordinator] through the domain contract.
class CoreHandshakeCoordinatorFactory implements IHandshakeCoordinatorFactory {
  const CoreHandshakeCoordinatorFactory();

  @override
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
  }) {
    return HandshakeCoordinator(
      myEphemeralId: myEphemeralId,
      myPublicKey: myPublicKey,
      myDisplayName: myDisplayName,
      sendMessage: sendMessage,
      onHandshakeComplete: onHandshakeComplete,
      phaseTimeout: phaseTimeout,
      onHandshakeStateChanged: onHandshakeStateChanged,
      startAsInitiator: startAsInitiator,
    );
  }
}
