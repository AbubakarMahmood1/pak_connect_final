// Core mesh relay engine that orchestrates A→B→C message forwarding
// Integrates spam prevention, recipient detection, and relay decision making

import 'dart:async';
import 'package:logging/logging.dart';
import '../models/mesh_relay_models.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/enhanced_message.dart';
import '../services/security_manager.dart';
import 'offline_message_queue.dart';
import '../security/spam_prevention_manager.dart';
import '../routing/smart_mesh_router.dart';

/// Core engine for mesh relay operations
class MeshRelayEngine {
  static final _logger = Logger('MeshRelayEngine');
  
  final ContactRepository _contactRepository;
  final OfflineMessageQueue _messageQueue;
  final SpamPreventionManager _spamPrevention;
  
  // Smart routing integration
  SmartMeshRouter? _smartRouter;

  // Node identification (NOT final to allow re-initialization in tests and node identity changes)
  late String _currentNodeId;

  // Relay statistics
  int _totalRelayed = 0;
  int _totalDropped = 0;
  int _totalDeliveredToSelf = 0;
  
  // Callbacks for integration
  Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage;
  Function(String originalMessageId, String content, String originalSender)? onDeliverToSelf;
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
  Future<void> initialize({
    required String currentNodeId,
    SmartMeshRouter? smartRouter,
    Function(MeshRelayMessage message, String nextHopNodeId)? onRelayMessage,
    Function(String originalMessageId, String content, String originalSender)? onDeliverToSelf,
    Function(RelayDecision decision)? onRelayDecision,
    Function(RelayStatistics stats)? onStatsUpdated,
  }) async {
    _currentNodeId = currentNodeId;
    _smartRouter = smartRouter;
    this.onRelayMessage = onRelayMessage;
    this.onDeliverToSelf = onDeliverToSelf;
    this.onRelayDecision = onRelayDecision;
    this.onStatsUpdated = onStatsUpdated;

    final truncatedNodeId = _currentNodeId.length > 16 ? _currentNodeId.substring(0, 16) : _currentNodeId;
    _logger.info('🔧 MeshRelayEngine (RE)INITIALIZED for node: $truncatedNodeId... (smart routing: ${_smartRouter != null})');
    // ignore: avoid_print
    print('📡 RELAY ENGINE: Node ID set to $truncatedNodeId... | Smart Routing: ${_smartRouter != null}');
  }

