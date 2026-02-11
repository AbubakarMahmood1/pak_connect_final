import 'package:logging/logging.dart';

import '../../domain/models/mesh_relay_models.dart';
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import '../../domain/values/id_types.dart';

/// Routes protocol messages to the appropriate handlers to keep
/// BLEMessageHandler lean (parsing/dispatch separate from fragmentation).
class ProtocolMessageDispatcher {
  ProtocolMessageDispatcher({
    required MessageAckTracker ackTracker,
    required Future<String?> Function(
      ProtocolMessage protocolMessage,
      String? Function(String)? onMessageIdFound,
      String? senderPublicKey,
    )
    onUnhandledMessage,
    Future<void> Function(String messageId)? onAckReceived,
    Future<void> Function({
      required String originalMessageId,
      required String relayNode,
      required bool delivered,
      List<String>? ackRoutingPath,
    })?
    onRelayAck,
    Future<void> Function({
      required MessageId originalMessageId,
      required String relayNode,
      required bool delivered,
      List<String>? ackRoutingPath,
    })?
    onRelayAckIds,
    void Function(QueueSyncMessage syncMessage, String fromNodeId)?
    onQueueSyncReceived,
    Logger? logger,
  }) : _ackTracker = ackTracker,
       _onUnhandledMessage = onUnhandledMessage,
       _onAckReceived = onAckReceived,
       _onRelayAck = onRelayAck,
       _onRelayAckIds = onRelayAckIds,
       _onQueueSyncReceived = onQueueSyncReceived,
       _logger = logger ?? Logger('ProtocolMessageDispatcher');

  final Logger _logger;
  final MessageAckTracker _ackTracker;
  final Future<void> Function(String messageId)? _onAckReceived;
  final Future<String?> Function(
    ProtocolMessage protocolMessage,
    String? Function(String)? onMessageIdFound,
    String? senderPublicKey,
  )
  _onUnhandledMessage;
  final Future<void> Function({
    required String originalMessageId,
    required String relayNode,
    required bool delivered,
    List<String>? ackRoutingPath,
  })?
  _onRelayAck;
  final Future<void> Function({
    required MessageId originalMessageId,
    required String relayNode,
    required bool delivered,
    List<String>? ackRoutingPath,
  })?
  _onRelayAckIds;
  final void Function(QueueSyncMessage syncMessage, String fromNodeId)?
  _onQueueSyncReceived;

  Future<String?> dispatch(
    ProtocolMessage protocolMessage, {
    String? Function(String)? onMessageIdFound,
    String? senderPublicKey,
  }) async {
    switch (protocolMessage.type) {
      case ProtocolMessageType.ack:
        final originalId =
            protocolMessage.payload['originalMessageId'] as String? ??
            protocolMessage.ackOriginalId;

        if (originalId == null) {
          _logger.warning('Received ACK with no originalMessageId');
          return null;
        }

        final messageId = MessageId(originalId);
        final completed = _ackTracker.complete(messageId.value);
        if (completed) {
          _logger.info('Received protocol ACK for: ${messageId.value}');
          if (_onAckReceived != null) {
            await _onAckReceived(messageId.value);
          }
        } else {
          _logger.fine('Protocol ACK for unknown message: ${messageId.value}');
        }
        return null;

      case ProtocolMessageType.ping:
        _logger.info('Received protocol ping');
        return null;

      case ProtocolMessageType.relayAck:
        final originalMessageId = protocolMessage.relayAckOriginalMessageId;
        final relayNode = protocolMessage.relayAckRelayNode ?? 'unknown';
        final delivered = protocolMessage.relayAckDelivered;
        final ackRoutingPath =
            protocolMessage.payload['ackRoutingPath'] as List<dynamic>?;

        if (originalMessageId == null) {
          _logger.warning('Received relayAck with no message ID');
          return null;
        }

        final messageId = MessageId(originalMessageId);

        if (_onRelayAckIds != null) {
          await _onRelayAckIds(
            originalMessageId: messageId,
            relayNode: relayNode,
            delivered: delivered,
            ackRoutingPath: ackRoutingPath?.cast<String>(),
          );
        } else if (_onRelayAck != null) {
          await _onRelayAck(
            originalMessageId: messageId.value,
            relayNode: relayNode,
            delivered: delivered,
            ackRoutingPath: ackRoutingPath?.cast<String>(),
          );
        }
        return null;

      case ProtocolMessageType.queueSync:
        final queueSyncMessage = protocolMessage.queueSyncMessage;

        if (queueSyncMessage != null &&
            senderPublicKey != null &&
            _onQueueSyncReceived != null) {
          _onQueueSyncReceived(queueSyncMessage, senderPublicKey);

          final truncated = senderPublicKey.length > 16
              ? senderPublicKey.substring(0, 16)
              : senderPublicKey;
          _logger.info('Received queue sync message from $truncated...');
        } else {
          _logger.warning('Received invalid queue sync message');
        }
        return null;

      default:
        return _onUnhandledMessage(
          protocolMessage,
          onMessageIdFound,
          senderPublicKey,
        );
    }
  }
}
