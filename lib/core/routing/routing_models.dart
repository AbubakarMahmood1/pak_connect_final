/// Represents a routing decision made by the smart mesh router
class RoutingDecision {
  final RoutingType type;
  final String? nextHop;
  final String? reason;
  final List<String>? routePath;
  final double? routeScore;
  final DateTime timestamp;

  RoutingDecision._({
    required this.type,
    this.nextHop,
    this.reason,
    this.routePath,
    this.routeScore,
  }) : timestamp = DateTime.now();

  factory RoutingDecision.direct(String recipient) => RoutingDecision._(
    type: RoutingType.direct,
    nextHop: recipient,
    reason: 'Direct connection available',
    routePath: [recipient],
    routeScore: 1.0,
  );

  factory RoutingDecision.relay(
    String nextHop,
    List<String> routePath,
    double routeScore,
  ) => RoutingDecision._(
    type: RoutingType.relay,
    nextHop: nextHop,
    reason: 'Mesh relay required',
    routePath: routePath,
    routeScore: routeScore,
  );

  factory RoutingDecision.failed(String reason) =>
      RoutingDecision._(type: RoutingType.failed, reason: reason);

  bool get isSuccessful => type != RoutingType.failed;
  bool get isDirect => type == RoutingType.direct;
  bool get isRelay => type == RoutingType.relay;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'nextHop': nextHop,
    'reason': reason,
    'routePath': routePath,
    'routeScore': routeScore,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  factory RoutingDecision.fromJson(Map<String, dynamic> json) =>
      RoutingDecision._(
        type: RoutingType.values.byName(json['type']),
        nextHop: json['nextHop'],
        reason: json['reason'],
        routePath: json['routePath'] != null
            ? List<String>.from(json['routePath'])
            : null,
        routeScore: json['routeScore']?.toDouble(),
      );
}

/// Types of routing decisions
enum RoutingType { direct, relay, failed }

/// Represents a calculated route through the mesh network
class MessageRoute {
  final List<String> hops;
  final double score;
  final RouteQuality quality;
  final int estimatedLatency;
  final double reliability;
  final DateTime calculatedAt;

  MessageRoute({
    required this.hops,
    required this.score,
    required this.quality,
    required this.estimatedLatency,
    required this.reliability,
  }) : calculatedAt = DateTime.now();

  factory MessageRoute.singleHop(String from, String hop, String to) =>
      MessageRoute(
        hops: [from, hop, to],
        score: 0.8, // Good single hop score
        quality: RouteQuality.good,
        estimatedLatency: 1000, // 1 second estimated
        reliability: 0.85,
      );

  factory MessageRoute.multiHop(List<String> fullPath) => MessageRoute(
    hops: fullPath,
    score: 0.6 - (fullPath.length - 2) * 0.1, // Decrease score with more hops
    quality: fullPath.length <= 3 ? RouteQuality.good : RouteQuality.poor,
    estimatedLatency: fullPath.length * 800, // Increase latency per hop
    reliability: 0.9 / fullPath.length, // Decrease reliability with more hops
  );

  String get from => hops.first;
  String get to => hops.last;
  int get hopCount => hops.length - 1;
  bool get isSingleHop => hopCount == 1;
  bool get isMultiHop => hopCount > 1;

  Map<String, dynamic> toJson() => {
    'hops': hops,
    'score': score,
    'quality': quality.name,
    'estimatedLatency': estimatedLatency,
    'reliability': reliability,
    'calculatedAt': calculatedAt.millisecondsSinceEpoch,
  };

  factory MessageRoute.fromJson(Map<String, dynamic> json) => MessageRoute(
    hops: List<String>.from(json['hops']),
    score: json['score'].toDouble(),
    quality: RouteQuality.values.byName(json['quality']),
    estimatedLatency: json['estimatedLatency'],
    reliability: json['reliability'].toDouble(),
  );
}

/// Quality levels for routes
enum RouteQuality { excellent, good, fair, poor, unusable }

/// Network topology representation
class NetworkTopology {
  final Map<String, Set<String>> connections;
  final Map<String, ConnectionQuality> connectionQualities;
  final DateTime lastUpdated;

  NetworkTopology({
    required this.connections,
    required this.connectionQualities,
  }) : lastUpdated = DateTime.now();

  /// Check if a node can reach another node directly
  bool canReach(String from, String to) {
    return connections[from]?.contains(to) ?? false;
  }

  /// Get all nodes connected to a given node
  Set<String> getConnectedNodes(String nodeId) {
    return connections[nodeId] ?? <String>{};
  }

