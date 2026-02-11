import 'package:flutter/material.dart';
import '../../domain/models/bluetooth_state_models.dart';

/// Widget that displays user-friendly Bluetooth status messages with action buttons
class BluetoothStatusWidget extends StatelessWidget {
  final BluetoothStatusMessage message;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenSettings;

  const BluetoothStatusWidget({
    super.key,
    required this.message,
    this.onRefresh,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _getBackgroundColor(theme),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _getBorderColor(theme), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_getIcon(), color: _getIconColor(theme), size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (message.actionHint != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        message.actionHint!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_shouldShowActions()) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onRefresh != null) ...[
                  TextButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh'),
                  ),
                  const SizedBox(width: 8),
                ],
                if (onOpenSettings != null && _shouldShowSettingsButton()) ...[
                  ElevatedButton.icon(
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings, size: 18),
                    label: const Text('Settings'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _getIcon() {
    switch (message.type) {
      case BluetoothMessageType.ready:
        return Icons.bluetooth_connected;
      case BluetoothMessageType.disabled:
        return Icons.bluetooth_disabled;
      case BluetoothMessageType.unauthorized:
        return Icons.bluetooth_searching;
      case BluetoothMessageType.unsupported:
        return Icons.bluetooth_disabled_outlined;
      case BluetoothMessageType.unknown:
        return Icons.help_outline;
      // Note: resetting state not available in this version
      case BluetoothMessageType.initializing:
        return Icons.bluetooth_searching;
      case BluetoothMessageType.error:
        return Icons.error_outline;
    }
  }

  Color _getIconColor(ThemeData theme) {
    switch (message.type) {
      case BluetoothMessageType.ready:
        return Colors.green;
      case BluetoothMessageType.disabled:
      case BluetoothMessageType.unauthorized:
      case BluetoothMessageType.unsupported:
        return Colors.orange;
      case BluetoothMessageType.unknown:
      case BluetoothMessageType.initializing:
        return theme.colorScheme.primary;
      case BluetoothMessageType.error:
        return Colors.red;
    }
  }

  Color _getBackgroundColor(ThemeData theme) {
    switch (message.type) {
      case BluetoothMessageType.ready:
        return Colors.green.withValues(alpha: 0.1);
      case BluetoothMessageType.disabled:
      case BluetoothMessageType.unauthorized:
      case BluetoothMessageType.unsupported:
        return Colors.orange.withValues(alpha: .1);
      case BluetoothMessageType.unknown:
      case BluetoothMessageType.initializing:
        return theme.colorScheme.primary.withValues(alpha: .1);
      case BluetoothMessageType.error:
        return Colors.red.withValues(alpha: .1);
    }
  }

  Color _getBorderColor(ThemeData theme) {
    switch (message.type) {
      case BluetoothMessageType.ready:
        return Colors.green.withValues(alpha: 0.3);
      case BluetoothMessageType.disabled:
      case BluetoothMessageType.unauthorized:
      case BluetoothMessageType.unsupported:
        return Colors.orange.withValues(alpha: 0.3);
      case BluetoothMessageType.unknown:
      case BluetoothMessageType.initializing:
        return theme.colorScheme.primary.withValues(alpha: 0.3);
      case BluetoothMessageType.error:
        return Colors.red.withValues(alpha: 0.3);
    }
  }

  bool _shouldShowActions() {
    return message.type != BluetoothMessageType.ready &&
        message.type != BluetoothMessageType.initializing;
  }

  bool _shouldShowSettingsButton() {
    return message.type == BluetoothMessageType.disabled ||
        message.type == BluetoothMessageType.unauthorized ||
        message.type == BluetoothMessageType.unsupported;
  }
}

/// Stream builder widget for displaying real-time Bluetooth status
class BluetoothStatusListener extends StatelessWidget {
  final Widget Function(BuildContext context, BluetoothStatusMessage? message)
  builder;
  final Stream<BluetoothStatusMessage> messageStream;

  const BluetoothStatusListener({
    super.key,
    required this.builder,
    required this.messageStream,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BluetoothStatusMessage>(
      stream: messageStream,
      builder: (context, snapshot) {
        return builder(context, snapshot.data);
      },
    );
  }
}

/// Banner widget that appears when Bluetooth is not available
class BluetoothBanner extends StatelessWidget {
  final BluetoothStatusMessage message;
  final VoidCallback? onDismiss;
  final VoidCallback? onAction;

  const BluetoothBanner({
    super.key,
    required this.message,
    this.onDismiss,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Only show banner for important states
    if (message.type == BluetoothMessageType.ready ||
        message.type == BluetoothMessageType.initializing) {
      return const SizedBox.shrink();
    }

    return MaterialBanner(
      leading: Icon(_getIcon(), color: _getIconColor(theme)),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message.message,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          if (message.actionHint != null) ...[
            const SizedBox(height: 4),
            Text(
              message.actionHint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (onAction != null)
          TextButton(onPressed: onAction, child: Text(_getActionText())),
        if (onDismiss != null)
          TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
      ],
      backgroundColor: _getBackgroundColor(theme),
    );
  }

  IconData _getIcon() {
    switch (message.type) {
      case BluetoothMessageType.disabled:
        return Icons.bluetooth_disabled;
      case BluetoothMessageType.unauthorized:
        return Icons.bluetooth_searching;
      case BluetoothMessageType.unsupported:
        return Icons.bluetooth_disabled_outlined;
      case BluetoothMessageType.unknown:
        return Icons.help_outline;
      case BluetoothMessageType.error:
        return Icons.error_outline;
      default:
        return Icons.bluetooth;
    }
  }

  Color _getIconColor(ThemeData theme) {
    switch (message.type) {
      case BluetoothMessageType.disabled:
      case BluetoothMessageType.unauthorized:
      case BluetoothMessageType.unsupported:
        return Colors.orange;
      case BluetoothMessageType.error:
        return Colors.red;
      default:
        return theme.colorScheme.primary;
    }
  }

  Color _getBackgroundColor(ThemeData theme) {
    switch (message.type) {
      case BluetoothMessageType.disabled:
      case BluetoothMessageType.unauthorized:
      case BluetoothMessageType.unsupported:
        return Colors.orange.withValues(alpha: 0.1);
      case BluetoothMessageType.error:
        return Colors.red.withValues(alpha: 0.1);
      default:
        return theme.colorScheme.primary.withValues(alpha: 0.1);
    }
  }

  String _getActionText() {
    switch (message.type) {
      case BluetoothMessageType.disabled:
      case BluetoothMessageType.unauthorized:
        return 'Settings';
      case BluetoothMessageType.unknown:
      case BluetoothMessageType.error:
        return 'Retry';
      default:
        return 'Fix';
    }
  }
}
