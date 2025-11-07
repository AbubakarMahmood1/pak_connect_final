import 'dart:async';
import 'package:logging/logging.dart';
import 'routing_models.dart';
import 'route_calculator.dart';
import 'network_topology_analyzer.dart';
import 'connection_quality_monitor.dart';
import '../../domain/entities/enhanced_message.dart';

/// Intelligent mesh router that makes optimal routing decisions
class SmartMeshRouter {
  static final _logger = Logger('SmartMeshRouter');

  final RouteCalculator _routeCalculator;
  final NetworkTopologyAnalyzer _topologyAnalyzer;
  final ConnectionQualityMonitor _qualityMonitor;
  final String _currentNodeId;

  // Decision caching
  final Map<String, RoutingDecision> _decisionCache = {};
  final Map<String, DateTime> _cacheExpiry = {};
  static const Duration _cacheTimeout = Duration(minutes: 2);

  // Demo mode
  bool _demoMode = false;
  final StreamController<RoutingDecision> _demoDecisionController =
      StreamController<RoutingDecision>.broadcast();

  Timer? _maintenanceTimer;

  SmartMeshRouter({
    required RouteCalculator routeCalculator,
    required NetworkTopologyAnalyzer topologyAnalyzer,
    required ConnectionQualityMonitor qualityMonitor,
    required String currentNodeId,
  }) : _routeCalculator = routeCalculator,
       _topologyAnalyzer = topologyAnalyzer,
       _qualityMonitor = qualityMonitor,
       _currentNodeId = currentNodeId;

  /// Stream of routing decisions (for demo purposes)
  Stream<RoutingDecision> get demoDecisions => _demoDecisionController.stream;

  /// Initialize the smart mesh router
  Future<void> initialize({bool enableDemo = false}) async {
    try {
      _logger.info(
        'Initializing Smart Mesh Router for node ${_currentNodeId.substring(0, 8)}...',
      );

      _demoMode = enableDemo;

      // Initialize all components
      await _topologyAnalyzer.initialize();
      await _qualityMonitor.initialize();

      // Start maintenance timer
      _maintenanceTimer = Timer.periodic(
        Duration(minutes: 5),
        (_) => _performMaintenance(),
      );

      _logger.info('✅ Smart Mesh Router initialized (demo: $_demoMode)');
    } catch (e) {
      _logger.severe('❌ Failed to initialize Smart Mesh Router: $e');
      rethrow;
    }
  }

