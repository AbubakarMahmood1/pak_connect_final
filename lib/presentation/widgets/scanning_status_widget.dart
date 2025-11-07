import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/ble_providers.dart';
import '../../core/scanning/burst_scanning_controller.dart';

/// Elegant scanning status widget for the ChatsScreen header
/// Shows scanning state with clean countdown display
class ScanningStatusWidget extends ConsumerWidget {
  final VoidCallback? onTap;

  const ScanningStatusWidget({super.key, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final burstStatusAsync = ref.watch(burstScanningStatusProvider);
    final theme = Theme.of(context);

    return burstStatusAsync.when(
      data: (burstStatus) => _buildStatusIcon(context, theme, burstStatus),
      loading: () => _buildLoadingIcon(theme),
      error: (error, stack) => _buildErrorIcon(theme),
    );
  }

  /// Build status icon based on current scanning state
  Widget _buildStatusIcon(
    BuildContext context,
    ThemeData theme,
    BurstScanningStatus burstStatus,
  ) {
    final isScanning = burstStatus.isBurstActive;
    final hasCountdown =
        burstStatus.secondsUntilNextScan != null &&
        burstStatus.secondsUntilNextScan! > 0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isScanning
              ? theme.colorScheme.primary.withValues(alpha: .1)
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Background circle for countdown
            if (hasCountdown && !isScanning)
              CircularProgressIndicator(
                value: _calculateProgress(
                  burstStatus.secondsUntilNextScan!,
                  60,
                ),
                strokeWidth: 2,
                backgroundColor: theme.colorScheme.outline.withValues(
                  alpha: .2,
                ),
                valueColor: AlwaysStoppedAnimation(
                  theme.colorScheme.primary.withValues(alpha: .3),
                ),
              ),

            // Main icon
            if (isScanning)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
                ),
              )
            else
              Icon(
                hasCountdown ? Icons.schedule : Icons.bluetooth_searching,
                size: 18,
                color: hasCountdown
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),

            // Countdown text overlay
            if (hasCountdown &&
                !isScanning &&
                burstStatus.secondsUntilNextScan! <= 60)
              Positioned(
                bottom: -2,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${burstStatus.secondsUntilNextScan}',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Build loading icon
  Widget _buildLoadingIcon(ThemeData theme) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(
              theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// Build error icon
  Widget _buildErrorIcon(ThemeData theme) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.error_outline,
          size: 18,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }

  /// Calculate progress for circular indicator
  double _calculateProgress(int secondsRemaining, int totalSeconds) {
    if (totalSeconds <= 0) return 1.0;
    final progress = (totalSeconds - secondsRemaining) / totalSeconds;
    return progress.clamp(0.0, 1.0);
  }
}
