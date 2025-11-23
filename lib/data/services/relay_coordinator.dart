import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_relay_coordinator.dart';
import '../../core/interfaces/i_seen_message_store.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../core/app_core.dart';

/// Coordinates relay decisions and message routing
///
/// Bridge layer between:
/// - BLE message handling (receiving ProtocolMessages)
/// - Mesh relay engine (relay decisions and routing)
///
/// Responsibilities:
/// - Determining if messages should be relayed
/// - Creating outgoing relay messages
/// - Handling relay ACKs (delivery confirmations)
/// - Managing relay statistics
/// - Coordinating with MeshRelayEngine for routing decisions
class RelayCoordinator implements IRelayCoordinator {
  final _logger = Logger('RelayCoordinator');

  // Dependencies (initialized via initializeRelaySystem)
  MeshRelayEngine? _relayEngine;
  SpamPreventionManager? _spamPrevention;
  bool _spamInitialized = false;
  OfflineMessageQueue? _messageQueue;
  ISeenMessageStore? _seenMessageStore;
  List<String> Function()? _nextHopsProvider;

  String? _currentNodeId;

  // Relay ACK management
  final Map<String, Timer> _relayAckTimeouts = {};
  final Map<String, Completer<bool>> _relayAcks = {};

  // Callbacks
  Function(String, String, String)? _onRelayMessageReceived;
  Function(RelayDecision)? _onRelayDecisionMade;
  Function(RelayStatistics)? _onRelayStatsUpdated;
  Function(ProtocolMessage)? _onSendAckMessage;
  Function(ProtocolMessage, String)? _onSendRelayMessage;
  Function(QueueSyncMessage, String)? _onQueueSyncReceived;
  Function(String, QueueSyncResult)? _onQueueSyncCompleted;

  /// Initialize relay system with dependencies
  @override
  Future<void> initializeRelaySystem({required String currentNodeId}) async {
    _currentNodeId = currentNodeId;
    _messageQueue ??= _resolveMessageQueue();
    _spamPrevention ??= SpamPreventionManager();
    if (!_spamInitialized && _spamPrevention != null) {
      await _spamPrevention!.initialize();
      _spamInitialized = true;
    }
    _relayEngine ??= MeshRelayEngine(
      messageQueue: _messageQueue!,
      spamPrevention: _spamPrevention!,
      seenMessageStore: _seenMessageStore,
    );
    await _relayEngine!.initialize(
      currentNodeId: currentNodeId,
      onRelayMessage: (relayMessage, nextHopId) {
        handleRelayToNextHop(
          relayMessage: relayMessage,
          nextHopDeviceId: nextHopId,
        );
      },
      onDeliverToSelf: (id, content, sender) {
        _onRelayMessageReceived?.call(id, content, sender);
      },
      onRelayDecision: _onRelayDecisionMade,
      onStatsUpdated: _onRelayStatsUpdated,
    );
    _logger.info(
      '🔄 Relay system initialized for node: ${currentNodeId.substring(0, 8)}...',
    );
  }

