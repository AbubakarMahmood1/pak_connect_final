import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/services/mesh_networking_service.dart'
    show ReceivedBinaryEvent, PendingBinaryTransfer;

class BinaryInboxList extends StatelessWidget {
  const BinaryInboxList({
    required this.inbox,
    required this.onDismiss,
    super.key,
  });

  final Map<String, ReceivedBinaryEvent> inbox;
  final void Function(String transferId) onDismiss;

  @override
  Widget build(BuildContext context) {
    final items = inbox.values.toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'New media received',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          ...items.map(
            (event) => Card(
              child: InkWell(
                onTap: () => _openViewer(context, event),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    _isImage(event.filePath)
                        ? Icons.image
                        : Icons.insert_drive_file,
                  ),
                  title: Text(
                    'Media ${event.originalType} • ${_formatBytes(event.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    event.filePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: 'Copy path',
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: event.filePath),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.open_in_new),
                        tooltip: 'Open',
                        onPressed: () => _openViewer(context, event),
                      ),
                      IconButton(
                        icon: const Icon(Icons.check),
                        onPressed: () => onDismiss(event.transferId),
                        tooltip: 'Dismiss',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
  }

  void _openViewer(BuildContext context, ReceivedBinaryEvent event) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BinaryPayloadViewer(event: event)),
    );
  }
}

class PendingBinaryBanner extends StatelessWidget {
  const PendingBinaryBanner({
    required this.transfers,
    required this.onRetryNow,
    super.key,
  });

  final List<PendingBinaryTransfer> transfers;
  final Future<void> Function() onRetryNow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.cloud_upload, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Pending media sends: ${transfers.length}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(onPressed: onRetryNow, child: const Text('Retry now')),
          ],
        ),
      ),
    );
  }
}

class BinaryPayloadViewer extends StatelessWidget {
  const BinaryPayloadViewer({required this.event, super.key});

  final ReceivedBinaryEvent event;

  @override
  Widget build(BuildContext context) {
    final file = File(event.filePath);
    final isImage = _isImage(event.filePath);

    return Scaffold(
      appBar: AppBar(
        title: Text('Media ${event.originalType}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy path',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: event.filePath)),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Dismiss',
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'transferId: ${event.transferId}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              'TTL: ${event.ttl} • Recipient: ${event.recipient ?? "broadcast"}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              event.filePath,
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            if (isImage && file.existsSync())
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(file, fit: BoxFit.contain),
                ),
              )
            else
              Expanded(
                child: Center(
                  child: Icon(
                    Icons.insert_drive_file,
                    size: 48,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
  }
}