  /// Get connection quality between two nodes
  ConnectionQuality? getConnectionQuality(String from, String to) {
    final key = _connectionKey(from, to);
    return connectionQualities[key];
  }

  /// Add or update a connection
  NetworkTopology withConnection(
    String from,
    String to,
    ConnectionQuality quality,
  ) {
    final newConnections = Map<String, Set<String>>.from(connections);
    final newQualities = Map<String, ConnectionQuality>.from(
      connectionQualities,
    );

    // Add bidirectional connection
    newConnections.putIfAbsent(from, () => <String>{}).add(to);
    newConnections.putIfAbsent(to, () => <String>{}).add(from);

    // Store quality
    final key = _connectionKey(from, to);
    newQualities[key] = quality;

    return NetworkTopology(
      connections: newConnections,
      connectionQualities: newQualities,
    );
  }

  /// Remove a connection
  NetworkTopology withoutConnection(String from, String to) {
    final newConnections = Map<String, Set<String>>.from(connections);
    final newQualities = Map<String, ConnectionQuality>.from(
      connectionQualities,
    );

    newConnections[from]?.remove(to);
    newConnections[to]?.remove(from);

    final key = _connectionKey(from, to);
    newQualities.remove(key);

    return NetworkTopology(
      connections: newConnections,
      connectionQualities: newQualities,
    );
  }

  String _connectionKey(String from, String to) {
    final sorted = [from, to]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  Map<String, dynamic> toJson() => {
    'connections': connections.map(
      (key, value) => MapEntry(key, value.toList()),
    ),
    'connectionQualities': connectionQualities.map(
      (key, value) => MapEntry(key, value.name),
    ),
    'lastUpdated': lastUpdated.millisecondsSinceEpoch,
  };

  factory NetworkTopology.fromJson(Map<String, dynamic> json) =>
      NetworkTopology(
        connections: (json['connections'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(key, Set<String>.from(value)),
        ),
        connectionQualities:
            (json['connectionQualities'] as Map<String, dynamic>).map(
              (key, value) =>
                  MapEntry(key, ConnectionQuality.values.byName(value)),
            ),
      );
}

/// Quality levels for connections
enum ConnectionQuality {
  excellent, // Strong, stable connection
  good, // Reliable connection
  fair, // Usable but may have issues
  poor, // Weak connection, high failure rate
  unreliable, // Very poor connection
}

/// Connection quality metrics
class ConnectionMetrics {
  final double signalStrength;
  final double latency;
  final double packetLoss;
  final double throughput;
  final DateTime lastMeasured;

  ConnectionMetrics({
    required this.signalStrength,
    required this.latency,
    required this.packetLoss,
    required this.throughput,
  }) : lastMeasured = DateTime.now();

  /// Calculate overall connection quality score (0.0 to 1.0)
  double get qualityScore {
    final signalScore = signalStrength.clamp(0.0, 1.0);
    final latencyScore = (1.0 - (latency / 5000.0)).clamp(
      0.0,
      1.0,
    ); // 5s max latency
    final lossScore = (1.0 - packetLoss).clamp(0.0, 1.0);
    final throughputScore = throughput.clamp(0.0, 1.0);

    return (signalScore * 0.3 +
        latencyScore * 0.3 +
        lossScore * 0.3 +
        throughputScore * 0.1);
  }

  /// Get connection quality enum based on score
  ConnectionQuality get quality {
    final score = qualityScore;
    if (score >= 0.8) return ConnectionQuality.excellent;
    if (score >= 0.6) return ConnectionQuality.good;
    if (score >= 0.4) return ConnectionQuality.fair;
    if (score >= 0.2) return ConnectionQuality.poor;
    return ConnectionQuality.unreliable;
  }

  Map<String, dynamic> toJson() => {
    'signalStrength': signalStrength,
    'latency': latency,
    'packetLoss': packetLoss,
    'throughput': throughput,
    'lastMeasured': lastMeasured.millisecondsSinceEpoch,
  };

  factory ConnectionMetrics.fromJson(Map<String, dynamic> json) =>
      ConnectionMetrics(
        signalStrength: json['signalStrength'].toDouble(),
        latency: json['latency'].toDouble(),
        packetLoss: json['packetLoss'].toDouble(),
        throughput: json['throughput'].toDouble(),
      );
}

/// Demo scenario types for FYP evaluation
enum DemoScenarioType { aToBtoC, queueSync, spamPrevention, smartRouting }

/// Route optimization strategies
enum RouteOptimizationStrategy {
  shortestPath, // Minimize hop count
  highestQuality, // Maximize connection quality
  lowestLatency, // Minimize estimated latency
  balanced, // Balance all factors
}
