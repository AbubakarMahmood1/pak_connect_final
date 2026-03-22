import 'dart:math';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/constants/special_recipients.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:pak_connect/core/security/stealth_address.dart';
import '../../domain/values/id_types.dart';

/// Encapsulates relay decision logic (dedup, recipient resolution, next-hop selection).
class RelayDecisionEngine {
  final Logger _logger;
  final ISeenMessageStore _seenMessageStore;
  IMeshRoutingService? _routingService;
  NetworkTopologyAnalyzer? _topologyAnalyzer;
  String _currentNodeId;
  String? _myPersistentId;

  /// X25519 scan private key for stealth address checking.
  /// Set via [setScanKey] when the user's identity is available.
  Uint8List? _scanPrivateKey;

  RelayDecisionEngine({
    required Logger logger,
    required ISeenMessageStore seenMessageStore,
    IMeshRoutingService? routingService,
    NetworkTopologyAnalyzer? topologyAnalyzer,
    required String currentNodeId,
    String? myPersistentId,
  }) : _logger = logger,
       _seenMessageStore = seenMessageStore,
       _routingService = routingService,
       _topologyAnalyzer = topologyAnalyzer,
       _currentNodeId = currentNodeId,
       _myPersistentId = myPersistentId;

  void updateContext({
    required String currentNodeId,
    IMeshRoutingService? routingService,
    NetworkTopologyAnalyzer? topologyAnalyzer,
    String? myPersistentId,
  }) {
    _currentNodeId = currentNodeId;
    _routingService = routingService;
    _topologyAnalyzer = topologyAnalyzer;
    if (myPersistentId != null) {
      _myPersistentId = myPersistentId;
    }
  }

  /// Set the scan private key for stealth address checking.
  void setScanKey(Uint8List? scanPrivateKey) {
    _scanPrivateKey = scanPrivateKey;
  }

  bool isDuplicate(String messageId) =>
      _seenMessageStore.hasDelivered(messageId);
  bool isDuplicateId(MessageId messageId) => isDuplicate(messageId.value);

  /// Network size threshold for broadcast mode.
  /// Below this, all messages flood to all peers (no routing metadata needed).
  static const int broadcastModeThreshold = 30;

  double calculateRelayProbability() {
    final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 1;
    if (networkSize <= broadcastModeThreshold) return 1.0; // Flood all
    if (networkSize <= 50) return 0.7;
    if (networkSize <= 100) return 0.55;
    return 0.4;
  }

  /// Whether the network is small enough to use broadcast mode.
  /// In broadcast mode, messages flood to all peers and recipients
  /// self-identify via stealth addressing / view tags.
  bool get isSmallNetworkBroadcast {
    final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 1;
    return networkSize <= broadcastModeThreshold;
  }

  Future<bool> isMessageForCurrentNode(String finalRecipientPublicKey) async {
    if (SpecialRecipients.isBroadcast(finalRecipientPublicKey)) {
      _logger.info('📣 Broadcast message - delivering to self AND forwarding');
      return true;
    }
    if (finalRecipientPublicKey.isEmpty) {
      _logger.fine('📭 No recipient specified - rejecting (use broadcast)');
      return false;
    }
    if (finalRecipientPublicKey == _currentNodeId) {
      _logger.info('✅ Message IS for current node (node ID match)');
      return true;
    }

    final persistentId = _getMyPersistentId();
    if (persistentId != null && finalRecipientPublicKey == persistentId) {
      _logger.info('✅ Message IS for current node (persistent key match)');
      return true;
    }

    final ephemeralKey = EphemeralKeyManager.currentSessionKey;
    if (ephemeralKey != null && finalRecipientPublicKey == ephemeralKey) {
      _logger.info('✅ Message IS for current node (ephemeral key match)');
      return true;
    }

    final ephemeralSigningKey = EphemeralKeyManager.ephemeralSigningPublicKey;
    if (ephemeralSigningKey != null &&
        finalRecipientPublicKey == ephemeralSigningKey) {
      _logger.info(
        '✅ Message IS for current node (ephemeral signing key match)',
      );
      return true;
    }

    final truncatedRecipient = finalRecipientPublicKey.length > 16
        ? finalRecipientPublicKey.shortId()
        : finalRecipientPublicKey;
    final truncatedNodeId = _currentNodeId.length > 16
        ? _currentNodeId.shortId()
        : _currentNodeId;

    _logger.fine('📭 Message NOT for current node:');
    _logger.fine('   - Recipient: $truncatedRecipient...');
    _logger.fine('   - Our node ID: $truncatedNodeId...');
    _logger.fine(
      '   - Our ephemeral key: ${ephemeralKey?.shortId() ?? "NULL"}...',
    );
    return false;
  }

