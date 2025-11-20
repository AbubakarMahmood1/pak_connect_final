import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/interfaces/i_mesh_ble_service.dart';
import 'package:pak_connect/core/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/routing/network_topology_analyzer.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';

typedef RelayStatsCallback = void Function(RelayStatistics stats);
typedef RelayDecisionCallback = void Function(RelayDecision decision);
typedef DeliverToSelfCallback =
    Future<void> Function(
      String originalMessageId,
      String content,
      String originalSender,
    );
typedef MeshRelayEngineFactory =
    MeshRelayEngine Function(
      OfflineMessageQueue queue,
      SpamPreventionManager spamPrevention,
    );

/// Coordinates MeshRelayEngine, routing services, and relay-specific decisions.
///
/// MeshNetworkingService delegates all relay responsibilities here so it can
/// focus on orchestration and queue/health concerns.
class MeshRelayCoordinator {
  final Logger _logger;
  final IMeshBleService _bleService;
  final RelayDecisionCallback _onRelayDecision;
  final RelayStatsCallback _onRelayStatsUpdated;
  final DeliverToSelfCallback _onDeliverToSelf;
  final MeshRelayEngineFactory _relayEngineFactory;

  MeshRelayEngine? _relayEngine;
  IMeshRoutingService? _routingService;
  NetworkTopologyAnalyzer? _topologyAnalyzer;
  OfflineMessageQueue? _messageQueue;
  SpamPreventionManager? _spamPrevention;
  String? _currentNodeId;

  MeshRelayCoordinator({
    required IMeshBleService bleService,
    required RelayDecisionCallback onRelayDecision,
    required RelayStatsCallback onRelayStatsUpdated,
    required DeliverToSelfCallback onDeliverToSelf,
    MeshRelayEngineFactory? relayEngineFactory,
    Logger? logger,
  }) : _bleService = bleService,
       _onRelayDecision = onRelayDecision,
       _onRelayStatsUpdated = onRelayStatsUpdated,
       _onDeliverToSelf = onDeliverToSelf,
       _logger = logger ?? Logger('MeshRelayCoordinator'),
       _relayEngineFactory =
           relayEngineFactory ??
           ((queue, spam) =>
               MeshRelayEngine(messageQueue: queue, spamPrevention: spam));

  /// Initialize relay dependencies and smart routing.
  Future<void> initialize({
    required String nodeId,
    required OfflineMessageQueue messageQueue,
    required SpamPreventionManager spamPrevention,
  }) async {
    _currentNodeId = nodeId;
    _messageQueue = messageQueue;
    _spamPrevention = spamPrevention;

    await _initializeSmartRouting();

    _relayEngine ??= _relayEngineFactory(messageQueue, spamPrevention);
    await _relayEngine!.initialize(
      currentNodeId: nodeId,
      routingService: _routingService,
      topologyAnalyzer: _topologyAnalyzer,
      onRelayMessage: _handleRelayMessage,
      onDeliverToSelf: _onDeliverToSelf,
      onRelayDecision: _onRelayDecision,
      onStatsUpdated: _onRelayStatsUpdated,
    );
  }

