import 'dart:async';
import '../routing/routing_models.dart';
import '../routing/network_topology_analyzer.dart';
import '../routing/smart_mesh_router.dart';
import '../../domain/entities/enhanced_message.dart';

/// Interface for intelligent mesh routing service
///
/// Abstracts SmartMeshRouter and related topology/quality analysis
/// into a unified service interface.
abstract class IMeshRoutingService {
  /// Initialize the routing service with network topology analyzer
  ///
  /// Required before any routing decisions can be made.
  Future<void> initialize({
    required String currentNodeId,
    required NetworkTopologyAnalyzer topologyAnalyzer,
    bool enableDemo = false,
  });

  /// Determine the optimal route for a message to reach a final recipient
  ///
  /// Uses network topology, connection quality metrics, and priority
  /// to select the best next hop for message delivery.
  ///
  /// Parameters:
  /// - [finalRecipient]: Ultimate destination node ID
  /// - [availableHops]: Currently connected peers that could relay
  /// - [priority]: Message priority (affects max hops allowed)
  /// - [strategy]: Route optimization strategy (default: balanced)
  ///
  /// Returns a RoutingDecision containing:
  /// - type: direct/relay/failed
  /// - nextHop: ID of peer to send to
  /// - routeScore: Quality score (0.0-1.0)
  /// - reason: Human-readable explanation
  Future<RoutingDecision> determineOptimalRoute({
    required String finalRecipient,
    required List<String> availableHops,
    required MessagePriority priority,
    RouteOptimizationStrategy strategy = RouteOptimizationStrategy.balanced,
  });

  /// Update topology when a new connection is discovered
  void addConnection(String node1, String node2);

  /// Remove topology connection (e.g., when device disconnects)
  void removeConnection(String node1, String node2);

  /// Get current routing statistics
  SmartRouterStats getStatistics();

  /// Clear all routing state (topology, cache, connections)
  void clearAll();

  /// Enable/disable demo mode for visualization
  void setDemoMode(bool enabled);

  /// Stream of routing decisions (for demo/monitoring)
  Stream<RoutingDecision> get demoDecisions;

  /// Clean up resources (timers, controllers)
  void dispose();
}
