// Restore confirmation dialog widget for chat restoration
// Provides detailed confirmation and options for restoring archived chats

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/archived_chat.dart';
import '../../core/models/archive_models.dart';
import '../providers/archive_provider.dart';

/// Comprehensive confirmation dialog for chat restoration
class RestoreConfirmationDialog extends ConsumerStatefulWidget {
  final ArchivedChatSummary archive;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  
  const RestoreConfirmationDialog({
    super.key,
    required this.archive,
    this.onConfirm,
    this.onCancel,
  });
  
  @override
  ConsumerState<RestoreConfirmationDialog> createState() => _RestoreConfirmationDialogState();
}

class _RestoreConfirmationDialogState extends ConsumerState<RestoreConfirmationDialog> {
  bool _overwriteExisting = false;
  bool _isRestoring = false;
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final operationsState = ref.watch(archiveOperationsStateProvider);
    
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.restore,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          const Text('Restore Chat'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Archive information
            _buildArchiveInfo(context),
            
            const SizedBox(height: 16),
            
            // What will happen section
            _buildRestoreDetails(context),
            
            const SizedBox(height: 16),
            
            // Options section
            _buildRestoreOptions(context),
            
            const SizedBox(height: 16),
            
            // Warnings section
            _buildWarnings(context),
            
            // Loading indicator if restoring
            if (_isRestoring || operationsState.isRestoring) ...[
              const SizedBox(height: 16),
              _buildRestoringIndicator(context),
            ],
          ],
        ),
      ),
      actions: _isRestoring || operationsState.isRestoring 
          ? [
              TextButton(
                onPressed: null,
                child: const Text('Restoring...'),
              ),
            ]
          : [
              TextButton(
                onPressed: () {
                  widget.onCancel?.call();
                  Navigator.pop(context, false);
                },
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: _handleRestore,
                child: const Text('Restore Chat'),
              ),
            ],
    );
  }
  
  Widget _buildArchiveInfo(BuildContext context) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.person,
                size: 16,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                'Contact: ${widget.archive.contactName}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: 14,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.archive.messageCount} messages',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Icon(
                Icons.storage,
                size: 14,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                widget.archive.formattedSize,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 14,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                'Archived ${widget.archive.ageDescription}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildRestoreDetails(BuildContext context) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What will happen:',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _buildDetailItem(
          context,
          Icons.chat,
          'Chat will be restored to your active conversations',
        ),
        _buildDetailItem(
          context,
          Icons.message,
          '${widget.archive.messageCount} messages will be restored',
        ),
        _buildDetailItem(
          context,
          Icons.archive_outlined,
          'Archive will be removed after successful restore',
        ),
        if (widget.archive.isCompressed)
          _buildDetailItem(
            context,
            Icons.compress,
            'Compressed data will be decompressed',
            color: theme.colorScheme.tertiary,
          ),
      ],
    );
  }
  
  Widget _buildDetailItem(
    BuildContext context,
    IconData icon,
    String text, {
    Color? color,
  }) {
    final theme = Theme.of(context);
    final itemColor = color ?? theme.colorScheme.onSurfaceVariant;
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: itemColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: itemColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildRestoreOptions(BuildContext context) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Options:',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          title: const Text('Overwrite existing chat'),
          subtitle: const Text(
            'Replace existing chat if contact is already active',
          ),
          value: _overwriteExisting,
          onChanged: (value) {
            setState(() {
              _overwriteExisting = value ?? false;
            });
          },
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
  
  Widget _buildWarnings(BuildContext context) {
    final theme = Theme.of(context);
    final warnings = _generateWarnings();
    
    if (warnings.isEmpty) return const SizedBox.shrink();
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Text(
                'Please note:',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...warnings.map((warning) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '• ',
                  style: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
                Expanded(
                  child: Text(
                    warning,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
  
  Widget _buildRestoringIndicator(BuildContext context) {
    final theme = Theme.of(context);
    final operationsState = ref.watch(archiveOperationsStateProvider);
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              operationsState.currentOperation ?? 'Restoring chat...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  List<String> _generateWarnings() {
    final warnings = <String>[];
    
    // Archive age warning
    final archiveAge = DateTime.now().difference(widget.archive.archivedAt);
    if (archiveAge.inDays > 30) {
      warnings.add(
        'This archive is ${archiveAge.inDays} days old. Some data may be outdated.'
      );
    }
    
    // Large archive warning
    if (widget.archive.messageCount > 1000) {
      warnings.add(
        'This is a large archive with ${widget.archive.messageCount} messages. '
        'Restoration may take longer than usual.'
      );
    }
    
    // Compressed archive warning
    if (widget.archive.isCompressed) {
      warnings.add(
        'This archive is compressed. Decompression will be performed during restore.'
      );
    }
    
    // Non-searchable archive warning
    if (!widget.archive.isSearchable) {
      warnings.add(
        'This archive is not searchable. Some metadata may be missing.'
      );
    }
    
    return warnings;
  }
  
  Future<void> _handleRestore() async {
    setState(() {
      _isRestoring = true;
    });
    
    try {
      final notifier = ref.read(archiveOperationsProvider);
      final result = await notifier.restoreChat(
        archiveId: widget.archive.id,
        overwriteExisting: _overwriteExisting,
      );
      
      if (mounted) {
        if (result.success) {
          // Show success message
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    color: Theme.of(context).colorScheme.inverseSurface,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Successfully restored chat with ${widget.archive.contactName}'),
                  ),
                ],
              ),
              backgroundColor: Theme.of(context).extension<CustomColors>()?.success,
            ),
          );
          
          widget.onConfirm?.call();
          Navigator.pop(context, true);
        } else {
          // Show error message
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to restore chat: ${result.message}'),
              backgroundColor: Theme.of(context).colorScheme.error,
              action: SnackBarAction(
                label: 'Retry',
                onPressed: _handleRestore,
                textColor: Theme.of(context).colorScheme.onError,
              ),
            ),
          );
          
          setState(() {
            _isRestoring = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restore failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        
        setState(() {
          _isRestoring = false;
        });
      }
    }
  }
}

/// Simple restore confirmation dialog with minimal options
class SimpleRestoreConfirmationDialog extends StatelessWidget {
  final ArchivedChatSummary archive;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  
  const SimpleRestoreConfirmationDialog({
    super.key,
    required this.archive,
    this.onConfirm,
    this.onCancel,
  });
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.restore,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          const Text('Restore Chat?'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Restore archived chat with ${archive.contactName}?'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '• ${archive.messageCount} messages will be restored',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '• Chat will appear in your conversations',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '• Archive will be permanently removed',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            onCancel?.call();
            Navigator.pop(context, false);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            onConfirm?.call();
            Navigator.pop(context, true);
          },
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

/// Utility function to show restore confirmation dialog
Future<bool?> showRestoreConfirmationDialog({
  required BuildContext context,
  required ArchivedChatSummary archive,
  bool simple = false,
  VoidCallback? onConfirm,
  VoidCallback? onCancel,
}) {
  if (simple) {
    return showDialog<bool>(
      context: context,
      builder: (context) => SimpleRestoreConfirmationDialog(
        archive: archive,
        onConfirm: onConfirm,
        onCancel: onCancel,
      ),
    );
  } else {
    return showDialog<bool>(
      context: context,
      builder: (context) => RestoreConfirmationDialog(
        archive: archive,
        onConfirm: onConfirm,
        onCancel: onCancel,
      ),
    );
  }
}

// Placeholder for custom colors - would be defined in theme
class CustomColors {
  final Color? success;
  const CustomColors({this.success});
}