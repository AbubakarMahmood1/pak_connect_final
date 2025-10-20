// Topology manager for tracking mesh network graph
// Inspired by BitChat's topology gossip system

import 'dart:async';
import 'package:logging/logging.dart';
import '../models/network_topology.dart';

/// Manages network topology tracking and gossip
class TopologyManager {
  static final _logger = Logger('TopologyManager');

  // Singleton
  static TopologyManager? _instance;
  static TopologyManager get instance {
    _instance ??= TopologyManager._();
    return _instance!;
  }

  TopologyManager._();

  // Network graph storage
  final Map<String, NetworkNode> _nodes = {};
  final Set<NetworkConnection> _connections = {};
  String? _currentNodeId;
  final DateTime _startTime = DateTime.now();

  // Update stream for UI
  final StreamController<NetworkTopology> _topologyStreamController =
      StreamController<NetworkTopology>.broadcast();
  Stream<NetworkTopology> get topologyStream => _topologyStreamController.stream;

  // Cleanup timer
  Timer? _cleanupTimer;

  /// Initialize topology manager
  void initialize(String currentNodeId) {
    _currentNodeId = currentNodeId;

    // Add self to network
    _addOrUpdateNode(
      nodeId: currentNodeId,
      displayName: 'You',
      isCurrentDevice: true,
      hopDistance: 0,
    );

    // Start periodic cleanup
    _startCleanupTimer();

    _logger.info('TopologyManager initialized for node ${currentNodeId.substring(0, 8)}...');
  }

  /// Record node announcement (basic - without neighbors)
  /// This is called when we receive an announcement from a peer
  void recordNodeAnnouncement({
    required String nodeId,
    required String displayName,
  }) {
    if (_currentNodeId == null) {
      _logger.warning('TopologyManager not initialized');
      return;
    }

    // Add/update node
    _addOrUpdateNode(
      nodeId: nodeId,
      displayName: displayName,
      hopDistance: 1, // Direct neighbor (we received announcement directly)
    );

    // Record connection to this node
    if (nodeId != _currentNodeId) {
      _addOrUpdateConnection(
        fromNodeId: _currentNodeId!,
        toNodeId: nodeId,
      );
    }

    _notifyUpdate();
  }

  /// Record node announcement with neighbors (Priority 3: Topology Gossip)
  /// This builds the full network graph from neighbor lists
  void recordNodeAnnouncementWithNeighbors({
    required String nodeId,
    required String displayName,
    required List<String> neighborIds,
  }) {
    if (_currentNodeId == null) {
      _logger.warning('TopologyManager not initialized');
      return;
    }

    // Add/update announcing node
    _addOrUpdateNode(
      nodeId: nodeId,
      displayName: displayName,
      connectedNeighbors: neighborIds.toSet(),
      hopDistance: nodeId == _currentNodeId ? 0 : 1, // Direct or self
    );

    // Record connection from us to this node (if direct announcement)
    if (nodeId != _currentNodeId) {
      _addOrUpdateConnection(
        fromNodeId: _currentNodeId!,
        toNodeId: nodeId,
      );
    }

    // Record connections FROM this node TO its neighbors
    for (final neighborId in neighborIds) {
      if (neighborId == nodeId) continue; // Skip self-connections

      // Add neighbor node (placeholder until we get their announcement)
      _addOrUpdateNode(
        nodeId: neighborId,
        displayName: 'Node ${neighborId.substring(0, 8)}',
        hopDistance: nodeId == _currentNodeId ? 1 : 2, // 1 if from us, 2 if from neighbor
      );

      // Record connection
      _addOrUpdateConnection(
        fromNodeId: nodeId,
        toNodeId: neighborId,
      );
    }

    // Update hop distances (breadth-first search from current node)
    _updateHopDistances();

    _notifyUpdate();
    _logger.fine('Recorded announcement from ${nodeId.substring(0, 8)} with ${neighborIds.length} neighbors');
  }

  /// Add or update a node
  NetworkNode _addOrUpdateNode({
    required String nodeId,
    required String displayName,
    bool isCurrentDevice = false,
    Set<String>? connectedNeighbors,
    int? hopDistance,
  }) {
    final existing = _nodes[nodeId];

    if (existing != null) {
      // Update existing node
      final updated = existing.copyWith(
        displayName: displayName,
        lastSeen: DateTime.now(),
        connectedNeighbors: connectedNeighbors,
        hopDistance: hopDistance,
      );
      _nodes[nodeId] = updated;
      return updated;
    } else {
      // Create new node
      final newNode = NetworkNode(
        nodeId: nodeId,
        displayName: displayName,
        lastSeen: DateTime.now(),
        isCurrentDevice: isCurrentDevice,
        connectedNeighbors: connectedNeighbors,
        hopDistance: hopDistance ?? 999,
      );
      _nodes[nodeId] = newNode;
      _logger.info('Added new node: ${nodeId.substring(0, 8)} ($displayName)');
      return newNode;
    }
  }

