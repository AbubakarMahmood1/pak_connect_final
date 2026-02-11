import 'package:flutter/material.dart';
import '../../domain/routing/routing_models.dart';
import '../../domain/routing/network_topology_analyzer.dart';
import '../../domain/routing/connection_quality_monitor.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

/// Widget that displays routing status and decisions for monitoring purposes
class RoutingStatusIndicator extends StatelessWidget {
  final RoutingDecision? lastDecision;
  final NetworkTopologyStats? topologyStats;
  final QualityMonitoringStats? qualityStats;

  const RoutingStatusIndicator({
    super.key,
    this.lastDecision,
    this.topologyStats,
    this.qualityStats,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getStatusColor(context).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _getStatusColor(context), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_getStatusIcon(), color: _getStatusColor(context), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _getStatusTitle(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _getStatusColor(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_getStatusDescription(), style: const TextStyle(fontSize: 11)),
          if (lastDecision != null && lastDecision!.routePath != null) ...[
            const SizedBox(height: 8),
            _buildRoutePath(context),
          ],
          if (topologyStats != null || qualityStats != null) ...[
            const SizedBox(height: 8),
            _buildNetworkStats(context),
          ],
        ],
      ),
    );
  }

  /// Build route path visualization
  Widget _buildRoutePath(BuildContext context) {
    final path = lastDecision!.routePath!;
    if (path.length < 2) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Route Path:',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (int i = 0; i < path.length; i++) ...[
              if (i > 0) ...[
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward, size: 12, color: Colors.grey[600]),
                const SizedBox(width: 4),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: i == 0
                      ? Colors.green.withValues(alpha: 0.2)
                      : i == path.length - 1
                      ? Colors.orange.withValues(alpha: 0.2)
                      : Colors.blue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: i == 0
                        ? Colors.green
                        : i == path.length - 1
                        ? Colors.orange
                        : Colors.blue,
                    width: 0.5,
                  ),
                ),
                child: Text(
                  path[i].shortId(4),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: i == 0
                        ? Colors.green[700]
                        : i == path.length - 1
                        ? Colors.orange[700]
                        : Colors.blue[700],
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Build network statistics display
  Widget _buildNetworkStats(BuildContext context) {
    return Row(
      children: [
        if (topologyStats != null) ...[
          Expanded(
            child: _buildStatCard(
              'Network',
              '${topologyStats!.totalNodes} nodes',
              topologyStats!.isConnected ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(width: 8),
        ],
        if (qualityStats != null) ...[
          Expanded(
            child: _buildStatCard(
              'Quality',
              '${(qualityStats!.averageQuality * 100).toInt()}%',
              _getQualityColor(qualityStats!.averageQuality),
            ),
          ),
        ],
      ],
    );
  }

  /// Build individual stat card
  Widget _buildStatCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Get status color based on decision type
  Color _getStatusColor(BuildContext context) {
    if (lastDecision == null) return Colors.grey;

    switch (lastDecision!.type) {
      case RoutingType.direct:
        return Colors.green;
      case RoutingType.relay:
        return Colors.blue;
      case RoutingType.failed:
        return Colors.red;
    }
  }

  /// Get status icon based on decision type
  IconData _getStatusIcon() {
    if (lastDecision == null) return Icons.help_outline;

    switch (lastDecision!.type) {
      case RoutingType.direct:
        return Icons.near_me;
      case RoutingType.relay:
        return Icons.route;
      case RoutingType.failed:
        return Icons.error_outline;
    }
  }

  /// Get status title
  String _getStatusTitle() {
    if (lastDecision == null) return 'Smart Routing Standby';

    switch (lastDecision!.type) {
      case RoutingType.direct:
        return 'Direct Route Selected';
      case RoutingType.relay:
        return 'Smart Relay Route';
      case RoutingType.failed:
        return 'Routing Failed';
    }
  }

  /// Get status description
  String _getStatusDescription() {
    if (lastDecision == null) {
      return 'Waiting for routing decisions...';
    }

    final decision = lastDecision!;
    final scoreText = decision.routeScore != null
        ? ' (Score: ${(decision.routeScore! * 100).toInt()}%)'
        : '';

    switch (decision.type) {
      case RoutingType.direct:
        return 'Message will be sent directly to recipient$scoreText';
      case RoutingType.relay:
        final hopCount = decision.routePath?.length ?? 2;
        return 'Message will be relayed through ${hopCount - 1} hop(s)$scoreText';
      case RoutingType.failed:
        return decision.reason ?? 'Routing failed for unknown reason';
    }
  }

  /// Get color based on quality score
  Color _getQualityColor(double quality) {
    if (quality >= 0.8) return Colors.green;
    if (quality >= 0.6) return Colors.orange;
    if (quality >= 0.4) return Colors.red;
    return Colors.grey;
  }
}

/// Compact routing status indicator for messages
class CompactRoutingIndicator extends StatelessWidget {
  final RoutingDecision decision;
  final bool showDetails;

  const CompactRoutingIndicator({
    super.key,
    required this.decision,
    this.showDetails = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _getStatusColor().withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _getStatusColor(), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_getStatusIcon(), size: 10, color: _getStatusColor()),
          const SizedBox(width: 4),
          Text(
            _getStatusText(),
            style: TextStyle(
              fontSize: 8,
              color: _getStatusColor(),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (showDetails && decision.routeScore != null) ...[
            const SizedBox(width: 4),
            Text(
              '${(decision.routeScore! * 100).toInt()}%',
              style: TextStyle(
                fontSize: 7,
                color: _getStatusColor().withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getStatusColor() {
    switch (decision.type) {
      case RoutingType.direct:
        return Colors.green;
      case RoutingType.relay:
        return Colors.blue;
      case RoutingType.failed:
        return Colors.red;
    }
  }

  IconData _getStatusIcon() {
    switch (decision.type) {
      case RoutingType.direct:
        return Icons.near_me;
      case RoutingType.relay:
        return Icons.route;
      case RoutingType.failed:
        return Icons.error_outline;
    }
  }

  String _getStatusText() {
    switch (decision.type) {
      case RoutingType.direct:
        return 'Direct';
      case RoutingType.relay:
        final hopCount = decision.routePath?.length ?? 2;
        return '${hopCount - 1}hop';
      case RoutingType.failed:
        return 'Failed';
    }
  }
}

/// Network topology visualization widget
class NetworkTopologyVisualization extends StatelessWidget {
  final NetworkTopologyStats stats;
  final bool compactView;

  const NetworkTopologyVisualization({
    super.key,
    required this.stats,
    this.compactView = true,
  });

  @override
  Widget build(BuildContext context) {
    if (compactView) {
      return _buildCompactView(context);
    } else {
      return _buildDetailedView(context);
    }
  }

  Widget _buildCompactView(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hub,
            size: 14,
            color: stats.isConnected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 6),
          Text(
            '${stats.totalNodes}N/${stats.totalConnections}C',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 6),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _getQualityColor(stats.averageQuality),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailedView(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.hub,
                size: 16,
                color: stats.isConnected ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              const Text(
                'Network Topology',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: stats.isConnected ? Colors.green : Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildNetworkStat(
                  'Nodes',
                  '${stats.totalNodes}',
                  Colors.blue,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildNetworkStat(
                  'Links',
                  '${stats.totalConnections}',
                  Colors.green,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildNetworkStat(
                  'Quality',
                  '${(stats.averageQuality * 100).toInt()}%',
                  _getQualityColor(stats.averageQuality),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkStat(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Color _getQualityColor(double quality) {
    if (quality >= 0.8) return Colors.green;
    if (quality >= 0.6) return Colors.orange;
    if (quality >= 0.4) return Colors.red;
    return Colors.grey;
  }
}
