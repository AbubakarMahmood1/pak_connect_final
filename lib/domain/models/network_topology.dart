// Network topology data models for mesh visualization
// Tracks nodes, connections, and network graph structure

/// Represents a node in the mesh network
///
/// 🔧 IDENTITY ARCHITECTURE (2025-10-20 FIX):
/// - nodeId MUST be EPHEMERAL session key (NOT persistent identity)
/// - Ephemeral keys rotate per app session - prevents long-term tracking
/// - Topology gossip broadcasts nodeId - MUST NOT expose persistent identity
class NetworkNode {
  /// Node identifier (EPHEMERAL session key, rotates per app session)
  /// 🔐 PRIVACY: This is NOT a persistent identity - it's session-specific
  final String nodeId;
  final String displayName;
  final DateTime lastSeen;
  final bool isCurrentDevice;
  final Set<String> connectedNeighbors; // Direct connections this node has
  final int
  hopDistance; // Hops from current device (0 = self, 1 = direct neighbor, etc.)

  NetworkNode({
    required this.nodeId,
    required this.displayName,
    required this.lastSeen,
    this.isCurrentDevice = false,
    Set<String>? connectedNeighbors,
    this.hopDistance = 999, // Unknown distance by default
  }) : connectedNeighbors = connectedNeighbors ?? {};

  /// Create copy with updated fields
  NetworkNode copyWith({
    String? displayName,
    DateTime? lastSeen,
    Set<String>? connectedNeighbors,
    int? hopDistance,
  }) {
    return NetworkNode(
      nodeId: nodeId,
      displayName: displayName ?? this.displayName,
      lastSeen: lastSeen ?? this.lastSeen,
      isCurrentDevice: isCurrentDevice,
      connectedNeighbors: connectedNeighbors ?? this.connectedNeighbors,
      hopDistance: hopDistance ?? this.hopDistance,
    );
  }

  /// Check if node is active (seen in last 5 minutes)
  bool get isActive {
    return DateTime.now().difference(lastSeen).inMinutes < 5;
  }

  /// Check if node is stale (not seen in 10+ minutes)
  bool get isStale {
    return DateTime.now().difference(lastSeen).inMinutes >= 10;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is NetworkNode && nodeId == other.nodeId;

  @override
  int get hashCode => nodeId.hashCode;
}

/// Represents a connection (edge) between two nodes
class NetworkConnection {
  final String fromNodeId;
  final String toNodeId;
  final DateTime lastSeen;
  final int signalStrength; // -100 to 0 dBm (placeholder for future RSSI)

  NetworkConnection({
    required this.fromNodeId,
    required this.toNodeId,
    required this.lastSeen,
    this.signalStrength = -50, // Default medium strength
  });

  /// Check if connection is active
  bool get isActive {
    return DateTime.now().difference(lastSeen).inMinutes < 5;
  }

  /// Get connection quality (0.0 - 1.0)
  double get quality {
    // Convert dBm to quality score
    // -30 dBm = excellent (1.0)
    // -50 dBm = good (0.7)
    // -70 dBm = fair (0.4)
    // -90 dBm = poor (0.1)
    final normalized = ((signalStrength + 90) / 60).clamp(0.0, 1.0);
    return normalized;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkConnection &&
          ((fromNodeId == other.fromNodeId && toNodeId == other.toNodeId) ||
              (fromNodeId == other.toNodeId && toNodeId == other.fromNodeId));

  @override
  int get hashCode => fromNodeId.hashCode ^ toNodeId.hashCode;
}

/// Complete network graph snapshot
class NetworkTopology {
  final Map<String, NetworkNode> nodes;
  final Set<NetworkConnection> connections;
  final DateTime snapshotTime;

  NetworkTopology({
    required this.nodes,
    required this.connections,
    required this.snapshotTime,
  });

  /// Get all active nodes
  List<NetworkNode> get activeNodes {
    return nodes.values.where((node) => node.isActive).toList();
  }

  /// Get all active connections
  List<NetworkConnection> get activeConnections {
    return connections.where((conn) => conn.isActive).toList();
  }

  /// Get network size (total nodes)
  int get networkSize => nodes.length;

  /// Get active network size
  int get activeNetworkSize => activeNodes.length;

  /// Get total connections
  int get totalConnections => connections.length;

  /// Get active connections count
  int get activeConnectionsCount => activeConnections.length;

  /// Calculate network density (actual connections / possible connections)
  double get networkDensity {
    if (nodes.length < 2) return 0.0;
    final maxConnections = (nodes.length * (nodes.length - 1)) / 2;
    return connections.length / maxConnections;
  }

  /// Get average hop distance from current device
  double get averageHopDistance {
    final distances = nodes.values
        .where((node) => !node.isCurrentDevice && node.hopDistance < 999)
        .map((node) => node.hopDistance)
        .toList();

    if (distances.isEmpty) return 0.0;
    return distances.reduce((a, b) => a + b) / distances.length;
  }

  /// Find neighbors of a specific node
  List<String> getNeighbors(String nodeId) {
    return connections
        .where(
          (conn) =>
              (conn.fromNodeId == nodeId || conn.toNodeId == nodeId) &&
              conn.isActive,
        )
        .map(
          (conn) => conn.fromNodeId == nodeId ? conn.toNodeId : conn.fromNodeId,
        )
        .toList();
  }

  /// Get node by ID
  NetworkNode? getNode(String nodeId) => nodes[nodeId];

  /// Create empty topology
  factory NetworkTopology.empty() {
    return NetworkTopology(
      nodes: {},
      connections: {},
      snapshotTime: DateTime.now(),
    );
  }
}

/// Network statistics for dashboard
class NetworkStatistics {
  final int totalNodes;
  final int activeNodes;
  final int totalConnections;
  final int activeConnections;
  final double networkDensity;
  final double averageHopDistance;
  final Duration networkAge; // How long we've been tracking

  NetworkStatistics({
    required this.totalNodes,
    required this.activeNodes,
    required this.totalConnections,
    required this.activeConnections,
    required this.networkDensity,
    required this.averageHopDistance,
    required this.networkAge,
  });

  /// Create from topology
  factory NetworkStatistics.fromTopology(
    NetworkTopology topology,
    DateTime startTime,
  ) {
    return NetworkStatistics(
      totalNodes: topology.networkSize,
      activeNodes: topology.activeNetworkSize,
      totalConnections: topology.totalConnections,
      activeConnections: topology.activeConnectionsCount,
      networkDensity: topology.networkDensity,
      averageHopDistance: topology.averageHopDistance,
      networkAge: DateTime.now().difference(startTime),
    );
  }

  /// Get network health score (0.0 - 1.0)
  double get healthScore {
    final factors = [
      activeNodes > 0 ? 1.0 : 0.0, // Has active nodes
      networkDensity, // Network connectivity
      averageHopDistance < 3
          ? 1.0
          : (3 / averageHopDistance), // Low hop distance
      activeConnections > 0 ? 1.0 : 0.0, // Has active connections
    ];
    return factors.reduce((a, b) => a + b) / factors.length;
  }
}
