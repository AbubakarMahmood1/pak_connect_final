import 'package:logging/logging.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/models/protocol_message.dart';
import '../../core/utils/string_extensions.dart';
import '../../domain/values/id_types.dart';

/// Encapsulates mesh relay handling (ACKs, forwarding, delivery) so
/// BLEMessageHandler can stay as a thin orchestrator.
class MeshRelayHandler {
  MeshRelayHandler({Logger? logger})
    : _logger = logger ?? Logger('MeshRelayHandler');

  final Logger _logger;
  MeshRelayEngine? _relayEngine;
  SpamPreventionManager? _spamPrevention;
  OfflineMessageQueue? _messageQueue;
  String? _currentNodeId;
  bool _forceFloodRouting = true;
  List<String> Function()? _nextHopsProvider;

  Function(String originalMessageId, String content, String originalSender)?
  onRelayMessageReceived;
  Function(MessageId originalMessageId, String content, String originalSender)?
  onRelayMessageReceivedIds;
  Function(RelayDecision decision)? onRelayDecisionMade;
  Function(RelayStatistics stats)? onRelayStatsUpdated;
  Function(ProtocolMessage message)? onSendAckMessage;
  Function(ProtocolMessage relayMessage, String nextHopId)? onSendRelayMessage;

  Future<void> initializeRelaySystem({
    required String currentNodeId,
    required OfflineMessageQueue messageQueue,
    bool forceFloodRouting = true,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    onRelayMessageReceivedIds,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
  }) async {
    _currentNodeId = currentNodeId;
    _messageQueue = messageQueue;
    _forceFloodRouting = forceFloodRouting;

    if (onRelayMessageReceived != null) {
      this.onRelayMessageReceived = onRelayMessageReceived;
    }
    if (onRelayMessageReceivedIds != null) {
      this.onRelayMessageReceivedIds = onRelayMessageReceivedIds;
    }
    if (onRelayDecisionMade != null) {
      this.onRelayDecisionMade = onRelayDecisionMade;
    }
    if (onRelayStatsUpdated != null) {
      this.onRelayStatsUpdated = onRelayStatsUpdated;
    }

    _spamPrevention = SpamPreventionManager();
    await _spamPrevention!.initialize();

    _relayEngine = MeshRelayEngine(
      messageQueue: messageQueue,
      spamPrevention: _spamPrevention!,
      forceFloodMode: _forceFloodRouting,
    );

    await _relayEngine!.initialize(
      currentNodeId: currentNodeId,
      onRelayMessage: _handleRelayToNextHop,
      onDeliverToSelf: _handleRelayDeliveryToSelf,
      onRelayDecision: (decision) {
        onRelayDecisionMade?.call(decision);
        this.onRelayDecisionMade?.call(decision);
      },
      onStatsUpdated: (stats) {
        onRelayStatsUpdated?.call(stats);
        this.onRelayStatsUpdated?.call(stats);
      },
    );

    _logger.info(
      'Mesh relay system initialized for node: ${_preview(currentNodeId, 16)}',
    );
  }

  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
  }

  void setNextHopsProvider(List<String> Function() provider) {
    _nextHopsProvider = provider;
  }

  List<String> getAvailableNextHops() {
    if (_nextHopsProvider != null) {
      try {
        return _nextHopsProvider!.call();
      } catch (e) {
        _logger.fine('Failed to get next hops from provider: $e');
      }
    }
    return [];
  }

  Future<String?> handleIncomingRelay({
    required ProtocolMessage protocolMessage,
    required String? senderPublicKey,
  }) async {
    try {
      if (_relayEngine == null || senderPublicKey == null) {
        _logger.warning(
          '🔀 MESH RELAY: Relay system not initialized or no sender',
        );
        return null;
      }

      final originalMessageId = protocolMessage.meshRelayOriginalMessageId;
      final originalSender = protocolMessage.meshRelayOriginalSender;
      final finalRecipient = protocolMessage.meshRelayFinalRecipient;
      final relayMetadata = protocolMessage.meshRelayMetadata;
      final originalPayload = protocolMessage.meshRelayOriginalPayload;
      final originalMessageType = protocolMessage.meshRelayOriginalMessageType;

      if (originalMessageId == null ||
          originalSender == null ||
          finalRecipient == null ||
          relayMetadata == null ||
          originalPayload == null) {
        _logger.warning('🔀 MESH RELAY: Invalid relay message received');
        return null;
      }

      _logger.info(
        '🔀 MESH RELAY: Processing message ${_preview(originalMessageId, 16)} from ${_preview(senderPublicKey, 8)}',
      );
      if (originalMessageType != null) {
        _logger.info(
          '🔀 MESH RELAY: Original message type: ${originalMessageType.name}',
        );
      }

      final metadata = RelayMetadata.fromJson(relayMetadata);
      final originalContent = originalPayload['content'] as String? ?? '';

      final relayMessage = MeshRelayMessage(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        relayMetadata: metadata,
        relayNodeId: senderPublicKey,
        relayedAt: DateTime.now(),
        originalMessageType: originalMessageType,
      );

      final result = await _relayEngine!.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: senderPublicKey,
        availableNextHops: getAvailableNextHops(),
        messageType: originalMessageType,
      );

      switch (result.type) {
        case RelayProcessingType.deliveredToSelf:
          _logger.info('🔀 MESH RELAY: Message delivered to self');
          await _sendRelayAck(
            originalMessageId: relayMessage.originalMessageId,
            relayMetadata: relayMessage.relayMetadata,
            delivered: true,
          );
          return result.content;
        case RelayProcessingType.relayed:
          _logger.info(
            '🔀 MESH RELAY: Message relayed to ${_preview(result.nextHopNodeId ?? 'unknown', 8)}',
          );
          return null;
        case RelayProcessingType.dropped:
        case RelayProcessingType.blocked:
          _logger.warning(
            '🔀 MESH RELAY: Message ${result.type.name}: ${result.reason}',
          );
          return null;
        case RelayProcessingType.error:
          _logger.severe('🔀 MESH RELAY: Processing error: ${result.reason}');
          return null;
      }
    } catch (e) {
      _logger.severe('🔀 MESH RELAY: Failed to handle relay message: $e');
      return null;
    }
  }

  Future<void> handleRelayAck({
    required String originalMessageId,
    required String relayNode,
    required bool delivered,
    List<String>? ackRoutingPath,
  }) async {
    try {
      if (_currentNodeId == null) {
        _logger.warning('Cannot handle ACK - current node ID not set');
        return;
      }

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final truncatedRelayNode = relayNode.length > 8
          ? relayNode.shortId(8)
          : relayNode;

      _logger.info(
        '🔙 Received relayAck for $truncatedMessageId from $truncatedRelayNode',
      );

      final queuedMessage = _messageQueue?.getMessageById(originalMessageId);

      if (queuedMessage != null) {
        _logger.info('✅ ACK for our originated message - marking as delivered');
        await _messageQueue?.markMessageDelivered(originalMessageId);
        onRelayMessageReceivedIds?.call(
          MessageId(originalMessageId),
          queuedMessage.content,
          queuedMessage.senderPublicKey,
        );
        return;
      }

      if (ackRoutingPath != null && ackRoutingPath.isNotEmpty) {
        final currentIndex = ackRoutingPath.indexOf(_currentNodeId!);

        if (currentIndex > 0) {
          final previousHop = ackRoutingPath[currentIndex - 1];

          final truncatedPrevHop = previousHop.length > 8
              ? previousHop.shortId(8)
              : previousHop;

          _logger.info('⚡ Propagating ACK backward to $truncatedPrevHop');

          final forwardAck = ProtocolMessage.relayAckWithId(
            originalMessageId: MessageId(originalMessageId),
            relayNode: _currentNodeId!,
            delivered: delivered,
          );
          forwardAck.payload['ackRoutingPath'] = ackRoutingPath;

          onSendAckMessage?.call(forwardAck);
          _logger.info('✅ ACK propagated for $truncatedMessageId');
        } else {
          _logger.info('🏁 This is the originator - ACK propagation complete');
        }
      } else {
        _logger.warning(
          '⚠️ No ackRoutingPath in relay ACK - cannot propagate backward',
        );
      }
    } catch (e) {
      _logger.severe('Failed to handle relay ACK: $e');
    }
  }

  Future<void> handleRelayAckWithId({
    required MessageId originalMessageId,
    required String relayNode,
    required bool delivered,
    List<String>? ackRoutingPath,
  }) => handleRelayAck(
    originalMessageId: originalMessageId.value,
    relayNode: relayNode,
    delivered: delivered,
    ackRoutingPath: ackRoutingPath,
  );

  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    try {
      if (_relayEngine == null) {
        _logger.warning('Cannot create relay: relay engine not initialized');
        return null;
      }

      return await _relayEngine!.createOutgoingRelay(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        finalRecipientPublicKey: finalRecipientPublicKey,
        priority: priority,
      );
    } catch (e) {
      _logger.severe('Failed to create outgoing relay: $e');
      return null;
    }
  }

  Future<MeshRelayMessage?> createOutgoingRelayWithId({
    required MessageId originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) => createOutgoingRelay(
    originalMessageId: originalMessageId.value,
    originalContent: originalContent,
    finalRecipientPublicKey: finalRecipientPublicKey,
    priority: priority,
  );

  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async {
    if (_relayEngine == null) return false;

    return await _relayEngine!.shouldAttemptDecryption(
      finalRecipientPublicKey: finalRecipientPublicKey,
      originalSenderPublicKey: originalSenderPublicKey,
    );
  }

  RelayStatistics? getRelayStatistics() {
    return _relayEngine?.getStatistics();
  }

  void dispose() {
    _spamPrevention?.dispose();
  }

  Future<void> _sendRelayAck({
    required String originalMessageId,
    required RelayMetadata relayMetadata,
    required bool delivered,
  }) async {
    try {
      final previousHop = relayMetadata.previousHop;
      if (previousHop == null) {
        _logger.info(
          '🔙 No previous hop for ACK - message was direct delivery',
        );
        return;
      }

      if (_currentNodeId == null) {
        _logger.warning('Cannot send ACK - current node ID not set');
        return;
      }

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final truncatedPrevHop = previousHop.length > 8
          ? previousHop.shortId(8)
          : previousHop;

      _logger.info(
        '🔙 Sending relayAck for $truncatedMessageId to previous hop: $truncatedPrevHop',
      );

      final ackMessage = ProtocolMessage.relayAck(
        originalMessageId: originalMessageId,
        relayNode: _currentNodeId!,
        delivered: delivered,
      );

      ackMessage.payload['ackRoutingPath'] = relayMetadata.ackRoutingPath;

      if (onSendAckMessage != null) {
        onSendAckMessage!(ackMessage);
      } else {
        _logger.warning('⚠️ Cannot send ACK - callback not set');
      }
    } catch (e) {
      _logger.severe('Failed to send relay ACK: $e');
    }
  }

  Future<void> _handleRelayToNextHop(
    MeshRelayMessage message,
    String nextHopNodeId,
  ) async {
    try {
      _logger.info(
        '🔀 RELAY FORWARD: Preparing to send relay message to ${_preview(nextHopNodeId, 8)}',
      );

      final protocolMessage = ProtocolMessage.meshRelay(
        originalMessageId: message.originalMessageId,
        originalSender: message.relayMetadata.originalSender,
        finalRecipient: message.relayMetadata.finalRecipient,
        relayMetadata: message.relayMetadata.toJson(),
        originalPayload: {
          'content': message.originalContent,
          if (message.encryptedPayload != null)
            'encrypted': message.encryptedPayload,
        },
        useEphemeralAddressing: false,
        originalMessageType: message.originalMessageType,
      );

      if (onSendRelayMessage != null) {
        onSendRelayMessage!(protocolMessage, nextHopNodeId);
        _logger.info(
          '✅ Relay message forwarded to ${_preview(nextHopNodeId, 8)}',
        );
      } else {
        _logger.warning(
          '⚠️ Cannot forward relay: onSendRelayMessage callback not set',
        );
      }
    } catch (e) {
      _logger.severe('Failed to handle relay to next hop: $e');
    }
  }

  void _handleRelayDeliveryToSelf(
    String originalMessageId,
    String content,
    String originalSender,
  ) {
    try {
      _logger.info(
        '🔀 RELAY DELIVERY: Message delivered to self from ${_preview(originalSender, 8)}',
      );

      final id = MessageId(originalMessageId);
      onRelayMessageReceived?.call(originalMessageId, content, originalSender);
      onRelayMessageReceivedIds?.call(id, content, originalSender);
    } catch (e) {
      _logger.severe('Failed to handle relay delivery to self: $e');
    }
  }

  String _preview(String value, int maxLength) =>
      value.length <= maxLength ? value : '${value.substring(0, maxLength)}...';
}
