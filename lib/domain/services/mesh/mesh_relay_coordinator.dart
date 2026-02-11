import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/protocol_message_type.dart';

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
      OfflineMessageQueueContract queue,
      SpamPreventionManager spamPrevention,
    );

/// Coordinates MeshRelayEngine, routing services, and relay-specific decisions.
///
/// MeshNetworkingService delegates all relay responsibilities here so it can
/// focus on orchestration and queue/health concerns.
class MeshRelayCoordinator {
  final Logger _logger;
  final IConnectionService _bleService;
  final RelayDecisionCallback _onRelayDecision;
  final RelayStatsCallback _onRelayStatsUpdated;
  final DeliverToSelfCallback _onDeliverToSelf;
  final MeshRelayEngineFactory? _relayEngineFactory;

  MeshRelayEngine? _relayEngine;
  OfflineMessageQueueContract? _messageQueue;
  String? _currentNodeId;

  MeshRelayCoordinator({
    required IConnectionService bleService,
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
       _relayEngineFactory = relayEngineFactory;

  /// Initialize relay dependencies and smart routing.
  Future<void> initialize({
    required String nodeId,
    required OfflineMessageQueueContract messageQueue,
    required SpamPreventionManager spamPrevention,
  }) async {
    _currentNodeId = nodeId;
    _messageQueue = messageQueue;

    _relayEngine ??= _createRelayEngine(messageQueue, spamPrevention);
    await _relayEngine!.initialize(
      currentNodeId: nodeId,
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

      final relayMessage = await _relayEngine!.createOutgoingRelay(
        originalMessageId: originalMessageId,
        originalContent: content,
        finalRecipientPublicKey: recipientPublicKey,
        priority: priority,
        originalMessageType: ProtocolMessageType.textMessage,
      );

      if (relayMessage == null) {
        return MeshSendResult.error('Failed to create relay payload');
      }

      final processingResult = await _relayEngine!.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: _currentNodeId!,
        availableNextHops: nextHops,
        messageType: ProtocolMessageType.textMessage,
      );

      if (!processingResult.isSuccess) {
        return MeshSendResult.error(
          processingResult.reason ?? 'Relay processing failed',
        );
      }

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final hopSummary = 'ALL_NEIGHBORS(${nextHops.length})';
      _logger.info(
        'Message queued for flood relay: $truncatedMessageId... -> $hopSummary',
      );
      return MeshSendResult.relay(originalMessageId, hopSummary);
    } catch (e) {
      return MeshSendResult.error('Flood relay send failed: $e');
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

      final connectedHops = await getAvailableNextHops();
      final isDeviceConnected = connectedHops.contains(deviceId);
      if (!isDeviceConnected) return false;

      final isDirectRecipient = deviceId == finalRecipient;
      return !isDirectRecipient;
    } catch (e) {
      _logger.warning('Error checking relay route: $e');
      return false;
    }
  }

  /// Connected peers that are viable relay hops.
  Future<List<String>> getAvailableNextHops() async {
    final hops = <String>{};
    final connectedNodeId = _bleService.currentSessionId;
    if (connectedNodeId != null && connectedNodeId.isNotEmpty) {
      hops.add(connectedNodeId);
    }

    final persistentPeer = _bleService.theirPersistentPublicKey;
    if (persistentPeer != null && persistentPeer.isNotEmpty) {
      hops.add(persistentPeer);
    }

    hops.addAll(
      _bleService.activeConnectionDeviceIds.where((id) => id.isNotEmpty),
    );

    for (final server in _bleService.serverConnections) {
      if (server.address.isNotEmpty) {
        hops.add(server.address);
      }
    }

    return hops.toList();
  }

  /// Returns latest relay statistics for network status reporting.
  RelayStatistics? get relayStatistics => _relayEngine?.getStatistics();

  /// Clean up relay resources.
  void dispose() {
    _relayEngine = null;
    _messageQueue = null;
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

  MeshRelayEngine _createRelayEngine(
    OfflineMessageQueueContract queue,
    SpamPreventionManager spamPrevention,
  ) {
    final factory = _relayEngineFactory;
    if (factory == null) {
      throw StateError(
        'MeshRelayEngineFactory is required. '
        'Provide relayEngineFactory when constructing MeshRelayCoordinator.',
      );
    }
    return factory(queue, spamPrevention);
  }
}