  /// Determine optimal routing decision for a message
  Future<RoutingDecision> determineOptimalRoute({
    required String finalRecipient,
    required List<String> availableHops,
    required MessagePriority priority,
    RouteOptimizationStrategy strategy = RouteOptimizationStrategy.balanced,
  }) async {
    try {
      _logger.info(
        '🤔 Determining route to ${finalRecipient.substring(0, 8)}... via ${availableHops.length} hops',
      );

      // Check cache first
      final cacheKey =
          '$finalRecipient:${availableHops.join(",")}:${strategy.name}';
      final cachedDecision = _getCachedDecision(cacheKey);
      if (cachedDecision != null) {
        _logger.info('📋 Using cached routing decision');
        if (_demoMode) {
          _demoDecisionController.add(cachedDecision);
        }
        return cachedDecision;
      }

      // Step 1: Check for direct connectivity
      if (availableHops.contains(finalRecipient)) {
        _logger.info('🎯 Direct route available');
        final decision = RoutingDecision.direct(finalRecipient);
        _cacheDecision(cacheKey, decision);

        if (_demoMode) {
          _demoDecisionController.add(decision);
        }

        return decision;
      }

      // Step 2: Update network topology with current information
      await _updateTopologyWithCurrentHops(availableHops);

      // Step 3: Get network topology
      final topology = _topologyAnalyzer.getNetworkTopology();

      // Step 4: Calculate possible routes
      final routes = await _routeCalculator.calculateRoutes(
        from: _currentNodeId,
        to: finalRecipient,
        availableHops: availableHops,
        topology: topology,
        strategy: strategy,
        maxHops: _getMaxHopsForPriority(priority),
      );

      if (routes.isEmpty) {
        _logger.warning(
          '❌ No routes found to ${finalRecipient.substring(0, 8)}...',
        );
        final decision = RoutingDecision.failed(
          'No route available to destination',
        );

        if (_demoMode) {
          _demoDecisionController.add(decision);
        }

        return decision;
      }

      // Step 5: Score routes using connection quality
      final scoredRoutes = await _scoreRoutes(routes);

      // Step 6: Select the best route
      final bestRoute = _selectBestRoute(scoredRoutes, strategy, priority);

      // Step 7: Create routing decision
      final nextHop = bestRoute.hops.length > 1
          ? bestRoute.hops[1]
          : finalRecipient;
      final decision = RoutingDecision.relay(
        nextHop,
        bestRoute.hops,
        bestRoute.score,
      );

      _logger.info(
        '✅ Selected route via ${nextHop.substring(0, 8)}... (score: ${bestRoute.score.toStringAsFixed(2)})',
      );

      // Cache the decision
      _cacheDecision(cacheKey, decision);

      // Broadcast for demo
      if (_demoMode) {
        _demoDecisionController.add(decision);
      }

      return decision;
    } catch (e) {
      _logger.severe('❌ Route determination failed: $e');
      final decision = RoutingDecision.failed('Route calculation error: $e');

      if (_demoMode) {
        _demoDecisionController.add(decision);
      }

      return decision;
    }
  }

  /// Update network topology with current hop information
  Future<void> _updateTopologyWithCurrentHops(
    List<String> availableHops,
  ) async {
    try {
      // Add connections to current available hops with estimated quality
      for (final hop in availableHops) {
        final connectionScore = await _qualityMonitor.getConnectionScore(hop);
        final quality = _scoreToConnectionQuality(connectionScore);

        await _topologyAnalyzer.addConnection(
          _currentNodeId,
          hop,
          quality: quality,
        );
      }
    } catch (e) {
      _logger.warning('Failed to update topology: $e');
    }
  }

  /// Score routes using connection quality information
  Future<List<MessageRoute>> _scoreRoutes(List<MessageRoute> routes) async {
    final scoredRoutes = <MessageRoute>[];

    for (final route in routes) {
      double qualityScore = 1.0;

      // Calculate quality score for each hop in the route
      for (int i = 0; i < route.hops.length - 1; i++) {
        final fromNode = route.hops[i];
        final toNode = route.hops[i + 1];

        double hopScore = 0.7; // Default score

        // Get quality score if we have data
        if (fromNode == _currentNodeId) {
          hopScore = await _qualityMonitor.getConnectionScore(toNode);
        }

        qualityScore *= hopScore;
      }

      // Adjust score based on route characteristics
      final adjustedScore = qualityScore * _getRouteAdjustment(route);

      // Create new route with adjusted score
      final scoredRoute = MessageRoute(
        hops: route.hops,
        score: adjustedScore,
        quality: _scoreToRouteQuality(adjustedScore),
        estimatedLatency: route.estimatedLatency,
        reliability: qualityScore, // Use quality score as reliability
      );

      scoredRoutes.add(scoredRoute);
    }

    return scoredRoutes;
  }