  /// Process incoming relay message and decide what to do
  Future<RelayProcessingResult> processIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    List<String> availableNextHops = const [],
  }) async {
    try {
      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.substring(0, 16)
          : relayMessage.originalMessageId;
      final truncatedFromNode = fromNodeId.length > 8
          ? fromNodeId.substring(0, 8)
          : fromNodeId;
      _logger.info('Processing relay message $truncatedMessageId... from $truncatedFromNode...');
      
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
      
      // Step 2: Check if we are the final recipient
      final isForUs = await _isMessageForCurrentNode(
        relayMessage.relayMetadata.finalRecipient,
      );
      
      if (isForUs) {
        await _deliverToCurrentNode(relayMessage);
        _totalDeliveredToSelf++;
        
        final decision = RelayDecision.delivered(
          messageId: relayMessage.originalMessageId,
          finalRecipient: _currentNodeId,
        );
        
        onRelayDecision?.call(decision);
        _updateStatistics();
        
        return RelayProcessingResult.deliveredToSelf(relayMessage.originalContent);
      }
      
      // Step 3: Check if message can be relayed further
      if (!relayMessage.canRelay) {
        _totalDropped++;
        final decision = RelayDecision.dropped(
          messageId: relayMessage.originalMessageId,
          reason: 'TTL exceeded (${relayMessage.relayMetadata.hopCount}/${relayMessage.relayMetadata.ttl})',
        );
        
        onRelayDecision?.call(decision);
        _updateStatistics();
        
        return RelayProcessingResult.dropped('Message TTL exceeded');
      }
      
      // Step 4: Choose next hop and relay
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
      
    } catch (e) {
      _logger.severe('Failed to process relay message: $e');
      _totalDropped++;
      _updateStatistics();
      return RelayProcessingResult.error('Processing failed: $e');
    }
  }

  /// Create new relay message for outgoing message
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? encryptedPayload,
  }) async {
    try {
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
      
      // Create relay message
      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        metadata: relayMetadata,
        relayNodeId: _currentNodeId,
        encryptedPayload: encryptedPayload,
      );
      
      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.substring(0, 16)
          : originalMessageId;
      final truncatedRecipient = finalRecipientPublicKey.length > 8
          ? finalRecipientPublicKey.substring(0, 8)
          : finalRecipientPublicKey;
      _logger.info('Created outgoing relay for $truncatedMessageId... to $truncatedRecipient...');
      
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
      final senderContact = await _contactRepository.getContact(originalSenderPublicKey);
      if (senderContact != null && senderContact.securityLevel != SecurityLevel.low) {
        return true;
      }
      
      // Check if we have a relationship with final recipient (could be group message)
      final recipientContact = await _contactRepository.getContact(finalRecipientPublicKey);
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
    
    return RelayStatistics(
      totalRelayed: _totalRelayed,
      totalDropped: _totalDropped,
      totalDeliveredToSelf: _totalDeliveredToSelf,
      totalBlocked: spamStats.totalBlocked,
      spamScore: spamStats.averageSpamScore,
      relayEfficiency: _calculateRelayEfficiency(),
      activeRelayMessages: _getActiveRelayCount(),
    );
  }

  /// Clear statistics (for testing)
  void clearStatistics() {
    _totalRelayed = 0;
    _totalDropped = 0;
    _totalDeliveredToSelf = 0;
    _spamPrevention.clearStatistics();
  }

  // Private methods

  /// Check if message is for current node
  Future<bool> _isMessageForCurrentNode(String finalRecipientPublicKey) async {
    return finalRecipientPublicKey == _currentNodeId;
  }

  /// Deliver message to current node
  Future<void> _deliverToCurrentNode(MeshRelayMessage relayMessage) async {
    try {
      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.substring(0, 16)
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
      
      // Use smart router if available
      if (_smartRouter != null) {
        try {
          _logger.info('🧠 Using smart router for next hop selection');
          
          final routingDecision = await _smartRouter!.determineOptimalRoute(
            finalRecipient: relayMessage.relayMetadata.finalRecipient,
            availableHops: validHops,
            priority: relayMessage.relayMetadata.priority,
          );
          
          if (routingDecision.isSuccessful && routingDecision.nextHop != null) {
            final truncatedNextHop = routingDecision.nextHop!.length > 8
                ? routingDecision.nextHop!.substring(0, 8)
                : routingDecision.nextHop!;
            _logger.info('✅ Smart router chose: $truncatedNextHop... (score: ${routingDecision.routeScore?.toStringAsFixed(2)})');
            return routingDecision.nextHop;
          } else {
            _logger.warning('⚠️ Smart router failed: ${routingDecision.reason}');
          }
          
        } catch (e) {
          _logger.warning('Smart router error: $e - falling back to simple selection');
        }
      }
      
      // Fallback to enhanced simple selection
      final chosenHop = await _selectBestHopByQuality(validHops);
      
      final truncatedChosenHop = chosenHop.length > 8
          ? chosenHop.substring(0, 8)
          : chosenHop;
      _logger.info('📍 Selected hop: $truncatedChosenHop... from ${validHops.length} valid options');
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

  /// Relay message to next hop
  Future<void> _relayToNextHop(MeshRelayMessage relayMessage, String nextHopNodeId) async {
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
        senderPublicKey: nextHopMessage.relayMetadata.originalSender,  // ✅ Use original sender, not relay node
        priority: nextHopMessage.relayMetadata.priority,
      );
      
      // Notify relay
      onRelayMessage?.call(nextHopMessage, nextHopNodeId);
      
      final truncatedMessageId = relayMessage.originalMessageId.length > 16
          ? relayMessage.originalMessageId.substring(0, 16)
          : relayMessage.originalMessageId;
      final truncatedNextHop = nextHopNodeId.length > 8
          ? nextHopNodeId.substring(0, 8)
          : nextHopNodeId;
      _logger.info('Relayed message $truncatedMessageId... to $truncatedNextHop...');
      
    } catch (e) {
      _logger.severe('Failed to relay to next hop: $e');
      throw RelayException('Failed to relay message: $e');
    }
  }

  /// Calculate relay efficiency
  double _calculateRelayEfficiency() {
    final totalProcessed = _totalRelayed + _totalDropped + _totalDeliveredToSelf;
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

  const RelayProcessingResult._(this.type, this.content, this.nextHopNodeId, this.reason);

  factory RelayProcessingResult.deliveredToSelf(String content) =>
      RelayProcessingResult._(RelayProcessingType.deliveredToSelf, content, null, null);
  
  factory RelayProcessingResult.relayed(String nextHopNodeId) =>
      RelayProcessingResult._(RelayProcessingType.relayed, null, nextHopNodeId, null);
  
  factory RelayProcessingResult.dropped(String reason) =>
      RelayProcessingResult._(RelayProcessingType.dropped, null, null, reason);
  
  factory RelayProcessingResult.blocked(String reason) =>
      RelayProcessingResult._(RelayProcessingType.blocked, null, null, reason);
  
  factory RelayProcessingResult.error(String reason) =>
      RelayProcessingResult._(RelayProcessingType.error, null, null, reason);

  bool get isSuccess => type == RelayProcessingType.deliveredToSelf || type == RelayProcessingType.relayed;
  bool get isDelivered => type == RelayProcessingType.deliveredToSelf;
  bool get isRelayed => type == RelayProcessingType.relayed;
  bool get isBlocked => type == RelayProcessingType.blocked || type == RelayProcessingType.dropped;
}

/// Type of relay processing result
enum RelayProcessingType {
  deliveredToSelf,
  relayed,
  dropped,
  blocked,
  error,
}

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
enum RelayDecisionType {
  relayed,
  delivered,
  dropped,
  blocked,
}

/// Relay engine statistics
class RelayStatistics {
  final int totalRelayed;
  final int totalDropped;
  final int totalDeliveredToSelf;
  final int totalBlocked;
  final double spamScore;
  final double relayEfficiency;
  final int activeRelayMessages;

  const RelayStatistics({
    required this.totalRelayed,
    required this.totalDropped,
    required this.totalDeliveredToSelf,
    required this.totalBlocked,
    required this.spamScore,
    required this.relayEfficiency,
    required this.activeRelayMessages,
  });

  int get totalProcessed => totalRelayed + totalDropped + totalDeliveredToSelf;
  
  @override
  String toString() => 'RelayStatistics('
      'relayed: $totalRelayed, '
      'dropped: $totalDropped, '
      'delivered: $totalDeliveredToSelf, '
      'blocked: $totalBlocked, '
      'efficiency: ${(relayEfficiency * 100).toStringAsFixed(1)}%'
      ')';
}