  /// Route a message through the mesh network.
  Future<MeshSendResult> sendRelayMessage({
    required String content,
    required String recipientPublicKey,
    required String chatId,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (_messageQueue == null || _currentNodeId == null) {
      return MeshSendResult.error('Relay coordinator not initialized');
    }

    try {
      final originalMessageId = DateTime.now().millisecondsSinceEpoch
          .toString();
      final nextHops = await getAvailableNextHops();
      if (nextHops.isEmpty) {
        return MeshSendResult.error('No next hops available for relay');
      }

      String selectedNextHop = nextHops.first;
      double routeScore = 0.5;

      if (_routingService != null) {
        try {
          _logger.info('🧠 Using routing service for message routing');
          final decision = await _routingService!.determineOptimalRoute(
            finalRecipient: recipientPublicKey,
            availableHops: nextHops,
            priority: priority,
          );

          if (decision.isSuccessful && decision.nextHop != null) {
            selectedNextHop = decision.nextHop!;
            routeScore = decision.routeScore ?? 0.75;
            _logger.info(
              'Smart route selected: ${selectedNextHop.shortId(8)}... (score: ${routeScore.toStringAsFixed(2)})',
            );
          }
        } catch (e) {
          _logger.warning('Routing service failed - using fallback: $e');
        }
      }

      // Build relay metadata
      final metadata = RelayMetadata.create(
        originalMessageContent: content,
        priority: priority,
        originalSender: _currentNodeId!,
        finalRecipient: recipientPublicKey,
        currentNodeId: _currentNodeId!,
      );

      final relayMessage = MeshRelayMessage.createRelay(
        originalMessageId: originalMessageId,
        originalContent: content,
        metadata: metadata,
        relayNodeId: _currentNodeId!,
      );

      final queuedMessage = QueuedMessage.fromRelayMessage(
        relayMessage: relayMessage,
        chatId: 'mesh_relay_$selectedNextHop',
        maxRetries: 3,
      );

      await _messageQueue!.queueMessage(
        chatId: queuedMessage.chatId,
        content: queuedMessage.content,
        recipientPublicKey: queuedMessage.recipientPublicKey,
        senderPublicKey: queuedMessage.senderPublicKey,
        priority: priority,
      );

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final truncatedNextHop = selectedNextHop.length > 8
          ? selectedNextHop.shortId(8)
          : selectedNextHop;
      _logger.info(
        'Message queued for smart mesh relay: $truncatedMessageId... -> $truncatedNextHop... (score: ${routeScore.toStringAsFixed(2)})',
      );
      return MeshSendResult.relay(originalMessageId, selectedNextHop);
    } catch (e) {
      return MeshSendResult.error('Smart relay send failed: $e');
    }
  }

  /// Determine whether a pending message should relay through [deviceId].
  Future<bool> shouldRelayThroughDevice(
    QueuedMessage message,
    String deviceId,
  ) async {
    if (_currentNodeId == null) {
      return false;
    }

    try {
      final finalRecipient = message.recipientPublicKey;
      if (finalRecipient == deviceId) {
        return false;
      }

      if (_bleService.currentSessionId == finalRecipient) {
        return false;
      }

      if (message.isRelayMessage && message.relayMetadata != null) {
        if (message.relayMetadata!.hasNodeInPath(deviceId)) {
          return false;
        }

        if (!message.relayMetadata!.canRelay) {
          return false;
        }
      }

      if (_routingService != null) {
        try {
          final decision = await _routingService!.determineOptimalRoute(
            finalRecipient: finalRecipient,
            availableHops: [deviceId],
            priority: message.priority,
          );

          if (decision.isSuccessful && decision.nextHop == deviceId) {
            return true;
          }
        } catch (e) {
          _logger.fine('Routing service check failed, using fallback: $e');
        }
      }

      final isDeviceConnected = _bleService.currentSessionId == deviceId;
      final cannotReachRecipientDirectly =
          _bleService.currentSessionId != finalRecipient;
      return isDeviceConnected && cannotReachRecipientDirectly;
    } catch (e) {
      _logger.warning('Error checking relay route: $e');
      return false;
    }
  }

  /// Connected peers that are viable relay hops.
  Future<List<String>> getAvailableNextHops() async {
    final List<String> nextHops = [];
    final connectionInfo = _bleService.currentConnectionInfo;

    if (connectionInfo != null &&
        connectionInfo.isConnected &&
        connectionInfo.isReady) {
      final connectedNodeId = _bleService.currentSessionId;
      if (connectedNodeId != null && connectedNodeId.isNotEmpty) {
        nextHops.add(connectedNodeId);
      }
    }

    return nextHops;
  }

  /// Returns latest relay statistics for network status reporting.
  RelayStatistics? get relayStatistics => _relayEngine?.getStatistics();

  /// Clean up relay resources.
  void dispose() {
    _relayEngine = null;
    _routingService?.dispose();
    _routingService = null;
    _topologyAnalyzer?.dispose();
    _topologyAnalyzer = null;
    _messageQueue = null;
    _spamPrevention = null;
  }

  Future<void> _initializeSmartRouting() async {
    try {
      _topologyAnalyzer?.dispose();
      _topologyAnalyzer = NetworkTopologyAnalyzer();

      _routingService ??= GetIt.instance<IMeshRoutingService>();
      await _routingService!.initialize(
        currentNodeId: _currentNodeId!,
        topologyAnalyzer: _topologyAnalyzer!,
      );

      _logger.info('✅ Smart routing components initialized');
    } catch (e) {
      _logger.severe('❌ Failed to initialize smart routing: $e');
      _routingService = null;
      _topologyAnalyzer?.dispose();
      _topologyAnalyzer = null;
    }
  }

  void _handleRelayMessage(MeshRelayMessage message, String nextHopNodeId) {
    final truncatedMessageId = message.originalMessageId.length > 16
        ? message.originalMessageId.shortId()
        : message.originalMessageId;
    final truncatedNextHop = nextHopNodeId.length > 8
        ? nextHopNodeId.shortId(8)
        : nextHopNodeId;
    _logger.info(
      'Relay message to next hop: $truncatedMessageId... -> $truncatedNextHop...',
    );
  }
}
