import 'network_topology_analyzer.dart';
import 'connection_quality_monitor.dart';
import '../utils/string_extensions.dart';

/// Smart router statistics.
class SmartRouterStats {
  final String nodeId;
  final int cachedDecisions;
  final NetworkTopologyStats topologyStats;
  final QualityMonitoringStats qualityStats;
  final Map<String, int> cacheStats;

  const SmartRouterStats({
    required this.nodeId,
    required this.cachedDecisions,
    required this.topologyStats,
    required this.qualityStats,
    required this.cacheStats,
  });

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'cachedDecisions': cachedDecisions,
    'topologyStats': topologyStats.toJson(),
    'qualityStats': qualityStats.toJson(),
    'cacheStats': cacheStats,
  };

  @override
  String toString() =>
      'SmartRouterStats(node: ${nodeId.shortId(8)}..., '
      'cached: $cachedDecisions)';
}
