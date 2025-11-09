import 'dart:collection';
import 'package:logging/logging.dart';
import 'routing_models.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Calculates optimal routes through the mesh network
class RouteCalculator {
  static final _logger = Logger('RouteCalculator');

  final Map<String, List<MessageRoute>> _routeCache = {};
  final Map<String, DateTime> _cacheExpiry = {};
  static const Duration _cacheTimeout = Duration(minutes: 5);

  /// Calculate all possible routes from source to destination
  Future<List<MessageRoute>> calculateRoutes({
    required String from,
    required String to,
    required List<String> availableHops,
    required NetworkTopology topology,
    RouteOptimizationStrategy strategy = RouteOptimizationStrategy.balanced,
    int maxHops = 3,
  }) async {
    try {
      _logger.info(
        'Calculating routes from ${from.shortId(8)}... to ${to.shortId(8)}...',
      );

      // Check cache first
      final cacheKey = '$from:$to:${availableHops.join(",")}';
      if (_routeCache.containsKey(cacheKey)) {
        final cacheTime = _cacheExpiry[cacheKey];
        if (cacheTime != null && DateTime.now().isBefore(cacheTime)) {
          _logger.info('Using cached routes for $cacheKey');
          return _routeCache[cacheKey]!;
        }
      }

      final routes = <MessageRoute>[];

      // Direct route check
      if (availableHops.contains(to)) {
        routes.add(
          MessageRoute(
            hops: [from, to],
            score: _calculateDirectScore(from, to, topology),
            quality: _getDirectQuality(from, to, topology),
            estimatedLatency: 500, // Direct connection latency
            reliability: 0.95,
          ),
        );
        _logger.info('Direct route available');
      }

      // Single-hop relay routes
      for (final hop in availableHops) {
        if (hop == to || hop == from) continue;

        if (topology.canReach(hop, to)) {
          final route = MessageRoute(
            hops: [from, hop, to],
            score: _calculateSingleHopScore(from, hop, to, topology),
            quality: _getSingleHopQuality(from, hop, to, topology),
            estimatedLatency: 1000, // Single hop relay latency
            reliability: _calculateSingleHopReliability(
              from,
              hop,
              to,
              topology,
            ),
          );
          routes.add(route);
          _logger.info('Single-hop route via ${hop.shortId(8)}...');
        }
      }

      // Multi-hop routes (limited to avoid complexity explosion)
      if (maxHops > 2) {
        final multiHopRoutes = _calculateMultiHopRoutes(
          from: from,
          to: to,
          availableHops: availableHops,
          topology: topology,
          maxHops: maxHops,
        );
        routes.addAll(multiHopRoutes);
      }

      // Sort routes by strategy
      final optimizedRoutes = _optimizeRoutes(routes, strategy);

      // Cache results
      _routeCache[cacheKey] = optimizedRoutes;
      _cacheExpiry[cacheKey] = DateTime.now().add(_cacheTimeout);

      _logger.info('Calculated ${optimizedRoutes.length} routes');
      return optimizedRoutes;
    } catch (e) {
      _logger.severe('Failed to calculate routes: $e');
      return <MessageRoute>[];
    }
  }

  /// Calculate multi-hop routes using breadth-first search
  List<MessageRoute> _calculateMultiHopRoutes({
    required String from,
    required String to,
    required List<String> availableHops,
    required NetworkTopology topology,
    required int maxHops,
  }) {
    final routes = <MessageRoute>[];
    final queue = Queue<List<String>>();
    final visited = <String>{};

    // Start with initial hops from source
    for (final hop in availableHops) {
      if (hop != from && hop != to) {
        queue.add([from, hop]);
      }
    }

    while (queue.isNotEmpty) {
      final currentPath = queue.removeFirst();
      final lastNode = currentPath.last;

      if (currentPath.length > maxHops) continue;
      if (visited.contains(lastNode)) continue;

      visited.add(lastNode);

      // Check if we can reach destination from current node
      if (topology.canReach(lastNode, to)) {
        final completePath = [...currentPath, to];
        final route = MessageRoute(
          hops: completePath,
          score: _calculateMultiHopScore(completePath, topology),
          quality: _getMultiHopQuality(completePath, topology),
          estimatedLatency: completePath.length * 800,
          reliability: _calculateMultiHopReliability(completePath, topology),
        );
        routes.add(route);
        continue;
      }

      // Add next possible hops
      final connectedNodes = topology.getConnectedNodes(lastNode);
      for (final nextNode in connectedNodes) {
        if (!currentPath.contains(nextNode) &&
            availableHops.contains(nextNode) &&
            nextNode != from) {
          queue.add([...currentPath, nextNode]);
        }
      }
    }

    _logger.info('Found ${routes.length} multi-hop routes');
    return routes;
  }

