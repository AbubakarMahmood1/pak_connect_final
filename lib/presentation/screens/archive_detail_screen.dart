import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../providers/archive_provider.dart';
import '../widgets/restore_confirmation_dialog.dart';
import '../widgets/archive_context_menu.dart';

/// Screen for viewing and managing individual archived chats
class ArchiveDetailScreen extends ConsumerStatefulWidget {
  final String archivedChatId;

  const ArchiveDetailScreen({
    super.key,
    required this.archivedChatId,
  });

  @override
  ConsumerState<ArchiveDetailScreen> createState() => _ArchiveDetailScreenState();
}

class _ArchiveDetailScreenState extends ConsumerState<ArchiveDetailScreen> {
  ArchivedChat? _archivedChat;
  List<ArchivedMessage> _messages = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Search result navigation
  List<int> _searchResultIndices = [];
  int _currentSearchResultIndex = -1;

  @override
  void initState() {
    super.initState();
    _loadArchivedChat();
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadArchivedChat() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      // Use the repository directly since the service doesn't expose getArchivedChat method
      // We'll need to create a provider for the repository or access it differently
      // For now, let's use a workaround by getting summaries and finding the one we need
      final summaries = await ref.read(archiveListProvider(const ArchiveListFilter()).future);
      final summary = summaries.where((s) => s.id == widget.archivedChatId).firstOrNull;

      if (summary == null) {
        if (mounted) {
          setState(() => _isLoading = false);
          _showError('Archived chat not found');
        }
        return;
      }

      // For now, create a basic ArchivedChat from the summary
      // In a real implementation, we'd have a proper method to get full archived chat
      final archivedChat = ArchivedChat.fromJson({
        'id': summary.id,
        'originalChatId': summary.originalChatId,
        'contactName': summary.contactName,
        'archivedAt': summary.archivedAt.millisecondsSinceEpoch,
        'messageCount': summary.messageCount,
        'metadata': {
          'version': '1.0',
          'reason': 'User archived',
          'originalUnreadCount': 0,
          'wasOnline': false,
          'hadUnsentMessages': false,
          'estimatedStorageSize': summary.estimatedSize,
          'archiveSource': 'ArchiveDetailScreen',
          'tags': summary.tags,
        },
        'messages': [], // Would need proper message loading
      });

      if (mounted) {
        setState(() {
          _archivedChat = archivedChat;
          _messages = archivedChat.messages;
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
        _showError('Archived chat not found');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError('Failed to load archived chat: $e');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResultIndices.clear();
        _currentSearchResultIndex = -1;
      });
      return;
    }

    setState(() => _searchQuery = query);

    // Find all messages containing the search query
    final indices = <int>[];
    for (int i = 0; i < _messages.length; i++) {
      if (_messages[i].content.toLowerCase().contains(query.toLowerCase())) {
        indices.add(i);
      }
    }

    setState(() {
      _searchResultIndices = indices;
      _currentSearchResultIndex = indices.isNotEmpty ? 0 : -1;
    });

    // Scroll to first result
    if (_searchResultIndices.isNotEmpty) {
      _scrollToSearchResult(0);
    }
  }

