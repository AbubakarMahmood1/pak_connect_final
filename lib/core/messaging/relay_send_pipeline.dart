import 'package:logging/logging.dart';
import '../messaging/offline_message_queue.dart';
import '../models/mesh_relay_models.dart';
import '../security/spam_prevention_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Handles relay send pipeline (broadcast + next-hop delivery) independent of decision logic.
class RelaySendPipeline {
  final Logger _logger;
  final OfflineMessageQueue _messageQueue;
  final SpamPreventionManager _spamPrevention;

  RelaySendPipeline({
    required Logger logger,
    required OfflineMessageQueue messageQueue,
    required SpamPreventionManager spamPrevention,
  }) : _logger = logger,
       _messageQueue = messageQueue,
       _spamPrevention = spamPrevention;

  Future<void> relayToNextHop({
    required MeshRelayMessage relayMessage,
    required String nextHopNodeId,
    Function(MeshRelayMessage, String)? onRelayMessage,
  }) async {
    try {
      final nextHopMessage = relayMessage.nextHop(nextHopNodeId);

      await _spamPrevention.recordRelayOperation(
        fromNodeId: relayMessage.relayNodeId,
        toNodeId: nextHopNodeId,
        messageHash: relayMessage.relayMetadata.messageHash,
        messageSize: relayMessage.messageSize,
      );

      await _messageQueue.queueMessage(
        chatId: 'mesh_relay_$nextHopNodeId',
        content: nextHopMessage.originalContent,
        recipientPublicKey: nextHopNodeId,
        senderPublicKey: nextHopMessage.relayMetadata.originalSender,
        priority: nextHopMessage.relayMetadata.priority,
      );

      onRelayMessage?.call(nextHopMessage, nextHopNodeId);

      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.shortId()
          : relayMessage.originalMessageId;
      final truncatedNextHop = nextHopNodeId.length > 8
          ? nextHopNodeId.shortId(8)
          : nextHopNodeId;
      _logger.info(
        'Relayed message $truncatedMessageId... to $truncatedNextHop...',
      );
    } catch (e) {
      _logger.severe('Failed to relay to next hop: $e');
      throw RelayException('Failed to relay message: $e');
    }
  }

  Future<void> broadcastToNeighbors({
    required MeshRelayMessage relayMessage,
    required List<String> availableNeighbors,
    Function(MeshRelayMessage, String)? onRelayMessage,
  }) async {
    try {
      final validNeighbors = availableNeighbors
          .where(
            (neighborId) =>
                !relayMessage.relayMetadata.hasNodeInPath(neighborId),
          )
          .toList();

      if (validNeighbors.isEmpty) {
        _logger.info(
          '📣 No valid neighbors for broadcast (all in routing path or none available)',
        );
        return;
      }

      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.shortId()
          : relayMessage.originalMessageId;
      _logger.info(
        '📣 Broadcasting message $truncatedMessageId... to ${validNeighbors.length} neighbor(s)',
      );

      int successCount = 0;
      int failCount = 0;

      for (final neighborId in validNeighbors) {
        try {
          final nextHopMessage = relayMessage.nextHop(neighborId);

          await _spamPrevention.recordRelayOperation(
            fromNodeId: relayMessage.relayNodeId,
            toNodeId: neighborId,
            messageHash: relayMessage.relayMetadata.messageHash,
            messageSize: relayMessage.messageSize,
          );

          await _messageQueue.queueMessage(
            chatId: 'broadcast_relay_$neighborId',
            content: nextHopMessage.originalContent,
            recipientPublicKey: neighborId,
            senderPublicKey: nextHopMessage.relayMetadata.originalSender,
            priority: nextHopMessage.relayMetadata.priority,
          );

          onRelayMessage?.call(nextHopMessage, neighborId);
          successCount++;

          final truncatedNeighbor = neighborId.length > 8
              ? neighborId.shortId(8)
              : neighborId;
          _logger.fine(
            '  ✅ Broadcast queued for neighbor $truncatedNeighbor...',
          );
        } catch (e) {
          failCount++;
          final truncatedNeighbor = neighborId.length > 8
              ? neighborId.shortId(8)
              : neighborId;
          _logger.warning(
            '  ⚠️ Failed to broadcast to neighbor $truncatedNeighbor...: $e',
          );
        }
      }

      _logger.info(
        '📣 Broadcast complete: $successCount success, $failCount failed (total: ${validNeighbors.length})',
      );
    } catch (e) {
      _logger.severe('Failed to broadcast to neighbors: $e');
      throw RelayException('Failed to broadcast message: $e');
    }
  }
}