  /// Add or update a connection
  void _addOrUpdateConnection({
    required String fromNodeId,
    required String toNodeId,
  }) {
    // Remove old connection if exists
    _connections.removeWhere((conn) =>
        (conn.fromNodeId == fromNodeId && conn.toNodeId == toNodeId) ||
        (conn.fromNodeId == toNodeId && conn.toNodeId == fromNodeId));

    // Add new connection
    final connection = NetworkConnection(
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
      lastSeen: DateTime.now(),
    );
    _connections.add(connection);
  }

  /// Update hop distances from current node using BFS
  void _updateHopDistances() {
    if (_currentNodeId == null) return;

    // Reset all distances
    for (final node in _nodes.values) {
      if (!node.isCurrentDevice) {
        _nodes[node.nodeId] = node.copyWith(hopDistance: 999);
      }
    }

    // BFS to calculate distances
    final queue = <String>[_currentNodeId!];
    final distances = <String, int>{_currentNodeId!: 0};
    final visited = <String>{};

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (visited.contains(current)) continue;
      visited.add(current);

      final currentDistance = distances[current]!;

      // Find neighbors
      final neighbors = _connections
          .where((conn) =>
              conn.fromNodeId == current || conn.toNodeId == current)
          .map((conn) =>
              conn.fromNodeId == current ? conn.toNodeId : conn.fromNodeId)
          .toList();

      for (final neighbor in neighbors) {
        if (!distances.containsKey(neighbor) ||
            distances[neighbor]! > currentDistance + 1) {
          distances[neighbor] = currentDistance + 1;
          queue.add(neighbor);
        }
      }
    }

    // Update node distances
    for (final entry in distances.entries) {
      final node = _nodes[entry.key];
      if (node != null) {
        _nodes[entry.key] = node.copyWith(hopDistance: entry.value);
      }
    }
  }

  /// Get current topology snapshot
  NetworkTopology getTopology() {
    return NetworkTopology(
      nodes: Map.from(_nodes),
      connections: Set.from(_connections),
      snapshotTime: DateTime.now(),
    );
  }

  /// Get network statistics
  NetworkStatistics getStatistics() {
    final topology = getTopology();
    return NetworkStatistics.fromTopology(topology, _startTime);
  }

  /// Get our current neighbors (direct connections)
  List<String> getCurrentNeighbors() {
    if (_currentNodeId == null) return [];

    return _connections
        .where((conn) =>
            (conn.fromNodeId == _currentNodeId ||
             conn.toNodeId == _currentNodeId) &&
            conn.isActive)
        .map((conn) =>
            conn.fromNodeId == _currentNodeId
                ? conn.toNodeId
                : conn.fromNodeId)
        .toList();
  }

  /// Start cleanup timer to remove stale nodes
  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(Duration(minutes: 1), (_) {
      _cleanupStaleData();
    });
  }

  /// Remove stale nodes and connections
  void _cleanupStaleData() {
    final now = DateTime.now();
    int nodesRemoved = 0;
    int connectionsRemoved = 0;

    // Remove stale nodes (not seen in 10+ minutes, except current device)
    _nodes.removeWhere((id, node) {
      if (node.isCurrentDevice) return false;
      if (now.difference(node.lastSeen).inMinutes >= 10) {
        nodesRemoved++;
        return true;
      }
      return false;
    });

    // Remove stale connections (not seen in 10+ minutes)
    _connections.removeWhere((conn) {
      if (now.difference(conn.lastSeen).inMinutes >= 10) {
        connectionsRemoved++;
        return true;
      }
      return false;
    });

    // Remove connections to non-existent nodes
    _connections.removeWhere((conn) =>
        !_nodes.containsKey(conn.fromNodeId) ||
        !_nodes.containsKey(conn.toNodeId));

    if (nodesRemoved > 0 || connectionsRemoved > 0) {
      _logger.info('Cleanup: removed $nodesRemoved nodes, $connectionsRemoved connections');
      _notifyUpdate();
    }
  }

  /// Notify listeners of topology update
  void _notifyUpdate() {
    if (!_topologyStreamController.isClosed) {
      _topologyStreamController.add(getTopology());
    }
  }

  /// Clear all topology data (for testing)
  void clear() {
    _nodes.clear();
    _connections.clear();

    // Re-add self if initialized
    if (_currentNodeId != null) {
      _addOrUpdateNode(
        nodeId: _currentNodeId!,
        displayName: 'You',
        isCurrentDevice: true,
        hopDistance: 0,
      );
    }

    _notifyUpdate();
    _logger.info('Topology data cleared');
  }

  /// Dispose resources
  void dispose() {
    _cleanupTimer?.cancel();
    _topologyStreamController.close();
    _logger.info('TopologyManager disposed');
  }
}
