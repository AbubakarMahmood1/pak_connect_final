import 'dart:async';
import 'dart:math';
import 'package:logging/logging.dart';
import 'routing_models.dart';
import '../../data/services/ble_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Monitors connection quality and provides scoring for routing decisions
class ConnectionQualityMonitor {
  static final _logger = Logger('ConnectionQualityMonitor');

  final Map<String, ConnectionMetrics> _connectionMetrics = {};
  final Map<String, List<double>> _latencyHistory = {};
  final Map<String, List<double>> _signalHistory = {};
  final Map<String, int> _messagesSent = {};
  final Map<String, int> _messagesAcked = {};
  final Map<String, DateTime> _lastUpdate = {};

  Timer? _monitoringTimer;
  Timer? _historyCleanupTimer;

  static const Duration _monitoringInterval = Duration(seconds: 10);
  static const int _maxHistoryEntries = 360; // 1 hour of 10-second intervals

  /// Initialize the connection quality monitor
  Future<void> initialize() async {
    _logger.info('Initializing Connection Quality Monitor');

    // Start periodic monitoring
    _monitoringTimer = Timer.periodic(
      _monitoringInterval,
      (_) => _updateConnectionMetrics(),
    );

    // Start history cleanup
    _historyCleanupTimer = Timer.periodic(
      Duration(minutes: 15),
      (_) => _cleanupHistory(),
    );

    _logger.info('Connection Quality Monitor initialized');
  }

  /// Get current connection metrics for a node
  ConnectionMetrics? getConnectionMetrics(String nodeId) {
    return _connectionMetrics[nodeId];
  }

  /// Get connection quality score between current node and target
  Future<double> getConnectionScore(String nodeId) async {
    final metrics = _connectionMetrics[nodeId];
    if (metrics == null) {
      // No data available, return neutral score
      return 0.5;
    }

    return metrics.qualityScore;
  }

  /// Record a message sent to track delivery statistics
  void recordMessageSent(String nodeId, String messageId) {
    _messagesSent[nodeId] = (_messagesSent[nodeId] ?? 0) + 1;
    final truncatedNodeId = nodeId.length > 8 ? nodeId.shortId(8) : nodeId;
    _logger.fine('Message sent to $truncatedNodeId...: $messageId');
  }

  /// Record a message acknowledgment to track delivery success
  void recordMessageAcknowledged(
    String nodeId,
    String messageId, {
    double? latency,
  }) {
    _messagesAcked[nodeId] = (_messagesAcked[nodeId] ?? 0) + 1;

    if (latency != null) {
      _recordLatency(nodeId, latency);
    }

    final truncatedNodeId = nodeId.length > 8 ? nodeId.shortId(8) : nodeId;
    _logger.fine(
      'Message acknowledged from $truncatedNodeId...: $messageId (latency: ${latency?.toStringAsFixed(0)}ms)',
    );
  }

  /// Measure connection quality with BLE service
  Future<void> measureConnectionQuality(
    String nodeId,
    BLEService bleService,
  ) async {
    try {
      if (!bleService.isConnected) {
        _logger.fine('Cannot measure quality - not connected to $nodeId');
        return;
      }

      final connectionInfo = bleService.currentConnectionInfo;
      if (!connectionInfo.isReady) {
        _logger.fine(
          'Cannot measure quality - connection not ready to $nodeId',
        );
        return;
      }

      // Measure signal strength (simulated for BLE - in real implementation use RSSI)
      final signalStrength = _measureSignalStrength(bleService);
      _recordSignalStrength(nodeId, signalStrength);

      // Calculate packet loss rate
      final packetLoss = _calculatePacketLoss(nodeId);

      // Get average latency
      final avgLatency = _getAverageLatency(nodeId);

      // Estimate throughput based on recent activity
      final throughput = _estimateThroughput(nodeId);

      // Create updated metrics
      final metrics = ConnectionMetrics(
        signalStrength: signalStrength,
        latency: avgLatency,
        packetLoss: packetLoss,
        throughput: throughput,
      );

      // Store metrics
      _connectionMetrics[nodeId] = metrics;
      _lastUpdate[nodeId] = DateTime.now();

      final truncatedNodeId = nodeId.length > 8 ? nodeId.shortId(8) : nodeId;
      _logger.fine(
        'Updated metrics for $truncatedNodeId...: ${metrics.quality.name} (score: ${metrics.qualityScore.toStringAsFixed(2)})',
      );
    } catch (e) {
      _logger.warning('Failed to measure connection quality for $nodeId: $e');
    }
  }

