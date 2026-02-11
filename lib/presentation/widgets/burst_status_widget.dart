import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/burst_scanning_controller.dart';
import '../providers/ble_providers.dart';

/// Widget that displays burst scanning status and controls
class BurstStatusWidget extends ConsumerWidget {
  final VoidCallback? onManualScanPressed;
  final bool isCompact;

  const BurstStatusWidget({
    super.key,
    this.onManualScanPressed,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final burstStatusAsync = ref.watch(burstScanningStatusProvider);
    final burstOperations = ref.watch(burstScanningOperationsProvider);

    return burstStatusAsync.when(
      data: (status) => _buildStatusContent(context, status, burstOperations),
      loading: () => _buildLoadingContent(context),
      error: (error, stack) => _buildErrorContent(context, error),
    );
  }

  Widget _buildStatusContent(
    BuildContext context,
    BurstScanningStatus status,
    BurstScanningOperations? operations,
  ) {
    if (isCompact) {
      return _buildCompactStatus(context, status, operations);
    } else {
      return _buildFullStatus(context, status, operations);
    }
  }

  Widget _buildCompactStatus(
    BuildContext context,
    BurstScanningStatus status,
    BurstScanningOperations? operations,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _getStatusColor(status).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _getStatusColor(status).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status indicator
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _getStatusColor(status),
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: 8),

          // Status text
          Expanded(
            child: Text(
              status.statusMessage,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _getStatusColor(status),
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Manual override button
          if (status.canOverride && onManualScanPressed != null) ...[
            SizedBox(width: 8),
            GestureDetector(
              onTap: onManualScanPressed,
              child: Container(
                padding: EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  Icons.search,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFullStatus(
    BuildContext context,
    BurstScanningStatus status,
    BurstScanningOperations? operations,
  ) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Burst Scanning',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),

              // Efficiency indicator
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getEfficiencyColor(
                    status.efficiencyRating,
                  ).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  status.efficiencyRating,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _getEfficiencyColor(status.efficiencyRating),
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 12),

          // Status information
          Row(
            children: [
              // Status indicator
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _getStatusColor(status),
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 8),

              Expanded(
                child: Text(
                  status.statusMessage,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),

          // Progress indicator for burst scanning
          if (status.isBurstActive && status.burstTimeRemaining != null) ...[
            SizedBox(height: 8),
            _buildBurstProgressIndicator(context, status),
          ],

          // Next scan countdown
          if (!status.isBurstActive && status.secondsUntilNextScan != null) ...[
            SizedBox(height: 8),
            _buildNextScanCountdown(context, status),
          ],

          // Controls
          SizedBox(height: 12),
          Row(
            children: [
              // Manual scan button
              if (status.canOverride && onManualScanPressed != null)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onManualScanPressed,
                    icon: Icon(Icons.search, size: 18),
                    label: Text('Scan Now'),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),

              if (status.canOverride && onManualScanPressed != null)
                SizedBox(width: 8),

              // Info button
              OutlinedButton.icon(
                onPressed: () => _showBurstInfo(context, status),
                icon: Icon(Icons.info_outline, size: 18),
                label: Text('Info'),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBurstProgressIndicator(
    BuildContext context,
    BurstScanningStatus status,
  ) {
    final progress = status.burstTimeRemaining != null
        ? (20 - status.burstTimeRemaining!) /
              20 // 20s total burst duration
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Scanning active',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '${status.burstTimeRemaining}s remaining',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
        SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation<Color>(
            Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildNextScanCountdown(
    BuildContext context,
    BurstScanningStatus status,
  ) {
    return Row(
      children: [
        Icon(
          Icons.timer_outlined,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SizedBox(width: 4),
        Text(
          'Next automatic scan in ${status.secondsUntilNextScan}s',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingContent(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 8 : 16),
      child: Row(
        mainAxisSize: isCompact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text(
            'Initializing burst scanning...',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorContent(BuildContext context, Object error) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 8 : 16),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(isCompact ? 8 : 12),
        border: Border.all(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: isCompact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Icon(
            Icons.error_outline,
            size: 16,
            color: Theme.of(context).colorScheme.error,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Burst scanning unavailable',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(BurstScanningStatus status) {
    if (status.isBurstActive) {
      return Colors.green;
    } else if (status.secondsUntilNextScan != null &&
        status.secondsUntilNextScan! <= 10) {
      return Colors.orange;
    } else {
      return Colors.blue;
    }
  }

  Color _getEfficiencyColor(String efficiency) {
    switch (efficiency.toLowerCase()) {
      case 'excellent':
        return Colors.green;
      case 'good':
        return Colors.lightGreen;
      case 'fair':
        return Colors.orange;
      case 'poor':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  void _showBurstInfo(BuildContext context, BurstScanningStatus status) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Burst Scanning Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(
              'Current interval',
              '${(status.currentScanInterval / 1000).toStringAsFixed(1)}s',
            ),
            _buildInfoRow('Efficiency', status.efficiencyRating),
            _buildInfoRow(
              'Quality score',
              '${(status.powerStats.connectionQualityScore * 100).toStringAsFixed(0)}%',
            ),
            _buildInfoRow(
              'Stability',
              '${(status.powerStats.connectionStabilityScore * 100).toStringAsFixed(0)}%',
            ),
            _buildInfoRow(
              'Successful checks',
              '${status.powerStats.consecutiveSuccessfulChecks}',
            ),
            _buildInfoRow(
              'Failed checks',
              '${status.powerStats.consecutiveFailedChecks}',
            ),
            SizedBox(height: 8),
            Text(
              'Burst scanning automatically adapts to connection quality and battery usage to optimize device discovery.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
