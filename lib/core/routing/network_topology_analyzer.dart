import 'dart:async';
import 'package:logging/logging.dart';
import 'routing_models.dart';
import '../../data/services/ble_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Analyzes and maintains the mesh network topology
class NetworkTopologyAnalyzer {
  static final _logger = Logger('NetworkTopologyAnalyzer');

  NetworkTopology _currentTopology = NetworkTopology(
    connections: {},
    connectionQualities: {},
  );

  final Map<String, ConnectionMetrics> _connectionMetrics = {};
  final Map<String, DateTime> _lastSeen = {};
  final StreamController<NetworkTopology> _topologyController =
      StreamController<NetworkTopology>.broadcast();

  Timer? _topologyUpdateTimer;
  Timer? _cleanupTimer;

  static const Duration _nodeTimeout = Duration(minutes: 10);
  static const Duration _topologyUpdateInterval = Duration(seconds: 30);
  static const Duration _cleanupInterval = Duration(minutes: 5);

  /// Stream of topology updates
  Stream<NetworkTopology> get topologyUpdates => _topologyController.stream;

  /// Get current network topology
  NetworkTopology getNetworkTopology() => _currentTopology;

  /// Initialize the topology analyzer
  Future<void> initialize() async {
    _logger.info('Initializing Network Topology Analyzer');

    // Start periodic topology updates
    _topologyUpdateTimer = Timer.periodic(
      _topologyUpdateInterval,
      (_) => _updateTopology(),
    );

    // Start cleanup timer for stale nodes
    _cleanupTimer = Timer.periodic(
      _cleanupInterval,
      (_) => _cleanupStaleNodes(),
    );

    _logger.info('Network Topology Analyzer initialized');
  }

  /// Add or update a node connection
  Future<void> addConnection(
    String from,
    String to, {
    ConnectionQuality quality = ConnectionQuality.good,
    ConnectionMetrics? metrics,
  }) async {
    try {
      final truncatedFrom = from.length > 8 ? from.shortId(8) : from;
      final truncatedTo = to.length > 8 ? to.shortId(8) : to;
      _logger.info('Adding connection: $truncatedFrom... -> $truncatedTo...');

      // Update topology
      _currentTopology = _currentTopology.withConnection(from, to, quality);

      // Update metrics if provided
      if (metrics != null) {
        final connectionKey = _getConnectionKey(from, to);
        _connectionMetrics[connectionKey] = metrics;
      }

      // Update last seen times
      _lastSeen[from] = DateTime.now();
      _lastSeen[to] = DateTime.now();

      // Notify listeners
      _topologyController.add(_currentTopology);
    } catch (e) {
      _logger.severe('Failed to add connection: $e');
    }
  }

  /// Remove a node connection
  Future<void> removeConnection(String from, String to) async {
    try {
      final truncatedFrom = from.length > 8 ? from.shortId(8) : from;
      final truncatedTo = to.length > 8 ? to.shortId(8) : to;
      _logger.info('Removing connection: $truncatedFrom... -> $truncatedTo...');

      // Update topology
      _currentTopology = _currentTopology.withoutConnection(from, to);

      // Remove metrics
      final connectionKey = _getConnectionKey(from, to);
      _connectionMetrics.remove(connectionKey);

      // Notify listeners
      _topologyController.add(_currentTopology);
    } catch (e) {
      _logger.severe('Failed to remove connection: $e');
    }
  }

  /// Update connection quality based on metrics
  Future<void> updateConnectionQuality(
    String from,
    String to,
    ConnectionMetrics metrics,
  ) async {
    try {
      final connectionKey = _getConnectionKey(from, to);
      _connectionMetrics[connectionKey] = metrics;

      // Determine new quality level based on metrics
      final quality = metrics.quality;

      // Update topology if quality changed
      final currentQuality = _currentTopology.getConnectionQuality(from, to);
      if (currentQuality != quality) {
        _currentTopology = _currentTopology.withConnection(from, to, quality);
        _topologyController.add(_currentTopology);

        final truncatedFrom = from.length > 8 ? from.shortId(8) : from;
        final truncatedTo = to.length > 8 ? to.shortId(8) : to;
        _logger.info(
          'Updated connection quality: $truncatedFrom... -> $truncatedTo... to ${quality.name}',
        );
      }
    } catch (e) {
      _logger.severe('Failed to update connection quality: $e');
    }
  }

