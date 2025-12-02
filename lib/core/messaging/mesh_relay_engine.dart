// Core mesh relay engine that orchestrates A→B→C message forwarding
// Integrates spam prevention, recipient detection, and relay decision making
// Phase 1 (Role Awareness): Added explicit relay configuration and message type filtering
// Phase 3 (Network-Size Adaptive): Added probabilistic relay based on network size
// Priority 2: Broadcast messaging support (BitChat-inspired)

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import '../models/mesh_relay_models.dart';
import '../models/protocol_message.dart';
import '../interfaces/i_repository_provider.dart';
import '../interfaces/i_seen_message_store.dart';
import '../interfaces/i_identity_manager.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/values/id_types.dart';
import '../services/security_manager.dart';
import 'offline_message_queue.dart';
import '../security/spam_prevention_manager.dart';
import '../routing/network_topology_analyzer.dart';
import '../interfaces/i_mesh_routing_service.dart';
import 'relay_config_manager.dart';
import 'relay_policy.dart';
import 'relay_decision_engine.dart';
import 'relay_send_pipeline.dart';
import '../constants/special_recipients.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Core engine for mesh relay operations
class MeshRelayEngine {
  static final _logger = Logger('MeshRelayEngine');

  final IRepositoryProvider? _repositoryProvider;
  final ISeenMessageStore _seenMessageStore;
  final OfflineMessageQueue _messageQueue;
  final SpamPreventionManager _spamPrevention;

  // Smart routing integration (via IMeshRoutingService interface)
  IMeshRoutingService? _routingService;

  // Phase 3: Network topology integration for adaptive relay
  NetworkTopologyAnalyzer? _topologyAnalyzer;

  // Relay configuration (Phase 1: Role Awareness)
  final RelayConfigManager _relayConfig = RelayConfigManager.instance;
  late final RelayDecisionEngine _decisionEngine;
  late final RelaySendPipeline _sendPipeline;

  // Node identification (NOT final to allow re-initialization in tests and node identity changes)
  late String _currentNodeId;

  // Relay statistics
  int _totalRelayed = 0;
  int _totalDropped = 0;
  int _totalDeliveredToSelf = 0;
  int _totalProbabilisticSkip = 0; // Phase 3: Probabilistic relay skips

  // Callbacks for integration
  Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage;
  Function(String originalMessageId, String content, String originalSender)?
  onDeliverToSelf;
  Function(MessageId originalMessageId, String content, String originalSender)?
  onDeliverToSelfIds;
  Function(RelayDecision decision)? onRelayDecision;
  Function(RelayStatistics stats)? onStatsUpdated;

  MeshRelayEngine({
    IRepositoryProvider? repositoryProvider,
    ISeenMessageStore? seenMessageStore,
    required OfflineMessageQueue messageQueue,
    required SpamPreventionManager spamPrevention,
  }) : _repositoryProvider =
           repositoryProvider ??
           (GetIt.instance.isRegistered<IRepositoryProvider>()
               ? GetIt.instance<IRepositoryProvider>()
               : null),
       _seenMessageStore =
           seenMessageStore ??
           (GetIt.instance.isRegistered<ISeenMessageStore>()
               ? GetIt.instance<ISeenMessageStore>()
               : _InMemorySeenMessageStore()),
       _messageQueue = messageQueue,
       _spamPrevention = spamPrevention {
    _decisionEngine = RelayDecisionEngine(
      logger: _logger,
      seenMessageStore: _seenMessageStore,
      routingService: _routingService,
      topologyAnalyzer: _topologyAnalyzer,
      currentNodeId: '', // updated on initialize
    );
    _sendPipeline = RelaySendPipeline(
      logger: _logger,
      messageQueue: _messageQueue,
      spamPrevention: _spamPrevention,
    );
  }

