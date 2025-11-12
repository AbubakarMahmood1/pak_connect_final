/// Performance Metrics Display Widget
///
/// Shows in-app encryption performance metrics to help users and developers
/// understand device performance and make informed decisions about FIX-013.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pak_connect/core/monitoring/performance_metrics.dart';
import 'package:pak_connect/core/security/noise/adaptive_encryption_strategy.dart';

class PerformanceMetricsWidget extends StatefulWidget {
  const PerformanceMetricsWidget({super.key});

  @override
  State<PerformanceMetricsWidget> createState() =>
      _PerformanceMetricsWidgetState();
}

class _PerformanceMetricsWidgetState extends State<PerformanceMetricsWidget> {
  EncryptionMetrics? _metrics;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  Future<void> _loadMetrics() async {
    setState(() => _loading = true);
    final metrics = await PerformanceMonitor.getMetrics();
    setState(() {
      _metrics = metrics;
      _loading = false;
    });
  }

  Future<void> _resetMetrics() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Metrics?'),
        content: const Text('This will clear all performance data. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await PerformanceMonitor.reset();
      await _loadMetrics();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Performance metrics reset')),
        );
      }
    }
  }

  Future<void> _exportMetrics() async {
    final exported = await PerformanceMonitor.exportMetrics();

    if (mounted) {
      await Clipboard.setData(ClipboardData(text: exported));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Metrics copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance Metrics'),
        actions: [
          if (_metrics != null && _metrics!.totalEncryptions > 0) ...[
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _exportMetrics,
              tooltip: 'Export metrics',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _resetMetrics,
              tooltip: 'Reset metrics',
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _metrics == null || _metrics!.totalEncryptions == 0
          ? _buildEmptyState()
          : _buildMetricsView(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.analytics_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No performance data yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Send some messages to start collecting metrics',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsView() {
    final metrics = _metrics!;

    return RefreshIndicator(
      onRefresh: _loadMetrics,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Summary Card
          _buildRecommendationCard(metrics),
          const SizedBox(height: 16),

          // Operations Count
          _buildSectionCard(
            title: 'Operations',
            icon: Icons.swap_vert,
            children: [
              _buildMetricRow(
                'Encryptions',
                metrics.totalEncryptions.toString(),
              ),
              _buildMetricRow(
                'Decryptions',
                metrics.totalDecryptions.toString(),
              ),
              _buildMetricRow(
                'Total',
                (metrics.totalEncryptions + metrics.totalDecryptions)
                    .toString(),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Encryption Performance
          _buildSectionCard(
            title: 'Encryption Performance',
            icon: Icons.lock,
            children: [
              _buildMetricRow(
                'Average',
                '${metrics.avgEncryptMs.toStringAsFixed(2)} ms',
                color: _getPerformanceColor(metrics.avgEncryptMs),
              ),
              _buildMetricRow('Minimum', '${metrics.minEncryptMs} ms'),
              _buildMetricRow(
                'Maximum',
                '${metrics.maxEncryptMs} ms',
                color: _getPerformanceColor(metrics.maxEncryptMs.toDouble()),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Decryption Performance
          _buildSectionCard(
            title: 'Decryption Performance',
            icon: Icons.lock_open,
            children: [
              _buildMetricRow(
                'Average',
                '${metrics.avgDecryptMs.toStringAsFixed(2)} ms',
                color: _getPerformanceColor(metrics.avgDecryptMs),
              ),
              _buildMetricRow('Minimum', '${metrics.minDecryptMs} ms'),
              _buildMetricRow(
                'Maximum',
                '${metrics.maxDecryptMs} ms',
                color: _getPerformanceColor(metrics.maxDecryptMs.toDouble()),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Message Sizes
          _buildSectionCard(
            title: 'Message Sizes',
            icon: Icons.data_usage,
            children: [
              _buildMetricRow(
                'Average',
                '${(metrics.avgMessageSize / 1024).toStringAsFixed(2)} KB',
              ),
              _buildMetricRow('Minimum', '${metrics.minMessageSize} bytes'),
              _buildMetricRow(
                'Maximum',
                '${(metrics.maxMessageSize / 1024).toStringAsFixed(2)} KB',
              ),
            ],
          ),
          const SizedBox(height: 16),

          // UI Performance
          _buildSectionCard(
            title: 'UI Performance',
            icon: Icons.speed,
            children: [
              _buildMetricRow(
                'Janky Operations',
                '${metrics.jankyEncryptions} (>16ms)',
                color: metrics.jankyEncryptions > 0
                    ? Colors.orange
                    : Colors.green,
              ),
              _buildMetricRow(
                'Jank Rate',
                '${metrics.jankPercentage.toStringAsFixed(2)}%',
                color: _getJankColor(metrics.jankPercentage),
              ),
              _buildMetricRow(
                'Target',
                '<5% (for smooth UI)',
                color: Colors.grey,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Device Info
          _buildSectionCard(
            title: 'Device Info',
            icon: Icons.phone_android,
            children: [
              _buildMetricRow('Platform', metrics.devicePlatform),
              _buildMetricRow('Model', metrics.deviceModel),
            ],
          ),
          const SizedBox(height: 16),

          // Adaptive Encryption Debug Section (FIX-013)
          _buildAdaptiveEncryptionSection(metrics),
        ],
      ),
    );
  }

  Widget _buildAdaptiveEncryptionSection(EncryptionMetrics metrics) {
    final strategy = AdaptiveEncryptionStrategy();
    final isUsingIsolate = strategy.isUsingIsolate;

    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.developer_mode, size: 20, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  'Adaptive Encryption (FIX-013)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Current mode
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Current Mode',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isUsingIsolate ? Colors.purple : Colors.green,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isUsingIsolate ? 'ISOLATE' : 'SYNC',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            Text(
              isUsingIsolate
                  ? 'Large messages are encrypted in background isolates to prevent UI jank.'
                  : 'Encryption runs on main thread (fast enough for this device).',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.blue[800]),
            ),
            const SizedBox(height: 16),

            // Debug override buttons
            Text(
              'Test Mode Override:',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.blue[900],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      strategy.setDebugOverride(false);
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Force SYNC mode enabled (main thread)',
                          ),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.flash_on, size: 16),
                    label: const Text('Force Sync'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green[700],
                      side: BorderSide(color: Colors.green[300]!),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      strategy.setDebugOverride(true);
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Force ISOLATE mode enabled (background)',
                          ),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.workspaces, size: 16),
                    label: const Text('Force Isolate'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.purple[700],
                      side: BorderSide(color: Colors.purple[300]!),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            Center(
              child: TextButton.icon(
                onPressed: () async {
                  strategy.setDebugOverride(null);
                  await strategy.recheckMetrics();
                  setState(() {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Auto mode enabled (metrics-based decision)',
                        ),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.auto_mode, size: 16),
                label: const Text('Auto (Use Metrics)'),
                style: TextButton.styleFrom(foregroundColor: Colors.blue[700]),
              ),
            ),

            const Divider(height: 24),

            Text(
              'How it works:',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.blue[900],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '• Default: Sync (no isolate overhead)\n'
              '• If jank >5%: Auto-switch to isolate\n'
              '• Small messages (<1KB): Always sync\n'
              '• Re-checks every 100 operations',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.blue[700],
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecommendationCard(EncryptionMetrics metrics) {
    final isGood = !metrics.shouldUseIsolate;

    return Card(
      color: isGood ? Colors.green[50] : Colors.orange[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isGood ? Icons.check_circle : Icons.warning,
                  color: isGood ? Colors.green : Colors.orange,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isGood
                            ? 'Performance: Excellent'
                            : 'Performance: Needs Attention',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: isGood
                                  ? Colors.green[900]
                                  : Colors.orange[900],
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isGood
                            ? 'Your device handles encryption smoothly. No optimization needed.'
                            : 'Some encryption operations are causing UI lag. Consider enabling background encryption.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isGood
                              ? Colors.green[800]
                              : Colors.orange[800],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!isGood) ...[
              const SizedBox(height: 12),
              Text(
                'Recommendation: Background encryption (FIX-013) would improve UI smoothness on this device.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.orange[900],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Theme.of(context).primaryColor),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Color _getPerformanceColor(double ms) {
    if (ms < 8) return Colors.green;
    if (ms < 16) return Colors.orange;
    return Colors.red;
  }

  Color _getJankColor(double percentage) {
    if (percentage < 1) return Colors.green;
    if (percentage < 5) return Colors.orange;
    return Colors.red;
  }
}
