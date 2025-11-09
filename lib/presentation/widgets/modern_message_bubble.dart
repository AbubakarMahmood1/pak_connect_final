// Modern message bubble with Material Design 3.0 styling and enhanced features

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../theme/app_theme.dart';

/// Modern message bubble with comprehensive features and accessibility
class ModernMessageBubble extends StatefulWidget {
  final EnhancedMessage message;
  final bool showAvatar;
  final bool showStatus;
  final bool showTimestamp;
  final bool enableInteractions;
  final VoidCallback? onRetry;
  final VoidCallback? onReply;
  final VoidCallback? onForward;
  final VoidCallback? onCopy;
  final VoidCallback? onStar;
  final VoidCallback? onDelete;
  final VoidCallback? onLongPress;

  const ModernMessageBubble({
    super.key,
    required this.message,
    this.showAvatar = true,
    this.showStatus = true,
    this.showTimestamp = false,
    this.enableInteractions = true,
    this.onRetry,
    this.onReply,
    this.onForward,
    this.onCopy,
    this.onStar,
    this.onDelete,
    this.onLongPress,
  });

  @override
  State<ModernMessageBubble> createState() => _ModernMessageBubbleState();
}

class _ModernMessageBubbleState extends State<ModernMessageBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _slideAnimation =
        Tween<Offset>(
          begin: widget.message.isFromMe
              ? const Offset(0.5, 0)
              : const Offset(-0.5, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final customColors = theme.customColors;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            mainAxisAlignment: widget.message.isFromMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!widget.message.isFromMe && widget.showAvatar)
                _buildAvatar(theme),

              Flexible(
                child: GestureDetector(
                  onTapDown: (_) => _handleTapDown(),
                  onTapUp: (_) => _handleTapUp(),
                  onTapCancel: () => _handleTapUp(),
                  onLongPress: widget.enableInteractions
                      ? _handleLongPress
                      : null,
                  child: AnimatedScale(
                    scale: _isPressed ? 0.98 : 1.0,
                    duration: const Duration(milliseconds: 100),
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.8,
                        minWidth: 60,
                      ),
                      child: Card(
                        elevation: widget.message.isFromMe ? 1 : 2,
                        shadowColor: theme.colorScheme.shadow.withValues(
                          alpha: 0.1,
                        ),
                        color: _getMessageBackgroundColor(theme),
                        surfaceTintColor: widget.message.isFromMe
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: _getBubbleBorderRadius(),
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.message.isReply)
                                _buildReplyReference(theme),

                              _buildMessageContent(theme),

                              if (widget.message.reactions.isNotEmpty)
                                _buildReactions(theme),

                              const SizedBox(height: 4),
                              _buildMessageFooter(theme, customColors),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              if (widget.message.isFromMe && widget.showAvatar)
                _buildAvatar(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Build user avatar
  Widget _buildAvatar(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: CircleAvatar(
        radius: 16,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(
          Icons.person,
          size: 20,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  /// Build reply reference
  Widget _buildReplyReference(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Replying to message',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Original message content...',
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Build main message content
  Widget _buildMessageContent(ThemeData theme) {
    return SelectableText(
      widget.message.content,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: _getMessageTextColor(theme),
        height: 1.3,
      ),
      contextMenuBuilder: widget.enableInteractions ? _buildContextMenu : null,
    );
  }

  /// Build message reactions
  Widget _buildReactions(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 2,
        children: widget.message.reactionSummary.entries.map((entry) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Text(
              '${entry.key} ${entry.value}',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Build message footer with status and timestamp
  Widget _buildMessageFooter(ThemeData theme, CustomColors customColors) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (widget.message.wasEdited)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              'edited',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant.withValues(),
              ),
            ),
          ),

        if (widget.message.isStarred)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.star, size: 12, color: Colors.amber.shade600),
          ),

        if (widget.showTimestamp ||
            widget.message.status == MessageStatus.failed)
          Text(
            widget.message.status == MessageStatus.failed
                ? 'Failed'
                : _formatTime(widget.message.timestamp),
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: widget.message.status == MessageStatus.failed
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant.withValues(),
            ),
          ),

        if (widget.showStatus && widget.message.isFromMe) ...[
          const SizedBox(width: 4),
          _buildStatusIcon(theme, customColors),
        ],

        if (widget.message.status == MessageStatus.failed &&
            widget.onRetry != null)
          IconButton(
            onPressed: widget.onRetry,
            icon: Icon(Icons.refresh, size: 16, color: theme.colorScheme.error),
            tooltip: 'Retry sending',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
      ],
    );
  }

  /// Build status icon
  Widget _buildStatusIcon(ThemeData theme, CustomColors customColors) {
    IconData icon;
    Color color;

    switch (widget.message.status) {
      case MessageStatus.sending:
        icon = Icons.access_time;
        color = theme.colorScheme.onSurfaceVariant.withValues();
        break;
      case MessageStatus.sent:
        icon = Icons.check;
        color = theme.colorScheme.onSurfaceVariant.withValues();
        break;
      case MessageStatus.delivered:
        icon = widget.message.isRead ? Icons.done_all : Icons.done_all;
        color = widget.message.isRead
            ? customColors.success
            : theme.colorScheme.onSurfaceVariant.withValues();
        break;
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = theme.colorScheme.error;
        break;
    }

    return Icon(icon, size: 12, color: color);
  }

  /// Build context menu for text selection
  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: [
        if (widget.onCopy != null)
          ContextMenuButtonItem(
            onPressed: () {
              ContextMenuController.removeAny();
              _copyMessageToClipboard();
              widget.onCopy?.call();
            },
            label: 'Copy',
          ),
        if (widget.onReply != null)
          ContextMenuButtonItem(
            onPressed: () {
              ContextMenuController.removeAny();
              widget.onReply?.call();
            },
            label: 'Reply',
          ),
        if (widget.onForward != null)
          ContextMenuButtonItem(
            onPressed: () {
              ContextMenuController.removeAny();
              widget.onForward?.call();
            },
            label: 'Forward',
          ),
        if (widget.onStar != null)
          ContextMenuButtonItem(
            onPressed: () {
              ContextMenuController.removeAny();
              widget.onStar?.call();
            },
            label: widget.message.isStarred ? 'Unstar' : 'Star',
          ),
        if (widget.onDelete != null)
          ContextMenuButtonItem(
            onPressed: () {
              ContextMenuController.removeAny();
              widget.onDelete?.call();
            },
            label: 'Delete',
          ),
      ],
    );
  }

  /// Handle tap down for press effect
  void _handleTapDown() {
    if (widget.enableInteractions) {
      setState(() {
        _isPressed = true;
      });
    }
  }

  /// Handle tap up to remove press effect
  void _handleTapUp() {
    if (_isPressed) {
      setState(() {
        _isPressed = false;
      });
    }
  }

  /// Handle long press for context menu
  void _handleLongPress() {
    if (widget.enableInteractions) {
      HapticFeedback.mediumImpact();
      widget.onLongPress?.call();
      _showMessageContextMenu();
    }
  }

  /// Show context menu for message actions
  void _showMessageContextMenu() {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final Offset offset = renderBox.localToGlobal(Offset.zero);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy,
        offset.dx + renderBox.size.width,
        offset.dy + renderBox.size.height,
      ),
      items: [
        if (widget.onCopy != null)
          const PopupMenuItem<String>(
            value: 'copy',
            child: ListTile(
              leading: Icon(Icons.copy),
              title: Text('Copy'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (widget.onReply != null)
          const PopupMenuItem<String>(
            value: 'reply',
            child: ListTile(
              leading: Icon(Icons.reply),
              title: Text('Reply'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (widget.onForward != null)
          const PopupMenuItem<String>(
            value: 'forward',
            child: ListTile(
              leading: Icon(Icons.forward),
              title: Text('Forward'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (widget.onStar != null)
          PopupMenuItem<String>(
            value: 'star',
            child: ListTile(
              leading: Icon(
                widget.message.isStarred ? Icons.star : Icons.star_border,
              ),
              title: Text(widget.message.isStarred ? 'Unstar' : 'Star'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (widget.onDelete != null)
          const PopupMenuItem<String>(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete, color: Colors.red),
              title: Text('Delete', style: TextStyle(color: Colors.red)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ).then((value) {
      switch (value) {
        case 'copy':
          _copyMessageToClipboard();
          widget.onCopy?.call();
          break;
        case 'reply':
          widget.onReply?.call();
          break;
        case 'forward':
          widget.onForward?.call();
          break;
        case 'star':
          widget.onStar?.call();
          break;
        case 'delete':
          widget.onDelete?.call();
          break;
      }
    });
  }

  /// Copy message content to clipboard
  void _copyMessageToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.message.content));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Message copied to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  /// Get message background color based on sender and theme
  Color _getMessageBackgroundColor(ThemeData theme) {
    if (widget.message.isFromMe) {
      return theme.colorScheme.primaryContainer;
    } else {
      return theme.colorScheme.surfaceContainerHighest;
    }
  }

  /// Get message text color
  Color _getMessageTextColor(ThemeData theme) {
    if (widget.message.isFromMe) {
      return theme.colorScheme.onPrimaryContainer;
    } else {
      return theme.colorScheme.onSurfaceVariant;
    }
  }

  /// Get bubble border radius for natural chat appearance
  BorderRadius _getBubbleBorderRadius() {
    if (widget.message.isFromMe) {
      return const BorderRadius.only(
        topLeft: Radius.circular(16),
        topRight: Radius.circular(16),
        bottomLeft: Radius.circular(16),
        bottomRight: Radius.circular(4),
      );
    } else {
      return const BorderRadius.only(
        topLeft: Radius.circular(16),
        topRight: Radius.circular(16),
        bottomLeft: Radius.circular(4),
        bottomRight: Radius.circular(16),
      );
    }
  }

  /// Format timestamp for display
  String _formatTime(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(
      timestamp.year,
      timestamp.month,
      timestamp.day,
    );

    if (messageDate == today) {
      // Same day - show time only
      return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else if (today.difference(messageDate).inDays == 1) {
      // Yesterday
      return 'Yesterday';
    } else if (today.difference(messageDate).inDays < 7) {
      // This week - show day name
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[timestamp.weekday - 1];
    } else {
      // Older - show date
      return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
    }
  }
}