  /// Select the best route based on strategy and priority
  MessageRoute _selectBestRoute(
    List<MessageRoute> routes,
    RouteOptimizationStrategy strategy,
    MessagePriority priority,
  ) {
    if (routes.isEmpty) {
      throw Exception('No routes available for selection');
    }

    // Sort routes based on strategy
    final sortedRoutes = List<MessageRoute>.from(routes);

    switch (strategy) {
      case RouteOptimizationStrategy.shortestPath:
        sortedRoutes.sort((a, b) => a.hopCount.compareTo(b.hopCount));
        break;
      case RouteOptimizationStrategy.highestQuality:
        sortedRoutes.sort((a, b) => b.score.compareTo(a.score));
        break;
      case RouteOptimizationStrategy.lowestLatency:
        sortedRoutes.sort(
          (a, b) => a.estimatedLatency.compareTo(b.estimatedLatency),
        );
        break;
      case RouteOptimizationStrategy.balanced:
        sortedRoutes.sort(
          (a, b) =>
              _calculateBalancedScore(b).compareTo(_calculateBalancedScore(a)),
        );
        break;
    }

    // Apply priority-based selection
    final selectedRoute = _applyPrioritySelection(sortedRoutes, priority);

    _logger.info(
      '📊 Route selection: ${selectedRoute.hops.length - 1} hops, '
      'score: ${selectedRoute.score.toStringAsFixed(2)}, '
      'quality: ${selectedRoute.quality.name}',
    );

    return selectedRoute;
  }

  /// Apply priority-based route selection
  MessageRoute _applyPrioritySelection(
    List<MessageRoute> sortedRoutes,
    MessagePriority priority,
  ) {
    switch (priority) {
      case MessagePriority.urgent:
        // For urgent messages, prefer the fastest route even if quality is lower
        sortedRoutes.sort(
          (a, b) => a.estimatedLatency.compareTo(b.estimatedLatency),
        );
        return sortedRoutes.first;

      case MessagePriority.high:
        // For high priority, balance speed and quality
        final fastRoutes = sortedRoutes
            .where((r) => r.estimatedLatency < 2000)
            .toList();
        if (fastRoutes.isNotEmpty) {
          fastRoutes.sort((a, b) => b.score.compareTo(a.score));
          return fastRoutes.first;
        }
        return sortedRoutes.first;

      case MessagePriority.low:
        // For low priority, prefer quality over speed
        sortedRoutes.sort((a, b) => b.score.compareTo(a.score));
        return sortedRoutes.first;

      case MessagePriority.normal:
        // Use the already sorted route (based on strategy)
        return sortedRoutes.first;
    }
  }

  /// Calculate balanced score for route comparison
  double _calculateBalancedScore(MessageRoute route) {
    // Normalize hop count (prefer fewer hops)
    final hopScore = 1.0 / route.hopCount;

    // Normalize latency (prefer lower latency)
    final latencyScore =
        1.0 - (route.estimatedLatency / 5000.0).clamp(0.0, 1.0);

    // Use route quality score and reliability
    final qualityScore = route.score;
    final reliabilityScore = route.reliability;

    // Weighted combination
    return (hopScore * 0.25 +
        latencyScore * 0.25 +
        qualityScore * 0.3 +
        reliabilityScore * 0.2);
  }

  /// Get route adjustment factor based on route characteristics
  double _getRouteAdjustment(MessageRoute route) {
    double adjustment = 1.0;

    // Penalize longer routes
    if (route.hopCount > 2) {
      adjustment *= 0.9 / route.hopCount;
    }

    // Bonus for single-hop routes
    if (route.hopCount == 1) {
      adjustment *= 1.1;
    }

    return adjustment;
  }

  /// Get maximum hops allowed based on message priority
  int _getMaxHopsForPriority(MessagePriority priority) {
    switch (priority) {
      case MessagePriority.urgent:
        return 2; // Limit urgent messages to 2 hops for speed
      case MessagePriority.high:
        return 3;
      case MessagePriority.normal:
        return 4;
      case MessagePriority.low:
        return 5; // Allow more hops for low priority
    }
  }

  /// Convert connection quality score to ConnectionQuality enum
  ConnectionQuality _scoreToConnectionQuality(double score) {
    if (score >= 0.8) return ConnectionQuality.excellent;
    if (score >= 0.6) return ConnectionQuality.good;
    if (score >= 0.4) return ConnectionQuality.fair;
    if (score >= 0.2) return ConnectionQuality.poor;
    return ConnectionQuality.unreliable;
  }

