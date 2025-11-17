// Core mesh relay engine that orchestrates A→B→C message forwarding
// Integrates spam prevention, recipient detection, and relay decision making
// Phase 1 (Role Awareness): Added explicit relay configuration and message type filtering
// Phase 3 (Network-Size Adaptive): Added probabilistic relay based on network size
// Priority 2: Broadcast messaging support (BitChat-inspired)

import 'dart:async';
import 'dart:math';
import 'package:logging/logging.dart';
import '../models/mesh_relay_models.dart';
import '../models/protocol_message.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/services/seen_message_store.dart';
import '../../domain/entities/enhanced_message.dart';
import '../services/security_manager.dart';
import '../security/ephemeral_key_manager.dart';
import 'offline_message_queue.dart';
import '../security/spam_prevention_manager.dart';
import '../routing/network_topology_analyzer.dart';
import '../interfaces/i_mesh_routing_service.dart';
import 'relay_config_manager.dart';
import 'relay_policy.dart';
import '../constants/special_recipients.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Core engine for mesh relay operations
class MeshRelayEngine {
  static final _logger = Logger('MeshRelayEngine');

  final ContactRepository _contactRepository;
  final OfflineMessageQueue _messageQueue;
  final SpamPreventionManager _spamPrevention;

  // Smart routing integration (via IMeshRoutingService interface)
  IMeshRoutingService? _routingService;

  // Phase 3: Network topology integration for adaptive relay
  NetworkTopologyAnalyzer? _topologyAnalyzer;

  // Relay configuration (Phase 1: Role Awareness)
  final RelayConfigManager _relayConfig = RelayConfigManager.instance;

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
  Function(RelayDecision decision)? onRelayDecision;
  Function(RelayStatistics stats)? onStatsUpdated;

  MeshRelayEngine({
    required ContactRepository contactRepository,
    required OfflineMessageQueue messageQueue,
    required SpamPreventionManager spamPrevention,
  }) : _contactRepository = contactRepository,
       _messageQueue = messageQueue,
       _spamPrevention = spamPrevention;

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
    this.onRelayMessage = onRelayMessage;
    this.onDeliverToSelf = onDeliverToSelf;
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
      final seenStore = SeenMessageStore.instance;
      if (seenStore.hasDelivered(relayMessage.originalMessageId)) {
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
          messageId: relayMessage.originalMessageId,
          reason: spamCheck.reason,
          spamScore: spamCheck.spamScore,
        );

        onRelayDecision?.call(decision);
        _updateStatistics();

