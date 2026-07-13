// Sender-side broadcast history with per-recipient queue status.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/group_providers.dart';
import '../../domain/models/contact_group.dart';
import 'package:intl/intl.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  final String groupId;

  const GroupChatScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isSending = false;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    setState(() => _isSending = true);
    _messageController.clear();

    try {
      // Get sender key
      final senderKey = await ref.read(
        currentGroupUserPublicKeyProvider.future,
      );

      // Send message
      final sendMessage = ref.read(sendGroupMessageProvider);
      await sendMessage(
        groupId: widget.groupId,
        senderKey: senderKey,
        content: content,
      );

      // Scroll to bottom
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to send message: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupAsync = ref.watch(groupByIdProvider(widget.groupId));
    final messagesAsync = ref.watch(groupMessagesProvider(widget.groupId));

    return Scaffold(
      appBar: AppBar(
        title: groupAsync.when(
          data: (group) => group != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name),
                    Text(
                      '${group.memberCount} recipients',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                )
              : const Text('Broadcast List'),
          loading: () => const Text('Loading...'),
          error: (_, _) => const Text('Error'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              // Show group info dialog
              _showGroupInfo(groupAsync.value);
            },
            tooltip: 'Broadcast List Info',
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text(
                      'No broadcasts yet\nSend a message to every recipient separately.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  reverse: true, // Latest at bottom
                  padding: const EdgeInsets.all(8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return _MessageBubble(message: message);
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text('Error loading messages: $error'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () =>
                          ref.refresh(groupMessagesProvider(widget.groupId)),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Message input
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'Message all recipients...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    maxLines: null,
                    textCapitalization: TextCapitalization.sentences,
                    enabled: !_isSending,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: _isSending
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: _isSending ? null : _sendMessage,
                  tooltip: 'Send',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showGroupInfo(ContactGroup? group) {
    if (group == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(group.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (group.description != null) ...[
              Text(group.description!),
              const SizedBox(height: 16),
            ],
            Text('Recipients: ${group.memberCount}'),
            const SizedBox(height: 8),
            Text('Created: ${DateFormat.yMMMd().format(group.created)}'),
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
  }
}

class _MessageBubble extends ConsumerWidget {
  final GroupMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUserKey = ref.watch(currentGroupUserPublicKeyProvider).value;
    final isFromCurrentUser =
        currentUserKey != null &&
        currentUserKey.isNotEmpty &&
        message.senderKey == currentUserKey;
    final deliverySummary = isFromCurrentUser
        ? ref.watch(messageDeliverySummaryProvider(message.id))
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        key: ValueKey('group-message-${message.id}'),
        crossAxisAlignment: isFromCurrentUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // Message content
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isFromCurrentUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isFromCurrentUser) ...[
                  Text(
                    message.senderKey.shortId(8),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],

                // Message content
                Text(message.content),

                const SizedBox(height: 4),

                // Timestamp + delivery status
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat.jm().format(message.timestamp),
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                    if (isFromCurrentUser) ...[
                      const SizedBox(width: 8),
                      deliverySummary!.when(
                        data: (summary) {
                          final total = summary.values.fold<int>(
                            0,
                            (sum, count) => sum + count,
                          );
                          final delivered =
                              summary[MessageDeliveryStatus.delivered] ?? 0;
                          final queued =
                              summary[MessageDeliveryStatus.sent] ?? 0;
                          final failed =
                              summary[MessageDeliveryStatus.failed] ?? 0;

                          IconData icon;
                          Color color;

                          if (delivered == total) {
                            icon = Icons.done_all;
                            color = Colors.blue;
                          } else if (queued + delivered > 0) {
                            icon = Icons.done;
                            color = Colors.grey;
                          } else if (failed > 0) {
                            icon = Icons.error_outline;
                            color = Colors.red;
                          } else {
                            icon = Icons.schedule;
                            color = Colors.grey;
                          }

                          return Tooltip(
                            message:
                                'Delivered: $delivered/$total\nQueued: $queued\nFailed: $failed',
                            child: Icon(icon, size: 16, color: color),
                          );
                        },
                        loading: () => const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        error: (_, _) => const Icon(
                          Icons.help_outline,
                          size: 16,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Per-recipient queue details (expandable)
          if (isFromCurrentUser &&
              (message.hasFailures || !message.isFullyDelivered))
            TextButton.icon(
              onPressed: () {
                _showDeliveryDetails(context, ref);
              },
              icon: const Icon(Icons.info_outline, size: 16),
              label: Text(
                'Recipient status',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  void _showDeliveryDetails(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recipient Status'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: message.deliveryStatus.entries.map((entry) {
              final memberKey = entry.key;
              final status = entry.value;

              IconData icon;
              Color color;
              String statusText;

              switch (status) {
                case MessageDeliveryStatus.delivered:
                  icon = Icons.check_circle;
                  color = Colors.green;
                  statusText = 'Delivered';
                  break;
                case MessageDeliveryStatus.sent:
                  icon = Icons.done;
                  color = Colors.blue;
                  statusText = 'Queued';
                  break;
                case MessageDeliveryStatus.pending:
                  icon = Icons.schedule;
                  color = Colors.orange;
                  statusText = 'Pending';
                  break;
                case MessageDeliveryStatus.failed:
                  icon = Icons.error;
                  color = Colors.red;
                  statusText = 'Failed';
                  break;
              }

              return ListTile(
                leading: Icon(icon, color: color),
                title: Text(memberKey.shortId()),
                subtitle: Text(statusText),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
