import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/interfaces/i_relay_coordinator.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart'
    as domain_messaging;
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import '../../domain/values/id_types.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:pak_connect/domain/constants/special_recipients.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';

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
  static ISharedMessageQueueProvider? Function()? _sharedQueueProviderResolver;
  static IMeshRelayEngineFactory Function()? _relayEngineFactoryResolver;

  static void configureDependencyResolvers({
    ISharedMessageQueueProvider? Function()? sharedQueueProviderResolver,
    IMeshRelayEngineFactory Function()? relayEngineFactoryResolver,
  }) {
    if (sharedQueueProviderResolver != null) {
      _sharedQueueProviderResolver = sharedQueueProviderResolver;
    }
    if (relayEngineFactoryResolver != null) {
      _relayEngineFactoryResolver = relayEngineFactoryResolver;
    }
  }

  static void clearDependencyResolvers() {
    _sharedQueueProviderResolver = null;
    _relayEngineFactoryResolver = null;
  }

  final _logger = Logger('RelayCoordinator');
  final ISharedMessageQueueProvider? _sharedQueueProvider;
  final IMeshRelayEngineFactory? _relayEngineFactory;

  RelayCoordinator({
    ISharedMessageQueueProvider? sharedQueueProvider,
    IMeshRelayEngineFactory? relayEngineFactory,
  }) : _sharedQueueProvider = sharedQueueProvider,
       _relayEngineFactory = relayEngineFactory;

  // Dependencies (initialized via initializeRelaySystem)
  domain_messaging.MeshRelayEngine? _relayEngine;
  SpamPreventionManager? _spamPrevention;
  bool _spamInitialized = false;
  OfflineMessageQueueContract? _messageQueue;
  ISeenMessageStore? _seenMessageStore;
  List<String> Function()? _nextHopsProvider;

  String? _currentNodeId;

  // Relay ACK management
  final Map<String, Timer> _relayAckTimeouts = {};
  final Map<String, Completer<bool>> _relayAcks = {};

  // Callbacks
  Function(String, String, String)? _onRelayMessageReceived;
  Function(MessageId, String, String)? _onRelayMessageReceivedIds;
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
    _messageQueue ??= await _resolveMessageQueue();
    _spamPrevention ??= SpamPreventionManager();
    if (!_spamInitialized && _spamPrevention != null) {
      await _spamPrevention!.initialize();
      _spamInitialized = true;
    }
    _relayEngine ??= _resolveRelayEngineFactory().create(
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
        handleRelayDeliveryToSelf(
          originalMessageId: id,
          content: content,
          originalSender: sender,
        );
      },
      onRelayDecision: _onRelayDecisionMade,
      onStatsUpdated: _onRelayStatsUpdated,
    );
    _logger.info(
      '🔄 Relay system initialized for node: ${currentNodeId.shortId(8)}...',
    );
  }

  /// Sets current node ID
  @override
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    _logger.fine('📍 Relay coordinator node ID: ${nodeId.shortId(8)}...');
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
      if (_relayEngine == null) {
        _logger.warning('🚫 Relay engine not initialized');
        return false;
      }

      final relayPayload = _extractRelayPayload(
        messageData: messageData,
        fallbackContent: content,
      );
      if (relayPayload == null) {
        _logger.warning(
          '🚫 Relay message dropped: missing or invalid encrypted inner payload',
        );
        return false;
      }

      final hopCount = currentHopCount ?? 0;
      final metadataTemplate = RelayMetadata.create(
        originalMessageContent: relayPayload,
        priority: MessagePriority.normal,
        originalSender: originalSender,
        finalRecipient: intendedRecipient ?? SpecialRecipients.broadcast,
        currentNodeId: _currentNodeId ?? 'unknown',
      );
      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: originalMessageId,
        originalContent: '',
        metadata: RelayMetadata(
          ttl: metadataTemplate.ttl,
          hopCount: hopCount,
          routingPath: metadataTemplate.routingPath,
          messageHash: metadataTemplate.messageHash,
          priority: metadataTemplate.priority,
          relayTimestamp: metadataTemplate.relayTimestamp,
          originalSender: metadataTemplate.originalSender,
          finalRecipient: metadataTemplate.finalRecipient,
        ),
        relayNodeId: _currentNodeId ?? 'unknown',
        encryptedPayload: relayPayload,
        originalMessageType: ProtocolMessageType.textMessage,
      );

      final result = await _relayEngine!.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: originalSender,
        availableNextHops: getAvailableNextHops(),
        messageType: ProtocolMessageType.textMessage,
      );

      return result.type == RelayProcessingType.deliveredToSelf ||
          result.type == RelayProcessingType.relayed;
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
      if (_relayEngine == null) {
        _logger.warning('🚫 Relay engine not initialized');
        return null;
      }
      if (!_isValidInnerProtocolPayload(content)) {
        _logger.warning(
          '🚫 Rejecting outgoing relay without encrypted inner payload',
        );
        return null;
      }
      _logger.fine('📤 Creating relay message (hop ${currentHopCount + 1})');

      return await _relayEngine!.createOutgoingRelay(
        originalMessageId: originalMessageId,
        originalContent: '',
        finalRecipientPublicKey:
            intendedRecipient ?? SpecialRecipients.broadcast,
        encryptedPayload: content,
        originalMessageType: ProtocolMessageType.textMessage,
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
      final relayPayload = relayMessage.relayPayload;
      if (relayPayload == null || !_isValidInnerProtocolPayload(relayPayload)) {
        _logger.warning(
          '🚫 Refusing to forward relay without encrypted inner payload',
        );
        return;
      }
      _logger.fine('📤 Relaying to next hop: ${nextHopDeviceId.shortId(8)}...');

      // Use nextHop() for hop chaining (updates metadata internally)
      final nextRelayMessage = relayMessage.nextHop(nextHopDeviceId);

      // Convert metadata to Map<String, dynamic> for meshRelay() factory
      final metadataMap = <String, dynamic>{
        'originalSender': nextRelayMessage.relayMetadata.originalSender,
        'finalRecipient': nextRelayMessage.relayMetadata.finalRecipient,
        'currentNodeId': _currentNodeId,
        'hopCount': nextRelayMessage.relayMetadata.hopCount,
        'ttl': nextRelayMessage.relayMetadata.ttl,
        'routingPath': nextRelayMessage.relayMetadata.routingPath,
        'messageHash': nextRelayMessage.relayMetadata.messageHash,
        'priority': nextRelayMessage.relayMetadata.priority.index,
        if (nextRelayMessage.relayMetadata.sealedSender) 'sealedSender': true,
      };

      // Create protocol message wrapper using meshRelay() factory
      final protocolMessage = ProtocolMessage.meshRelay(
        originalMessageId: relayMessage.originalMessageId,
        originalSender: relayMessage.relayMetadata.originalSender,
        finalRecipient: relayMessage.relayMetadata.finalRecipient,
        relayMetadata: metadataMap,
        originalPayload: {'innerProtocolMessage': relayPayload},
        originalMessageType:
            relayMessage.originalMessageType ?? ProtocolMessageType.textMessage,
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
      final msgId = MessageId(originalMessageId);
      _onRelayMessageReceived?.call(originalMessageId, content, originalSender);
      _onRelayMessageReceivedIds?.call(msgId, content, originalSender);

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
      final shortId = messageId.length > 8 ? messageId.shortId(8) : messageId;
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
        '✅ Sending relay ACK for: ${originalMessageId.shortId(8)}...',
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
        '✅ Relay ACK received for: ${originalMessageId.shortId(8)}...',
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
      _logger.fine('📦 Sending queue sync to: ${toNodeId.shortId(8)}...');

      // Create QueueSyncMessage using factory
      final syncMessage = QueueSyncMessage.createRequestWithIds(
        messageIds: messageIds.map(MessageId.new).toList(),
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
  void onRelayMessageReceivedIds(
    Function(MessageId originalMessageId, String content, String originalSender)
    callback,
  ) {
    _onRelayMessageReceivedIds = callback;
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
  void setMessageQueue(OfflineMessageQueueContract queue) {
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

  Future<OfflineMessageQueueContract> _resolveMessageQueue() async {
    if (_messageQueue != null) return _messageQueue!;

    final queueProvider = _resolveSharedQueueProvider();
    if (queueProvider == null) {
      throw StateError(
        'OfflineMessageQueue not available. '
        'Register ISharedMessageQueueProvider or inject a queue provider.',
      );
    }

    if (!queueProvider.isInitialized) {
      _logger.warning(
        'Shared queue provider not initialized, initializing now...',
      );
      await queueProvider.initialize();
    }

    return queueProvider.waitForMessageQueue();
  }

  ISharedMessageQueueProvider? _resolveSharedQueueProvider() {
    if (_sharedQueueProvider != null) {
      return _sharedQueueProvider;
    }
    final resolver = _sharedQueueProviderResolver;
    return resolver?.call();
  }

  IMeshRelayEngineFactory _resolveRelayEngineFactory() {
    if (_relayEngineFactory != null) {
      return _relayEngineFactory;
    }
    final resolver = _relayEngineFactoryResolver;
    if (resolver != null) {
      return resolver();
    }
    throw StateError(
      'IMeshRelayEngineFactory not available. '
      'Configure RelayCoordinator.configureDependencyResolvers(...), '
      'or pass relayEngineFactory explicitly.',
    );
  }

  String? _extractRelayPayload({
    required Map<String, dynamic>? messageData,
    required String fallbackContent,
  }) {
    final messagePayload = messageData?['innerProtocolMessage'] as String?;
    if (messagePayload != null &&
        _isValidInnerProtocolPayload(messagePayload)) {
      return messagePayload;
    }
    if (_isValidInnerProtocolPayload(fallbackContent)) {
      return fallbackContent;
    }
    return null;
  }

  bool _isValidInnerProtocolPayload(String payload) {
    if (payload.isEmpty) {
      return false;
    }

    try {
      final decoded = base64.decode(payload);
      ProtocolMessage.fromBytes(Uint8List.fromList(decoded));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ==================== CLEANUP ====================

  /// Cleanup
  @override
  void dispose() {
    for (var timer in _relayAckTimeouts.values) {
      timer.cancel();
    }
    if (_onQueueSyncCompleted != null) {
      _logger.fine('Clearing queue sync completion callback');
    }
    _onQueueSyncCompleted = null;
    _relayAckTimeouts.clear();
    _relayAcks.clear();
    _logger.info('🔌 RelayCoordinator disposed');
  }
}
