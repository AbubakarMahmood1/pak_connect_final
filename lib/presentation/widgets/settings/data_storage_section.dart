import 'package:flutter/material.dart';

import '../../controllers/settings_controller.dart';
import '../../screens/permission_screen.dart';
import '../export_dialog.dart';
import '../import_dialog.dart';

class DataStorageSection extends StatelessWidget {
  const DataStorageSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.auto_delete),
            title: const Text('Auto-Archive Old Chats'),
            subtitle: const Text('Automatically archive inactive chats'),
            value: controller.autoArchiveOldChats,
            onChanged: (value) async {
              await controller.setAutoArchiveOldChats(value);
            },
          ),
          if (controller.autoArchiveOldChats) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: const Text('Archive After'),
              subtitle: Text(
                '${controller.archiveAfterDays} days of inactivity',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showArchiveDaysDialog(context),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Check Inactive Chats Now'),
              subtitle: const Text('Manually trigger auto-archive check'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _manualAutoArchiveCheck(context),
            ),
          ],
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('Export All Data'),
            subtitle: const Text('Create encrypted backup of all data'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showExportDialog(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.upload_file_rounded),
            title: const Text('Import Backup'),
            subtitle: const Text('Restore data from backup file'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showImportDialog(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Storage Usage'),
            subtitle: const Text('View app storage usage'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showStorageInfo(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
            title: Text(
              'Clear All Data',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: const Text('Delete all messages, chats, and contacts'),
            trailing: Icon(Icons.chevron_right, color: theme.colorScheme.error),
            onTap: () => _confirmClearData(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showArchiveDaysDialog(BuildContext context) async {
    int? selectedValue = controller.archiveAfterDays;
    final theme = Theme.of(context);

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Auto-Archive After'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Archive chats that have been inactive for:'),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                segments: [30, 60, 90, 180, 365]
                    .map(
                      (days) =>
                          ButtonSegment<int>(value: days, label: Text('$days')),
                    )
                    .toList(),
                selected: selectedValue != null
                    ? <int>{selectedValue!}
                    : <int>{},
                onSelectionChanged: (Set<int> selection) {
                  if (selection.isNotEmpty) {
                    setState(() => selectedValue = selection.first);
                  }
                },
                showSelectedIcon: false,
              ),
              const SizedBox(height: 8),
              Text(
                'days of inactivity',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selectedValue),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != null && result != controller.archiveAfterDays) {
      await controller.setArchiveAfterDays(result);
    }
  }

  Future<void> _manualAutoArchiveCheck(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Checking for inactive chats...'),
          ],
        ),
      ),
    );

    try {
      final archivedCount = await controller.manualAutoArchiveCheck();
      if (context.mounted) Navigator.pop(context);

      if (context.mounted) {
        final message = archivedCount > 0
            ? 'Auto-archived $archivedCount inactive chat${archivedCount == 1 ? '' : 's'}'
            : 'No inactive chats found';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: archivedCount > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to check inactive chats: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _showStorageInfo(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final info = await controller.getStorageInfo();
      if (context.mounted) Navigator.pop(context);

      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Storage Usage'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (info.exists) ...[
                Text('Database: ${info.sizeMB} MB'),
                const SizedBox(height: 8),
                Text('(${info.sizeKB} KB)'),
                const SizedBox(height: 16),
                Text(
                  'Includes: messages, chats, contacts, archives',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else ...[
                const Text('No database found'),
                const SizedBox(height: 8),
                const Text('Storage: 0 MB'),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to calculate storage: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _confirmClearData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 8),
            const Text('Clear All Data?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This will permanently delete:'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• All messages', style: TextStyle(fontSize: 14)),
                  Text('• All chats', style: TextStyle(fontSize: 14)),
                  Text('• All contacts', style: TextStyle(fontSize: 14)),
                  Text('• Archived data', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'This action cannot be undone!',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
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
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: const [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 16),
                Text('Clearing all data...'),
              ],
            ),
            duration: const Duration(seconds: 30),
          ),
        );

        await controller.clearAllData();

        if (!context.mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All data cleared successfully'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );

        await Future.delayed(const Duration(seconds: 2));

        if (context.mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const PermissionScreen()),
            (route) => false,
          );
        }
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to clear data: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _showExportDialog(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ExportDialog(),
    );
  }

  Future<void> _showImportDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ImportDialog(),
    );

    if (result == true && context.mounted) {
      await controller.initialize();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Data imported successfully! Please restart the app.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
