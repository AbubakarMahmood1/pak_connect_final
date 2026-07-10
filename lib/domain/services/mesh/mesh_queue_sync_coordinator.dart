import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:pak_connect/domain/utils/mesh_debug_logger.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';

import 'mesh_network_health_monitor.dart';

typedef QueueSyncManagerFactory =
    QueueSyncManagerContract Function(
      OfflineMessageQueueContract queue,
      String nodeId,
    );

/// Coordinates queue + sync responsibilities for MeshNetworkingService.
class MeshQueueSyncCoordinator {
  final Logger _logger;
  final IConnectionService _bleService;
  final IMessageRepository _messageRepository;
  final MeshNetworkHealthMonitor _healthMonitor;
  final QueueSyncManagerFactory _queueSyncManagerFactory;

  OfflineMessageQueueContract? _messageQueue;
  QueueSyncManagerContract? _queueSyncManager;
  String? _currentNodeId;
  VoidCallback? _onStatusChanged;
  StreamSubscription<ConnectionInfo>? _connectionSubscription;
  bool _queueSyncHandlerRegistered = false;
  final Set<String> _queueSyncInFlight = {};
  final Map<String, DateTime> _lastQueueSyncAt = {};
  // Inbound *request* debounce lives in its own map: sharing state with the
  // outbound attempt tracker (_lastQueueSyncAt) let an inbound request from a
  // peer suppress our own outbound sync to that peer, and vice versa.
  final Map<String, DateTime> _lastInboundSyncRequestAt = {};
  static const Duration _queueSyncDebounce = Duration(seconds: 10);

  MeshQueueSyncCoordinator({
    required IConnectionService bleService,
    required IMessageRepository messageRepository,
    required MeshNetworkHealthMonitor healthMonitor,
    QueueSyncManagerFactory? queueSyncManagerFactory,
    Logger? logger,
  }) : _bleService = bleService,
       _messageRepository = messageRepository,
       _healthMonitor = healthMonitor,
       _queueSyncManagerFactory =
           queueSyncManagerFactory ??
           ((queue, nodeId) =>
               QueueSyncManagerAdapter(queue: queue, nodeId: nodeId)),
       _logger = logger ?? Logger('MeshQueueSyncCoordinator');
  late final MessageAckTracker _ackTracker = MessageAckTracker();

  OfflineMessageQueueContract? get messageQueue => _messageQueue;

  QueueStatistics? get queueStatistics => _messageQueue?.getStatistics();

  QueueSyncManagerStats? get queueSyncStats => _queueSyncManager?.getStats();

  List<QueuedMessage> getActiveQueueMessages() {
    if (_messageQueue == null) {
      return [];
    }

    return [
      ..._messageQueue!.getMessagesByStatus(QueuedMessageStatus.pending),
      ..._messageQueue!.getMessagesByStatus(QueuedMessageStatus.sending),
      ..._messageQueue!.getMessagesByStatus(QueuedMessageStatus.retrying),
      ..._messageQueue!.getMessagesByStatus(QueuedMessageStatus.awaitingAck),
      ..._messageQueue!.getMessagesByStatus(QueuedMessageStatus.failed),
    ];
  }

  Future<void> initialize({
    required String nodeId,
    required OfflineMessageQueueContract messageQueue,
    required VoidCallback onStatusChanged,
  }) async {
    if (KillSwitches.disableQueueSync) {
      _logger.warning('⚠️ Queue sync disabled via kill switch');
      return;
    }
    _currentNodeId = nodeId;
    _messageQueue = messageQueue;
    _onStatusChanged = onStatusChanged;

    _configureQueueCallbacks();

    _queueSyncManager = _queueSyncManagerFactory(messageQueue, nodeId);
    await _queueSyncManager!.initialize(
      onSyncRequest: _handleSyncRequest,
      onSendMessages: _handleSendMessages,
      onSyncCompleted: _handleSyncCompleted,
      onSyncFailed: _handleSyncFailed,
    );

    _logger.info('Queue + sync coordinator initialized for $nodeId');

    // Hook ACK completions from the BLE layer if exposed; the BLE layer completes
    // MessageAckTracker internally. This hook allows future explicit ACK messages
    // to be mapped to queue delivery if needed.
    _bleService.receivedMessages.listen((_) {
      // Placeholder: no-op; delivery is driven by MessageAckTracker completion.
    });
  }