  /// Calculate score for direct connection
  double _calculateDirectScore(
    String from,
    String to,
    NetworkTopology topology,
  ) {
    final quality = topology.getConnectionQuality(from, to);
    switch (quality) {
      case ConnectionQuality.excellent:
        return 1.0;
      case ConnectionQuality.good:
        return 0.9;
      case ConnectionQuality.fair:
        return 0.7;
      case ConnectionQuality.poor:
        return 0.5;
      case ConnectionQuality.unreliable:
        return 0.3;
      case null:
        return 0.8; // Default for unknown quality
    }
  }

  /// Calculate score for single-hop relay
  double _calculateSingleHopScore(
    String from,
    String hop,
    String to,
    NetworkTopology topology,
  ) {
    final firstHopQuality = topology.getConnectionQuality(from, hop);
    final secondHopQuality = topology.getConnectionQuality(hop, to);

    final firstScore = _qualityToScore(firstHopQuality);
    final secondScore = _qualityToScore(secondHopQuality);

    // Average the scores with slight penalty for relay
    return (firstScore + secondScore) / 2 * 0.85;
  }

  /// Calculate score for multi-hop route
  double _calculateMultiHopScore(List<String> path, NetworkTopology topology) {
    if (path.length < 2) return 0.0;

    double totalScore = 0.0;
    int connectionCount = 0;

    for (int i = 0; i < path.length - 1; i++) {
      final quality = topology.getConnectionQuality(path[i], path[i + 1]);
      totalScore += _qualityToScore(quality);
      connectionCount++;
    }

    final averageScore = connectionCount > 0
        ? totalScore / connectionCount
        : 0.0;
    final hopPenalty = 0.9 / path.length; // Penalty for more hops

    return averageScore * hopPenalty;
  }

  /// Convert connection quality to numerical score
  double _qualityToScore(ConnectionQuality? quality) {
    switch (quality) {
      case ConnectionQuality.excellent:
        return 1.0;
      case ConnectionQuality.good:
        return 0.8;
      case ConnectionQuality.fair:
        return 0.6;
      case ConnectionQuality.poor:
        return 0.4;
      case ConnectionQuality.unreliable:
        return 0.2;
      case null:
        return 0.7; // Default for unknown quality
    }
  }

  /// Get route quality for direct connection
  RouteQuality _getDirectQuality(
    String from,
    String to,
    NetworkTopology topology,
  ) {
    final quality = topology.getConnectionQuality(from, to);
    switch (quality) {
      case ConnectionQuality.excellent:
        return RouteQuality.excellent;
      case ConnectionQuality.good:
        return RouteQuality.good;
      case ConnectionQuality.fair:
        return RouteQuality.fair;
      case ConnectionQuality.poor:
        return RouteQuality.poor;
      case ConnectionQuality.unreliable:
        return RouteQuality.unusable;
      case null:
        return RouteQuality.good; // Default assumption
    }
  }

  /// Get route quality for single-hop relay
  RouteQuality _getSingleHopQuality(
    String from,
    String hop,
    String to,
    NetworkTopology topology,
  ) {
    final firstQuality = topology.getConnectionQuality(from, hop);
    final secondQuality = topology.getConnectionQuality(hop, to);

    final firstScore = _qualityToScore(firstQuality);
    final secondScore = _qualityToScore(secondQuality);
    final averageScore = (firstScore + secondScore) / 2;

    if (averageScore >= 0.8) return RouteQuality.good;
    if (averageScore >= 0.6) return RouteQuality.fair;
    if (averageScore >= 0.4) return RouteQuality.poor;
    return RouteQuality.unusable;
  }