  /// Simulate connection degradation for demo purposes
  Future<void> simulateConnectionDegradation(
    String nodeId, {
    double signalReduction = 0.2,
    double latencyIncrease = 500.0,
    double packetLossIncrease = 0.1,
  }) async {
    final currentMetrics = _connectionMetrics[nodeId];
    if (currentMetrics == null) return;

    final degradedMetrics = ConnectionMetrics(
      signalStrength: (currentMetrics.signalStrength - signalReduction).clamp(
        0.0,
        1.0,
      ),
      latency: currentMetrics.latency + latencyIncrease,
      packetLoss: (currentMetrics.packetLoss + packetLossIncrease).clamp(
        0.0,
        1.0,
      ),
      throughput: (currentMetrics.throughput * 0.7).clamp(0.0, 1.0),
    );

    _connectionMetrics[nodeId] = degradedMetrics;
    _lastUpdate[nodeId] = DateTime.now();

    final truncatedNodeId = nodeId.length > 8 ? nodeId.shortId(8) : nodeId;
    _logger.info(
      'Simulated connection degradation for $truncatedNodeId...: ${degradedMetrics.quality.name}',
    );
  }

  /// Simulate connection improvement for demo purposes
  Future<void> simulateConnectionImprovement(
    String nodeId, {
    double signalBoost = 0.3,
    double latencyReduction = 300.0,
    double packetLossReduction = 0.05,
  }) async {
    final currentMetrics = _connectionMetrics[nodeId];
    if (currentMetrics == null) return;

    final improvedMetrics = ConnectionMetrics(
      signalStrength: (currentMetrics.signalStrength + signalBoost).clamp(
        0.0,
        1.0,
      ),
      latency: (currentMetrics.latency - latencyReduction).clamp(50.0, 5000.0),
      packetLoss: (currentMetrics.packetLoss - packetLossReduction).clamp(
        0.0,
        1.0,
      ),
      throughput: (currentMetrics.throughput * 1.2).clamp(0.0, 1.0),
    );

    _connectionMetrics[nodeId] = improvedMetrics;
    _lastUpdate[nodeId] = DateTime.now();

    final truncatedNodeId = nodeId.length > 8 ? nodeId.shortId(8) : nodeId;
    _logger.info(
      'Simulated connection improvement for $truncatedNodeId...: ${improvedMetrics.quality.name}',
    );
  }

  /// Get connection quality statistics for all monitored connections
  Map<String, ConnectionQuality> getAllConnectionQualities() {
    final qualities = <String, ConnectionQuality>{};

    for (final entry in _connectionMetrics.entries) {
      qualities[entry.key] = entry.value.quality;
    }

    return qualities;
  }

  /// Get quality monitoring statistics
  QualityMonitoringStats getMonitoringStats() {
    final totalConnections = _connectionMetrics.length;
    final averageQuality = _connectionMetrics.values.isEmpty
        ? 0.0
        : _connectionMetrics.values
                  .map((m) => m.qualityScore)
                  .reduce((a, b) => a + b) /
              totalConnections;

    final totalMessagesSent = _messagesSent.values.fold(
      0,
      (sum, count) => sum + count,
    );
    final totalMessagesAcked = _messagesAcked.values.fold(
      0,
      (sum, count) => sum + count,
    );

    final deliveryRate = totalMessagesSent > 0
        ? totalMessagesAcked / totalMessagesSent
        : 0.0;

    return QualityMonitoringStats(
      monitoredConnections: totalConnections,
      averageQuality: averageQuality,
      totalMessagesSent: totalMessagesSent,
      totalMessagesAcked: totalMessagesAcked,
      deliveryRate: deliveryRate,
      lastUpdated: DateTime.now(),
    );
  }

