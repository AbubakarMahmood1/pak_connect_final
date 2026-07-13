import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart'
    as domain_messaging;
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import '../../domain/values/id_types.dart';

/// Encapsulates mesh relay handling (ACKs, forwarding, delivery) so
/// BLEMessageHandler can stay as a thin orchestrator.
class MeshRelayHandler {
  static IMeshRelayEngineFactory Function()? _relayEngineFactoryResolver;

  static void configureRelayEngineFactoryResolver(
    IMeshRelayEngineFactory Function() resolver,
  ) {
    _relayEngineFactoryResolver = resolver;
  }

  static void clearRelayEngineFactoryResolver() {
    _relayEngineFactoryResolver = null;
  }

  MeshRelayHandler({
    Logger? logger,
    IMeshRelayEngineFactory? relayEngineFactory,
  }) : _logger = logger ?? Logger('MeshRelayHandler'),
       _relayEngineFactory = relayEngineFactory;

  final Logger _logger;
  final IMeshRelayEngineFactory? _relayEngineFactory;
  domain_messaging.MeshRelayEngine? _relayEngine;
  SpamPreventionManager? _spamPrevention;
  OfflineMessageQueueContract? _messageQueue;
  String? _currentNodeId;
  bool _forceFloodRouting = false;
  List<String> Function()? _nextHopsProvider;

  Function(String originalMessageId, String content, String originalSender)?
  onRelayMessageReceived;
  Function(MessageId originalMessageId, String content, String originalSender)?
  onRelayMessageReceivedIds;
  FutureOr<void> Function(
    String originalMessageId,
    String content,
    String originalSender,
  )?
  onProcessRelayDelivery;
  Function(RelayDecision decision)? onRelayDecisionMade;
  Function(RelayStatistics stats)? onRelayStatsUpdated;
  FutureOr<void> Function(ProtocolMessage message)? onSendAckMessage;
  Function(ProtocolMessage relayMessage, String nextHopId)? onSendRelayMessage;

