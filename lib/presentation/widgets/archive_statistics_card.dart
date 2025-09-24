// Archive statistics card widget for displaying archive overview and metrics
// Shows key statistics about archived chats and storage usage

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/archive_models.dart';
import '../../presentation/providers/archive_provider.dart';

/// Main archive statistics card displaying key metrics
class ArchiveStatisticsCard extends ConsumerWidget {
  final bool isExpanded;
  final VoidCallback? onToggleExpanded;
  
  const ArchiveStatisticsCard({
    super.key,
    this.isExpanded = false,
    this.onToggleExpanded,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statisticsAsync = ref.watch(archiveStatisticsProvider);
    
    return statisticsAsync.when(
      data: (statistics) => _buildStatisticsCard(context, statistics),
      loading: () => _buildLoadingCard(context),
      error: (error, stack) => _buildErrorCard(context, error.toString()),
    );
  }
  
  Widget _buildStatisticsCard(BuildContext context, ArchiveStatistics statistics) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with title and toggle
            Row(
              children: [
                Icon(
                  Icons.analytics_outlined,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Archive Statistics',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                if (onToggleExpanded != null)
                  IconButton(
                    onPressed: onToggleExpanded,
                    icon: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    tooltip: isExpanded ? 'Show less' : 'Show more',
                  ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Main statistics row
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    context,
                    'Total Archives',
                    '${statistics.totalArchives}',
                    Icons.archive,
                    colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    context,
                    'Total Messages',
                    '${statistics.totalMessages}',
                    Icons.chat_bubble_outline,
                    colorScheme.secondary,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    context,
                    'Storage Used',
                    statistics.formattedTotalSize,
                    Icons.storage,
                    colorScheme.tertiary,
                  ),
                ),
              ],
            ),
            
            // Expanded content
            if (isExpanded) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              
              // Storage efficiency row
              Row(
                children: [
                  Expanded(
                    child: _buildProgressItem(
                      context,
                      'Compression Efficiency',
                      statistics.compressionEfficiency,
                      '%',
                      colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildProgressItem(
                      context,
                      'Searchable Archives',
                      statistics.searchablePercentage,
                      '%',
                      colorScheme.secondary,
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 16),
              
              // Archive age distribution
              if (statistics.oldestArchive != null && statistics.newestArchive != null)
                _buildAgeDistribution(context, statistics),
              
              const SizedBox(height: 16),
              
              // Performance indicators
              _buildPerformanceIndicators(context, statistics.performanceStats),
            ],
          ],
        ),
      ),
    );
  }
  
  Widget _buildStatItem(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: color,
            size: 24,
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
  
  Widget _buildProgressItem(
    BuildContext context,
    String label,
    double value,
    String suffix,
    Color color,
  ) {
    final theme = Theme.of(context);
    final percentage = value / 100;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              '${value.toStringAsFixed(1)}$suffix',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: percentage,
          backgroundColor: color.withValues(),
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ],
    );
  }
  
  Widget _buildAgeDistribution(BuildContext context, ArchiveStatistics statistics) {
    final theme = Theme.of(context);
    final oldestAge = DateTime.now().difference(statistics.oldestArchive!);
    final newestAge = DateTime.now().difference(statistics.newestArchive!);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Archive Age Range',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildAgeItem(
                context,
                'Oldest',
                _formatDuration(oldestAge),
                Icons.schedule,
                theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildAgeItem(
                context,
                'Newest',
                _formatDuration(newestAge),
                Icons.schedule,
                theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildAgeItem(
    BuildContext context,
    String label,
    String age,
    IconData icon,
    Color color,
  ) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues()),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                ),
              ),
              Text(
                age,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildPerformanceIndicators(
    BuildContext context,
    ArchivePerformanceStats performanceStats,
  ) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Performance Metrics',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildPerformanceItem(
                context,
                'Avg Search Time',
                '${performanceStats.averageSearchTime.inMilliseconds}ms',
                performanceStats.averageSearchTime.inMilliseconds < 500
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildPerformanceItem(
                context,
                'Operations',
                '${performanceStats.operationsCount}',
                theme.colorScheme.secondary,
              ),
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildPerformanceItem(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildLoadingCard(BuildContext context) {
    final theme = Theme.of(context);
    
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.analytics_outlined,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Loading Statistics...',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildErrorCard(BuildContext context, String error) {
    final theme = Theme.of(context);
    
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Statistics Unavailable',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  String _formatDuration(Duration duration) {
    if (duration.inDays > 365) {
      return '${(duration.inDays / 365).round()}y ago';
    } else if (duration.inDays > 30) {
      return '${(duration.inDays / 30).round()}mo ago';
    } else if (duration.inDays > 7) {
      return '${(duration.inDays / 7).round()}w ago';
    } else if (duration.inDays > 0) {
      return '${duration.inDays}d ago';
    } else {
      return 'Today';
    }
  }
}

/// Compact statistics summary for smaller displays
class CompactArchiveStatistics extends ConsumerWidget {
  const CompactArchiveStatistics({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statisticsAsync = ref.watch(archiveStatisticsProvider);
    final theme = Theme.of(context);
    
    return statisticsAsync.when(
      data: (statistics) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildCompactStat(
              context,
              '${statistics.totalArchives}',
              'Archives',
              Icons.archive,
            ),
            _buildCompactStat(
              context,
              '${statistics.totalMessages}',
              'Messages',
              Icons.chat_bubble_outline,
            ),
            _buildCompactStat(
              context,
              statistics.formattedTotalSize,
              'Storage',
              Icons.storage,
            ),
          ],
        ),
      ),
      loading: () => Container(
        padding: const EdgeInsets.all(12),
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Container(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.error,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              'Statistics unavailable',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildCompactStat(
    BuildContext context,
    String value,
    String label,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}