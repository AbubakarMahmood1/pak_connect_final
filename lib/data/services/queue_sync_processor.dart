import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/models/protocol_message.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../domain/values/id_types.dart';

/// Handles queue synchronization messages and callbacks so BLEMessageHandler
/// can delegate the protocol-specific work.
class QueueSyncProcessor {
  QueueSyncProcessor({Logger? logger})
    : _logger = logger ?? Logger('QueueSyncProcessor');

  final Logger _logger;

  Function(QueueSyncMessage syncMessage, String fromNodeId)?
  onQueueSyncReceived;
  Function(QueueSyncMessage syncMessage, ChatId fromNodeId)?
  onQueueSyncReceivedIds;
  Function(List<QueuedMessage> messages, String toNodeId)? onSendQueueMessages;
  Function(String nodeId, QueueSyncResult result)? onQueueSyncCompleted;

  /// Process a queue sync protocol message coming from BLE.
  Future<String?> handleProtocolQueueSync({
    required ProtocolMessage protocolMessage,
    required String? senderPublicKey,
  }) async {
    try {
      final queueSyncMessage = protocolMessage.queueSyncMessage;

      if (queueSyncMessage == null || senderPublicKey == null) {
        _logger.warning('🔄 QUEUE SYNC: Invalid sync message received');
        return null;
      }

      final messageIds = queueSyncMessage.messageIdValues;
      final messageHashes = queueSyncMessage.messageHashValues?.map(
        (key, value) => MapEntry(key.value, value),
      );

      final syncMessage = QueueSyncMessage(
        queueHash: queueSyncMessage.queueHash,
        messageIds: messageIds.map((id) => id.value).toList(),
        syncTimestamp: queueSyncMessage.syncTimestamp,
        nodeId: senderPublicKey,
        syncType: queueSyncMessage.syncType,
        messageHashes: messageHashes,
        queueStats: queueSyncMessage.queueStats,
        gcsFilter: queueSyncMessage.gcsFilter,
      );

      _logger.info(
        '🔄 QUEUE SYNC: Received ${syncMessage.syncType.name} from ${_preview(senderPublicKey)}',
      );

      onQueueSyncReceived?.call(syncMessage, senderPublicKey);
      if (onQueueSyncReceivedIds != null) {
        onQueueSyncReceivedIds!(syncMessage, ChatId(senderPublicKey));
      }
    } catch (e) {
      _logger.severe('🔄 QUEUE SYNC: Failed to handle sync message: $e');
    }
    return null;
  }

  /// Callback target for [ProtocolMessageDispatcher] queue sync events.
  void handleDispatchedQueueSync({
    required QueueSyncMessage syncMessage,
    required String fromNodeId,
  }) {
    onQueueSyncReceived?.call(syncMessage, fromNodeId);
    if (onQueueSyncReceivedIds != null) {
      onQueueSyncReceivedIds!(syncMessage, ChatId(fromNodeId));
    }
    _logger.info(
      '🔄 QUEUE SYNC: Dispatch handler triggered from ${_preview(fromNodeId)}',
    );
  }

  /// Send queue synchronization message through either central or peripheral role.
  Future<bool> sendQueueSyncMessage({
    required CentralManager? centralManager,
    required PeripheralManager? peripheralManager,
    required Peripheral? connectedDevice,
    required Central? connectedCentral,
    required GATTCharacteristic messageCharacteristic,
    required QueueSyncMessage syncMessage,
    required int mtuSize,
  }) async {
    try {
      final protocolMessage = ProtocolMessage.queueSync(
        queueMessage: syncMessage,
      );

      final jsonBytes = protocolMessage.toBytes();
      final chunks = MessageFragmenter.fragmentBytes(
        jsonBytes,
        mtuSize,
        'queue_sync_${DateTime.now().millisecondsSinceEpoch}',
      );

      _logger.info(
        '🔄 QUEUE SYNC: Sending sync message with ${syncMessage.messageIds.length} message IDs',
      );

      if (centralManager != null && connectedDevice != null) {
        for (final chunk in chunks) {
          await centralManager.writeCharacteristic(
            connectedDevice,
            messageCharacteristic,
            value: chunk.toBytes(),
            type: GATTCharacteristicWriteType.withResponse,
          );
          await Future.delayed(Duration(milliseconds: 50));
        }
      } else if (peripheralManager != null && connectedCentral != null) {
        for (final chunk in chunks) {
          await peripheralManager.notifyCharacteristic(
            connectedCentral,
            messageCharacteristic,
            value: chunk.toBytes(),
          );
          await Future.delayed(Duration(milliseconds: 50));
        }
      }

      return true;
    } catch (e) {
      _logger.severe('🔄 QUEUE SYNC: Failed to send sync message: $e');
      return false;
    }
  }

  void dispose() {}

  String _preview(String value) =>
      value.length <= 16 ? value : '${value.substring(0, 16)}...';
}
