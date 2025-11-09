import 'package:flutter/material.dart';
import '../../domain/entities/message.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

class MessageContextMenu extends StatelessWidget {
  final Message message;
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;
  final VoidCallback? onReply; // Future enhancement

  const MessageContextMenu({
    super.key,
    required this.message,
    this.onDelete,
    this.onCopy,
    this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle indicator
          Container(
            width: 36,
            height: 4,
            margin: EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Copy option
          if (onCopy != null)
            ListTile(
              leading: Icon(Icons.content_copy),
              title: Text('Copy Message'),
              onTap: () {
                Navigator.pop(context);
                onCopy?.call();
              },
            ),

          // Delete option (only for own messages)
          if (onDelete != null && message.isFromMe)
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                'Delete Message',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(context);
                onDelete?.call();
              },
            ),

          // Message info/details
          ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Message Info'),
            onTap: () {
              Navigator.pop(context);
              _showMessageInfo(context, message);
            },
          ),

          // Reply option (future enhancement)
          if (onReply != null)
            ListTile(
              leading: Icon(Icons.reply),
              title: Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                onReply?.call();
              },
            ),

          // Cancel
          ListTile(
            leading: Icon(Icons.close),
            title: Text('Cancel'),
            onTap: () => Navigator.pop(context),
          ),

          // Bottom padding for safe area
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  void _showMessageInfo(BuildContext context, Message message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Message Details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow('Sent', message.isFromMe ? 'Yes' : 'No'),
            _buildInfoRow('Status', _getStatusText(message.status)),
            _buildInfoRow('Time', _formatDateTime(message.timestamp)),
            _buildInfoRow('ID', message.id.shortId(8)),
            if (message.content.length > 50)
              _buildInfoRow('Length', '${message.content.length} characters'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  String _getStatusText(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return 'Sending';
      case MessageStatus.sent:
        return 'Sent';
      case MessageStatus.delivered:
        return 'Delivered';
      case MessageStatus.failed:
        return 'Failed';
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day}/${dateTime.month}/${dateTime.year} '
        '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}';
  }
}
