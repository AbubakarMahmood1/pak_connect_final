// Archive screen for displaying and managing archived chats
// Provides comprehensive archive management functionality

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/archive_provider.dart';
import '../widgets/archived_chat_tile.dart';
import '../widgets/archive_statistics_card.dart';
import '../widgets/archive_search_delegate.dart';
import '../../core/models/archive_models.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';

/// Main archive screen showing list of archived chats with management features
class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});
  
  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounceTimer;
  bool _showStatistics = true;
  ArchiveListFilter? _currentFilter;
  
  @override
  void initState() {
    super.initState();
    // Initialize any required state
  }
  
  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounceTimer?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(archiveUIStateProvider);
    final operationsState = ref.watch(archiveOperationsProvider);
    
    return Scaffold(
      appBar: _buildAppBar(context, uiState),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        child: Column(
          children: [
            // Show loading indicator for active operations
            if (operationsState.hasActiveOperation)
              _buildOperationIndicator(operationsState),
            
            // Search bar when in search mode
            if (uiState.isSearchMode)
              _buildSearchBar(context),
            
            // Statistics card (collapsible)
            if (_showStatistics && !uiState.isSearchMode)
              ArchiveStatisticsCard(
                isExpanded: false,
                onToggleExpanded: () {
                  setState(() => _showStatistics = !_showStatistics);
                },
              ),
            
            // Archive list
            Expanded(
              child: _buildArchiveList(context, uiState),
            ),
          ],
        ),
      ),
      floatingActionButton: _buildFloatingActionButton(context, uiState),
    );
  }
  
  PreferredSizeWidget _buildAppBar(BuildContext context, ArchiveUIState uiState) {
    final theme = Theme.of(context);
    
    if (uiState.isSearchMode) {
      return AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search archives...',
            border: InputBorder.none,
            hintStyle: TextStyle(
              color: theme.colorScheme.onSurfaceVariant.withValues(),
            ),
          ),
          style: TextStyle(color: theme.colorScheme.onSurface),
          onChanged: _handleSearchQueryChanged,
        ),
        actions: [
          IconButton(
            onPressed: _clearSearch,
            icon: const Icon(Icons.clear),
            tooltip: 'Clear search',
          ),
        ],
      );
    }
    
    return AppBar(
      title: const Text('Archived Chats'),
      actions: [
        // Search button
        IconButton(
          onPressed: _toggleSearch,
          icon: const Icon(Icons.search),
          tooltip: 'Search archives',
        ),
        
        // Sort and filter menu
        PopupMenuButton<ArchiveMenuAction>(
          onSelected: _handleMenuAction,
          itemBuilder: (context) => [
            PopupMenuItem<ArchiveMenuAction>(
              value: ArchiveMenuAction.sortByDate,
              child: Row(
                children: [
                  const Icon(Icons.sort_by_alpha, size: 18),
                  const SizedBox(width: 8),
                  const Text('Sort by Date'),
                ],
              ),
            ),
            PopupMenuItem<ArchiveMenuAction>(
              value: ArchiveMenuAction.sortByName,
              child: Row(
                children: [
                  const Icon(Icons.person, size: 18),
                  const SizedBox(width: 8),
                  const Text('Sort by Name'),
                ],
              ),
            ),
            PopupMenuItem<ArchiveMenuAction>(
              value: ArchiveMenuAction.sortBySize,
              child: Row(
                children: [
                  const Icon(Icons.storage, size: 18),
                  const SizedBox(width: 8),
                  const Text('Sort by Size'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<ArchiveMenuAction>(
              value: ArchiveMenuAction.toggleStatistics,
              child: Row(
                children: [
                  Icon(
                    _showStatistics ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(_showStatistics ? 'Hide Statistics' : 'Show Statistics'),
                ],
              ),
            ),
            PopupMenuItem<ArchiveMenuAction>(
              value: ArchiveMenuAction.refreshAll,
              child: Row(
                children: [
                  const Icon(Icons.refresh, size: 18),
                  const SizedBox(width: 8),
                  const Text('Refresh All'),
                ],
              ),
            ),
          ],
          tooltip: 'More options',
        ),
      ],
    );
  }
  
  Widget _buildOperationIndicator(ArchiveOperationsState operationsState) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.primaryContainer.withValues(),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              operationsState.currentOperation ?? 'Processing...',
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSearchBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search archived chats and messages...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  onPressed: _clearSearch,
                  icon: const Icon(Icons.clear),
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        onChanged: _handleSearchQueryChanged,
      ),
    );
  }
  
  Widget _buildArchiveList(BuildContext context, ArchiveUIState uiState) {
    if (uiState.isSearchMode && uiState.searchQuery.isNotEmpty) {
      return _buildSearchResults(context, uiState);
    } else {
      return _buildRegularArchiveList(context);
    }
  }
  
  Widget _buildRegularArchiveList(BuildContext context) {
    final archiveListAsync = ref.watch(archiveListProvider(_currentFilter));
    
    return archiveListAsync.when(
      data: (archives) {
        if (archives.isEmpty) {
          return _buildEmptyState(context);
        }
        
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 80), // Account for FAB
          itemCount: archives.length,
          itemBuilder: (context, index) {
            final archive = archives[index];
            return ArchivedChatTile(
              archive: archive,
              onTap: () => _openArchiveDetail(archive),
              onRestore: () => _restoreChat(archive),
              onDelete: () => _deleteChat(archive),
              isSelected: archive.id == ref.read(archiveUIStateProvider).selectedArchiveId,
            );
          },
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ),
      error: (error, stack) => _buildErrorState(context, error.toString()),
    );
  }
  
  Widget _buildSearchResults(BuildContext context, ArchiveUIState uiState) {
    final searchQuery = ArchiveSearchQuery(query: uiState.searchQuery);
    final searchAsync = ref.watch(archiveSearchProvider(searchQuery));
    
    return searchAsync.when(
      data: (searchResult) {
        if (!searchResult.hasResults) {
          return _buildNoSearchResults(context, uiState.searchQuery);
        }
        
        return Column(
          children: [
            // Search result summary
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    '${searchResult.totalResults} results in ${searchResult.formattedSearchTime}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            
            // Search results list
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: searchResult.messages.length,
                itemBuilder: (context, index) {
                  final message = searchResult.messages[index];
                  // For search results, we need to get the archive summary
                  // This is a simplified version - in real implementation, we'd have better data structure
                  return SearchResultArchivedChatTile(
                    archive: ArchivedChatSummary(
                      id: message.chatId,
                      originalChatId: message.chatId,
                      contactName: 'Contact', // Would get from message metadata
                      archivedAt: message.archivedAt,
                      messageCount: 1,
                      estimatedSize: 1024,
                      isCompressed: false,
                      tags: [],
                      isSearchable: true,
                    ),
                    searchQuery: uiState.searchQuery,
                    onTap: () => _openSearchResult(message),
                    highlights: [message.content],
                  );
                },
              ),
            ),
          ],
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ),
      error: (error, stack) => _buildErrorState(context, error.toString()),
    );
  }
  
  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.archive_outlined,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(),
          ),
          const SizedBox(height: 16),
          Text(
            'No Archived Chats',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Archived chats will appear here.\nYou can archive chats from the main chat list.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.chat),
            label: const Text('Go to Chats'),
          ),
        ],
      ),
    );
  }
  
  Widget _buildNoSearchResults(BuildContext context, String query) {
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
            'No archived chats or messages found for "$query".',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _clearSearch,
            child: const Text('Clear Search'),
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
            'Error Loading Archives',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _handleRefresh,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
  
  Widget? _buildFloatingActionButton(BuildContext context, ArchiveUIState uiState) {
    if (uiState.isSearchMode) return null;
    
    return FloatingActionButton(
      onPressed: _showAdvancedSearch,
      tooltip: 'Advanced Search',
      child: const Icon(Icons.search),
    );
  }
  
  // Event handlers
  
  void _toggleSearch() {
    ref.read(archiveUIStateProvider.notifier).toggleSearchMode();
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(archiveUIStateProvider.notifier).clearSearch();
  }

  void _handleSearchQueryChanged(String query) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      ref.read(archiveUIStateProvider.notifier).updateSearchQuery(query);
    });
  }
  
  void _handleMenuAction(ArchiveMenuAction action) {
    switch (action) {
      case ArchiveMenuAction.sortByDate:
        _updateSort(ArchiveSortOption.dateArchived);
        break;
      case ArchiveMenuAction.sortByName:
        _updateSort(ArchiveSortOption.contactName);
        break;
      case ArchiveMenuAction.sortBySize:
        _updateSort(ArchiveSortOption.size);
        break;
      case ArchiveMenuAction.toggleStatistics:
        setState(() => _showStatistics = !_showStatistics);
        break;
      case ArchiveMenuAction.refreshAll:
        _handleRefresh();
        break;
    }
  }
  
  void _updateSort(ArchiveSortOption sortOption) {
    setState(() {
      _currentFilter = (_currentFilter ?? const ArchiveListFilter()).copyWith(
        sortBy: sortOption,
      );
    });
    ref.read(archiveUIStateProvider.notifier).updateFilter(_currentFilter);
  }
  
  Future<void> _handleRefresh() async {
    // Invalidate providers to trigger refresh
    ref.invalidate(archiveListProvider);
    ref.invalidate(archiveStatisticsProvider);
  }
  
  void _openArchiveDetail(ArchivedChatSummary archive) {
    // For now, show a placeholder dialog - will be replaced with actual detail screen
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Archive Details'),
        content: Text('Archive details for ${archive.contactName} will be shown here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }
  
  void _openSearchResult(ArchivedMessage message) {
    // For now, show a placeholder dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Search Result'),
        content: Text('Message: ${message.content}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _restoreChat(ArchivedChatSummary archive) async {
    final result = await ref.read(archiveOperationsProvider.notifier).restoreChat(archiveId: archive.id);
    
    if (mounted) {
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restored chat with ${archive.contactName}'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () => Navigator.pop(context),
            ),
          ),
        );
        _handleRefresh();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to restore chat: ${result.message}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }
  
  Future<void> _deleteChat(ArchivedChatSummary archive) async {
    final success = await ref.read(archiveOperationsProvider.notifier).deleteArchivedChat(archive.id);
    
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted archived chat with ${archive.contactName}'),
          ),
        );
        _handleRefresh();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to delete archived chat'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }
  
  void _showAdvancedSearch() {
    showSearch(
      context: context,
      delegate: ArchiveSearchDelegate(ref),
    );
  }
}

/// Menu actions for archive screen
enum ArchiveMenuAction {
  sortByDate,
  sortByName,
  sortBySize,
  toggleStatistics,
  refreshAll,
}