  void _scrollToSearchResult(int index) {
    if (index < 0 || index >= _searchResultIndices.length) return;

    final messageIndex = _searchResultIndices[index];
    // Scroll to show the message with some padding
    _scrollController.animateTo(
      (messageIndex * 80.0).clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _navigateSearchResult(bool forward) {
    if (_searchResultIndices.isEmpty) return;

    final newIndex = forward
        ? (_currentSearchResultIndex + 1) % _searchResultIndices.length
        : (_currentSearchResultIndex - 1 + _searchResultIndices.length) % _searchResultIndices.length;

    setState(() => _currentSearchResultIndex = newIndex);
    _scrollToSearchResult(newIndex);
  }

  Future<void> _restoreChat() async {
    if (_archivedChat == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => RestoreConfirmationDialog(
        archive: _archivedChat!.toSummary(),
        onConfirm: () => Navigator.pop(context, true),
        onCancel: () => Navigator.pop(context, false),
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final result = await ref.read(archiveOperationsProvider.notifier).restoreChat(archiveId: _archivedChat!.id);

        if (mounted) {
          if (result.success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(
                      Icons.restore,
                      color: Theme.of(context).colorScheme.onInverseSurface,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Chat with ${_archivedChat!.contactName} restored'),
                    ),
                  ],
                ),
                action: SnackBarAction(
                  label: 'View Chat',
                  onPressed: () => Navigator.pop(context), // Go back to chats
                ),
                duration: Duration(seconds: 4),
              ),
            );
            Navigator.pop(context); // Close detail screen
          } else {
            _showError('Failed to restore chat: ${result.message}');
          }
        }
      } catch (e) {
        _showError('Error restoring chat: $e');
      }
    }
  }

  Future<void> _deleteChat() async {
    if (_archivedChat == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.delete_forever,
              color: Theme.of(context).colorScheme.error,
            ),
            SizedBox(width: 8),
            Text('Permanently Delete'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will permanently delete the archived chat with ${_archivedChat!.contactName}.'),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'This action cannot be undone.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text('Delete Forever'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final success = await ref.read(archiveOperationsProvider.notifier).deleteArchivedChat(_archivedChat!.id);

        if (mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Permanently deleted chat with ${_archivedChat!.contactName}'),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
            Navigator.pop(context); // Close detail screen
          } else {
            _showError('Failed to delete chat');
          }
        }
      } catch (e) {
        _showError('Error deleting chat: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _archivedChat != null
            ? Text('Archived: ${_archivedChat!.contactName}')
            : Text('Archived Chat'),
        actions: [
          if (_searchQuery.isNotEmpty && _searchResultIndices.isNotEmpty) ...[
            Text(
              '${_currentSearchResultIndex + 1}/${_searchResultIndices.length}',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            IconButton(
              onPressed: () => _navigateSearchResult(false),
              icon: Icon(Icons.keyboard_arrow_up),
              tooltip: 'Previous result',
            ),
            IconButton(
              onPressed: () => _navigateSearchResult(true),
              icon: Icon(Icons.keyboard_arrow_down),
              tooltip: 'Next result',
            ),
          ],
          IconButton(
            onPressed: () => _showSearchDialog(),
            icon: Icon(Icons.search),
            tooltip: 'Search in chat',
          ),
          PopupMenuButton<ArchiveAction>(
            onSelected: _handleArchiveAction,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: ArchiveAction.restore,
                child: Row(
                  children: [
                    Icon(Icons.restore, size: 18),
                    SizedBox(width: 8),
                    Text('Restore Chat'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: ArchiveAction.delete,
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, size: 18, color: Theme.of(context).colorScheme.error),
                    SizedBox(width: 8),
                    Text('Delete Permanently', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: _searchQuery.isNotEmpty
            ? PreferredSize(
                preferredSize: Size.fromHeight(56),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Searching for: "$_searchQuery"',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _performSearch(''),
                        icon: Icon(Icons.clear, size: 18),
                        tooltip: 'Clear search',
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _archivedChat == null
              ? _buildErrorState()
              : _buildChatContent(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
          SizedBox(height: 16),
          Text(
            'Chat Not Found',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          SizedBox(height: 8),
          Text(
            'This archived chat may have been deleted or is no longer available.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.arrow_back),
            label: Text('Back to Archives'),
          ),
        ],
      ),
    );
  }

  Widget _buildChatContent() {
    if (_messages.isEmpty) {
      return _buildEmptyMessagesState();
    }

    return Column(
      children: [
        // Archive metadata header
        _buildArchiveMetadataHeader(),
        // Messages list
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, index) => _buildMessageItem(index),
          ),
        ),
      ],
    );
  }

  Widget _buildArchiveMetadataHeader() {
    if (_archivedChat == null) return SizedBox.shrink();

    return Container(
      padding: EdgeInsets.all(16),
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.archive,
                size: 20,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              SizedBox(width: 8),
              Text(
                'Archived on ${_formatDate(_archivedChat!.archivedAt)}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ],
          ),
          if (_archivedChat!.metadata.reason.isNotEmpty) ...[
            SizedBox(height: 4),
            Text(
              'Reason: ${_archivedChat!.metadata.reason}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          SizedBox(height: 8),
          Row(
            children: [
              _buildMetadataChip(
                '${_messages.length} messages',
                Icons.message,
              ),
              SizedBox(width: 8),
              _buildMetadataChip(
                '${(_archivedChat!.estimatedSize / 1024).toStringAsFixed(1)} KB',
                Icons.storage,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataChip(String text, IconData icon) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
          SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(int index) {
    final message = _messages[index];
    final isSearchResult = _searchResultIndices.contains(index);
    final isCurrentSearchResult = _currentSearchResultIndex >= 0 &&
                                  _searchResultIndices.isNotEmpty &&
                                  _searchResultIndices[_currentSearchResultIndex] == index;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isCurrentSearchResult
            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3)
            : isSearchResult
                ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.2)
                : null,
        border: isCurrentSearchResult
            ? Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              )
            : null,
      ),
      child: _buildArchivedMessageBubble(message),
    );
  }

  Widget _buildArchivedMessageBubble(ArchivedMessage message) {
    final theme = Theme.of(context);

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisAlignment: message.isFromMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isFromMe)
            Container(
              margin: EdgeInsets.only(right: 8),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.person,
                  size: 20,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),

          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
                minWidth: 60,
              ),
              child: Card(
                elevation: message.isFromMe ? 1 : 2,
                color: message.isFromMe
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: message.isFromMe
                      ? BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(4),
                        )
                      : BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(4),
                          bottomRight: Radius.circular(16),
                        ),
                ),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _highlightSearchText(message.content, _searchQuery),
                      SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (message.wasEdited)
                            Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Text(
                                'edited',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontStyle: FontStyle.italic,
                                  color: theme.colorScheme.onSurfaceVariant.withValues(),
                                ),
                              ),
                            ),
                          Text(
                            _formatMessageTime(message.originalTimestamp),
                            style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant.withValues(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          if (message.isFromMe)
            Container(
              margin: EdgeInsets.only(left: 8),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.person,
                  size: 20,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _highlightSearchText(String text, String query) {
    if (query.isEmpty) return Text(text);

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];

    int start = 0;
    int index = lowerText.indexOf(lowerQuery);

    while (index != -1) {
      // Add text before match
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }

      // Add highlighted match
      final end = index + query.length;
      spans.add(TextSpan(
        text: text.substring(index, end),
        style: TextStyle(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ));

      start = end;
      index = lowerText.indexOf(lowerQuery, start);
    }

    // Add remaining text
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }

    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildEmptyMessagesState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          SizedBox(height: 16),
          Text(
            'No Messages',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          SizedBox(height: 8),
          Text(
            'This archived chat contains no messages.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _showSearchDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.search),
            SizedBox(width: 8),
            Text('Search in Chat'),
          ],
        ),
        content: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Enter search term...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onChanged: (value) {
            _searchDebounceTimer?.cancel();
            _searchDebounceTimer = Timer(Duration(milliseconds: 300), () {
              _performSearch(value);
            });
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              _searchController.clear();
              _performSearch('');
              Navigator.pop(context);
            },
            child: Text('Clear'),
          ),
          FilledButton(
            onPressed: () {
              _performSearch(_searchController.text);
              Navigator.pop(context);
            },
            child: Text('Search'),
          ),
        ],
      ),
    );
  }

  void _handleArchiveAction(ArchiveAction action) {
    switch (action) {
      case ArchiveAction.restore:
        _restoreChat();
        break;
      case ArchiveAction.delete:
        _deleteChat();
        break;
      default:
        break;
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'today';
    } else if (difference.inDays == 1) {
      return 'yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String _formatMessageTime(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(timestamp.year, timestamp.month, timestamp.day);

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