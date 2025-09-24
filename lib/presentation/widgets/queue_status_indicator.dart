import 'package:flutter/material.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/utils/mesh_debug_logger.dart';

/// Compact status indicator for relay queue
/// Shows pending message count and connection status
class QueueStatusIndicator extends StatelessWidget {
  final QueueStatistics? queueStats;
  final bool isCompact;
  final VoidCallback? onTap;
  
  const QueueStatusIndicator({
    Key? key,
    this.queueStats,
    this.isCompact = false,
    this.onTap,
  }) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    if (queueStats == null) {
      return _buildUnavailableState();
    }
    
    if (isCompact) {
      return _buildCompactIndicator(context);
    } else {
      return _buildFullIndicator(context);
    }
  }
  
  /// Build unavailable state when queue stats are null
  Widget _buildUnavailableState() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.help_outline, color: Colors.grey[600], size: 14),
          SizedBox(width: 4),
          Text(
            'N/A',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
  
  /// Build compact indicator for app bar or toolbar
  Widget _buildCompactIndicator(BuildContext context) {
    final pendingCount = queueStats!.pendingMessages;
    final isOnline = queueStats!.isOnline;
    
    if (pendingCount == 0) {
      // Show online/offline status only when no pending messages
      return GestureDetector(
        onTap: () {
          onTap?.call();
          MeshDebugLogger.info('UI Action', 'Compact queue indicator tapped (no messages)');
        },
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isOnline ? Colors.green[100] : Colors.grey[300],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            isOnline ? Icons.wifi : Icons.wifi_off,
            color: isOnline ? Colors.green[700] : Colors.grey[600],
            size: 16,
          ),
        ),
      );
    }
    
    return GestureDetector(
      onTap: () {
        onTap?.call();
        MeshDebugLogger.info('UI Action', 'Compact queue indicator tapped ($pendingCount messages)');
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _getStatusColor(),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_getStatusIcon(), color: Colors.white, size: 14),
            SizedBox(width: 4),
            Text(
              '$pendingCount',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  /// Build full indicator with detailed information
  Widget _buildFullIndicator(BuildContext context) {
    final pendingCount = queueStats!.pendingMessages;
    final sendingCount = queueStats!.sendingMessages;
    final retryingCount = queueStats!.retryingMessages;
    final failedCount = queueStats!.failedMessages;
    final isOnline = queueStats!.isOnline;
    final successRate = queueStats!.successRate;
    
    return GestureDetector(
      onTap: () {
        onTap?.call();
        MeshDebugLogger.info('UI Action', 'Full queue indicator tapped');
      },
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _getStatusColor().withValues(),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with icon and title
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _getStatusColor().withValues(),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _getStatusIcon(),
                    color: _getStatusColor(),
                    size: 20,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Relay Queue',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        _getStatusText(pendingCount, sendingCount, retryingCount, isOnline),
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // Connection indicator
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOnline ? Colors.green : Colors.orange,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isOnline ? 'Online' : 'Offline',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            
            // Progress indicators if there's activity
            if (pendingCount > 0 || sendingCount > 0 || retryingCount > 0)
              ...[
                SizedBox(height: 12),
                _buildProgressBar(context, pendingCount, sendingCount, retryingCount, failedCount),
              ],
            
            // Success rate if available
            if (successRate > 0) ...[
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.trending_up, size: 14, color: Colors.grey[600]),
                  SizedBox(width: 4),
                  Text(
                    'Success rate: ${(successRate * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  /// Build progress bar showing queue status breakdown
  Widget _buildProgressBar(BuildContext context, int pending, int sending, int retrying, int failed) {
    final total = pending + sending + retrying + failed;
    if (total == 0) return SizedBox.shrink();
    
    return Column(
      children: [
        // Visual progress bar
        Container(
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            color: Colors.grey[200],
          ),
          child: Row(
            children: [
              // Sending (green)
              if (sending > 0)
                Expanded(
                  flex: sending,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.green[600],
                      borderRadius: BorderRadius.horizontal(left: Radius.circular(3)),
                    ),
                  ),
                ),
              // Pending (blue)
              if (pending > 0)
                Expanded(
                  flex: pending,
                  child: Container(
                    color: Colors.blue[600],
                  ),
                ),
              // Retrying (orange)
              if (retrying > 0)
                Expanded(
                  flex: retrying,
                  child: Container(
                    color: Colors.orange[600],
                  ),
                ),
              // Failed (red)
              if (failed > 0)
                Expanded(
                  flex: failed,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.red[600],
                      borderRadius: BorderRadius.horizontal(right: Radius.circular(3)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        
        SizedBox(height: 8),
        
        // Legend
        Wrap(
          spacing: 12,
          children: [
            if (sending > 0) _buildLegendItem('Sending', Colors.green[600]!, sending),
            if (pending > 0) _buildLegendItem('Pending', Colors.blue[600]!, pending),
            if (retrying > 0) _buildLegendItem('Retrying', Colors.orange[600]!, retrying),
            if (failed > 0) _buildLegendItem('Failed', Colors.red[600]!, failed),
          ],
        ),
      ],
    );
  }
  
  /// Build legend item for progress bar
  Widget _buildLegendItem(String label, Color color, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: 4),
        Text(
          '$label ($count)',
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }
  
  /// Get status color based on queue state
  Color _getStatusColor() {
    if (queueStats == null) return Colors.grey;
    
    final pendingCount = queueStats!.pendingMessages;
    final failedCount = queueStats!.failedMessages;
    final isOnline = queueStats!.isOnline;
    
    if (failedCount > 0) return Colors.red;
    if (pendingCount == 0 && isOnline) return Colors.green;
    if (pendingCount > 0 && !isOnline) return Colors.orange;
    if (pendingCount > 10) return Colors.red;
    if (pendingCount > 5) return Colors.orange;
    return Colors.blue;
  }
  
  /// Get status icon based on queue state
  IconData _getStatusIcon() {
    if (queueStats == null) return Icons.help_outline;
    
    final pendingCount = queueStats!.pendingMessages;
    final sendingCount = queueStats!.sendingMessages;
    final failedCount = queueStats!.failedMessages;
    
    if (failedCount > 0) return Icons.error;
    if (sendingCount > 0) return Icons.send;
    if (pendingCount == 0) return Icons.check_circle;
    return Icons.queue;
  }
  
  /// Get status text for full indicator
  String _getStatusText(int pending, int sending, int retrying, bool isOnline) {
    if (pending == 0 && sending == 0 && retrying == 0) {
      return isOnline ? 'Ready for messages' : 'Waiting for connection';
    }
    
    final parts = <String>[];
    if (sending > 0) parts.add('$sending sending');
    if (pending > 0) parts.add('$pending queued');
    if (retrying > 0) parts.add('$retrying retrying');
    
    return parts.join(' • ');
  }
}

/// Factory methods for common use cases
class QueueStatusIndicatorFactory {
  /// Create a compact indicator for app bar
  static Widget appBarIndicator({
    required QueueStatistics? queueStats,
    VoidCallback? onTap,
  }) {
    return QueueStatusIndicator(
      queueStats: queueStats,
      isCompact: true,
      onTap: onTap,
    );
  }
  
  /// Create a detailed indicator for drawer or main screen
  static Widget detailedIndicator({
    required QueueStatistics? queueStats,
    VoidCallback? onTap,
  }) {
    return QueueStatusIndicator(
      queueStats: queueStats,
      isCompact: false,
      onTap: onTap,
    );
  }
  
  /// Create a floating action button style indicator
  static Widget floatingIndicator({
    required QueueStatistics? queueStats,
    required VoidCallback onTap,
  }) {
    if (queueStats == null || queueStats.pendingMessages == 0) {
      return SizedBox.shrink();
    }
    
    return FloatingActionButton.small(
      onPressed: onTap,
      backgroundColor: queueStats.pendingMessages > 5 ? Colors.red[600] : Colors.blue[600],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.queue, size: 16),
          Text(
            '${queueStats.pendingMessages}',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}