  /// Completes a pending ACK for the given message. Useful for inbound ACKs
  /// from the BLE layer or for tests that need to simulate delivery.
  void completeAck(String messageId, {bool success = true}) {
    _ackTracker.complete(messageId, success: success);
  }

  void enableQueueSyncHandling() {
    if (_queueSyncHandlerRegistered) {
      return;
    }
    if (KillSwitches.disableQueueSync) {
      _logger.warning(
        '⚠️ Queue sync handler registration skipped (kill switch)',
      );
      return;
    }
    _bleService.registerQueueSyncHandler(_handleIncomingQueueSync);
    _queueSyncHandlerRegistered = true;
  }

  void startConnectionMonitoring() {
    if (KillSwitches.disableQueueSync) {
      _logger.warning('⚠️ Queue sync monitoring skipped (kill switch)');
      return;
    }
    _connectionSubscription ??= _bleService.connectionInfo.listen(
      _handleConnectionChange,
      onError: (error) {
        _logger.warning('BLE connection stream error: $error');
      },
    );
  }

  Future<String> queueDirectMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (_messageQueue == null) {
      throw StateError('Message queue not initialized');
    }

    final typedChatId = ChatId(chatId);

    final messageId = await _messageQueue!.queueMessage(
      chatId: typedChatId.value,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
    );
    return messageId;
  }

  /// Re-drive delivery of the backlog to the currently-connected peer.
  ///
  /// Intended for app foreground-resume: while backgrounded (notably iOS) the
  /// queue's delivery timers are suspended, so a message enqueued in the
  /// background is not sent until the app returns. This reuses the same
  /// per-peer delivery path as connection-ready, pushing pending direct
  /// messages immediately rather than waiting on the suspended timers. No-ops
  /// when there is no usable link (delivery then resumes on reconnect).
  Future<void> reprocessPendingDeliveries() async {
    final queue = _messageQueue;
    if (queue == null) {
      return;
    }
    final deviceId = _bleService.currentSessionId;
    if (deviceId == null ||
        deviceId.isEmpty ||
        !_bleService.canSendMessages) {
      _logger.fine(
        'Resume flush skipped: no usable link (delivery resumes on reconnect)',
      );
      return;
    }
    try {
      await queue.setOnline();
      await _deliverQueuedMessagesToDevice(deviceId);
      _onStatusChanged?.call();
    } catch (e) {
      _logger.warning('Failed to reprocess pending deliveries: $e');
    }
  }

  Future<bool> retryMessage(String messageId) async {
    final queue = _messageQueue;
    if (queue == null) {
      _logger.warning('Cannot retry message: queue not initialized');
      return false;
    }

    try {
      final message = queue.getMessageById(messageId);
      if (message == null) {
        _logger.warning(
          'Message not found for retry: ${messageId.shortId()}...',
        );
        return false;
      }

      message
        ..status = QueuedMessageStatus.pending
        ..attempts = 0
        ..nextRetryAt = null
        ..failureReason = null;

      if (queue.getStatistics().isOnline) {
        await _handleSendMessage(messageId);
      }

      _onStatusChanged?.call();
      return true;
    } catch (e) {
      _logger.severe('Failed to retry message: $e');
      return false;
    }
  }

  Future<bool> removeMessage(String messageId) async {
    final queue = _messageQueue;
    if (queue == null) {
      _logger.warning('Cannot remove message: queue not initialized');
      return false;
    }

    try {
      await queue.removeMessage(messageId);
      _onStatusChanged?.call();
      return true;
    } catch (e) {
      _logger.severe('Failed to remove message: $e');
      return false;
    }
  }

  Future<bool> setPriority(String messageId, MessagePriority priority) async {
    final queue = _messageQueue;
    if (queue == null) {
      _logger.warning('Cannot set priority: queue not initialized');
      return false;
    }

    try {
      return await queue.changePriority(messageId, priority);
    } catch (e) {
      _logger.severe('Failed to set message priority: $e');
      return false;
    }
  }

  Future<int> retryAllMessages() async {
    final queue = _messageQueue;
    if (queue == null) {
      return 0;
    }

    try {
      await queue.retryFailedMessages();
      _onStatusChanged?.call();
      return queue.getMessagesByStatus(QueuedMessageStatus.failed).length;
    } catch (e) {
      _logger.severe('Failed to retry all messages: $e');
      return 0;
    }
  }

  List<QueuedMessage> getQueuedMessagesForChat(String chatId) {
    final queue = _messageQueue;
    if (queue == null) {
      _logger.warning('Cannot get queued messages: queue not initialized');
      return [];
    }

    final typedChatId = ChatId(chatId);

    final statuses = [
      QueuedMessageStatus.pending,
      QueuedMessageStatus.sending,
      QueuedMessageStatus.retrying,
      QueuedMessageStatus.failed,
    ];

    final messages = <QueuedMessage>[];
    for (final status in statuses) {
      messages.addAll(
        queue
            .getMessagesByStatus(status)
            .where((m) => ChatId(m.chatId) == typedChatId),
      );
    }

    messages.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return messages;
  }

  Future<Map<String, QueueSyncResult>> syncWithPeers(
    List<String> nodeIds,
  ) async {
    final manager = _queueSyncManager;
    if (manager == null) {
      return {'error': QueueSyncResult.error('Queue sync not initialized')};
    }

    if (nodeIds.isEmpty) {
      return {
        'no_peers': QueueSyncResult.error('No connected peers available'),
      };
    }

    return manager.forceSyncAll(nodeIds);
  }

  Future<void> dispose() async {
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _queueSyncManager?.dispose();
    _queueSyncManager = null;
    _messageQueue = null;
    _onStatusChanged = null;
  }

  void _configureQueueCallbacks() {
    if (_messageQueue == null) {
      throw StateError('Message queue not available');
    }

    _messageQueue!
      ..onMessageQueued = _handleMessageQueued
      ..onMessageDelivered = _handleMessageDelivered
      ..onMessageFailed = _handleMessageFailed
      ..onStatsUpdated = _handleQueueStatsUpdated
      ..onSendMessage = (messageId) {
        unawaited(_handleSendMessage(messageId));
      }
      ..onConnectivityCheck = _handleConnectivityCheck;
  }

  void _handleMessageQueued(QueuedMessage message) {
    final truncatedId = message.id.length > 16
        ? message.id.shortId()
        : message.id;
    _logger.fine('Message queued: $truncatedId...');
    _onStatusChanged?.call();
  }

  Future<void> _handleMessageDelivered(QueuedMessage message) async {
    final truncatedId = message.id.length > 16
        ? message.id.shortId()
        : message.id;
    _logger.info('Message delivered (ACK): $truncatedId...');

    try {
      final deliveredMessage = EnhancedMessage(
        id: MessageId(message.id),
        chatId: ChatId(message.chatId),
        content: message.content,
        timestamp: message.queuedAt,
        isFromMe: true,
        status: MessageStatus.delivered,
        replyToMessageId: message.replyToMessageId != null
            ? MessageId(message.replyToMessageId!)
            : null,
      );

      await _messageRepository.saveMessage(deliveredMessage);
    } catch (e) {
      _logger.severe('Failed to persist delivered message: $e');
    }

    _healthMonitor.notifyMessageDelivered(message.id);
    _onStatusChanged?.call();
  }

  void _handleMessageFailed(QueuedMessage message, String reason) {
    final truncatedId = message.id.length > 16
        ? message.id.shortId()
        : message.id;
    _logger.warning('Message failed: $truncatedId... - $reason');
    _onStatusChanged?.call();
  }

  void _handleQueueStatsUpdated(QueueStatistics stats) {
    _onStatusChanged?.call();
  }

  Future<void> _handleSendMessage(String messageId) async {
    final queue = _messageQueue;
    if (queue == null) {
      return;
    }

    final truncatedId = messageId.length > 16 ? messageId.shortId() : messageId;
    _logger.fine('Send message request: $truncatedId...');

    try {
      final message = queue.getMessageById(messageId);
      if (message == null) {
        _logger.severe('Message not found in queue: $truncatedId...');
        await queue.markMessageFailed(messageId, 'Message not found in queue');
        return;
      }

      if (!_bleService.canSendMessages) {
        _logger.warning(
          'No active connection available (will retry later): $truncatedId...',
        );
        return;
      }

      final canUseCurrentPeer = await _canSendMessageToCurrentPeer(message);
      if (!canUseCurrentPeer) {
        _logger.warning(
          'Connected peer is neither the queued recipient nor an approved relay '
          '(will retry later): '
          '$truncatedId...',
        );
        return;
      }

      final success = message.isRelayMessage
          ? await _sendRelayMessage(message)
          : _bleService.hasPeripheralConnection
          ? await _bleService.sendPeripheralMessage(
              message.content,
              messageId: messageId,
            )
          : await _bleService.sendMessage(
              message.content,
              messageId: messageId,
              originalIntendedRecipient: message.recipientPublicKey,
            );

      if (!success) {
        await queue.markMessageFailed(messageId, 'BLE transmission failed');
        return;
      }

      // Defer marking delivered until ACK arrives; queue already sets awaitingAck.
      // MessageAckTracker is completed by BLEMessageHandler on ACK.
      _ackTracker
          .track(
            messageId,
            onTimeout: (id) {
              _logger.warning('ACK timeout for message ${id.shortId()}...');
              queue.markMessageFailed(id, 'ACK timeout');
            },
          )
          .future
          .then((ackSuccess) async {
            if (ackSuccess) {
              await queue.markMessageDelivered(messageId);
            }
          });
    } catch (e) {
      _logger.severe('Error sending message $truncatedId...: $e');
      await _messageQueue?.markMessageFailed(messageId, 'Send error: $e');
    }
  }

  Future<bool> _sendRelayMessage(QueuedMessage message) async {
    final relayMetadata = message.relayMetadata;
    final originalMessageId = message.originalMessageId;
    final relayPayload = message.content.trim();
    if (relayMetadata == null || originalMessageId == null) {
      _logger.warning(
        'Relay queue item missing metadata/original message ID: ${message.id.shortId()}...',
      );
      return false;
    }
    if (relayPayload.isEmpty) {
      _logger.warning(
        'Relay queue item missing inner protocol payload: ${message.id.shortId()}...',
      );
      return false;
    }

    final protocolMessage = ProtocolMessage.meshRelay(
      originalMessageId: originalMessageId,
      originalSender: relayMetadata.originalSender,
      finalRecipient: relayMetadata.finalRecipient,
      relayMetadata: relayMetadata.toJson(),
      originalPayload: {'innerProtocolMessage': relayPayload},
      useEphemeralAddressing: false,
      originalMessageType: ProtocolMessageType.textMessage,
    );
    return _bleService.sendProtocolMessage(protocolMessage);
  }

  /// Returns true when the currently connected BLE peer matches the
  /// [intendedRecipient] by any of its known identifiers (session id,
  /// ephemeral id, or persistent key).
  bool _isIntendedRecipientConnected(String intendedRecipient) {
    return _matchesConnectedPeer(intendedRecipient);
  }

  bool _matchesConnectedPeer(String candidateId) {
    if (candidateId.isEmpty) {
      return false;
    }

    final connectedIdentifiers = <String?>{
      _bleService.currentSessionId,
      _bleService.theirEphemeralId,
      _bleService.theirPersistentKey,
    };

    return connectedIdentifiers.any(
      (candidate) =>
          candidate != null && candidate.isNotEmpty && candidate == candidateId,
    );
  }

  Future<bool> _canSendMessageToCurrentPeer(QueuedMessage message) async {
    if (message.recipientPublicKey.isEmpty) {
      return false;
    }

    return _isIntendedRecipientConnected(message.recipientPublicKey);
  }

  void _handleConnectivityCheck() {
    final queue = _messageQueue;
    if (queue == null) {
      return;
    }

    final hasConnection = _bleService.canSendMessages;
    if (hasConnection) {
      queue.setOnline();
    } else {
      queue.setOffline();
    }
  }

  Future<bool> _handleIncomingQueueSync(
    QueueSyncMessage message,
    String fromNodeId,
  ) async {
    final manager = _queueSyncManager;
    if (manager == null) {
      return false;
    }

    try {
      if (message.syncType == QueueSyncType.request) {
        // Debounce duplicate *requests* only (tight retries on notification
        // failure). Responses must never be debounced: they complete a
        // pending initiated sync and dropping one forces a 15s timeout.
        final lastRequest = _lastInboundSyncRequestAt[fromNodeId];
        if (lastRequest != null &&
            DateTime.now().difference(lastRequest) < _queueSyncDebounce) {
          _logger.fine(
            '⏳ Skipping queue sync request from ${fromNodeId.shortId(8)}... (debounced)',
          );
          return false;
        }
        _lastInboundSyncRequestAt[fromNodeId] = DateTime.now();

        final response = await manager.handleSyncRequest(message, fromNodeId);
        if (response.type == QueueSyncResponseType.success &&
            response.responseMessage != null) {
          final sent = await _bleService.sendQueueSyncMessage(
            response.responseMessage!,
            peerId: fromNodeId,
          );
          if (!sent) return false;
        }
        return true;
      }

      if (message.syncType == QueueSyncType.response) {
        await manager.processSyncResponse(
          message,
          const <QueuedMessage>[],
          _resolvePendingSyncKey(manager, message, fromNodeId),
        );
        return true;
      }
    } catch (e) {
      _logger.severe(
        'Queue sync handling failed for ${fromNodeId.shortId(8)}...: $e',
      );
    }

    return false;
  }

  /// The transport, the peer's self-declared node id, and our session state
  /// may all use different identifier flavors for the same peer (relationship
  /// hint vs ephemeral session id vs persistent key). A pending initiated
  /// sync is keyed by whichever flavor we initiated with, so resolve the
  /// response against every known alias before falling back to the transport
  /// id.
  String _resolvePendingSyncKey(
    QueueSyncManagerContract manager,
    QueueSyncMessage message,
    String fromNodeId,
  ) {
    final aliases = <String?>[
      fromNodeId,
      message.nodeId,
      _bleService.currentSessionId,
      _bleService.theirEphemeralId,
      _bleService.theirPersistentKey,
    ];
    for (final alias in aliases) {
      if (alias != null && alias.isNotEmpty && manager.hasPendingSyncWith(alias)) {
        return alias;
      }
    }
    return fromNodeId;
  }

  void _handleConnectionChange(ConnectionInfo connectionInfo) async {
    final connectedDeviceId = _bleService.currentSessionId;

    // Only treat the link as usable when the handshake has completed (isReady)
    // and we are not awaiting an in-progress handshake/notification setup.
    if (connectionInfo.isConnected &&
        connectionInfo.isReady &&
        !connectionInfo.awaitingHandshake &&
        connectedDeviceId != null &&
        connectedDeviceId.isNotEmpty) {
      MeshDebugLogger.deviceConnected(connectedDeviceId);
      _messageQueue?.setOnline();
      await _deliverQueuedMessagesToDevice(connectedDeviceId);
      await _syncQueueWithDevice(connectedDeviceId);
    } else if (!connectionInfo.isConnected) {
      if (connectedDeviceId != null && connectedDeviceId.isNotEmpty) {
        MeshDebugLogger.deviceDisconnected(connectedDeviceId);
      }
      _queueSyncManager?.cancelAllSyncs(reason: 'Connection lost');
      _messageQueue?.setOffline();
      _queueSyncInFlight.clear();
      _lastInboundSyncRequestAt.clear();
      if (connectedDeviceId != null) {
        _lastQueueSyncAt.remove(connectedDeviceId);
      }
    } else {
      // Connected but not ready (handshake/identity in progress) — keep queues offline.
      _queueSyncManager?.cancelAllSyncs(reason: 'Handshake incomplete');
      _messageQueue?.setOffline();
      _queueSyncInFlight.clear();
    }

    _onStatusChanged?.call();
  }

  Future<void> _deliverQueuedMessagesToDevice(String deviceId) async {
    final queue = _messageQueue;
    if (queue == null) {
      return;
    }

    try {
      final pendingMessages = queue.getMessagesByStatus(
        QueuedMessageStatus.pending,
      );

      // Direct queue delivery must stay recipient-bound. Relay fan-out uses the
      // dedicated mesh relay pipeline so next hops never receive plaintext.
      final directMessages = pendingMessages
          .where((msg) => msg.recipientPublicKey == deviceId)
          .toList();

      if (directMessages.isEmpty) {
        return;
      }

      directMessages.sort((a, b) {
        final priorityCompare = b.priority.index.compareTo(a.priority.index);
        if (priorityCompare != 0) return priorityCompare;
        return a.queuedAt.compareTo(b.queuedAt);
      });

      for (int i = 0; i < directMessages.length; i++) {
        final message = directMessages[i];
        try {
          if (i > 0) {
            await Future.delayed(Duration(milliseconds: 200));
          }
          MeshDebugLogger.messageDequeued(message.id, deviceId);
          await _handleSendMessage(message.id);
        } catch (e) {
          MeshDebugLogger.deliveryFailed(message.id, e.toString(), 1, 1);
        }
      }
    } catch (e) {
      MeshDebugLogger.error('QUEUE_DELIVERY', e.toString());
    }
  }

  Future<void> _syncQueueWithDevice(String deviceId) async {
    final queue = _messageQueue;
    final manager = _queueSyncManager;
    if (queue == null || manager == null) {
      return;
    }

    if (_currentNodeId == null) {
      return;
    }

    if (_queueSyncInFlight.contains(deviceId)) {
      _logger.fine(
        '⏳ Queue sync already in flight for ${deviceId.shortId(8)}..., skipping',
      );
      return;
    }

    final lastAttempt = _lastQueueSyncAt[deviceId];
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < _queueSyncDebounce) {
      _logger.fine(
        '⏸️ Queue sync recently attempted for ${deviceId.shortId(8)}... (debounced)',
      );
      return;
    }

    try {
      final truncatedDeviceId = deviceId.length > 8
          ? deviceId.shortId(8)
          : deviceId;
      _logger.info('🔄 Starting queue sync with $truncatedDeviceId...');
      _queueSyncInFlight.add(deviceId);
      await manager.initiateSync(deviceId);
    } catch (e) {
      _logger.severe('Failed to sync queue with device: $e');
    } finally {
      _queueSyncInFlight.remove(deviceId);
      _lastQueueSyncAt[deviceId] = DateTime.now();
    }
  }

  void _handleSyncRequest(QueueSyncMessage message, String toNodeId) {
    final truncatedNodeId = toNodeId.length > 8
        ? toNodeId.shortId(8)
        : toNodeId;
    _logger.info(
      '🔄 Sending queue sync to $truncatedNodeId... (${message.messageIds.length} ids)',
    );

    unawaited(
      _bleService
          .sendQueueSyncMessage(message, peerId: toNodeId)
          .then((sent) {
            if (!sent) {
              _logger.warning(
                '⚠️ Queue sync request to $truncatedNodeId... had no BLE '
                'route — failing fast instead of waiting for timeout',
              );
              _queueSyncManager?.failPendingSync(toNodeId, 'No BLE route');
            }
          })
          .catchError((Object e) {
            _logger.warning(
              '⚠️ Queue sync request send to $truncatedNodeId... failed: $e',
            );
            _queueSyncManager?.failPendingSync(toNodeId, 'Send failed: $e');
          }),
    );
  }

  void _handleSendMessages(List<QueuedMessage> messages, String toNodeId) {
    if (messages.isEmpty) {
      return;
    }

    // The requester id arrives in whatever flavor the transport resolved
    // (often a relationship hint), so it may not match our session
    // identifiers even though it is the connected peer. Recipient binding is
    // enforced per message in _handleSendMessage via
    // _canSendMessageToCurrentPeer; a mismatch here is only informational.
    if (!_matchesConnectedPeer(toNodeId)) {
      _logger.fine(
        'Queue sync requester ${toNodeId.shortId(8)}... does not match '
        'session identifiers; relying on per-message recipient gate',
      );
    }

    final truncated = toNodeId.length > 8 ? toNodeId.shortId(8) : toNodeId;
    _logger.info(
      '📤 Sync delivering ${messages.length} queued message(s) to $truncated...',
    );

    for (final message in messages) {
      _handleSendMessage(message.id).catchError((e) {
        _logger.warning(
          'Queue sync delivery failed for ${message.id.shortId(8)}...: $e',
        );
      });
    }
  }

  void _handleSyncCompleted(String nodeId, QueueSyncResult result) {
    _logger.info(
      'Sync completed with ${nodeId.shortId(8)}...: ${result.success ? "success" : "failed"}',
    );

    final stats = _queueSyncManager?.getStats();
    if (stats != null) {
      _healthMonitor.emitQueueStats(stats);
    }
  }

  void _handleSyncFailed(String nodeId, String error) {
    _logger.warning('Sync failed with ${nodeId.shortId(8)}...: $error');
  }
}