  /// Get route quality for multi-hop route
  RouteQuality _getMultiHopQuality(
    List<String> path,
    NetworkTopology topology,
  ) {
    final score = _calculateMultiHopScore(path, topology);

    if (score >= 0.7) return RouteQuality.good;
    if (score >= 0.5) return RouteQuality.fair;
    if (score >= 0.3) return RouteQuality.poor;
    return RouteQuality.unusable;
  }

  /// Calculate reliability for single-hop route
  double _calculateSingleHopReliability(
    String from,
    String hop,
    String to,
    NetworkTopology topology,
  ) {
    final firstQuality = topology.getConnectionQuality(from, hop);
    final secondQuality = topology.getConnectionQuality(hop, to);

    final firstReliability = _qualityToReliability(firstQuality);
    final secondReliability = _qualityToReliability(secondQuality);

    // Combined reliability is the product of individual reliabilities
    return firstReliability * secondReliability;
  }

  /// Calculate reliability for multi-hop route
  double _calculateMultiHopReliability(
    List<String> path,
    NetworkTopology topology,
  ) {
    if (path.length < 2) return 0.0;

    double totalReliability = 1.0;

    for (int i = 0; i < path.length - 1; i++) {
      final quality = topology.getConnectionQuality(path[i], path[i + 1]);
      final reliability = _qualityToReliability(quality);
      totalReliability *= reliability;
    }

    return totalReliability;
  }

  /// Convert connection quality to reliability score
  double _qualityToReliability(ConnectionQuality? quality) {
    switch (quality) {
      case ConnectionQuality.excellent:
        return 0.95;
      case ConnectionQuality.good:
        return 0.85;
      case ConnectionQuality.fair:
        return 0.70;
      case ConnectionQuality.poor:
        return 0.50;
      case ConnectionQuality.unreliable:
        return 0.30;
      case null:
        return 0.80; // Default reliability
    }
  }

  /// Optimize and sort routes based on strategy
  List<MessageRoute> _optimizeRoutes(
    List<MessageRoute> routes,
    RouteOptimizationStrategy strategy,
  ) {
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
        // Balanced scoring: combine hop count, quality, and latency
        sortedRoutes.sort((a, b) {
          final aBalancedScore = _calculateBalancedScore(a);
          final bBalancedScore = _calculateBalancedScore(b);
          return bBalancedScore.compareTo(aBalancedScore);
        });
        break;
    }

    return sortedRoutes;
  }

  /// Calculate balanced score for route optimization
  double _calculateBalancedScore(MessageRoute route) {
    // Normalize hop count (prefer fewer hops)
    final hopScore = 1.0 / route.hopCount;

    // Normalize latency (prefer lower latency)
    final latencyScore =
        1.0 - (route.estimatedLatency / 5000.0).clamp(0.0, 1.0);

    // Use route quality score directly
    final qualityScore = route.score;

    // Use reliability score directly
    final reliabilityScore = route.reliability;

    // Weighted combination
    return (hopScore * 0.25 +
        latencyScore * 0.25 +
        qualityScore * 0.25 +
        reliabilityScore * 0.25);
  }

  /// Clear route cache
  void clearCache() {
    _routeCache.clear();
    _cacheExpiry.clear();
    _logger.info('Route cache cleared');
  }

  /// Get cache statistics
  Map<String, int> getCacheStatistics() {
    return {
      'cached_routes': _routeCache.length,
      'expired_entries': _cacheExpiry.values
          .where((expiry) => DateTime.now().isAfter(expiry))
          .length,
    };
  }

  /// Clean expired cache entries
  void cleanExpiredCache() {
    final now = DateTime.now();
    final expiredKeys = _cacheExpiry.entries
        .where((entry) => now.isAfter(entry.value))
        .map((entry) => entry.key)
        .toList();

    for (final key in expiredKeys) {
      _routeCache.remove(key);
      _cacheExpiry.remove(key);
    }

    if (expiredKeys.isNotEmpty) {
      _logger.info('Cleaned ${expiredKeys.length} expired cache entries');
    }
  }
}
