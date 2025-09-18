import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/entities/message.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool showAvatar;
  final bool showStatus;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    this.showAvatar = true,
    this.showStatus = true,
    this.onLongPress,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isFromMe = message.isFromMe;
    
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2, horizontal: 12),
      child: Row(
        mainAxisAlignment: isFromMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress ?? () => _copyMessage(context, message.content),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
  gradient: isFromMe 
    ? LinearGradient(
        colors: [
          Theme.of(context).colorScheme.primary,
          Theme.of(context).colorScheme.primary.withValues(),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      )
    : null,
  color: isFromMe 
    ? null  // Use gradient instead
    : Theme.of(context).colorScheme.surfaceContainerHighest,
  borderRadius: BorderRadius.circular(20).copyWith(
    bottomRight: isFromMe ? Radius.circular(6) : Radius.circular(20),
    bottomLeft: isFromMe ? Radius.circular(20) : Radius.circular(6),
  ),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(),
      blurRadius: 6,
      offset: Offset(0, 2),
    ),
    BoxShadow(
      color: Colors.black.withValues(),
      blurRadius: 1,
      offset: Offset(0, 1),
    ),
  ],
),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.content,
                      style: TextStyle(
                        color: isFromMe 
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 16,
                        height: 1.3,
                      ),
                    ),
                    SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            color: isFromMe 
                                ? Theme.of(context).colorScheme.onPrimary.withValues()
                                : Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (isFromMe && showStatus) ...[
                          SizedBox(width: 4),
                          _buildStatusIcon(context, message.status),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          if (isFromMe) SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context, MessageStatus status) {
    switch (status) {
      case MessageStatus.failed:
      return GestureDetector(
        onTap: () => onRetry?.call(),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.red.withValues(),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withValues()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error, size: 12, color: Colors.red),
              SizedBox(width: 4),
              Text('Tap to retry', style: TextStyle(fontSize: 10, color: Colors.red)),
            ],
          ),
        ),
      );
      case MessageStatus.sending:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1,
            color: Theme.of(context).colorScheme.onPrimary.withValues(),
          ),
        );
      case MessageStatus.sent:
        return Icon(Icons.check, size: 14, color: Theme.of(context).colorScheme.onPrimary.withValues());
      case MessageStatus.delivered:
        return Icon(Icons.done_all, size: 14, color: Colors.green);
      }
  }

  String _formatTime(DateTime timestamp) {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
  }

  void _copyMessage(BuildContext context, String content) async {
  await Clipboard.setData(ClipboardData(text: content));
}
}