  /// Stealth-aware recipient check: if the metadata carries a [StealthEnvelope],
  /// try ECDH scan first. Falls back to plaintext [finalRecipient] matching.
  Future<bool> isMessageForCurrentNodeFromMetadata(
    RelayMetadata metadata,
  ) async {
    if (metadata.usesStealth && _scanPrivateKey != null) {
      final result = StealthAddress.check(
        scanPrivateKey: _scanPrivateKey!,
        envelope: metadata.stealthEnvelope!,
      );
      if (result.isForMe) {
        _logger.info(
          '🕵️ Stealth address match (viewTag passed: ${result.passedViewTag})',
        );
        return true;
      }
      if (!result.passedViewTag) {
        _logger.fine('🕵️ Stealth view tag mismatch — fast skip');
        return false;
      }
      // View tag matched but stealth address didn't → false positive, fall through
      _logger.fine('🕵️ Stealth view tag matched but address mismatch');
    }
    // Fall back to plaintext recipient check
    return isMessageForCurrentNode(metadata.finalRecipient);
  }

  bool shouldProbabilisticallySkip({
    required bool isForUs,
    required double relayProbability,
  }) {
    if (isForUs || relayProbability >= 1.0) return false;
    final randomValue = Random().nextDouble();
    if (randomValue > relayProbability) {
      final networkSize = _topologyAnalyzer?.getNetworkSize() ?? 1;
      _logger.info(
        '🎲 Probabilistic relay SKIP (network: $networkSize nodes, prob: ${(relayProbability * 100).toStringAsFixed(0)}%, roll: ${(randomValue * 100).toStringAsFixed(0)}%)',
      );
      return true;
    }
    return false;
  }

  Future<String?> chooseNextHop({
    required MeshRelayMessage relayMessage,
    required List<String> availableHops,
  }) async {
    if (availableHops.isEmpty) return null;

    try {
      final validHops = availableHops
          .where((hop) => !relayMessage.relayMetadata.hasNodeInPath(hop))
          .toList();

      if (validHops.isEmpty) {
        _logger.warning('All available hops would create loops');
        return null;
      }

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

      return _selectBestHopByQuality(validHops);
    } catch (e) {
      _logger.severe('Failed to choose next hop: $e');
      return null;
    }
  }

  Future<String> _selectBestHopByQuality(List<String> validHops) async {
    if (validHops.length == 1) {
      return validHops.first;
    }

    return validHops.first;
  }

  Future<ChatId?> chooseNextHopId({
    required MeshRelayMessage relayMessage,
    required List<ChatId> availableHops,
  }) async {
    final hopStrings = availableHops.map((h) => h.value).toList();
    final chosen = await chooseNextHop(
      relayMessage: relayMessage,
      availableHops: hopStrings,
    );
    return chosen != null ? ChatId(chosen) : null;
  }

  String? _getMyPersistentId() {
    if (_myPersistentId != null && _myPersistentId!.isNotEmpty) {
      return _myPersistentId;
    }
    return null;
  }
}