/// Abstraction over [QueueSyncManager] to simplify testing.
abstract class QueueSyncManagerContract {
  Future<void> initialize({
    Function(QueueSyncMessage message, String fromNodeId)? onSyncRequest,
    Function(List<QueuedMessage> messages, String toNodeId)? onSendMessages,
    Function(String nodeId, QueueSyncResult result)? onSyncCompleted,
    Function(String nodeId, String error)? onSyncFailed,
  });

  QueueSyncManagerStats getStats();

  Future<Map<String, QueueSyncResult>> forceSyncAll(List<String> nodeIds);

  Future<QueueSyncResult> initiateSync(String targetNodeId);

  Future<QueueSyncResponse> handleSyncRequest(
    QueueSyncMessage syncMessage,
    String fromNodeId,
  );

  Future<QueueSyncResult> processSyncResponse(
    QueueSyncMessage responseMessage,
    List<QueuedMessage> receivedMessages,
    String fromNodeId,
  );

  /// True when an initiated sync is still awaiting a response from [nodeId].
  bool hasPendingSyncWith(String nodeId);

  /// Fail a pending initiated sync immediately (e.g. transport had no route).
  void failPendingSync(String nodeId, String reason);

  void cancelAllSyncs({String? reason});

  void dispose();
}

class QueueSyncManagerAdapter implements QueueSyncManagerContract {
  final QueueSyncManager _manager;

