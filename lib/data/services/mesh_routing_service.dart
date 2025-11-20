import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/routing/smart_mesh_router.dart';
import '../../core/routing/network_topology_analyzer.dart';
import '../../core/routing/routing_models.dart';
import '../../core/routing/route_calculator.dart';
import '../../core/routing/connection_quality_monitor.dart';
import '../../core/interfaces/i_mesh_routing_service.dart';
import '../../domain/entities/enhanced_message.dart';

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

  late String _currentNodeId;
  bool _isInitialized = false;

  int _totalDecisionsMade = 0;
  double _cumulativeRouteScore = 0.0;

  @override
  Future<void> initialize({
    required String currentNodeId,
    required NetworkTopologyAnalyzer topologyAnalyzer,
  }) async {
    try {
      _currentNodeId = currentNodeId;
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

      // Track statistics
      _totalDecisionsMade++;
      if (decision.isSuccessful && decision.routeScore != null) {
        _cumulativeRouteScore += decision.routeScore!;
      }

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
      _totalDecisionsMade = 0;
      _cumulativeRouteScore = 0.0;
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