  /// Convert score to RouteQuality enum
  RouteQuality _scoreToRouteQuality(double score) {
    if (score >= 0.8) return RouteQuality.excellent;
    if (score >= 0.6) return RouteQuality.good;
    if (score >= 0.4) return RouteQuality.fair;
    if (score >= 0.2) return RouteQuality.poor;
    return RouteQuality.unusable;
  }

  /// Get cached routing decision if still valid
  RoutingDecision? _getCachedDecision(String cacheKey) {
    final decision = _decisionCache[cacheKey];
    final expiry = _cacheExpiry[cacheKey];

    if (decision != null && expiry != null && DateTime.now().isBefore(expiry)) {
      return decision;
    }

    // Remove expired entry
    _decisionCache.remove(cacheKey);
    _cacheExpiry.remove(cacheKey);

    return null;
  }

  /// Cache a routing decision
  void _cacheDecision(String cacheKey, RoutingDecision decision) {
    _decisionCache[cacheKey] = decision;
    _cacheExpiry[cacheKey] = DateTime.now().add(_cacheTimeout);
  }

  /// Perform periodic maintenance
  Future<void> _performMaintenance() async {
    try {
      // Clean expired cache entries
      final now = DateTime.now();
      final expiredKeys = _cacheExpiry.entries
          .where((entry) => now.isAfter(entry.value))
          .map((entry) => entry.key)
          .toList();

      for (final key in expiredKeys) {
        _decisionCache.remove(key);
        _cacheExpiry.remove(key);
      }

      // Clean route calculator cache
      _routeCalculator.cleanExpiredCache();

      if (expiredKeys.isNotEmpty) {
        _logger.fine('Cleaned ${expiredKeys.length} expired routing decisions');
      }
    } catch (e) {
      _logger.warning('Maintenance failed: $e');
    }
  }

  /// Enable or disable demo mode
  void setDemoMode(bool enabled) {
    _demoMode = enabled;
    _logger.info('Demo mode ${enabled ? 'enabled' : 'disabled'}');
  }

  /// Get routing statistics
  SmartRouterStats getStatistics() {
    final topologyStats = _topologyAnalyzer.getNetworkStats();
    final qualityStats = _qualityMonitor.getMonitoringStats();
    final cacheStats = _routeCalculator.getCacheStatistics();

    return SmartRouterStats(
      nodeId: _currentNodeId,
      cachedDecisions: _decisionCache.length,
      topologyStats: topologyStats,
      qualityStats: qualityStats,
      cacheStats: cacheStats,
      demoModeEnabled: _demoMode,
    );
  }

  /// Clear all caches and reset state
  Future<void> clearAll() async {
    _decisionCache.clear();
    _cacheExpiry.clear();
    _routeCalculator.clearCache();
    _qualityMonitor.clearAll();
    _logger.info('Smart Mesh Router state cleared');
  }

  /// Dispose of all resources
  void dispose() {
    _maintenanceTimer?.cancel();
    _demoDecisionController.close();
    _topologyAnalyzer.dispose();
    _qualityMonitor.dispose();
    clearAll();
    _logger.info('Smart Mesh Router disposed');
  }
}

/// Smart router statistics
class SmartRouterStats {
  final String nodeId;
  final int cachedDecisions;
  final NetworkTopologyStats topologyStats;
  final QualityMonitoringStats qualityStats;
  final Map<String, int> cacheStats;
  final bool demoModeEnabled;

  const SmartRouterStats({
    required this.nodeId,
    required this.cachedDecisions,
    required this.topologyStats,
    required this.qualityStats,
    required this.cacheStats,
    required this.demoModeEnabled,
  });

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'cachedDecisions': cachedDecisions,
    'topologyStats': topologyStats.toJson(),
    'qualityStats': qualityStats.toJson(),
    'cacheStats': cacheStats,
    'demoModeEnabled': demoModeEnabled,
  };

  @override
  String toString() =>
      'SmartRouterStats(node: ${nodeId.substring(0, 8)}..., '
      'cached: $cachedDecisions, demo: $demoModeEnabled)';
}
