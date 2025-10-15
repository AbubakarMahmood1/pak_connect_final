// Archive context menu widget for archive operations
// Provides restore, delete, and other archive-specific actions

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/archived_chat.dart';

/// Context menu for archived chat operations
class ArchiveContextMenu extends ConsumerWidget {
  final ArchivedChatSummary archive;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;
  final VoidCallback? onViewDetails;
  final VoidCallback? onExport;
  final Widget child;
  
  const ArchiveContextMenu({
    super.key,
    required this.archive,
    this.onRestore,
    this.onDelete,
    this.onViewDetails,
    this.onExport,
    required this.child,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<ArchiveAction>(
      onSelected: (action) => _handleAction(context, action),
      itemBuilder: (context) => [
        // View details
        PopupMenuItem<ArchiveAction>(
          value: ArchiveAction.viewDetails,
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              const Text('View Details'),
            ],
          ),
        ),
        
        // Restore
        PopupMenuItem<ArchiveAction>(
          value: ArchiveAction.restore,
          child: Row(
            children: [
              Icon(
                Icons.restore,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              const Text('Restore Chat'),
            ],
          ),
        ),
        
        // Export (if available)
        if (archive.isSearchable)
          PopupMenuItem<ArchiveAction>(
            value: ArchiveAction.export,
            child: Row(
              children: [
                Icon(
                  Icons.download,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                const Text('Export Archive'),
              ],
            ),
          ),
        
        // Divider before destructive action
        const PopupMenuDivider(),
        
        // Delete permanently
        PopupMenuItem<ArchiveAction>(
          value: ArchiveAction.delete,
          child: Row(
            children: [
              Icon(
                Icons.delete_forever,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 12),
              Text(
                'Delete Permanently',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ],
      child: child,
    );
  }
  
  void _handleAction(BuildContext context, ArchiveAction action) {
    switch (action) {
      case ArchiveAction.viewDetails:
        onViewDetails?.call();
        break;
      case ArchiveAction.restore:
        _showRestoreConfirmation(context);
        break;
      case ArchiveAction.export:
        _showExportDialog(context);
        break;
      case ArchiveAction.delete:
        _showDeleteConfirmation(context);
        break;
    }
  }
  
  void _showRestoreConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.restore,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            const Text('Restore Chat'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Restore archived chat with ${archive.contactName}?'),
            const SizedBox(height: 8),
            Text(
              '• ${archive.messageCount} messages will be restored\n'
              '• Chat will appear in your active conversations\n'
              '• Archive will be removed',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            onPressed: () {
              Navigator.pop(context);
              onRestore?.call();
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }
  
  void _showDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.warning,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 12),
            const Text('Delete Permanently'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Permanently delete archived chat with ${archive.contactName}?',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.warning,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This action cannot be undone!',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• ${archive.messageCount} messages will be lost forever\n'
                    '• ${archive.formattedSize} of storage will be freed\n'
                    '• Archive cannot be recovered',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ],
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
            onPressed: () {
              Navigator.pop(context);
              onDelete?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );
  }
  
  void _showExportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.download,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            const Text('Export Archive'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Export archived chat with ${archive.contactName}?'),
            const SizedBox(height: 8),
            Text(
              'Archive will be exported as a JSON file containing all messages and metadata.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            onPressed: () {
              Navigator.pop(context);
              onExport?.call();
            },
            child: const Text('Export'),
          ),
        ],
      ),
    );
  }
}

/// Archive action types for context menu
enum ArchiveAction {
  viewDetails,
  restore,
  export,
  delete,
}

/// Simple context menu for inline archive actions
class SimpleArchiveContextMenu extends ConsumerWidget {
  final ArchivedChatSummary archive;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;
  
  const SimpleArchiveContextMenu({
    super.key,
    required this.archive,
    this.onRestore,
    this.onDelete,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Restore button
        IconButton(
          onPressed: onRestore,
          icon: Icon(
            Icons.restore,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          tooltip: 'Restore chat',
          visualDensity: VisualDensity.compact,
        ),
        
        // Delete button
        IconButton(
          onPressed: () => _showQuickDeleteConfirmation(context),
          icon: Icon(
            Icons.delete_outline,
            size: 18,
            color: theme.colorScheme.error,
          ),
          tooltip: 'Delete permanently',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
  
  void _showQuickDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Archive?'),
        content: Text(
          'Permanently delete archived chat with ${archive.contactName}?\n\n'
          'This will delete ${archive.messageCount} messages and cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              onDelete?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}