import 'package:flutter/material.dart';
import '../../domain/entities/message.dart';

class DeleteConfirmationDialog extends StatefulWidget {
  final Message message;
  final Function(bool deleteForEveryone) onConfirm;

  const DeleteConfirmationDialog({
    super.key,
    required this.message,
    required this.onConfirm,
  });

  @override
  State<DeleteConfirmationDialog> createState() =>
      _DeleteConfirmationDialogState();
}

class _DeleteConfirmationDialogState extends State<DeleteConfirmationDialog> {
  bool _deleteForEveryone = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(Icons.delete_outline, color: Colors.red, size: 32),
      title: Text('Delete Message?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Are you sure you want to delete this message?',
            style: Theme.of(context).textTheme.bodyMedium,
          ),

          SizedBox(height: 16),

          // Message preview
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              widget.message.content.length > 100
                  ? '${widget.message.content.substring(0, 100)}...'
                  : widget.message.content,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),

          SizedBox(height: 16),

          // Delete for everyone option (only for own messages that are delivered)
          if (widget.message.isFromMe &&
              (widget.message.status == MessageStatus.delivered ||
                  widget.message.status == MessageStatus.sent))
            CheckboxListTile(
              value: _deleteForEveryone,
              onChanged: (value) {
                setState(() {
                  _deleteForEveryone = value ?? false;
                });
              },
              title: Text(
                'Delete for everyone',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Text(
                'This will also remove the message from the recipient\'s device',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            widget.onConfirm(_deleteForEveryone);
          },
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: Text('Delete'),
        ),
      ],
    );
  }
}