  /// Measure signal strength (simulated for BLE)
  double _measureSignalStrength(BLEService bleService) {
    try {
      final connectionInfo = bleService.currentConnectionInfo;

      // Simulate signal strength based on connection stability
      // In a real implementation, you'd use RSSI values from BLE
      if (connectionInfo.isConnected && connectionInfo.isReady) {
        // Add some randomness to simulate real-world conditions
        final baseStrength = 0.8;
        final noise = (Random().nextDouble() - 0.5) * 0.2; // ±10%
        return (baseStrength + noise).clamp(0.0, 1.0);
      } else {
        return 0.3; // Poor signal for unstable connections
      }
    } catch (e) {
      _logger.warning('Failed to measure signal strength: $e');
      return 0.5; // Default neutral value
    }
  }

  /// Record signal strength measurement
  void _recordSignalStrength(String nodeId, double signalStrength) {
    _signalHistory.putIfAbsent(nodeId, () => <double>[]).add(signalStrength);

    // Limit history size
    final history = _signalHistory[nodeId]!;
    if (history.length > _maxHistoryEntries) {
      history.removeAt(0);
    }
  }

  /// Record latency measurement
  void _recordLatency(String nodeId, double latency) {
    _latencyHistory.putIfAbsent(nodeId, () => <double>[]).add(latency);

    // Limit history size
    final history = _latencyHistory[nodeId]!;
    if (history.length > _maxHistoryEntries) {
      history.removeAt(0);
    }
  }

  /// Calculate packet loss rate for a connection
  double _calculatePacketLoss(String nodeId) {
    final sent = _messagesSent[nodeId] ?? 0;
    final acked = _messagesAcked[nodeId] ?? 0;

    if (sent == 0) return 0.0;

    final lossRate = 1.0 - (acked / sent);
    return lossRate.clamp(0.0, 1.0);
  }

  /// Get average latency for a connection
  double _getAverageLatency(String nodeId) {
    final latencies = _latencyHistory[nodeId];
    if (latencies == null || latencies.isEmpty) {
      return 1000.0; // Default 1 second latency
    }

    // Calculate moving average of recent latencies
    final recentLatencies = latencies.length > 10
        ? latencies.sublist(latencies.length - 10)
        : latencies;

    final sum = recentLatencies.reduce((a, b) => a + b);
    return sum / recentLatencies.length;
  }

  /// Estimate throughput based on recent activity
  double _estimateThroughput(String nodeId) {
    final sent = _messagesSent[nodeId] ?? 0;
    final acked = _messagesAcked[nodeId] ?? 0;
    final lastUpdate = _lastUpdate[nodeId];

    if (lastUpdate == null || sent == 0) {
      return 0.5; // Default moderate throughput
    }

    // Simple throughput estimation based on success rate and recency
    final successRate = acked / sent;
    final timeSinceUpdate = DateTime.now().difference(lastUpdate).inSeconds;

    // Reduce throughput estimate if connection hasn't been used recently
    final recencyFactor = timeSinceUpdate < 60 ? 1.0 : 0.5;

    return (successRate * recencyFactor).clamp(0.0, 1.0);
  }

  /// Periodic update of connection metrics (non-blocking)
  Future<void> _updateConnectionMetrics() async {
    try {
      // Limit operation time to prevent blocking
      final updateTimeout = Timer(Duration(seconds: 3), () {
        _logger.fine(
          'Connection metrics update timeout - completing partial update',
        );
      });

      try {
        // Update metrics for connections that haven't been updated recently
        final now = DateTime.now();
        final staleConnections = <String>[];

        for (final nodeId in _connectionMetrics.keys.toList()) {
          final lastUpdate = _lastUpdate[nodeId];
          if (lastUpdate == null ||
              now.difference(lastUpdate) > _monitoringInterval * 2) {
            staleConnections.add(nodeId);
          }
        }

        // Process in batches to prevent blocking
        const batchSize = 3;
        final batches = <List<String>>[];
        for (int i = 0; i < staleConnections.length; i += batchSize) {
          batches.add(
            staleConnections.sublist(
              i,
              (i + batchSize).clamp(0, staleConnections.length),
            ),
          );
        }

        for (final batch in batches) {
          for (final nodeId in batch) {
            await _degradeStaleConnection(nodeId);
          }
          // Small delay between batches to prevent blocking
          if (batch != batches.last) {
            await Future.delayed(Duration(milliseconds: 100));
          }
        }
      } finally {
        updateTimeout.cancel();
      }
    } catch (e) {
      _logger.warning('Connection metrics update failed (non-critical): $e');
    }
  }