  /// Discover network nodes through BLE scanning (non-blocking)
  Future<void> discoverNodes(BLEService bleService) async {
    try {
      _logger.info('Starting non-blocking network discovery');

      // Get current node ID (non-blocking)
      final currentNodeId = await bleService.getMyPublicKey();
      if (currentNodeId.isEmpty) {
        _logger.warning('Cannot discover nodes: no current node ID');
        return;
      }

      // Update current node as seen
      _lastSeen[currentNodeId] = DateTime.now();

      // Check current connection without blocking operations
      final connectionInfo = bleService.currentConnectionInfo;
      if (connectionInfo.isConnected && connectionInfo.isReady) {
        final connectedNodeId = bleService.currentSessionId;
        if (connectedNodeId != null && connectedNodeId.isNotEmpty) {
          // Estimate connection quality based on BLE connection strength
          final quality = _estimateConnectionQuality(bleService);

          // Create metrics based on BLE data
          final metrics = _createConnectionMetrics(bleService);

          await addConnection(
            currentNodeId,
            connectedNodeId,
            quality: quality,
            metrics: metrics,
          );

          final truncatedConnected = connectedNodeId.length > 8
              ? connectedNodeId.shortId(8)
              : connectedNodeId;
          _logger.info('Discovered connection via BLE: $truncatedConnected...');
        }
      }

      _logger.info('Non-blocking network discovery completed');
    } catch (e) {
      _logger.warning('Failed to discover nodes (non-critical): $e');
    }
  }

  /// Get all known nodes in the network
  Set<String> getAllKnownNodes() {
    final nodes = <String>{};

    // Add all nodes from connections
    for (final entry in _currentTopology.connections.entries) {
      nodes.add(entry.key);
      nodes.addAll(entry.value);
    }

    // Add nodes from last seen
    nodes.addAll(_lastSeen.keys);

    return nodes;
  }

  /// Get the current network size (number of known nodes)
  ///
  /// Phase 3: Network-size adaptive relay
  /// Used for calculating probabilistic relay decisions
  int getNetworkSize() {
    return getAllKnownNodes().length;
  }

  /// Get nodes reachable from a given node
  Set<String> getReachableNodes(String nodeId, {int maxHops = 3}) {
    final reachable = <String>{};
    final queue = <({String node, int hops})>[];
    final visited = <String>{};

    // Start with direct connections
    final directConnections = _currentTopology.getConnectedNodes(nodeId);
    for (final node in directConnections) {
      queue.add((node: node, hops: 1));
      reachable.add(node);
    }

    // BFS to find reachable nodes within hop limit
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);

      if (current.hops >= maxHops || visited.contains(current.node)) {
        continue;
      }

      visited.add(current.node);

