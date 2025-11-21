import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

class ReconnectionBanner extends StatelessWidget {
  final dynamic bleService;
  final bool isPeripheralMode;
  final VoidCallback onReconnect;

  const ReconnectionBanner({
    super.key,
    required this.bleService,
    required this.isPeripheralMode,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    if (bleService.state != BluetoothLowEnergyState.poweredOn) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Row(
          children: const [
            Icon(Icons.bluetooth_disabled, size: 16),
            SizedBox(width: 8),
            Text(
              'Bluetooth is off - Please enable Bluetooth',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (isPeripheralMode) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Row(
          children: const [
            Icon(Icons.wifi_tethering, size: 16, color: Colors.green),
            SizedBox(width: 8),
            Text(
              'Advertising - Waiting for connection...',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (bleService.isActivelyReconnecting) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Searching for device...',
                style: TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: onReconnect,
              child: const Text('Reconnect Now'),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

class InitializationStatusPanel extends StatelessWidget {
  final String statusText;

  const InitializationStatusPanel({super.key, required this.statusText});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Smart Routing Mesh Network',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                Text(
                  statusText,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyChatPlaceholder extends StatelessWidget {
  const EmptyChatPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Start your conversation',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Send a message to begin chatting',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class RetryIndicator extends StatelessWidget {
  final int failedCount;
  final VoidCallback onRetry;

  const RetryIndicator({
    super.key,
    required this.failedCount,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (failedCount == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16, left: 16, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withValues(),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$failedCount failed',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.refresh,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'retry',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class UnreadSeparator extends StatelessWidget {
  const UnreadSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Theme.of(context).colorScheme.primary.withValues(),
                    Theme.of(context).colorScheme.primary.withValues(),
                    Theme.of(context).colorScheme.primary.withValues(),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