  /// Degrade quality for connections that haven't been updated
  Future<void> _degradeStaleConnection(String nodeId) async {
    final currentMetrics = _connectionMetrics[nodeId];
    if (currentMetrics == null) return;

    // Gradually degrade stale connections
    final degradedMetrics = ConnectionMetrics(
      signalStrength: (currentMetrics.signalStrength * 0.9).clamp(0.0, 1.0),
      latency: (currentMetrics.latency * 1.1).clamp(50.0, 5000.0),
      packetLoss: (currentMetrics.packetLoss * 1.05).clamp(0.0, 1.0),
      throughput: (currentMetrics.throughput * 0.95).clamp(0.0, 1.0),
    );

    _connectionMetrics[nodeId] = degradedMetrics;
    _lastUpdate[nodeId] = DateTime.now();

    final truncatedNodeId = nodeId.length > 8 ? nodeId.shortId(8) : nodeId;
    _logger.fine(
      'Degraded stale connection $truncatedNodeId...: ${degradedMetrics.quality.name}',
    );
  }

  /// Clean up old history data
  void _cleanupHistory() {
    try {
      // For simplicity, we'll just limit the size of history arrays
      // In a real implementation, you'd store timestamps with each measurement

      for (final history in _latencyHistory.values) {
        if (history.length > _maxHistoryEntries) {
          history.removeRange(0, history.length - _maxHistoryEntries);
        }
      }

      for (final history in _signalHistory.values) {
        if (history.length > _maxHistoryEntries) {
          history.removeRange(0, history.length - _maxHistoryEntries);
        }
      }

      _logger.fine('Cleaned up connection quality history');
    } catch (e) {
      _logger.warning('History cleanup failed: $e');
    }
  }

  /// Clear all monitoring data
  void clearAll() {
    _connectionMetrics.clear();
    _latencyHistory.clear();
    _signalHistory.clear();
    _messagesSent.clear();
    _messagesAcked.clear();
    _lastUpdate.clear();
    _logger.info('Cleared all connection quality monitoring data');
  }

  /// Dispose of resources
  void dispose() {
    _monitoringTimer?.cancel();
    _historyCleanupTimer?.cancel();
    clearAll();
    _logger.info('Connection Quality Monitor disposed');
  }
}

/// Quality monitoring statistics
class QualityMonitoringStats {
  final int monitoredConnections;
  final double averageQuality;
  final int totalMessagesSent;
  final int totalMessagesAcked;
  final double deliveryRate;
  final DateTime lastUpdated;

  const QualityMonitoringStats({
    required this.monitoredConnections,
    required this.averageQuality,
    required this.totalMessagesSent,
    required this.totalMessagesAcked,
    required this.deliveryRate,
    required this.lastUpdated,
  });

  Map<String, dynamic> toJson() => {
    'monitoredConnections': monitoredConnections,
    'averageQuality': averageQuality,
    'totalMessagesSent': totalMessagesSent,
    'totalMessagesAcked': totalMessagesAcked,
    'deliveryRate': deliveryRate,
    'lastUpdated': lastUpdated.millisecondsSinceEpoch,
  };

  @override
  String toString() =>
      'QualityStats(connections: $monitoredConnections, '
      'avgQuality: ${(averageQuality * 100).toStringAsFixed(1)}%, '
      'delivery: ${(deliveryRate * 100).toStringAsFixed(1)}%)';
}