  /// Initialize the relay engine
  ///
  /// MULTI-DEVICE NOTE: This can be called multiple times to change node identity.
  /// Bug #1 fix (2025-10-05): Changed _currentNodeId from 'late final' to 'late'
  /// to allow re-initialization for testing multi-node scenarios and production
  /// node identity changes.
  ///
  /// 🔧 CRITICAL FIX (2025-10-20): Identity validation
  /// - currentNodeId MUST be EPHEMERAL session key (NOT persistent identity)
  /// - Ephemeral keys rotate per app session - prevents long-term tracking
  /// - Persistent keys ONLY for: Contact relationships, Noise KK pattern, database PKs
  ///
  /// Phase 1 (Role Awareness): Added relay config initialization
  /// Phase 3 (Network-Size Adaptive): Added topology analyzer integration
  Future<void> initialize({
    required String currentNodeId,
    IMeshRoutingService? routingService,
    NetworkTopologyAnalyzer?
    topologyAnalyzer, // Phase 3: Added topology analyzer
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)?
    onDeliverToSelf,
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    onDeliverToSelfIds,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  }) async {
    // 🔐 VALIDATION: Warn if nodeId looks like a persistent key
    // Ephemeral keys from EphemeralKeyManager are 64-char hex (same as persistent)
    // But we can detect common patterns in persistent key sources
    if (currentNodeId.startsWith('persistent_') ||
        currentNodeId.contains('Ed25519')) {
      _logger.severe(
        '❌ SECURITY VIOLATION: Received persistent identity as nodeId!',
      );
      _logger.severe('🚨 Mesh routing MUST use ephemeral session keys');
      _logger.severe(
        '🔧 Fix: Use EphemeralKeyManager.generateMyEphemeralKey()',
      );
      throw ArgumentError(
        'currentNodeId must be ephemeral session key, not persistent identity',
      );
    }

    _currentNodeId = currentNodeId;
    _routingService = routingService;
    _topologyAnalyzer = topologyAnalyzer; // Phase 3: Store topology analyzer
    _decisionEngine.updateContext(
      currentNodeId: _currentNodeId,
      routingService: _routingService,
      topologyAnalyzer: _topologyAnalyzer,
      myPersistentId: _getMyPersistentId(),
    );
    this.onRelayMessage = onRelayMessage;
    this.onDeliverToSelf = onDeliverToSelf;
    this.onDeliverToSelfIds = onDeliverToSelfIds;
    this.onRelayDecision = onRelayDecision;
    this.onStatsUpdated = onStatsUpdated;

    // Initialize relay configuration
    await _relayConfig.initialize();

    final truncatedNodeId = _currentNodeId.length > 16
        ? _currentNodeId.shortId()
        : _currentNodeId;
    final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 0;
    _logger.info(
      '🔧 MeshRelayEngine (RE)INITIALIZED for node: $truncatedNodeId... (EPHEMERAL)',
    );
    _logger.info(
      '📡 Relay enabled: ${_relayConfig.isRelayEnabled()} | Network: $networkSize nodes',
    );
    // ignore: avoid_print
    print(
      '📡 RELAY ENGINE: Node ID set to $truncatedNodeId... (EPHEMERAL) | Smart Routing: ${_routingService != null} | Relay: ${_relayConfig.isRelayEnabled() ? "ON" : "OFF"} | Network: $networkSize nodes',
    );
  }

  /// Process incoming relay message and decide what to do
  ///
  /// Phase 1 (Role Awareness): Added relay config and message type filtering
  Future<RelayProcessingResult> processIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    List<String> availableNextHops = const [],
    ProtocolMessageType?
    messageType, // Phase 1: Added message type parameter for filtering
  }) async {
    try {
      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.shortId()
          : relayMessage.originalMessageId;
      final originalMessageIdValue = relayMessage.originalMessageIdValue;
      final truncatedFromNode = fromNodeId.length > 8
          ? fromNodeId.shortId(8)
          : fromNodeId;
      _logger.info(
        '📨 Processing relay message $truncatedMessageId... from $truncatedFromNode...',
      );

      // Step 0A: Check if relay is enabled (Phase 1: Role Awareness)
      if (!_relayConfig.isRelayEnabled()) {
        _totalDropped++;
        _logger.info(
          '🚫 Relay DISABLED - dropping message $truncatedMessageId...',
        );
        return RelayProcessingResult.dropped('Relay functionality is disabled');
      }

      // Step 0B: Check message type eligibility (Phase 1: Role Awareness)
      if (messageType != null &&
          !RelayPolicy.isRelayEligibleMessageType(messageType)) {
        _totalDropped++;
        _logger.info(
          '🚫 Message type ${messageType.name} is NOT relay-eligible - dropping $truncatedMessageId...',
        );
        return RelayProcessingResult.dropped(
          'Message type ${messageType.name} cannot be relayed',
        );
      }

      // Step 0C: Deduplication check (FIRST - before spam prevention)
      if (_decisionEngine.isDuplicateId(originalMessageIdValue)) {
        _totalDropped++;
        _logger.info(
          '⏭️  Duplicate message detected (already delivered): $truncatedMessageId...',
        );
        return RelayProcessingResult.dropped(
          'Message already delivered (duplicate)',
        );
      }

      // Step 1: Spam prevention check
      final spamCheck = await _spamPrevention.checkIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: fromNodeId,
        currentNodeId: _currentNodeId,
      );

      if (!spamCheck.allowed) {
        _totalDropped++;
        final decision = RelayDecision.blocked(
          messageId: originalMessageIdValue.value,
          reason: spamCheck.reason,
          spamScore: spamCheck.spamScore,
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        return RelayProcessingResult.blocked(spamCheck.reason);
      }

      // Determine message targeting before probabilistic decisions
      final isForUs = await _decisionEngine.isMessageForCurrentNode(
        relayMessage.relayMetadata.finalRecipient,
      );

      final isBroadcast = SpecialRecipients.isBroadcast(
        relayMessage.relayMetadata.finalRecipient,
      );

      // Step 1A: Probabilistic relay decision (Phase 3: Network-size adaptive)
      // Apply BEFORE checking if message is for us to reduce processing overhead
      final relayProbability = _decisionEngine.calculateRelayProbability();
      final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 1;

      if (_decisionEngine.shouldProbabilisticallySkip(
        isForUs: isForUs,
        relayProbability: relayProbability,
      )) {
        _totalProbabilisticSkip++;

        final decision = RelayDecision.dropped(
          messageId: relayMessage.originalMessageId,
          reason: 'Probabilistic skip (network size: $networkSize)',
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        return RelayProcessingResult.dropped('Probabilistic relay skip');
      }

      // Step 2: Check if we are the final recipient
      if (isForUs) {
        await _deliverToCurrentNode(relayMessage);
        _totalDeliveredToSelf++;

        // Mark as delivered in persistent store
        await _seenMessageStore.markDelivered(relayMessage.originalMessageId);

        final decision = RelayDecision.delivered(
          messageId: relayMessage.originalMessageId,
          finalRecipient: _currentNodeId,
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        // Priority 2: For broadcast messages, deliver to self AND continue forwarding
        // For point-to-point messages, stop here (message reached destination)
        if (!isBroadcast) {
          return RelayProcessingResult.deliveredToSelf(
            relayMessage.originalContent,
          );
        }
        // Broadcast: Continue to Step 3 to forward to all neighbors
        _logger.info(
          '📣 Broadcast delivered to self, continuing to forward to neighbors...',
        );
      }

      // Step 3: Check if message can be relayed further
      if (!relayMessage.canRelay) {
        _totalDropped++;
        final decision = RelayDecision.dropped(
          messageId: relayMessage.originalMessageId,
          reason:
              'TTL exceeded (${relayMessage.relayMetadata.hopCount}/${relayMessage.relayMetadata.ttl})',
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        return RelayProcessingResult.dropped('Message TTL exceeded');
      }

      // Step 4 & 5: Relay logic (broadcast vs point-to-point)

      if (isBroadcast) {
        // Priority 2: Broadcast to ALL neighbors (no single next-hop selection)
        await _sendPipeline.broadcastToNeighbors(
          relayMessage: relayMessage,
          availableNeighbors: availableNextHops,
          onRelayMessage: onRelayMessage,
        );
        _totalRelayed++;

        final decision = RelayDecision.relayed(
          messageId: relayMessage.originalMessageId,
          nextHopNodeId: 'ALL_NEIGHBORS',
          hopCount: relayMessage.relayMetadata.hopCount + 1,
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        return RelayProcessingResult.relayed('broadcast_to_all');
      } else {
        // Point-to-point: Choose single next hop and relay
        final nextHop = await _decisionEngine.chooseNextHop(
          relayMessage: relayMessage,
          availableHops: availableNextHops,
        );

        if (nextHop == null) {
          _totalDropped++;
          final decision = RelayDecision.dropped(
            messageId: relayMessage.originalMessageId,
            reason: 'No suitable next hop available',
          );

          onRelayDecision?.call(decision);
          _updateStatistics();

          return RelayProcessingResult.dropped('No next hop available');
        }

        // Step 5: Create next hop message and relay
        await _sendPipeline.relayToNextHop(
          relayMessage: relayMessage,
          nextHopNodeId: nextHop,
          onRelayMessage: onRelayMessage,
        );
        _totalRelayed++;

        final decision = RelayDecision.relayed(
          messageId: relayMessage.originalMessageId,
          nextHopNodeId: nextHop,
          hopCount: relayMessage.relayMetadata.hopCount + 1,
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        return RelayProcessingResult.relayed(nextHop);
      }
    } catch (e) {
      _logger.severe('Failed to process relay message: $e');
      _totalDropped++;
      _updateStatistics();
      return RelayProcessingResult.error('Processing failed: $e');
    }
  }

  /// Create new relay message for outgoing message
  ///
  /// PHASE 2: Added message type parameter for relay policy filtering
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? encryptedPayload,
    ProtocolMessageType?
    originalMessageType, // PHASE 2: Message type for filtering
  }) async {
    try {
      if (originalMessageId.isEmpty || finalRecipientPublicKey.isEmpty) {
        _logger.warning(
          'Cannot create relay: missing message id or recipient (msgId: "$originalMessageId", recipient: "$finalRecipientPublicKey")',
        );
        return null;
      }

      // PHASE 2: Check message type eligibility before creating relay
      if (originalMessageType != null &&
          !RelayPolicy.isRelayEligibleMessageType(originalMessageType)) {
        _logger.warning(
          'Cannot create relay: Message type ${originalMessageType.name} is not relay-eligible',
        );
        return null;
      }

      // Spam prevention check for outgoing relays
      final canCreateRelay = await _spamPrevention.checkOutgoingRelay(
        senderNodeId: _currentNodeId,
        messageSize: originalContent.length,
      );

      if (!canCreateRelay.allowed) {
        _logger.warning('Outgoing relay blocked: ${canCreateRelay.reason}');
        return null;
      }

      // Create relay metadata
      final relayMetadata = RelayMetadata.create(
        originalMessageContent: originalContent,
        priority: priority,
        originalSender: _currentNodeId,
        finalRecipient: finalRecipientPublicKey,
        currentNodeId: _currentNodeId,
      );

      // PHASE 2: Create relay message with message type
      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        metadata: relayMetadata,
        relayNodeId: _currentNodeId,
        encryptedPayload: encryptedPayload,
        originalMessageType:
            originalMessageType, // PHASE 2: Include message type
      );

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final truncatedRecipient = finalRecipientPublicKey.length > 8
          ? finalRecipientPublicKey.shortId(8)
          : finalRecipientPublicKey;
      _logger.info(
        'Created outgoing relay for $truncatedMessageId... to $truncatedRecipient...',
      );

      return relayMessage;
    } catch (e) {
      _logger.severe('Failed to create outgoing relay: $e');
      return null;
    }
  }

  /// Check if current node should attempt to decrypt message (recipient optimization)
  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async {
    try {
      // Check if we are the final recipient
      if (await _decisionEngine.isMessageForCurrentNode(
        finalRecipientPublicKey,
      )) {
        return true;
      }

      // Check if we have a relationship with sender that might indicate
      // we could be an intended intermediate recipient
      if (_repositoryProvider != null) {
        final senderContact = await _repositoryProvider!.contactRepository
            .getContact(originalSenderPublicKey);
        if (senderContact != null &&
            senderContact.securityLevel != SecurityLevel.low) {
          return true;
        }

        // Check if we have a relationship with final recipient (could be group message)
        final recipientContact = await _repositoryProvider!.contactRepository
            .getContact(finalRecipientPublicKey);
        if (recipientContact != null) {
          return true;
        }
      }

      // Default: don't waste resources on decryption attempts
      return false;
    } catch (e) {
      _logger.warning('Error in decryption optimization: $e');
      return false; // Conservative approach
    }
  }

  /// Get relay engine statistics
  RelayStatistics getStatistics() {
    final spamStats = _spamPrevention.getStatistics();
    final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 0;
    final relayProbability = _decisionEngine.calculateRelayProbability();

    return RelayStatistics(
      totalRelayed: _totalRelayed,
      totalDropped: _totalDropped,
      totalDeliveredToSelf: _totalDeliveredToSelf,
      totalBlocked: spamStats.totalBlocked,
      totalProbabilisticSkip:
          _totalProbabilisticSkip, // Phase 3: Probabilistic skips
      spamScore: spamStats.averageSpamScore,
      relayEfficiency: _calculateRelayEfficiency(),
      activeRelayMessages: _getActiveRelayCount(),
      networkSize: networkSize, // Phase 3: Current network size
      currentRelayProbability:
          relayProbability, // Phase 3: Current relay probability
    );
  }

  /// Clear statistics (for testing)
  void clearStatistics() {
    _totalRelayed = 0;
    _totalDropped = 0;
    _totalDeliveredToSelf = 0;
    _totalProbabilisticSkip = 0;
    _spamPrevention.clearStatistics();
  }

  // Private methods

  /// Deliver message to current node
  Future<void> _deliverToCurrentNode(MeshRelayMessage relayMessage) async {
    try {
      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.shortId()
          : relayMessage.originalMessageId;
      _logger.info('Delivering message to self: $truncatedMessageId...');

      // Extract original content
      final originalContent = relayMessage.originalContent;
      final originalSender = relayMessage.relayMetadata.originalSender;
      final messageId = relayMessage.originalMessageIdValue;

      // Notify delivery
      onDeliverToSelf?.call(
        relayMessage.originalMessageId,
        originalContent,
        originalSender,
      );
      onDeliverToSelfIds?.call(messageId, originalContent, originalSender);
    } catch (e) {
      _logger.severe('Failed to deliver message to self: $e');
    }
  }

  /// Calculate relay efficiency
  double _calculateRelayEfficiency() {
    final totalProcessed =
        _totalRelayed + _totalDropped + _totalDeliveredToSelf;
    if (totalProcessed == 0) return 1.0;

    return (_totalRelayed + _totalDeliveredToSelf) / totalProcessed;
  }

  /// Get count of active relay messages in queue
  int _getActiveRelayCount() {
    // This would need to be implemented with queue integration
    // For now, return 0 as placeholder
    return 0;
  }

  /// Update statistics and notify listeners
  void _updateStatistics() {
    final stats = getStatistics();
    onStatsUpdated?.call(stats);
  }

  String? _getMyPersistentId() {
    if (GetIt.instance.isRegistered<IIdentityManager>()) {
      return GetIt.instance<IIdentityManager>().myPersistentId;
    }
    return null;
  }
}

/// Result of relay processing
class RelayProcessingResult {
  final RelayProcessingType type;
  final String? content;
  final String? nextHopNodeId;
  final String? reason;

  const RelayProcessingResult._(
    this.type,
    this.content,
    this.nextHopNodeId,
    this.reason,
  );

  factory RelayProcessingResult.deliveredToSelf(String content) =>
      RelayProcessingResult._(
        RelayProcessingType.deliveredToSelf,
        content,
        null,
        null,
      );

  factory RelayProcessingResult.relayed(String nextHopNodeId) =>
      RelayProcessingResult._(
        RelayProcessingType.relayed,
        null,
        nextHopNodeId,
        null,
      );

  factory RelayProcessingResult.dropped(String reason) =>
      RelayProcessingResult._(RelayProcessingType.dropped, null, null, reason);

  factory RelayProcessingResult.blocked(String reason) =>
      RelayProcessingResult._(RelayProcessingType.blocked, null, null, reason);

  factory RelayProcessingResult.error(String reason) =>
      RelayProcessingResult._(RelayProcessingType.error, null, null, reason);

  bool get isSuccess =>
      type == RelayProcessingType.deliveredToSelf ||
      type == RelayProcessingType.relayed;
  bool get isDelivered => type == RelayProcessingType.deliveredToSelf;
  bool get isRelayed => type == RelayProcessingType.relayed;
  bool get isBlocked =>
      type == RelayProcessingType.blocked ||
      type == RelayProcessingType.dropped;
}

/// Type of relay processing result
enum RelayProcessingType { deliveredToSelf, relayed, dropped, blocked, error }

/// Relay decision information
class RelayDecision {
  final RelayDecisionType type;
  final String messageId;
  final String? nextHopNodeId;
  final String? finalRecipient;
  final String reason;
  final int hopCount;
  final double? spamScore;
  final DateTime timestamp;

  RelayDecision._({
    required this.type,
    required this.messageId,
    required this.reason,
    this.nextHopNodeId,
    this.finalRecipient,
    this.hopCount = 0,
    this.spamScore,
  }) : timestamp = DateTime.now();

  factory RelayDecision.relayed({
    required String messageId,
    required String nextHopNodeId,
    required int hopCount,
  }) => RelayDecision._(
    type: RelayDecisionType.relayed,
    messageId: messageId,
    nextHopNodeId: nextHopNodeId,
    hopCount: hopCount,
    reason: 'Message relayed to next hop',
  );

  factory RelayDecision.delivered({
    required String messageId,
    required String finalRecipient,
  }) => RelayDecision._(
    type: RelayDecisionType.delivered,
    messageId: messageId,
    finalRecipient: finalRecipient,
    reason: 'Message delivered to final recipient',
  );

  factory RelayDecision.dropped({
    required String messageId,
    required String reason,
  }) => RelayDecision._(
    type: RelayDecisionType.dropped,
    messageId: messageId,
    reason: reason,
  );

  factory RelayDecision.blocked({
    required String messageId,
    required String reason,
    double? spamScore,
  }) => RelayDecision._(
    type: RelayDecisionType.blocked,
    messageId: messageId,
    reason: reason,
    spamScore: spamScore,
  );

  MessageId get messageIdValue => MessageId(messageId);
}

/// Type of relay decision
enum RelayDecisionType { relayed, delivered, dropped, blocked }

/// Relay engine statistics
class RelayStatistics {
  final int totalRelayed;
  final int totalDropped;
  final int totalDeliveredToSelf;
  final int totalBlocked;
  final int totalProbabilisticSkip; // Phase 3: Probabilistic relay skips
  final double spamScore;
  final double relayEfficiency;
  final int activeRelayMessages;
  final int networkSize; // Phase 3: Current network size
  final double currentRelayProbability; // Phase 3: Current relay probability

  const RelayStatistics({
    required this.totalRelayed,
    required this.totalDropped,
    required this.totalDeliveredToSelf,
    required this.totalBlocked,
    required this.totalProbabilisticSkip,
    required this.spamScore,
    required this.relayEfficiency,
    required this.activeRelayMessages,
    required this.networkSize,
    required this.currentRelayProbability,
  });

  int get totalProcessed => totalRelayed + totalDropped + totalDeliveredToSelf;

  @override
  String toString() =>
      'RelayStatistics('
      'relayed: $totalRelayed, '
      'dropped: $totalDropped, '
      'delivered: $totalDeliveredToSelf, '
      'blocked: $totalBlocked, '
      'probSkip: $totalProbabilisticSkip, '
      'efficiency: ${(relayEfficiency * 100).toStringAsFixed(1)}%, '
      'network: $networkSize nodes, '
      'relayProb: ${(currentRelayProbability * 100).toStringAsFixed(0)}%'
      ')';
}

/// Lightweight fallback seen-message store used when DI isn't configured (tests)
class _InMemorySeenMessageStore implements ISeenMessageStore {
  final Set<String> _delivered = <String>{};
  final Set<String> _read = <String>{};

  @override
  bool hasDelivered(String messageId) => _delivered.contains(messageId);

  @override
  bool hasRead(String messageId) => _read.contains(messageId);

  @override
  Future<void> markDelivered(String messageId) async {
    _delivered.add(messageId);
  }

  @override
  Future<void> markRead(String messageId) async {
    _read.add(messageId);
  }

  @override
  Map<String, dynamic> getStatistics() => {
    'delivered': _delivered.length,
    'read': _read.length,
  };

  @override
  Future<void> clear() async {
    _delivered.clear();
    _read.clear();
  }

  @override
  Future<void> performMaintenance() async {
    // No persistent state to maintain
  }
}
