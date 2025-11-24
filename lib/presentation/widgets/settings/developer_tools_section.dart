import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/settings_controller.dart';

class DeveloperToolsSection extends StatelessWidget {
  const DeveloperToolsSection({
    super.key,
    required this.controller,
    required this.onShowMessage,
    required this.onShowError,
  });

  final SettingsController controller;
  final void Function(String message) onShowMessage;
  final void Function(String message) onShowError;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Debug Build Only - These tools will not appear in release',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(
              Icons.notifications_active,
              color: Colors.orange,
            ),
            title: const Text('Test Notification'),
            subtitle: const Text('Test sound & vibration settings'),
            trailing: FilledButton.icon(
              onPressed: () async {
                try {
                  await controller.triggerTestNotification();
                  onShowMessage('Test notification triggered');
                } catch (e) {
                  onShowError('Failed to trigger notification: $e');
                }
              },
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Test'),
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.archive, color: Colors.brown),
            title: const Text('Check Inactive Chats'),
            subtitle: const Text('Manually trigger auto-archive check'),
            trailing: FilledButton.icon(
              onPressed: () async {
                final count = await controller.manualAutoArchiveCheck();
                onShowMessage(
                  count > 0
                      ? '✅ Archived $count inactive chat${count == 1 ? '' : 's'}'
                      : 'No inactive chats found',
                );
              },
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Check'),
              style: FilledButton.styleFrom(backgroundColor: Colors.brown),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(
              Icons.battery_charging_full,
              color: Colors.lightGreen,
            ),
            title: const Text('Battery Optimizer'),
            subtitle: const Text('View battery level and power mode'),
            trailing: FilledButton.icon(
              onPressed: () => _showBatteryInfo(context),
              icon: const Icon(Icons.info, size: 16),
              label: const Text('View'),
              style: FilledButton.styleFrom(backgroundColor: Colors.lightGreen),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.storage, color: Colors.teal),
            title: const Text('Database Info'),
            subtitle: const Text('View detailed database statistics'),
            trailing: FilledButton.icon(
              onPressed: () => _showDatabaseInfo(context),
              icon: const Icon(Icons.info, size: 16),
              label: const Text('View'),
              style: FilledButton.styleFrom(backgroundColor: Colors.teal),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_sweep, color: Colors.deepOrange),
            title: const Text('Clear Cache'),
            subtitle: const Text('Clear temporary cached data'),
            trailing: FilledButton.icon(
              onPressed: () => _clearCache(context),
              icon: const Icon(Icons.delete, size: 16),
              label: const Text('Clear'),
              style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.verified, color: Colors.blue),
            title: const Text('Database Integrity'),
            subtitle: const Text('Verify database health'),
            trailing: FilledButton.icon(
              onPressed: () => _checkDatabaseIntegrity(context),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Check'),
              style: FilledButton.styleFrom(backgroundColor: Colors.blue),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _showBatteryInfo(BuildContext context) {
    try {
      final batteryInfo = controller.getBatteryInfo();
      if (!context.mounted) return;

      IconData batteryIcon;
      Color batteryColor;

      if (batteryInfo.isCharging) {
        batteryIcon = Icons.battery_charging_full;
        batteryColor = Colors.green;
      } else if (batteryInfo.level >= 80) {
        batteryIcon = Icons.battery_full;
        batteryColor = Colors.green;
      } else if (batteryInfo.level >= 50) {
        batteryIcon = Icons.battery_std;
        batteryColor = Colors.lightGreen;
      } else if (batteryInfo.level >= 30) {
        batteryIcon = Icons.battery_5_bar;
        batteryColor = Colors.orange;
      } else if (batteryInfo.level >= 15) {
        batteryIcon = Icons.battery_3_bar;
        batteryColor = Colors.deepOrange;
      } else {
        batteryIcon = Icons.battery_alert;
        batteryColor = Colors.red;
      }

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(batteryIcon, color: batteryColor),
              const SizedBox(width: 8),
              const Text('Battery Optimizer'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(context, 'Battery Level', '${batteryInfo.level}%'),
              const Divider(),
              _buildInfoRow(
                context,
                'State',
                batteryInfo.isCharging ? '⚡ Charging' : '🔋 On Battery',
              ),
              const Divider(),
              _buildInfoRow(
                context,
                'Power Mode',
                batteryInfo.powerModeName.toUpperCase(),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        batteryInfo.modeDescription,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Last updated: ${_formatTime(batteryInfo.lastUpdate)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      onShowError('Failed to load battery info: $e');
    }
  }

  Future<void> _showDatabaseInfo(BuildContext context) async {
    try {
      final stats = await controller.loadDatabaseStats();
      if (!context.mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.storage, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              const Text('Database Info'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(context, 'Size (MB)', '${stats.sizeMB} MB'),
              const SizedBox(height: 8),
              _buildInfoRow(context, 'Size (KB)', '${stats.sizeKB} KB'),
              const SizedBox(height: 8),
              _buildInfoRow(context, 'Size (Bytes)', stats.sizeBytes),
              const SizedBox(height: 16),
              const Text(
                'Statistics:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              _buildInfoRow(context, 'Contacts', '${stats.contacts}'),
              _buildInfoRow(context, 'Chats', '${stats.chats}'),
              _buildInfoRow(context, 'Messages', '${stats.messages}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      onShowError('Error loading database info: $e');
    }
  }

  Future<void> _clearCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Cache?'),
        content: const Text(
          'This will clear temporary cached data. Your messages and contacts will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await controller.clearCaches();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cache cleared:\n• Conversation keys\n• Message cache\n• Hint cache\n• Ephemeral session',
          ),
          backgroundColor: Color(0xFF1976D2),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      onShowError('Failed to clear cache: $e');
    }
  }

  Future<void> _checkDatabaseIntegrity(BuildContext context) async {
    try {
      final result = await controller.checkDatabaseIntegrity();
      if (!context.mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(
                result.isOk ? Icons.check_circle : Icons.error,
                color: result.isOk
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              const Text('Database Integrity'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.isOk
                    ? '✅ Database is healthy'
                    : '⚠️ Database has issues',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: result.isOk
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
              const Text('Result:'),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  result.raw,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      onShowError('Error checking integrity: $e');
    }
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
