import 'package:flutter/material.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

class ContactRequestDialog extends StatelessWidget {
  final String senderName;
  final String senderPublicKey;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final bool isOutgoing;

  const ContactRequestDialog({
    super.key,
    required this.senderName,
    required this.senderPublicKey,
    required this.onAccept,
    required this.onReject,
    this.isOutgoing = false,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isOutgoing ? Icons.person_add : Icons.group_add,
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(width: 8),
          Text(isOutgoing ? 'Add Contact?' : 'Contact Request'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOutgoing) ...[
            Text(
              'Do you want to add "$senderName" as a contact?',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            SizedBox(height: 12),
            Text(
              'This will send a contact request that they need to accept.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ] else ...[
            Text(
              '"$senderName" wants to add you as a contact.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Only accept if you recognize this person',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Device ID: ${senderPublicKey.length > 16 ? '${senderPublicKey.shortId()}...' : senderPublicKey}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: onReject,
          child: Text(isOutgoing ? 'Cancel' : 'Reject'),
        ),
        FilledButton(
          onPressed: onAccept,
          child: Text(isOutgoing ? 'Send Request' : 'Accept'),
        ),
      ],
    );
  }
}

class ContactRequestPendingDialog extends StatelessWidget {
  final String recipientName;
  final VoidCallback onCancel;

  const ContactRequestPendingDialog({
    super.key,
    required this.recipientName,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('Contact Request Sent'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Waiting for "$recipientName" to accept your contact request...',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          SizedBox(height: 16),
          LinearProgressIndicator(),
        ],
      ),
      actions: [TextButton(onPressed: onCancel, child: Text('Cancel'))],
    );
  }
}

class ContactRequestResultDialog extends StatelessWidget {
  final String contactName;
  final bool wasAccepted;
  final VoidCallback onClose;

  const ContactRequestResultDialog({
    super.key,
    required this.contactName,
    required this.wasAccepted,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            wasAccepted ? Icons.check_circle : Icons.cancel,
            color: wasAccepted
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
          SizedBox(width: 8),
          Text(wasAccepted ? 'Contact Added!' : 'Request Rejected'),
        ],
      ),
      content: Text(
        wasAccepted
            ? '"$contactName" accepted your contact request. You can now chat securely!'
            : '"$contactName" rejected your contact request.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      actions: [FilledButton(onPressed: onClose, child: Text('OK'))],
    );
  }
}
