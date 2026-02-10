// Network topology visualization screen
// Shows live mesh network graph with nodes and connections

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/network_topology.dart';
import '../providers/mesh_networking_provider.dart';
import 'dart:math' as math;
import 'package:pak_connect/core/utils/string_extensions.dart';

class NetworkTopologyScreen extends ConsumerStatefulWidget {
  const NetworkTopologyScreen({super.key});

  @override
  ConsumerState<NetworkTopologyScreen> createState() =>
      _NetworkTopologyScreenState();
}

class _NetworkTopologyScreenState extends ConsumerState<NetworkTopologyScreen> {
  NetworkTopology? _topology;
  NetworkStatistics? _statistics;
  late final ProviderSubscription<AsyncValue<NetworkTopology>> _topologySub;

  @override
  void initState() {
    super.initState();
    _loadTopology();

    // Listen for topology updates with manual subscription (allowed in initState).
    _topologySub = ref.listenManual<AsyncValue<NetworkTopology>>(
      topologyStreamProvider,
      (prev, next) {
        next.whenData((topology) {
          if (!mounted) return;
          setState(() {
            _topology = topology;
            _statistics = ref.read(topologyManagerProvider).getStatistics();
          });
        });
      },
    );
  }

  void _loadTopology() {
    final topologyManager = ref.read(topologyManagerProvider);
    setState(() {
      _topology = topologyManager.getTopology();
      _statistics = topologyManager.getStatistics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Mesh Network'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadTopology,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _topology == null
          ? Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async => _loadTopology(),
              child: SingleChildScrollView(
                physics: AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    // Network statistics dashboard
                    _buildStatisticsDashboard(theme),

                    SizedBox(height: 16),

                    // Network graph visualization
                    _buildNetworkGraph(theme),

                    SizedBox(height: 16),

                    // Node list
                    _buildNodeList(theme),

                    SizedBox(height: 16),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildStatisticsDashboard(ThemeData theme) {
    if (_statistics == null) return SizedBox.shrink();

    final healthScore = _statistics!.healthScore;
    final healthColor = healthScore > 0.7
        ? Colors.green
        : healthScore > 0.4
        ? Colors.orange
        : Colors.red;

    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub, color: theme.colorScheme.primary),
                SizedBox(width: 8),
                Text(
                  'Network Status',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),

            // Health indicator
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Network Health', style: theme.textTheme.bodySmall),
                      SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: healthScore,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(healthColor),
                        minHeight: 8,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 16),
                Text(
                  '${(healthScore * 100).toInt()}%',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: healthColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            SizedBox(height: 16),

            // Statistics grid
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _buildStatChip(
                  theme,
                  icon: Icons.devices,
                  label: 'Nodes',
                  value:
                      '${_statistics!.activeNodes}/${_statistics!.totalNodes}',
                  color: Colors.blue,
                ),
                _buildStatChip(
                  theme,
                  icon: Icons.link,
                  label: 'Connections',
                  value:
                      '${_statistics!.activeConnections}/${_statistics!.totalConnections}',
                  color: Colors.green,
                ),
                _buildStatChip(
                  theme,
                  icon: Icons.route,
                  label: 'Avg Hops',
                  value: _statistics!.averageHopDistance.toStringAsFixed(1),
                  color: Colors.orange,
                ),
                _buildStatChip(
                  theme,
                  icon: Icons.pie_chart,
                  label: 'Density',
                  value: '${(_statistics!.networkDensity * 100).toInt()}%',
                  color: Colors.purple,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          SizedBox(width: 6),
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkGraph(ThemeData theme) {
    if (_topology == null) return SizedBox.shrink();

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.account_tree, color: theme.colorScheme.primary),
                SizedBox(width: 8),
                Text(
                  'Network Graph',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 300,
            child: NetworkGraphPainter(topology: _topology!, theme: theme),
          ),
          Padding(
            padding: EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildLegendItem(theme, Colors.blue, 'You', Icons.person),
                _buildLegendItem(theme, Colors.green, 'Active', Icons.circle),
                _buildLegendItem(
                  theme,
                  Colors.grey,
                  'Inactive',
                  Icons.circle_outlined,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(
    ThemeData theme,
    Color color,
    String label,
    IconData icon,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 12),
        SizedBox(width: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _buildNodeList(ThemeData theme) {
    if (_topology == null) return SizedBox.shrink();

    final nodes = _topology!.nodes.values.toList()
      ..sort((a, b) {
        // Current device first
        if (a.isCurrentDevice) return -1;
        if (b.isCurrentDevice) return 1;
        // Then by hop distance
        if (a.hopDistance != b.hopDistance) {
          return a.hopDistance.compareTo(b.hopDistance);
        }
        // Then by last seen
        return b.lastSeen.compareTo(a.lastSeen);
      });

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.list, color: theme.colorScheme.primary),
                SizedBox(width: 8),
                Text(
                  'Network Nodes (${nodes.length})',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          ListView.separated(
            shrinkWrap: true,
            physics: NeverScrollableScrollPhysics(),
            itemCount: nodes.length,
            separatorBuilder: (context, index) => Divider(height: 1),
            itemBuilder: (context, index) {
              final node = nodes[index];
              return _buildNodeListItem(theme, node);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNodeListItem(ThemeData theme, NetworkNode node) {
    final isActive = node.isActive;
    final statusColor = node.isCurrentDevice
        ? Colors.blue
        : isActive
        ? Colors.green
        : Colors.grey;

    final neighbors = _topology!.getNeighbors(node.nodeId);

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: statusColor.withValues(alpha: 0.2),
        ),
        child: Center(
          child: Icon(
            node.isCurrentDevice ? Icons.person : Icons.devices,
            color: statusColor,
            size: 20,
          ),
        ),
      ),
      title: Text(
        node.displayName,
        style: TextStyle(
          fontWeight: node.isCurrentDevice
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ID: ${node.nodeId.shortId()}...',
            style: TextStyle(fontFamily: 'monospace', fontSize: 10),
          ),
          SizedBox(height: 2),
          Wrap(
            spacing: 8,
            children: [
              _buildNodeBadge(theme, Icons.route, '${node.hopDistance} hops'),
              _buildNodeBadge(
                theme,
                Icons.link,
                '${neighbors.length} connections',
              ),
              if (!node.isCurrentDevice)
                _buildNodeBadge(
                  theme,
                  Icons.access_time,
                  _getTimeAgo(node.lastSeen),
                ),
            ],
          ),
        ],
      ),
      trailing: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor),
      ),
    );
  }

  Widget _buildNodeBadge(ThemeData theme, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 10, color: theme.colorScheme.onSurfaceVariant),
        SizedBox(width: 2),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _getTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  void dispose() {
    _topologySub.close();
    super.dispose();
  }
}

/// Custom painter for network graph visualization
class NetworkGraphPainter extends StatelessWidget {
  final NetworkTopology topology;
  final ThemeData theme;

  const NetworkGraphPainter({
    super.key,
    required this.topology,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GraphPainter(topology: topology, theme: theme),
      child: Container(),
    );
  }
}

class _GraphPainter extends CustomPainter {
  final NetworkTopology topology;
  final ThemeData theme;

  _GraphPainter({required this.topology, required this.theme});

  @override
  void paint(Canvas canvas, Size size) {
    final nodes = topology.activeNodes;
    if (nodes.isEmpty) {
      _paintEmptyState(canvas, size);
      return;
    }

    // Calculate node positions (circular layout)
    final positions = _calculateNodePositions(nodes, size);

    // Draw connections first (behind nodes)
    _paintConnections(canvas, positions);

    // Draw nodes on top
    _paintNodes(canvas, positions);
  }

  void _paintEmptyState(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'No active nodes\nConnect to peers to see the mesh network',
        style: TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 14,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: size.width - 32);
    textPainter.paint(
      canvas,
      Offset(
        (size.width - textPainter.width) / 2,
        (size.height - textPainter.height) / 2,
      ),
    );
  }

  Map<String, Offset> _calculateNodePositions(
    List<NetworkNode> nodes,
    Size size,
  ) {
    final positions = <String, Offset>{};
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.35;

    if (nodes.length == 1) {
      positions[nodes[0].nodeId] = center;
      return positions;
    }

    // Place current device in center
    final currentNode = nodes.firstWhere(
      (n) => n.isCurrentDevice,
      orElse: () => nodes.first,
    );
    positions[currentNode.nodeId] = center;

    // Place other nodes in a circle
    final otherNodes = nodes.where((n) => !n.isCurrentDevice).toList();
    final angleStep = (2 * math.pi) / otherNodes.length;

    for (int i = 0; i < otherNodes.length; i++) {
      final angle = i * angleStep - math.pi / 2; // Start from top
      final x = center.dx + radius * math.cos(angle);
      final y = center.dy + radius * math.sin(angle);
      positions[otherNodes[i].nodeId] = Offset(x, y);
    }

    return positions;
  }

  void _paintConnections(Canvas canvas, Map<String, Offset> positions) {
    final paint = Paint()
      ..color = theme.colorScheme.outlineVariant
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final connection in topology.activeConnections) {
      final from = positions[connection.fromNodeId];
      final to = positions[connection.toNodeId];

      if (from != null && to != null) {
        canvas.drawLine(from, to, paint);
      }
    }
  }

  void _paintNodes(Canvas canvas, Map<String, Offset> positions) {
    for (final node in topology.activeNodes) {
      final position = positions[node.nodeId];
      if (position == null) continue;

      final isCurrentDevice = node.isCurrentDevice;
      final nodeColor = isCurrentDevice
          ? Colors.blue
          : node.isActive
          ? Colors.green
          : Colors.grey;

      // Draw node circle
      final nodePaint = Paint()
        ..color = nodeColor.withValues(alpha: 1.0)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(position, isCurrentDevice ? 16 : 12, nodePaint);

      // Draw node border
      final borderPaint = Paint()
        ..color = theme.colorScheme.surface
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      canvas.drawCircle(position, isCurrentDevice ? 16 : 12, borderPaint);

      // Draw node label
      final textPainter = TextPainter(
        text: TextSpan(
          text: node.displayName.length > 10
              ? '${node.displayName.shortId(10)}...'
              : node.displayName,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 10,
            fontWeight: isCurrentDevice ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          position.dx - textPainter.width / 2,
          position.dy + (isCurrentDevice ? 20 : 16),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) {
    return oldDelegate.topology != topology;
  }
}
