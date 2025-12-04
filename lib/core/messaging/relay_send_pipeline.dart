import 'package:logging/logging.dart';
import '../messaging/offline_message_queue.dart';
import '../models/mesh_relay_models.dart';
import '../security/spam_prevention_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../domain/values/id_types.dart';

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

  Future<bool> relayToNextHop({
    required MeshRelayMessage relayMessage,
    required String nextHopNodeId,
    Function(MeshRelayMessage, String)? onRelayMessage,
    Function(MessageId, MeshRelayMessage, String)? onRelayMessageIds,
  }) async {
    try {
      MeshRelayMessage nextHopMessage;
      try {
        nextHopMessage = relayMessage.nextHop(nextHopNodeId);
      } catch (e) {
        _logger.info(
          '🚫 Relay drop to $nextHopNodeId (TTL/path exhausted): $e',
        );
        return false;
      }
      final persistToStorage = relayMessage.relayMetadata.isOriginator;

      await _spamPrevention.recordRelayOperation(
        fromNodeId: relayMessage.relayNodeId,
        toNodeId: nextHopNodeId,
        messageHash: relayMessage.relayMetadata.messageHash,
        messageSize: relayMessage.messageSize,
      );

      await _messageQueue.queueMessageWithIds(
        chatId: ChatId('mesh_relay_$nextHopNodeId'),
        content: nextHopMessage.originalContent,
        recipientId: ChatId(nextHopNodeId),
        senderId: ChatId(nextHopMessage.relayMetadata.originalSender),
        priority: nextHopMessage.relayMetadata.priority,
        isRelayMessage: true,
        relayMetadata: nextHopMessage.relayMetadata,
        originalMessageId: nextHopMessage.originalMessageId,
        relayNodeId: relayMessage.relayNodeId,
        messageHash: nextHopMessage.relayMetadata.messageHash,
        persistToStorage: persistToStorage,
      );

      onRelayMessage?.call(nextHopMessage, nextHopNodeId);
      if (onRelayMessageIds != null) {
        onRelayMessageIds!(
          nextHopMessage.originalMessageIdValue,
          nextHopMessage,
          nextHopNodeId,
        );
      }

      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.shortId()
          : relayMessage.originalMessageId;
      final truncatedNextHop = nextHopNodeId.length > 8
          ? nextHopNodeId.shortId(8)
          : nextHopNodeId;
      _logger.info(
        'Relayed message $truncatedMessageId... to $truncatedNextHop...',
      );
      return true;
    } catch (e) {
      _logger.severe('Failed to relay to next hop: $e');
      throw RelayException('Failed to relay message: $e');
    }
  }

  Future<int> broadcastToNeighbors({
    required MeshRelayMessage relayMessage,
    required List<String> availableNeighbors,
    Function(MeshRelayMessage, String)? onRelayMessage,
    Function(MessageId, MeshRelayMessage, String)? onRelayMessageIds,
  }) async {
    try {
      final persistToStorage = relayMessage.relayMetadata.isOriginator;
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
        return 0;
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
          MeshRelayMessage nextHopMessage;
          try {
            nextHopMessage = relayMessage.nextHop(neighborId);
          } catch (e) {
            failCount++;
            final truncatedNeighbor = neighborId.length > 8
                ? neighborId.shortId(8)
                : neighborId;
            _logger.info(
              '  🚫 Skip neighbor $truncatedNeighbor... (TTL/path exhausted): $e',
            );
            continue;
          }

          await _spamPrevention.recordRelayOperation(
            fromNodeId: relayMessage.relayNodeId,
            toNodeId: neighborId,
            messageHash: relayMessage.relayMetadata.messageHash,
            messageSize: relayMessage.messageSize,
          );

          await _messageQueue.queueMessageWithIds(
            chatId: ChatId('broadcast_relay_$neighborId'),
            content: nextHopMessage.originalContent,
            recipientId: ChatId(neighborId),
            senderId: ChatId(nextHopMessage.relayMetadata.originalSender),
            priority: nextHopMessage.relayMetadata.priority,
            isRelayMessage: true,
            relayMetadata: nextHopMessage.relayMetadata,
            originalMessageId: nextHopMessage.originalMessageId,
            relayNodeId: relayMessage.relayNodeId,
            messageHash: nextHopMessage.relayMetadata.messageHash,
            persistToStorage: persistToStorage,
          );

          onRelayMessage?.call(nextHopMessage, neighborId);
          if (onRelayMessageIds != null) {
            onRelayMessageIds!(
              nextHopMessage.originalMessageIdValue,
              nextHopMessage,
              neighborId,
            );
          }
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
      return successCount;
    } catch (e) {
      _logger.severe('Failed to broadcast to neighbors: $e');
      throw RelayException('Failed to broadcast message: $e');
    }
  }
}