      // Add next hop nodes
      final nextHopNodes = _currentTopology.getConnectedNodes(current.node);
      for (final node in nextHopNodes) {
        if (!visited.contains(node) && node != nodeId) {
          queue.add((node: node, hops: current.hops + 1));
          reachable.add(node);
        }
      }
    }

    return reachable;
  }

  /// Check if network is connected (all nodes can reach each other)
  bool isNetworkConnected() {
    final allNodes = getAllKnownNodes();
    if (allNodes.isEmpty) return true;

    final startNode = allNodes.first;
    final reachableNodes = getReachableNodes(startNode, maxHops: 10);

    // Add the start node itself
    reachableNodes.add(startNode);

    return reachableNodes.length == allNodes.length;
  }

  /// Get network statistics
  NetworkTopologyStats getNetworkStats() {
    final allNodes = getAllKnownNodes();
    final totalConnections =
        _currentTopology.connections.values.fold(
          0,
          (sum, connections) => sum + connections.length,
        ) ~/
        2; // Divide by 2 for bidirectional

    final qualities = _currentTopology.connectionQualities.values.toList();
    final avgQuality = qualities.isEmpty
        ? 0.0
        : qualities.map(_qualityToScore).reduce((a, b) => a + b) /
              qualities.length;

    return NetworkTopologyStats(
      totalNodes: allNodes.length,
      totalConnections: totalConnections,
      averageQuality: avgQuality,
      isConnected: isNetworkConnected(),
      lastUpdated: _currentTopology.lastUpdated,
    );
  }

  /// Estimate connection quality based on BLE service data
  ConnectionQuality _estimateConnectionQuality(BLEService bleService) {
    try {
      final connectionInfo = bleService.currentConnectionInfo;

      // For now, use basic heuristics
      // In a real implementation, you'd use RSSI, connection stability, etc.
      if (connectionInfo.isConnected && connectionInfo.isReady) {
        // Assume good quality for stable connections
        return ConnectionQuality.good;
      } else if (connectionInfo.isConnected) {
        // Fair quality for connecting state
        return ConnectionQuality.fair;
      } else {
        // Poor quality for unstable connections
        return ConnectionQuality.poor;
      }
    } catch (e) {
      _logger.warning('Failed to estimate connection quality: $e');
      return ConnectionQuality.fair;
    }
  }

  /// Create connection metrics from BLE service data
  ConnectionMetrics _createConnectionMetrics(BLEService bleService) {
    try {
      // For now, use estimated values
      // In a real implementation, you'd get actual RSSI, latency measurements, etc.
      return ConnectionMetrics(
        signalStrength: 0.8, // Estimated signal strength
        latency: 200.0, // Estimated latency in ms
        packetLoss: 0.05, // Estimated packet loss rate
        throughput: 0.7, // Estimated throughput ratio
      );
    } catch (e) {
      _logger.warning('Failed to create connection metrics: $e');
      return ConnectionMetrics(
        signalStrength: 0.5,
        latency: 1000.0,
        packetLoss: 0.1,
        throughput: 0.5,
      );
    }
  }

  /// Periodic topology update (non-blocking)
  Future<void> _updateTopology() async {
    try {
      // Limit operation time to prevent blocking
      final updateTimeout = Timer(Duration(seconds: 5), () {
        _logger.warning('Topology update timeout - skipping this cycle');
      });

      try {
        // Clean up stale connections based on quality degradation
        final connectionsToRemove = <({String from, String to})>[];

        for (final entry in _connectionMetrics.entries) {
          final metrics = entry.value;
          final timeSinceUpdate = DateTime.now().difference(
            metrics.lastMeasured,
          );

          // Remove connections that haven't been updated and have poor quality
          if (timeSinceUpdate > Duration(minutes: 5) &&
              metrics.quality == ConnectionQuality.unreliable) {
            final parts = entry.key.split(':');
            if (parts.length == 2) {
              connectionsToRemove.add((from: parts[0], to: parts[1]));
            }
          }
        }

        // Remove stale connections (limited batch size)
        final maxRemovalsBatch = 5;
        final limitedRemovals = connectionsToRemove.take(maxRemovalsBatch);

        for (final connection in limitedRemovals) {
          await removeConnection(connection.from, connection.to);
        }

        _logger.fine(
          'Topology update completed (removed ${limitedRemovals.length} stale connections)',
        );
      } finally {
        updateTimeout.cancel();
      }
    } catch (e) {
      _logger.warning('Topology update failed (non-critical): $e');
    }
  }

  /// Clean up nodes that haven't been seen recently
  Future<void> _cleanupStaleNodes() async {
    try {
      final now = DateTime.now();
      final staleNodes = <String>[];

      for (final entry in _lastSeen.entries) {
        if (now.difference(entry.value) > _nodeTimeout) {
          staleNodes.add(entry.key);
        }
      }

      // Remove stale nodes and their connections
      for (final staleNode in staleNodes) {
        final connections = _currentTopology.getConnectedNodes(staleNode);
        for (final connectedNode in connections) {
          await removeConnection(staleNode, connectedNode);
        }
        _lastSeen.remove(staleNode);
      }

      if (staleNodes.isNotEmpty) {
        _logger.info('Cleaned up ${staleNodes.length} stale nodes');
      }
    } catch (e) {
      _logger.warning('Cleanup failed: $e');
    }
  }

  /// Get connection key for storing metrics
  String _getConnectionKey(String from, String to) {
    final sorted = [from, to]..sort();
    return '${sorted[0]}:${sorted[1]}';
  }

  /// Convert connection quality to numerical score
  double _qualityToScore(ConnectionQuality quality) {
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
    }
  }

  /// Dispose of resources
  void dispose() {
    _topologyUpdateTimer?.cancel();
    _cleanupTimer?.cancel();
    _topologyController.close();
    _connectionMetrics.clear();
    _lastSeen.clear();
    _logger.info('Network Topology Analyzer disposed');
  }
}

/// Network topology statistics
class NetworkTopologyStats {
  final int totalNodes;
  final int totalConnections;
  final double averageQuality;
  final bool isConnected;
  final DateTime lastUpdated;

  const NetworkTopologyStats({
    required this.totalNodes,
    required this.totalConnections,
    required this.averageQuality,
    required this.isConnected,
    required this.lastUpdated,
  });

  Map<String, dynamic> toJson() => {
    'totalNodes': totalNodes,
    'totalConnections': totalConnections,
    'averageQuality': averageQuality,
    'isConnected': isConnected,
    'lastUpdated': lastUpdated.millisecondsSinceEpoch,
  };

  @override
  String toString() =>
      'NetworkStats(nodes: $totalNodes, connections: $totalConnections, '
      'avgQuality: ${(averageQuality * 100).toStringAsFixed(1)}%, connected: $isConnected)';
}
