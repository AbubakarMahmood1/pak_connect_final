// Modern search interface with comprehensive filtering and accessibility features

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/services/chat_management_service.dart' as chat_service;
import 'modern_message_bubble.dart';

/// Modern search delegate with advanced filtering and suggestions
class ModernSearchDelegate extends SearchDelegate<String> {
  final chat_service.ChatManagementService _chatService;
  final String? chatId;
  
  // Search state
  chat_service.MessageSearchFilter? _currentFilter;
  
  ModernSearchDelegate({
    required chat_service.ChatManagementService chatService,
    this.chatId,
  }) : _chatService = chatService;

  @override
  String get searchFieldLabel => chatId != null ? 'Search in chat...' : 'Search messages...';

  @override
  TextStyle get searchFieldStyle => const TextStyle(fontSize: 16);

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 3,
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        iconTheme: IconThemeData(
          color: theme.colorScheme.onSurface,
        ),
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintStyle: TextStyle(
          color: theme.colorScheme.onSurfaceVariant.withValues(),
        ),
      ),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      // Filter button
      IconButton(
        icon: Badge(
          isLabelVisible: _currentFilter != null,
          child: Icon(Icons.filter_list),
        ),
        onPressed: () => _showFilterDialog(context),
        tooltip: 'Filter results',
      ),
      
      // Clear button
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
          tooltip: 'Clear search',
        ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: AnimatedIcon(
        icon: AnimatedIcons.menu_arrow,
        progress: transitionAnimation,
      ),
      onPressed: () => close(context, ''),
      tooltip: 'Back',
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) {
      return _buildEmptyState(context, 'Enter a search term to find messages');
    }

    return FutureBuilder<chat_service.MessageSearchResult>(
      future: _performSearch(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoadingState(context);
        }
        
        if (snapshot.hasError) {
          return _buildErrorState(context, snapshot.error.toString());
        }
        
        final result = snapshot.data;
        if (result == null || result.results.isEmpty) {
          return _buildEmptyState(context, 'No messages found for "$query"');
        }
        
        return _buildSearchResults(context, result);
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final recentSearches = _chatService.getMessageSearchHistory();
    final theme = Theme.of(context);
    
    if (query.isEmpty && recentSearches.isEmpty) {
      return _buildSearchTips(context);
    }
    
    if (query.isEmpty) {
      return _buildRecentSearches(context, recentSearches);
    }
    
    // Show filtered recent searches based on current query
    final filteredSuggestions = recentSearches
        .where((search) => search.toLowerCase().contains(query.toLowerCase()))
        .take(5)
        .toList();
    
    if (filteredSuggestions.isEmpty) {
      return _buildQuickActions(context);
    }
    
    return ListView.builder(
      itemCount: filteredSuggestions.length,
      padding: const EdgeInsets.all(8),
      itemBuilder: (context, index) {
        final suggestion = filteredSuggestions[index];
        return ListTile(
          leading: Icon(
            Icons.history,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: RichText(
            text: TextSpan(
              style: theme.textTheme.bodyMedium,
              children: _highlightQueryInText(suggestion, query, theme),
            ),
          ),
          trailing: IconButton(
            icon: Icon(
              Icons.call_made,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: () => query = suggestion,
          ),
          onTap: () {
            query = suggestion;
            showResults(context);
          },
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }

  /// Perform search with current query and filters
  Future<chat_service.MessageSearchResult> _performSearch() async {
    return await _chatService.searchMessages(
      query: query,
      chatId: chatId,
      filter: _currentFilter,
      limit: 50,
    );
  }

  /// Build search results list
  Widget _buildSearchResults(BuildContext context, chat_service.MessageSearchResult result) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search info header
        Container(
          padding: const EdgeInsets.all(16),
          color: theme.colorScheme.surfaceContainerHighest.withValues(),
          child: Row(
            children: [
              Icon(
                Icons.search,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                '${result.totalResults} result${result.totalResults != 1 ? 's' : ''} in ${result.searchTime.inMilliseconds}ms',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (result.hasMore)
                Chip(
                  label: Text(
                    'More available',
                    style: TextStyle(fontSize: 10),
                  ),
                  backgroundColor: theme.colorScheme.primaryContainer,
                  side: BorderSide.none,
                ),
            ],
          ),
        ),
        
        // Results list
        Expanded(
          child: chatId != null 
              ? _buildChatResults(context, result.results)
              : _buildGroupedResults(context, result.resultsByChat),
        ),
      ],
    );
  }

  /// Build results for single chat
  Widget _buildChatResults(BuildContext context, List<EnhancedMessage> messages) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          child: ModernMessageBubble(
            message: message,
            showAvatar: true,
            showStatus: false,
            showTimestamp: true,
            enableInteractions: false,
            onCopy: () => _copyMessage(message),
          ),
        );
      },
    );
  }

  /// Build grouped results by chat
  Widget _buildGroupedResults(BuildContext context, Map<String, List<EnhancedMessage>> resultsByChat) {
    final theme = Theme.of(context);
    
    return ListView(
      padding: const EdgeInsets.all(8),
      children: resultsByChat.entries.map((entry) {
        final chatId = entry.key;
        final messages = entry.value;
        
        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Chat header
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.chat,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                title: Text(
                  'Chat: ${chatId.substring(0, 8)}...', // In real app, would show contact name
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(
                  '${messages.length} message${messages.length != 1 ? 's' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Icon(
                  Icons.keyboard_arrow_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onTap: () => _openChatWithMessages(context, chatId, messages),
              ),
              
              // Preview messages
              ...messages.take(2).map((message) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ModernMessageBubble(
                  message: message,
                  showAvatar: false,
                  showStatus: false,
                  showTimestamp: true,
                  enableInteractions: false,
                ),
              )),
              
              if (messages.length > 2)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${messages.length - 2} more message${messages.length - 2 != 1 ? 's' : ''}...',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// Build loading state
  Widget _buildLoadingState(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Searching messages...'),
        ],
      ),
    );
  }

  /// Build error state
  Widget _buildErrorState(BuildContext context, String error) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            'Search failed',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            error,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => showResults(context),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  /// Build empty state
  Widget _buildEmptyState(BuildContext context, String message) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Build search tips for empty query
  Widget _buildSearchTips(BuildContext context) {
    final theme = Theme.of(context);
    
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Search Tips',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        
        _buildSearchTip(
          context,
          Icons.search,
          'Type keywords',
          'Search for specific words or phrases in messages',
        ),
        _buildSearchTip(
          context,
          Icons.person,
          'Find messages from you',
          'Use filters to search only your messages or received messages',
        ),
        _buildSearchTip(
          context,
          Icons.star,
          'Search starred messages',
          'Find your starred messages quickly',
        ),
        _buildSearchTip(
          context,
          Icons.date_range,
          'Filter by date',
          'Search messages from specific time periods',
        ),
      ],
    );
  }

  /// Build search tip item
  Widget _buildSearchTip(BuildContext context, IconData icon, String title, String description) {
    final theme = Theme.of(context);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          icon,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          title,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          description,
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }

  /// Build recent searches
  Widget _buildRecentSearches(BuildContext context, List<String> recentSearches) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(
                'Recent Searches',
                style: theme.textTheme.titleMedium,
              ),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  await _chatService.clearMessageSearchHistory();
                  // Refresh suggestions after clearing history
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (context.mounted) showSuggestions(context);
                  });
                },
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        
        Expanded(
          child: ListView.builder(
            itemCount: recentSearches.length,
            itemBuilder: (context, index) {
              final search = recentSearches[index];
              return ListTile(
                leading: Icon(
                  Icons.history,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(search),
                trailing: Icon(
                  Icons.call_made,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onTap: () {
                  query = search;
                  showResults(context);
                },
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Build quick actions
  Widget _buildQuickActions(BuildContext context) {
    final theme = Theme.of(context);
    
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Quick Actions',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        
        ListTile(
          leading: Icon(Icons.star, color: Colors.amber),
          title: const Text('View Starred Messages'),
          subtitle: const Text('See all your starred messages'),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          onTap: () => _viewStarredMessages(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        
        const SizedBox(height: 8),
        
        ListTile(
          leading: Icon(Icons.today, color: theme.colorScheme.primary),
          title: const Text('Today\'s Messages'),
          subtitle: const Text('Search messages from today'),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          onTap: () => _searchTodayMessages(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ],
    );
  }

  /// Show filter dialog
  Future<void> _showFilterDialog(BuildContext context) async {
    final result = await showModalBottomSheet<chat_service.MessageSearchFilter>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SearchFilterBottomSheet(
        currentFilter: _currentFilter,
      ),
    );
    
    if (result != null) {
      _currentFilter = result;
      if (query.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) showResults(context);
        });
      }
    }
  }

  /// Highlight query terms in text
  List<TextSpan> _highlightQueryInText(String text, String query, ThemeData theme) {
    if (query.isEmpty) {
      return [TextSpan(text: text)];
    }
    
    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    
    int lastIndex = 0;
    int index = lowerText.indexOf(lowerQuery);
    
    while (index != -1) {
      // Add text before match
      if (index > lastIndex) {
        spans.add(TextSpan(text: text.substring(lastIndex, index)));
      }
      
      // Add highlighted match
      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: TextStyle(
          backgroundColor: theme.colorScheme.primary.withValues(),
          fontWeight: FontWeight.bold,
        ),
      ));
      
      lastIndex = index + query.length;
      index = lowerText.indexOf(lowerQuery, lastIndex);
    }
    
    // Add remaining text
    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex)));
    }
    
    return spans;
  }

  /// Copy message to clipboard
  void _copyMessage(EnhancedMessage message) {
    Clipboard.setData(ClipboardData(text: message.content));
  }

  /// Open chat with specific messages
  void _openChatWithMessages(BuildContext context, String chatId, List<EnhancedMessage> messages) {
    // Navigate to the chat screen with the chat ID
    // The chat screen will load the messages and can highlight specific ones if needed
    close(context, chatId);
    // Navigation would typically be handled by the parent widget or a navigation service
    // For now, we just close the search and return the chat ID
  }

  /// View starred messages
  void _viewStarredMessages(BuildContext context) {
    query = '';
    _currentFilter = const chat_service.MessageSearchFilter(isStarred: true);
    showResults(context);
  }

  /// Search today's messages
  void _searchTodayMessages(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    
    query = '';
    _currentFilter = chat_service.MessageSearchFilter(
      dateRange: chat_service.DateTimeRange(start: today, end: tomorrow),
    );
    showResults(context);
  }
}