  QueueSyncManagerAdapter({
    required OfflineMessageQueueContract queue,
    required String nodeId,
  }) : _manager = QueueSyncManager(messageQueue: queue, nodeId: nodeId);

  @override
  Future<void> initialize({
    Function(QueueSyncMessage message, String fromNodeId)? onSyncRequest,
    Function(List<QueuedMessage> messages, String toNodeId)? onSendMessages,
    Function(String nodeId, QueueSyncResult result)? onSyncCompleted,
    Function(String nodeId, String error)? onSyncFailed,
  }) async {
    await _manager.initialize(
      onSyncRequest: onSyncRequest,
      onSendMessages: onSendMessages,
      onSyncCompleted: onSyncCompleted,
      onSyncFailed: onSyncFailed,
    );
  }

  @override
  QueueSyncManagerStats getStats() => _manager.getStats();

  @override
  Future<Map<String, QueueSyncResult>> forceSyncAll(List<String> nodeIds) =>
      _manager.forceSyncAll(nodeIds);

  @override
  Future<QueueSyncResult> initiateSync(String targetNodeId) =>
      _manager.initiateSync(targetNodeId);

  @override
  Future<QueueSyncResponse> handleSyncRequest(
    QueueSyncMessage syncMessage,
    String fromNodeId,
  ) => _manager.handleSyncRequest(syncMessage, fromNodeId);

  @override
  Future<QueueSyncResult> processSyncResponse(
    QueueSyncMessage responseMessage,
    List<QueuedMessage> receivedMessages,
    String fromNodeId,
  ) => _manager.processSyncResponse(
    responseMessage,
    receivedMessages,
    fromNodeId,
  );

  @override
  bool hasPendingSyncWith(String nodeId) => _manager.hasPendingSyncWith(nodeId);

  @override
  void failPendingSync(String nodeId, String reason) =>
      _manager.failPendingSync(nodeId, reason);

  @override
  void cancelAllSyncs({String? reason}) =>
      _manager.cancelAllSyncs(reason: reason);

  @override
  void dispose() => _manager.dispose();
}