  Future<void> initializeRelaySystem({
    required String currentNodeId,
    required OfflineMessageQueueContract messageQueue,
    bool forceFloodRouting = false,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    onRelayMessageReceivedIds,
    FutureOr<void> Function(
      String originalMessageId,
      String content,
      String originalSender,
    )?
    onProcessRelayDelivery,
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
    this.onProcessRelayDelivery = onProcessRelayDelivery;
    if (onRelayDecisionMade != null) {
      this.onRelayDecisionMade = onRelayDecisionMade;
    }
    if (onRelayStatsUpdated != null) {
      this.onRelayStatsUpdated = onRelayStatsUpdated;
    }

    _spamPrevention = SpamPreventionManager();
    await _spamPrevention!.initialize();

    final factory = _resolveRelayEngineFactory();
    _relayEngine = factory.create(
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
      final innerProtocolMessage =
          originalPayload['innerProtocolMessage'] as String?;
      if (innerProtocolMessage == null || innerProtocolMessage.isEmpty) {
        _logger.warning(
          '🔀 MESH RELAY: Unsupported legacy plaintext relay payload dropped',
        );
        return null;
      }

      final relayMessage = MeshRelayMessage(
        originalMessageId: originalMessageId,
        originalContent: '',
        relayMetadata: metadata,
        relayNodeId: senderPublicKey,
        relayedAt: DateTime.now(),
        encryptedPayload: innerProtocolMessage,
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
          if (result.isDuplicate &&
              relayMessage.relayMetadata.finalRecipient == _currentNodeId) {
            _logger.info(
              '🔀 MESH RELAY: Re-sending relayAck for duplicate final delivery',
            );
            await _sendRelayAck(
              originalMessageId: relayMessage.originalMessageId,
              relayMetadata: relayMessage.relayMetadata,
              delivered: true,
            );
            return null;
          }
          _logger.warning(
            '🔀 MESH RELAY: Message ${result.type.name}: ${result.reason}',
          );
          return null;
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
    required String transportSender,
    required bool delivered,
    List<String>? ackRoutingPath,
  }) async {
    try {
      if (_currentNodeId == null) {
        _logger.warning('Cannot handle ACK - current node ID not set');
        return;
      }
      if (transportSender.isEmpty || relayNode != transportSender) {
        _logger.warning(
          'Dropping relay ACK with unbound route claim: claimed=$relayNode, '
          'transport=$transportSender',
        );
        return;
      }

      if (ackRoutingPath != null && ackRoutingPath.isNotEmpty) {
        final currentIndex = ackRoutingPath.indexOf(_currentNodeId!);
        final senderIndex = currentIndex + 1;
        if (currentIndex < 0 ||
            senderIndex >= ackRoutingPath.length ||
            ackRoutingPath[senderIndex] != transportSender) {
          _logger.warning(
            'Dropping relay ACK whose transport sender is not the next hop '
            'in the authenticated route',
          );
          return;
        }
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

      final queue = _messageQueue;
      final originatedMessage = queue?.getMessageById(originalMessageId);
      final isOriginatedMessage =
          originatedMessage != null && !originatedMessage.isRelayMessage;

      // Relay queue rows use a local wrapper ID while wire ACKs carry the
      // original message ID. Bind the ACK to the wrapper for the authenticated
      // immediate sender; sibling fan-out routes must remain independent.
      final allRelayRows = <String, QueuedMessage>{};
      final matchingRelayRows = <String, QueuedMessage>{};
      if (queue != null) {
        if ((originatedMessage?.isRelayMessage ?? false) &&
            originatedMessage!.originalMessageId == originalMessageId) {
          allRelayRows[originatedMessage.id] = originatedMessage;
        }
        for (final status in QueuedMessageStatus.values) {
          for (final message in queue.getMessagesByStatus(status)) {
            if (message.isRelayMessage &&
                message.originalMessageId == originalMessageId) {
              allRelayRows[message.id] = message;
            }
          }
        }
        for (final relayRow in allRelayRows.values) {
          if (relayRow.recipientPublicKey == transportSender) {
            matchingRelayRows[relayRow.id] = relayRow;
          }
        }
      }

      if (matchingRelayRows.isEmpty) {
        _logger.warning(
          'Dropping uncorrelated relay ACK for $truncatedMessageId',
        );
        return;
      }

      // An intermediate hop must durably hand the ACK upstream before
      // completing its local wrapper. If that control write fails, retaining
      // the awaiting-ACK row lets a duplicate downstream ACK retry propagation.
      if (!isOriginatedMessage) {
        if (ackRoutingPath == null || ackRoutingPath.isEmpty) {
          _logger.warning(
            '⚠️ No ackRoutingPath in relay ACK - cannot propagate backward',
          );
          return;
        }
        final currentIndex = ackRoutingPath.indexOf(_currentNodeId!);
        if (currentIndex <= 0) {
          _logger.warning(
            'Dropping relay ACK with no upstream hop in its route',
          );
          return;
        }

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

        final callback = onSendAckMessage;
        if (callback == null) {
          throw StateError('Cannot propagate relay ACK - callback not set');
        }
        await callback(forwardAck);
        _logger.info('✅ ACK propagated for $truncatedMessageId');
      }

      for (final relayRow in matchingRelayRows.values) {
        if (delivered) {
          await queue!.markMessageDelivered(relayRow.id);
        } else {
          await queue!.markMessageFailed(
            relayRow.id,
            'Relay delivery was rejected downstream',
          );
        }
      }

      if (isOriginatedMessage && delivered) {
        _logger.info('✅ Positive relay ACK completed our originated message');
        await queue!.markMessageDelivered(originatedMessage.id);
        onRelayMessageReceivedIds?.call(
          MessageId(originalMessageId),
          originatedMessage.content,
          originatedMessage.senderPublicKey,
        );
      } else if (isOriginatedMessage) {
        // A single rejected fan-out route cannot fail the origin while a
        // sibling route may still deliver it. Only an explicitly terminal
        // aggregate failure may transition the origin.
        final allRoutesTerminal = allRelayRows.values.every(
          (message) => message.status == QueuedMessageStatus.failed,
        );
        if (allRoutesTerminal) {
          await queue!.markMessageFailed(
            originatedMessage.id,
            'All relay delivery routes were rejected downstream',
          );
        }
      }
    } catch (e, stack) {
      _logger.severe('Failed to handle relay ACK: $e');
      Error.throwWithStackTrace(e, stack);
    }
  }

  Future<void> handleRelayAckWithId({
    required MessageId originalMessageId,
    required String relayNode,
    required String transportSender,
    required bool delivered,
    List<String>? ackRoutingPath,
  }) => handleRelayAck(
    originalMessageId: originalMessageId.value,
    relayNode: relayNode,
    transportSender: transportSender,
    delivered: delivered,
    ackRoutingPath: ackRoutingPath,
  );

  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? relayPayload,
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
        encryptedPayload: relayPayload,
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
    String? relayPayload,
  }) => createOutgoingRelay(
    originalMessageId: originalMessageId.value,
    originalContent: originalContent,
    finalRecipientPublicKey: finalRecipientPublicKey,
    priority: priority,
    relayPayload: relayPayload,
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

      final callback = onSendAckMessage;
      if (callback != null) {
        await callback(ackMessage);
      } else {
        _logger.warning('⚠️ Cannot send ACK - callback not set');
      }
    } catch (e, stack) {
      _logger.severe('Failed to send relay ACK: $e');
      Error.throwWithStackTrace(e, stack);
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
          if (message.relayPayload != null)
            'innerProtocolMessage': message.relayPayload,
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

  Future<void> _handleRelayDeliveryToSelf(
    String originalMessageId,
    String content,
    String originalSender,
  ) async {
    try {
      _logger.info(
        '🔀 RELAY DELIVERY: Message delivered to self from ${_preview(originalSender, 8)}',
      );

      final processor = onProcessRelayDelivery;
      if (processor != null) {
        await processor(originalMessageId, content, originalSender);
      }

      final id = MessageId(originalMessageId);
      try {
        onRelayMessageReceived?.call(
          originalMessageId,
          content,
          originalSender,
        );
      } catch (e, stack) {
        _logger.warning(
          'Relay delivery observer failed after successful processing: $e',
          e,
          stack,
        );
      }
      try {
        onRelayMessageReceivedIds?.call(id, content, originalSender);
      } catch (e, stack) {
        _logger.warning(
          'Typed relay delivery observer failed after successful processing: $e',
          e,
          stack,
        );
      }
    } catch (e) {
      _logger.severe('Failed to handle relay delivery to self: $e');
      rethrow;
    }
  }

  String _preview(String value, int maxLength) =>
      value.length <= maxLength ? value : '${value.substring(0, maxLength)}...';

  IMeshRelayEngineFactory _resolveRelayEngineFactory() {
    if (_relayEngineFactory != null) {
      return _relayEngineFactory;
    }
    final resolver = _relayEngineFactoryResolver;
    if (resolver != null) {
      return resolver();
    }
    throw StateError(
      'IMeshRelayEngineFactory is not registered. '
      'Configure MeshRelayHandler.configureRelayEngineFactoryResolver(...), '
      'or pass relayEngineFactory explicitly.',
    );
  }
}