  /// Sets current node ID
  @override
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    _logger.fine('📍 Relay coordinator node ID: ${nodeId.substring(0, 8)}...');
  }

  /// Sets the SeenMessageStore for deduplication
  void setSeenMessageStore(ISeenMessageStore seenMessageStore) {
    _seenMessageStore = seenMessageStore;
    _logger.fine('🔐 SeenMessageStore injected for relay deduplication');
  }

  /// Processes incoming message through relay decision engine
  @override
  Future<bool> handleMeshRelay({
    required String originalMessageId,
    required String content,
    required String originalSender,
    required String? intendedRecipient,
    required Map<String, dynamic>? messageData,
    required int? currentHopCount,
  }) async {
    try {
      final hopCount = currentHopCount ?? 0;

      // Check if we should relay this message
      if (!shouldAttemptRelay(
        messageId: originalMessageId,
        currentHopCount: hopCount,
      )) {
        _logger.fine('🚫 Message relay rejected (policy or dedup)');
        return false;
      }

      // Mark as delivered to prevent future duplicate relays
      // This must happen AFTER we decide to relay but BEFORE any forwarding
      // Prevents: same message received twice → forwarded twice → loops
      if (_seenMessageStore != null) {
        await _seenMessageStore!.markDelivered(originalMessageId);
        final shortId = originalMessageId.length > 8
            ? originalMessageId.substring(0, 8)
            : originalMessageId;
        _logger.fine(
          '✅ Relay marked as delivered for dedup window: $shortId...',
        );
      }

      // Check if message is for us first
      final isForUs =
          intendedRecipient == null || intendedRecipient == _currentNodeId;
      if (isForUs) {
        _logger.fine('📩 Delivering relay message to self');
        handleRelayDeliveryToSelf(
          originalMessageId: originalMessageId,
          content: content,
          originalSender: originalSender,
        );
      }

      // Attempt relay to next hops
      _logger.fine('🔄 Relaying message to next hops');
      _onRelayMessageReceived?.call(originalMessageId, content, originalSender);

      return true;
    } catch (e) {
      _logger.severe('❌ Relay failed: $e');
      return false;
    }
  }

  /// Creates outgoing relay message using existing factory
  @override
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String content,
    required String originalSender,
    required String? intendedRecipient,
    required int currentHopCount,
  }) async {
    try {
      _logger.fine('📤 Creating relay message (hop ${currentHopCount + 1})');

      // Build relay metadata with correct factory signature
      final relayMetadata = RelayMetadata.create(
        originalMessageContent: content,
        priority: MessagePriority.normal,
        originalSender: originalSender,
        finalRecipient: intendedRecipient ?? 'broadcast',
        currentNodeId: _currentNodeId ?? 'unknown',
      );

      // Use MeshRelayMessage.createRelay() factory with correct parameter names
      return MeshRelayMessage.createRelay(
        originalMessageId: originalMessageId,
        originalContent: content,
        metadata: relayMetadata,
        relayNodeId: _currentNodeId ?? 'unknown',
      );
    } catch (e) {
      _logger.severe('❌ Failed to create relay message: $e');
      return null;
    }
  }

  /// Sends relay message to next hop
  @override
  Future<void> handleRelayToNextHop({
    required MeshRelayMessage relayMessage,
    required String nextHopDeviceId,
  }) async {
    try {
      _logger.fine(
        '📤 Relaying to next hop: ${nextHopDeviceId.substring(0, 8)}...',
      );

      // Use nextHop() for hop chaining (updates metadata internally)
      final nextRelayMessage = relayMessage.nextHop(nextHopDeviceId);

      // Convert metadata to Map<String, dynamic> for meshRelay() factory
      final metadataMap = <String, dynamic>{
        'originalSender': nextRelayMessage.relayMetadata.originalSender,
        'finalRecipient': nextRelayMessage.relayMetadata.finalRecipient,
        'currentNodeId': _currentNodeId,
        'hopCount': nextRelayMessage.relayMetadata.hopCount,
      };

      // Convert original payload to Map<String, dynamic>
      final payloadMap = <String, dynamic>{
        'content': relayMessage.originalContent,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // Create protocol message wrapper using meshRelay() factory
      final protocolMessage = ProtocolMessage.meshRelay(
        originalMessageId: relayMessage.originalMessageId,
        originalSender: relayMessage.relayMetadata.originalSender,
        finalRecipient: relayMessage.relayMetadata.finalRecipient,
        relayMetadata: metadataMap,
        originalPayload: payloadMap,
      );

      // Register ACK timeout (5 second wait)
      _relayAckTimeouts[relayMessage.originalMessageId] = Timer(
        Duration(seconds: 5),
        () {
          if (!_relayAcks.containsKey(relayMessage.originalMessageId)) {
            _logger.warning(
              '⏱️ Relay ACK timeout for: ${relayMessage.originalMessageId}',
            );
          }
        },
      );

      // Send via callback
      _onSendRelayMessage?.call(protocolMessage, nextHopDeviceId);
    } catch (e) {
      _logger.severe('❌ Failed to relay to next hop: $e');
    }
  }

  /// Delivers relay message to self
  @override
  void handleRelayDeliveryToSelf({
    required String originalMessageId,
    required String content,
    required String originalSender,
  }) {
    try {
      _logger.fine('📩 Delivering relay message to self');

      // Call delivery callback
      _onRelayMessageReceived?.call(originalMessageId, content, originalSender);

      // Send ACK back to original sender
      sendRelayAck(
        originalMessageId: originalMessageId,
        toDeviceId: originalSender,
        relayAckContent: 'ACK:$originalMessageId',
      );
    } catch (e) {
      _logger.severe('❌ Failed to deliver relay to self: $e');
    }
  }

  /// Determines if message should be relayed
  @override
  bool shouldAttemptRelay({
    required String messageId,
    required int currentHopCount,
  }) {
    // Check hop limit
    if (currentHopCount >= 3) {
      _logger.fine('🚫 Hop limit reached ($currentHopCount >= 3)');
      return false;
    }

    // Check if we've seen this message (deduplication)
    // Prevents loops and traffic amplification from duplicate relay paths
    if (_seenMessageStore != null &&
        _seenMessageStore!.hasDelivered(messageId)) {
      final shortId = messageId.length > 8
          ? messageId.substring(0, 8)
          : messageId;
      _logger.fine(
        '🔄 Duplicate relay suppressed (already processed): $shortId...',
      );
      return false;
    }

    return true;
  }

  /// Determines if decryption should be attempted
  @override
  Future<bool> shouldAttemptDecryption({
    required String messageId,
    required String senderKey,
  }) async {
    // This depends on encryption method and security level
    // For relay messages, only decrypt if we're the intended recipient
    return false;
  }

  /// Sends relay ACK using actual factory
  @override
  Future<void> sendRelayAck({
    required String originalMessageId,
    required String toDeviceId,
    required String relayAckContent,
  }) async {
    try {
      _logger.fine(
        '✅ Sending relay ACK for: ${originalMessageId.substring(0, 8)}...',
      );

      // Use ProtocolMessage.relayAck() factory (NOT createRelayAck)
      final ackMessage = ProtocolMessage.relayAck(
        originalMessageId: originalMessageId,
        relayNode: _currentNodeId ?? 'unknown',
        delivered: true,
      );

      _onSendAckMessage?.call(ackMessage);
    } catch (e) {
      _logger.severe('❌ Failed to send relay ACK: $e');
    }
  }

  /// Handles relay ACK (delivery confirmation)
  @override
  Future<void> handleRelayAck({
    required String originalMessageId,
    required String fromDeviceId,
    required Map<String, dynamic>? ackData,
  }) async {
    try {
      _logger.fine(
        '✅ Relay ACK received for: ${originalMessageId.substring(0, 8)}...',
      );

      // Cancel timeout
      _relayAckTimeouts[originalMessageId]?.cancel();
      _relayAckTimeouts.remove(originalMessageId);

      // Notify via callback if set
      final completer = _relayAcks[originalMessageId];
      if (completer != null && !completer.isCompleted) {
        completer.complete(true);
      }
    } catch (e) {
      _logger.severe('❌ Failed to handle relay ACK: $e');
    }
  }

  /// Gets relay statistics from MeshRelayEngine
  @override
  Future<RelayStatistics> getRelayStatistics() async {
    if (_relayEngine != null) {
      return _relayEngine!.getStatistics();
    }
    _logger.warning('RelayEngine not initialized, returning empty statistics');
    // Return default statistics if engine not available
    return RelayStatistics(
      totalRelayed: 0,
      totalDropped: 0,
      totalDeliveredToSelf: 0,
      totalBlocked: 0,
      totalProbabilisticSkip: 0,
      spamScore: 0.0,
      relayEfficiency: 0.0,
      activeRelayMessages: 0,
      networkSize: 0,
      currentRelayProbability: 0.0,
    );
  }

  /// Sends queue synchronization message
  @override
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  }) async {
    try {
      _logger.fine('📦 Sending queue sync to: ${toNodeId.substring(0, 8)}...');

      // Create QueueSyncMessage using factory
      final syncMessage = QueueSyncMessage.createRequest(
        messageIds: messageIds,
        nodeId: toNodeId,
      );

      // Use ProtocolMessage.queueSync() factory (NOT createQueueSync)
      final protocolMessage = ProtocolMessage.queueSync(
        queueMessage: syncMessage,
      );

      _onSendAckMessage?.call(protocolMessage);
      return true;
    } catch (e) {
      _logger.severe('❌ Failed to send queue sync: $e');
      return false;
    }
  }

  /// Gets available next hops for relay
  @override
  List<String> getAvailableNextHops() {
    if (_nextHopsProvider != null) {
      try {
        return _nextHopsProvider!();
      } catch (e) {
        _logger.fine('Failed to read next hops from provider: $e');
      }
    }
    return [];
  }

  // ==================== CALLBACKS ====================

  @override
  void onRelayStatsUpdated(Function(RelayStatistics stats) callback) {
    _onRelayStatsUpdated = callback;
  }

  @override
  void onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)
    callback,
  ) {
    _onRelayMessageReceived = callback;
  }

  @override
  void onRelayDecisionMade(Function(RelayDecision decision) callback) {
    _onRelayDecisionMade = callback;
  }

  @override
  void onSendRelayMessage(
    Function(ProtocolMessage message, String nextHopId) callback,
  ) {
    _onSendRelayMessage = callback;
  }

  @override
  void onSendAckMessage(Function(ProtocolMessage message) callback) {
    _onSendAckMessage = callback;
  }

  @override
  void onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId) callback,
  ) {
    _onQueueSyncReceived = callback;
  }

  @override
  void onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result) callback,
  ) {
    _onQueueSyncCompleted = callback;
  }

  /// Override the message queue (useful for tests or explicit injection).
  void setMessageQueue(OfflineMessageQueue queue) {
    _messageQueue = queue;
  }

  /// Override spam prevention manager (useful for tests).
  void setSpamPrevention(SpamPreventionManager spamPrevention) {
    _spamPrevention = spamPrevention;
  }

  /// Provide available next hops from the BLE layer.
  void setNextHopsProvider(List<String> Function() provider) {
    _nextHopsProvider = provider;
  }

  /// Forward queue sync events to registered handler.
  void handleQueueSyncReceived(
    QueueSyncMessage syncMessage,
    String fromNodeId,
  ) {
    _onQueueSyncReceived?.call(syncMessage, fromNodeId);
  }

  OfflineMessageQueue _resolveMessageQueue() {
    if (_messageQueue != null) return _messageQueue!;
    try {
      final core = AppCore.instance;
      if (core.isInitialized || core.isInitializing) {
        return core.messageQueue;
      }
    } catch (_) {
      // Fall through to error below
    }
    throw StateError(
      'OfflineMessageQueue not available. Inject a queue or initialize AppCore before relay setup.',
    );
  }

  // ==================== CLEANUP ====================

  /// Cleanup
  @override
  void dispose() {
    for (var timer in _relayAckTimeouts.values) {
      timer.cancel();
    }
    _relayAckTimeouts.clear();
    _relayAcks.clear();
    _logger.info('🔌 RelayCoordinator disposed');
  }
}
