// Archive search delegate for advanced search functionality
// Provides comprehensive search across archived chats and messages

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../core/models/archive_models.dart';
import '../../domain/services/archive_search_service.dart';
import '../providers/archive_provider.dart';
import 'archived_chat_tile.dart';

/// Advanced search delegate for archived content
class ArchiveSearchDelegate extends SearchDelegate<String> {
  final WidgetRef ref;
  
  ArchiveSearchDelegate(this.ref);
  
  @override
  String get searchFieldLabel => 'Search archived chats and messages...';
  
  @override
  TextStyle? get searchFieldStyle => TextStyle(
    fontSize: 16,
    color: Colors.white,
  );
  
  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
          icon: const Icon(Icons.clear),
          tooltip: 'Clear search',
        ),
      IconButton(
        onPressed: () => _showFilterDialog(context),
        icon: const Icon(Icons.tune),
        tooltip: 'Search filters',
      ),
    ];
  }
  
  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      onPressed: () => close(context, ''),
      icon: const Icon(Icons.arrow_back),
      tooltip: 'Back',
    );
  }
  
  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) {
      return _buildEmptyQuery(context);
    }
    
    return Consumer(
      builder: (context, ref, child) {
        final searchQuery = ArchiveSearchQuery(query: query);
        final searchAsync = ref.watch(archiveSearchProvider(searchQuery));
        
        return searchAsync.when(
          data: (searchResult) {
            if (!searchResult.hasResults) {
              return _buildNoResults(context);
            }
            
            return _buildSearchResults(context, searchResult);
          },
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, stack) => _buildErrorState(context, error.toString()),
        );
      },
    );
  }
  
  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.trim().isEmpty) {
      return _buildRecentSearches(context);
    }
    
    return Consumer(
      builder: (context, ref, child) {
        final suggestionsAsync = ref.watch(archiveSearchSuggestionsProvider(query));
        
        return suggestionsAsync.when(
          data: (suggestions) {
            if (suggestions.isEmpty) {
              return _buildNoSuggestions(context);
            }
            
            return ListView.builder(
              itemCount: suggestions.length,
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return _buildSuggestionTile(context, suggestion);
              },
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, stack) => _buildErrorState(context, error.toString()),
        );
      },
    );
  }
  
  Widget _buildSearchResults(BuildContext context, AdvancedSearchResult searchResult) {
    return Column(
      children: [
        // Search summary
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(),
          child: Row(
            children: [
              Icon(
                Icons.search,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${searchResult.totalResults} results found in ${searchResult.formattedSearchTime}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (searchResult.suggestions.isNotEmpty)
                TextButton(
                  onPressed: () => _showSuggestions(context, searchResult.suggestions),
                  child: const Text('Suggestions'),
                ),
            ],
          ),
        ),
        
        // Results tabs
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(
                      icon: const Icon(Icons.archive),
                      text: 'Chats (${searchResult.searchResult.chats.length})',
                    ),
                    Tab(
                      icon: const Icon(Icons.chat_bubble),
                      text: 'Messages (${searchResult.messages.length})',
                    ),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildChatResults(context, searchResult.searchResult.chats),
                      _buildMessageResults(context, searchResult.messages),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildChatResults(BuildContext context, List<ArchivedChatSummary> chats) {
    if (chats.isEmpty) {
      return _buildNoResults(context, 'No archived chats found');
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: chats.length,
      itemBuilder: (context, index) {
        final chat = chats[index];
        return SearchResultArchivedChatTile(
          archive: chat,
          searchQuery: query,
          onTap: () {
            close(context, chat.contactName);
            // Would navigate to archive detail
          },
        );
      },
    );
  }
  
  Widget _buildMessageResults(BuildContext context, List<ArchivedMessage> messages) {
    if (messages.isEmpty) {
      return _buildNoResults(context, 'No messages found');
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _buildMessageResultTile(context, message);
      },
    );
  }
  
  Widget _buildMessageResultTile(BuildContext context, ArchivedMessage message) {
    final theme = Theme.of(context);
    
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            message.isFromMe ? Icons.send : Icons.inbox,
            size: 18,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          _highlightQuery(message.content, query),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From: ${message.isFromMe ? 'You' : 'Contact'}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              _formatMessageTime(message.originalTimestamp),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onTap: () {
          close(context, message.content);
          // Would navigate to specific message in archive
        },
      ),
    );
  }
  
  Widget _buildSuggestionTile(BuildContext context, SearchSuggestion suggestion) {
    final theme = Theme.of(context);
    
    IconData suggestionIcon = Icons.help;
    Color suggestionColor = theme.colorScheme.onSurfaceVariant;
    
    switch (suggestion.type) {
      case SearchSuggestionType.history:
        suggestionIcon = Icons.history;
        suggestionColor = theme.colorScheme.onSurfaceVariant;
        break;
      case SearchSuggestionType.content:
        suggestionIcon = Icons.content_copy;
        suggestionColor = theme.colorScheme.primary;
        break;
      case SearchSuggestionType.saved:
        suggestionIcon = Icons.bookmark;
        suggestionColor = theme.colorScheme.secondary;
        break;
      case SearchSuggestionType.related:
        suggestionIcon = Icons.link;
        suggestionColor = theme.colorScheme.tertiary;
        break;
      case SearchSuggestionType.refinement:
        suggestionIcon = Icons.tune;
        suggestionColor = theme.colorScheme.onSurfaceVariant;
        break;
    }
    
    return ListTile(
      leading: Icon(
        suggestionIcon,
        color: suggestionColor,
        size: 20,
      ),
      title: Text(suggestion.text),
      subtitle: suggestion.metadata != null 
          ? Text(_buildSuggestionSubtitle(suggestion))
          : null,
      trailing: IconButton(
        onPressed: () {
          query = suggestion.text;
          showResults(context);
        },
        icon: const Icon(Icons.north_west),
        tooltip: 'Use suggestion',
      ),
      onTap: () {
        query = suggestion.text;
        showResults(context);
      },
    );
  }
  
  Widget _buildRecentSearches(BuildContext context) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Recent Searches',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // For now, show placeholder recent searches
        ListTile(
          leading: Icon(Icons.history, color: theme.colorScheme.onSurfaceVariant),
          title: const Text('holiday photos'),
          onTap: () {
            query = 'holiday photos';
            showResults(context);
          },
        ),
        ListTile(
          leading: Icon(Icons.history, color: theme.colorScheme.onSurfaceVariant),
          title: const Text('project meeting'),
          onTap: () {
            query = 'project meeting';
            showResults(context);
          },
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.clear_all, color: theme.colorScheme.error),
          title: Text(
            'Clear search history',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          onTap: () {
            // Would clear search history
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Search history cleared')),
            );
          },
        ),
      ],
    );
  }
  
  Widget _buildEmptyQuery(BuildContext context) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(),
          ),
          const SizedBox(height: 16),
          Text(
            'Search Archives',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Search through your archived chats and messages',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildNoResults(BuildContext context, [String? message]) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(),
          ),
          const SizedBox(height: 16),
          Text(
            'No Results Found',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            message ?? 'Try different keywords or check your spelling',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildNoSuggestions(BuildContext context) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(),
          ),
          const SizedBox(height: 16),
          Text(
            'No suggestions available',
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
  
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
            'Search Error',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
  
  void _showFilterDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Search Filters'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              title: const Text('Include compressed archives'),
              value: true,
              onChanged: (value) {},
            ),
            CheckboxListTile(
              title: const Text('Messages only'),
              value: false,
              onChanged: (value) {},
            ),
            CheckboxListTile(
              title: const Text('Chats only'),
              value: false,
              onChanged: (value) {},
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // Apply filters and refresh search
              showResults(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
  
  void _showSuggestions(BuildContext context, List<SearchSuggestion> suggestions) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Search Suggestions'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: suggestions.length,
            itemBuilder: (context, index) {
              final suggestion = suggestions[index];
              return ListTile(
                title: Text(suggestion.text),
                onTap: () {
                  Navigator.pop(context);
                  query = suggestion.text;
                  showResults(context);
                },
              );
            },
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
  
  String _highlightQuery(String text, String query) {
    // Simple highlighting - in a real implementation, this would use proper text highlighting
    return text;
  }
  
  String _formatMessageTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
  
  String _buildSuggestionSubtitle(SearchSuggestion suggestion) {
    final metadata = suggestion.metadata;
    if (metadata == null) return '';
    
    switch (suggestion.type) {
      case SearchSuggestionType.history:
        final resultCount = metadata['resultCount'] as int? ?? 0;
        return '$resultCount results';
      case SearchSuggestionType.content:
        final frequency = metadata['frequency'] as int? ?? 0;
        return 'Found $frequency times';
      case SearchSuggestionType.saved:
        final name = metadata['name'] as String? ?? '';
        return 'Saved as "$name"';
      default:
        return '';
    }
  }
}