        return RelayProcessingResult.blocked(spamCheck.reason);
      }

      // Determine message targeting before probabilistic decisions
      final isForUs = await _isMessageForCurrentNode(
        relayMessage.relayMetadata.finalRecipient,
      );

      final isBroadcast = SpecialRecipients.isBroadcast(
        relayMessage.relayMetadata.finalRecipient,
      );

      // Step 1A: Probabilistic relay decision (Phase 3: Network-size adaptive)
      // Apply BEFORE checking if message is for us to reduce processing overhead
      final relayProbability = _calculateRelayProbability();
      final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 1;

      if (!isForUs && relayProbability < 1.0) {
        final randomValue = Random().nextDouble();
        if (randomValue > relayProbability) {
          _totalProbabilisticSkip++;
          _logger.info(
            '🎲 Probabilistic relay SKIP (network: $networkSize nodes, prob: ${(relayProbability * 100).toStringAsFixed(0)}%, roll: ${(randomValue * 100).toStringAsFixed(0)}%)',
          );

          final decision = RelayDecision.dropped(
            messageId: relayMessage.originalMessageId,
            reason: 'Probabilistic skip (network size: $networkSize)',
          );

          onRelayDecision?.call(decision);
          _updateStatistics();

          return RelayProcessingResult.dropped('Probabilistic relay skip');
        } else {
          _logger.fine(
            '🎲 Probabilistic relay PASS (network: $networkSize nodes, prob: ${(relayProbability * 100).toStringAsFixed(0)}%, roll: ${(randomValue * 100).toStringAsFixed(0)}%)',
          );
        }
      }

      // Step 2: Check if we are the final recipient
      if (isForUs) {
        await _deliverToCurrentNode(relayMessage);
        _totalDeliveredToSelf++;

        // Mark as delivered in persistent store
        final seenStore = SeenMessageStore.instance;
        await seenStore.markDelivered(relayMessage.originalMessageId);

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
        await _broadcastToAllNeighbors(relayMessage, availableNextHops);
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
        final nextHop = await _chooseNextHop(
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
        await _relayToNextHop(relayMessage, nextHop);
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
      if (await _isMessageForCurrentNode(finalRecipientPublicKey)) {
        return true;
      }

      // Check if we have a relationship with sender that might indicate
      // we could be an intended intermediate recipient
      final senderContact = await _contactRepository.getContact(
        originalSenderPublicKey,
      );
      if (senderContact != null &&
          senderContact.securityLevel != SecurityLevel.low) {
        return true;
      }

      // Check if we have a relationship with final recipient (could be group message)
      final recipientContact = await _contactRepository.getContact(
        finalRecipientPublicKey,
      );
      if (recipientContact != null) {
        return true;
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
    final relayProbability = _calculateRelayProbability();

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

  /// Calculate relay probability based on network size
  ///
  /// Phase 3: Network-size adaptive relay (inspired by BitChat Android)
  /// Prevents broadcast storms in large networks by scaling relay probability
  ///
  /// Probability scale:
  /// - Small networks (≤3 nodes): 100% - always relay (critical for connectivity)
  /// - Medium networks (≤10 nodes): 100% - full relay for reliability
  /// - Growing networks (≤30 nodes): 85% - start reducing relay load
  /// - Large networks (≤50 nodes): 70% - further reduce broadcast traffic
  /// - Very large (≤100 nodes): 55% - significant reduction
  /// - Massive networks (>100 nodes): 40% - minimum relay to prevent storms
  double _calculateRelayProbability() {
    final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 1;

    // Small networks: always relay (critical for connectivity)
    if (networkSize <= 3) return 1.0;

    // Adaptive relay probability based on network size
    if (networkSize <= 10) return 1.0; // Still small, full relay
    if (networkSize <= 30) return 0.85; // Growing network
    if (networkSize <= 50) return 0.7; // Large network
    if (networkSize <= 100) return 0.55; // Very large
    return 0.4; // Massive network - prevent broadcast storms
  }

  /// Check if message is for current node
  ///
  /// Phase 1 (Role Awareness): Enhanced with ephemeral key checking and broadcast handling
  /// Priority 2 (Broadcast): Broadcast messages delivered to ALL nodes
  /// Inspired by BitChat's isPacketAddressedToMe() method
  Future<bool> _isMessageForCurrentNode(String finalRecipientPublicKey) async {
    // Priority 2: Broadcast messages are for EVERYONE (including us)
    if (SpecialRecipients.isBroadcast(finalRecipientPublicKey)) {
      _logger.info('📣 Broadcast message - delivering to self AND forwarding');
      return true; // Always deliver broadcast locally
    }

    // Handle null/empty recipient (reject - must use explicit broadcast sentinel)
    if (finalRecipientPublicKey.isEmpty) {
      _logger.fine(
        '📭 No recipient specified - rejecting (use broadcast sentinel)',
      );
      return false;
    }

    // Check 1: Match persistent public key
    if (finalRecipientPublicKey == _currentNodeId) {
      _logger.info('✅ Message IS for current node (persistent key match)');
      return true;
    }

    // Check 2: Match ephemeral session key
    final ephemeralKey = EphemeralKeyManager.currentSessionKey;
    if (ephemeralKey != null && finalRecipientPublicKey == ephemeralKey) {
      _logger.info('✅ Message IS for current node (ephemeral key match)');
      return true;
    }

    // Check 3: Match ephemeral signing public key
    final ephemeralSigningKey = EphemeralKeyManager.ephemeralSigningPublicKey;
    if (ephemeralSigningKey != null &&
        finalRecipientPublicKey == ephemeralSigningKey) {
      _logger.info(
        '✅ Message IS for current node (ephemeral signing key match)',
      );
      return true;
    }

    // No match - message is NOT for us
    final truncatedRecipient = finalRecipientPublicKey.length > 16
        ? finalRecipientPublicKey.shortId()
        : finalRecipientPublicKey;
    final truncatedNodeId = _currentNodeId.length > 16
        ? _currentNodeId.shortId()
        : _currentNodeId;

    _logger.fine('📭 Message NOT for current node:');
    _logger.fine('   - Recipient: $truncatedRecipient...');
    _logger.fine('   - Our persistent key: $truncatedNodeId...');
    _logger.fine(
      '   - Our ephemeral key: ${ephemeralKey?.shortId() ?? "NULL"}...',
    );

    return false;
  }

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

      // Notify delivery
      onDeliverToSelf?.call(
        relayMessage.originalMessageId,
        originalContent,
        originalSender,
      );
    } catch (e) {
      _logger.severe('Failed to deliver message to self: $e');
    }
  }

  /// Choose next hop for relay using smart routing
  Future<String?> _chooseNextHop({
    required MeshRelayMessage relayMessage,
    required List<String> availableHops,
  }) async {
    if (availableHops.isEmpty) {
      return null;
    }

    try {
      // Filter out hops already in routing path (loop prevention)
      final validHops = availableHops
          .where((hop) => !relayMessage.relayMetadata.hasNodeInPath(hop))
          .toList();

      if (validHops.isEmpty) {
        _logger.warning('All available hops would create loops');
        return null;
      }

      // Use routing service if available
      if (_routingService != null) {
        try {
          _logger.info('🧠 Using routing service for next hop selection');

          final routingDecision = await _routingService!.determineOptimalRoute(
            finalRecipient: relayMessage.relayMetadata.finalRecipient,
            availableHops: validHops,
            priority: relayMessage.relayMetadata.priority,
          );

          if (routingDecision.isSuccessful && routingDecision.nextHop != null) {
            final truncatedNextHop = routingDecision.nextHop!.length > 8
                ? routingDecision.nextHop!.shortId(8)
                : routingDecision.nextHop!;
            _logger.info(
              '✅ Routing service chose: $truncatedNextHop... (score: ${routingDecision.routeScore?.toStringAsFixed(2)})',
            );
            return routingDecision.nextHop;
          } else {
            _logger.warning(
              '⚠️ Routing service failed: ${routingDecision.reason}',
            );
          }
        } catch (e) {
          _logger.warning(
            'Smart router error: $e - falling back to simple selection',
          );
        }
      }

      // Fallback to enhanced simple selection
      final chosenHop = await _selectBestHopByQuality(validHops);

      final truncatedChosenHop = chosenHop.length > 8
          ? chosenHop.shortId(8)
          : chosenHop;
      _logger.info(
        '📍 Selected hop: $truncatedChosenHop... from ${validHops.length} valid options',
      );
      return chosenHop;
    } catch (e) {
      _logger.severe('Failed to choose next hop: $e');
      return null;
    }
  }

  /// Select best hop by quality metrics (fallback when smart router not available)
  Future<String> _selectBestHopByQuality(List<String> validHops) async {
    if (validHops.length == 1) {
      return validHops.first;
    }

    // For now, use simple first selection
    // In a more sophisticated implementation, this could use basic quality heuristics
    return validHops.first;
  }

  /// Relay message to next hop (point-to-point)
  Future<void> _relayToNextHop(
    MeshRelayMessage relayMessage,
    String nextHopNodeId,
  ) async {
    try {
      // Create next hop relay message
      final nextHopMessage = relayMessage.nextHop(nextHopNodeId);

      // Record relay operation for spam prevention
      await _spamPrevention.recordRelayOperation(
        fromNodeId: relayMessage.relayNodeId,
        toNodeId: nextHopNodeId,
        messageHash: relayMessage.relayMetadata.messageHash,
        messageSize: relayMessage.messageSize,
      );

      // 🎯 CRITICAL FIX: Preserve original sender identity through relay chain
      await _messageQueue.queueMessage(
        chatId: 'mesh_relay_$nextHopNodeId',
        content: nextHopMessage.originalContent,
        recipientPublicKey: nextHopNodeId,
        senderPublicKey: nextHopMessage
            .relayMetadata
            .originalSender, // ✅ Use original sender, not relay node
        priority: nextHopMessage.relayMetadata.priority,
      );

      // Notify relay
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

  /// Broadcast message to all neighbors (Priority 2: Broadcast messaging)
  ///
  /// Forwards broadcast message to ALL connected neighbors, with:
  /// - Loop prevention (skip nodes already in routing path)
  /// - Deduplication (handled by SeenMessageStore)
  /// - Spam prevention (recorded for each neighbor)
  ///
  /// Inspired by BitChat's broadcast packet forwarding
  Future<void> _broadcastToAllNeighbors(
    MeshRelayMessage relayMessage,
    List<String> availableNeighbors,
  ) async {
    try {
      // Filter out neighbors already in routing path (loop prevention)
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

      // Broadcast to each neighbor
      for (final neighborId in validNeighbors) {
        try {
          // Create next hop message for this neighbor
          final nextHopMessage = relayMessage.nextHop(neighborId);

          // Record relay operation for spam prevention
          await _spamPrevention.recordRelayOperation(
            fromNodeId: relayMessage.relayNodeId,
            toNodeId: neighborId,
            messageHash: relayMessage.relayMetadata.messageHash,
            messageSize: relayMessage.messageSize,
          );

          // Queue message for this neighbor
          await _messageQueue.queueMessage(
            chatId: 'broadcast_relay_$neighborId',
            content: nextHopMessage.originalContent,
            recipientPublicKey: neighborId,
            senderPublicKey: nextHopMessage
                .relayMetadata
                .originalSender, // Preserve original sender
            priority: nextHopMessage.relayMetadata.priority,
          );

          // Notify relay
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
          // Continue broadcasting to other neighbors
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