/// Bottom sheet for search filters
class _SearchFilterBottomSheet extends StatefulWidget {
  final chat_service.MessageSearchFilter? currentFilter;
  
  const _SearchFilterBottomSheet({this.currentFilter});
  
  @override
  State<_SearchFilterBottomSheet> createState() => _SearchFilterBottomSheetState();
}

class _SearchFilterBottomSheetState extends State<_SearchFilterBottomSheet> {
  bool? _fromMe;
  bool? _hasAttachments;
  bool? _isStarred;
  DateTimeRange? _dateRange;
  
  @override
  void initState() {
    super.initState();
    _fromMe = widget.currentFilter?.fromMe;
    _hasAttachments = widget.currentFilter?.hasAttachments;
    _isStarred = widget.currentFilter?.isStarred;
    final filterDateRange = widget.currentFilter?.dateRange;
    _dateRange = filterDateRange != null
        ? DateTimeRange(start: filterDateRange.start, end: filterDateRange.end)
        : null;
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (context, scrollController) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              
              Text(
                'Search Filters',
                style: theme.textTheme.titleLarge,
              ),
              
              const SizedBox(height: 24),
              
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    // Message source
                    Text(
                      'Message Source',
                      style: theme.textTheme.titleMedium,
                    ),
                    
                    ListTile(
                      leading: Icon(
                        _fromMe == null ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: _fromMe == null ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: const Text('All messages'),
                      onTap: () => setState(() => _fromMe = null),
                      selected: _fromMe == null,
                    ),
                    ListTile(
                      leading: Icon(
                        _fromMe == true ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: _fromMe == true ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: const Text('Messages from me'),
                      onTap: () => setState(() => _fromMe = true),
                      selected: _fromMe == true,
                    ),
                    ListTile(
                      leading: Icon(
                        _fromMe == false ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: _fromMe == false ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: const Text('Messages to me'),
                      onTap: () => setState(() => _fromMe = false),
                      selected: _fromMe == false,
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Special filters
                    Text(
                      'Special Filters',
                      style: theme.textTheme.titleMedium,
                    ),
                    
                    CheckboxListTile(
                      title: const Text('Starred messages only'),
                      value: _isStarred ?? false,
                      onChanged: (value) => setState(() => _isStarred = value),
                    ),
                    
                    CheckboxListTile(
                      title: const Text('Messages with attachments'),
                      value: _hasAttachments ?? false,
                      onChanged: (value) => setState(() => _hasAttachments = value),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Date range
                    Text(
                      'Date Range',
                      style: theme.textTheme.titleMedium,
                    ),
                    
                    ListTile(
                      title: Text(_dateRange != null 
                        ? '${_formatDate(_dateRange!.start)} - ${_formatDate(_dateRange!.end)}'
                        : 'Any time'),
                      subtitle: const Text('Tap to select date range'),
                      trailing: _dateRange != null 
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() => _dateRange = null),
                          )
                        : const Icon(Icons.date_range),
                      onTap: _selectDateRange,
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  
                  const SizedBox(width: 12),
                  
                  Expanded(
                    child: FilledButton(
                      onPressed: _applyFilters,
                      child: const Text('Apply Filters'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
  
  /// Select date range
  Future<void> _selectDateRange() async {
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
    );
    
    if (result != null) {
      setState(() => _dateRange = result);
    }
  }
  
  /// Apply selected filters
  void _applyFilters() {
    final filter = chat_service.MessageSearchFilter(
      fromMe: _fromMe,
      hasAttachments: _hasAttachments,
      isStarred: _isStarred,
      dateRange: _dateRange != null ? chat_service.DateTimeRange(
        start: _dateRange!.start,
        end: _dateRange!.end
      ) : null,
    );
    
    Navigator.pop(context, filter);
  }
  
  /// Format date for display
  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }
}