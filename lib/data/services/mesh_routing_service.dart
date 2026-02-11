import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/routing/smart_mesh_router.dart';
import 'package:pak_connect/domain/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';
import 'package:pak_connect/domain/routing/smart_router_stats.dart';
import '../../domain/routing/route_calculator.dart';
import 'package:pak_connect/domain/routing/connection_quality_monitor.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_routing_service.dart';
import '../../domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/models/message_priority.dart';

/// Implementation of mesh routing service
///
/// Wraps SmartMeshRouter with dependency injection and provides
/// a clean interface for routing decisions in the mesh network.
///
/// Responsibilities:
/// - Initialize routing components (router, topology, quality monitoring)
/// - Make optimal routing decisions for relay messages
/// - Update network topology as connections change
/// - Expose routing statistics for diagnostics
/// - Coordinate with BLE service for actual message sending
class MeshRoutingService implements IMeshRoutingService {
  static final _logger = Logger('MeshRoutingService');

  SmartMeshRouter? _smartRouter;
  NetworkTopologyAnalyzer? _topologyAnalyzer;
  final RouteCalculator _routeCalculator = RouteCalculator();
  final ConnectionQualityMonitor _qualityMonitor = ConnectionQualityMonitor();

  bool _isInitialized = false;

  @override
  Future<void> initialize({
    required String currentNodeId,
    required NetworkTopologyAnalyzer topologyAnalyzer,
  }) async {
    try {
      _topologyAnalyzer = topologyAnalyzer;

      _logger.info(
        '🎯 Initializing MeshRoutingService for node $currentNodeId...',
      );

      // Create smart router with all dependencies
      _smartRouter = SmartMeshRouter(
        routeCalculator: _routeCalculator,
        topologyAnalyzer: topologyAnalyzer,
        qualityMonitor: _qualityMonitor,
        currentNodeId: currentNodeId,
      );

      // Initialize router
      await _smartRouter!.initialize();

      _isInitialized = true;
      _logger.info('✅ MeshRoutingService initialized');
    } catch (e) {
      _logger.severe('❌ Failed to initialize MeshRoutingService: $e');
      rethrow;
    }
  }

  @override
  Future<RoutingDecision> determineOptimalRoute({
    required String finalRecipient,
    required List<String> availableHops,
    required MessagePriority priority,
    RouteOptimizationStrategy strategy = RouteOptimizationStrategy.balanced,
  }) async {
    if (!_isInitialized) {
      return RoutingDecision.failed('MeshRoutingService not initialized');
    }

    if (_smartRouter == null) {
      return RoutingDecision.failed('Smart router not available');
    }

    try {
      _logger.info(
        '🤔 Determining route to $finalRecipient via ${availableHops.length} hops (priority: ${priority.name})',
      );

      // Use smart router for optimal decision
      final decision = await _smartRouter!.determineOptimalRoute(
        finalRecipient: finalRecipient,
        availableHops: availableHops,
        priority: priority,
        strategy: strategy,
      );

      _logger.info(
        '✅ Route decision: ${decision.type.name} via ${decision.nextHop} (score: ${decision.routeScore?.toStringAsFixed(2)})',
      );

      return decision;
    } catch (e) {
      _logger.severe('❌ Error determining route to $finalRecipient: $e');
      return RoutingDecision.failed('Route determination failed: $e');
    }
  }

  @override
  void addConnection(String node1, String node2) {
    try {
      _logger.info('➕ Adding connection: $node1 ↔ $node2');
      _topologyAnalyzer?.addConnection(node1, node2);
    } catch (e) {
      _logger.warning('⚠️ Failed to add connection: $e');
    }
  }

  @override
  void removeConnection(String node1, String node2) {
    try {
      _logger.info('➖ Removing connection: $node1 ↔ $node2');
      _topologyAnalyzer?.removeConnection(node1, node2);
    } catch (e) {
      _logger.warning('⚠️ Failed to remove connection: $e');
    }
  }

  @override
  SmartRouterStats getStatistics() {
    if (_smartRouter == null) {
      throw StateError('Routing service not initialized');
    }
    return _smartRouter!.getStatistics();
  }

  @override
  void clearAll() {
    try {
      _logger.info('🔄 Clearing all routing state');
      _smartRouter?.clearAll();
    } catch (e) {
      _logger.warning('⚠️ Failed to clear routing state: $e');
    }
  }

  @override
  void dispose() {
    try {
      _logger.info('🔌 Disposing MeshRoutingService');
      _smartRouter?.dispose();
      _smartRouter = null;
      _isInitialized = false;
    } catch (e) {
      _logger.warning('⚠️ Error disposing MeshRoutingService: $e');
    }
  }
}
