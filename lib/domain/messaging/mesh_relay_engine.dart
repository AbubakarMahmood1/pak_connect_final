import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/models/protocol_message_type.dart';

export 'package:pak_connect/domain/models/mesh_relay_models.dart'
    show
        RelayDecision,
        RelayDecisionType,
        RelayProcessingResult,
        RelayProcessingType,
        RelayStatistics;

/// Domain-facing contract for mesh relay engines.
abstract interface class MeshRelayEngine {
  Future<void> initialize({
    required String currentNodeId,
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)?
    onDeliverToSelf,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  });

  Future<RelayProcessingResult> processIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    List<String> availableNextHops = const [],
    ProtocolMessageType? messageType,
  });

  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? encryptedPayload,
    ProtocolMessageType? originalMessageType,
  });

  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  });

  RelayStatistics getStatistics();
}
