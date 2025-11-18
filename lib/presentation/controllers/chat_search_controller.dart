import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../widgets/chat_search_bar.dart' show SearchResult;

/// Callback when search mode is toggled
typedef OnSearchModeToggledCallback = void Function(bool isSearchMode);

/// Callback when search results change
typedef OnSearchResultsChangedCallback =
    void Function(String query, List<SearchResult> results);

/// Callback when navigating to a search result
typedef OnNavigateToResultCallback = void Function(int messageIndex);

/// Controller for managing chat search functionality
///
/// Handles:
/// - Search mode toggling (show/hide search bar)
/// - Search query handling (filter messages)
/// - Navigation to search results (scroll to message)
class ChatSearchController {
  static final _logger = Logger('ChatSearchController');

  bool _isSearchMode = false;
  String _searchQuery = '';

  // Callbacks
  final OnSearchModeToggledCallback? onSearchModeToggled;
  final OnSearchResultsChangedCallback? onSearchResultsChanged;
  final OnNavigateToResultCallback? onNavigateToResult;
  final ScrollController? scrollController;

  ChatSearchController({
    this.onSearchModeToggled,
    this.onSearchResultsChanged,
    this.onNavigateToResult,
    this.scrollController,
  });

  /// Get current search mode state
  bool get isSearchMode => _isSearchMode;

  /// Get current search query
  String get searchQuery => _searchQuery;

  /// Toggle search mode on/off
  ///
  /// When entering search mode: Prepares UI for search input
  /// When exiting search mode: Clears search query and resets to normal view
  void toggleSearchMode() {
    _isSearchMode = !_isSearchMode;

    // Clear search query when exiting search mode
    if (!_isSearchMode) {
      _searchQuery = '';
    }

    _logger.info('🔍 Search mode toggled: $_isSearchMode');
    onSearchModeToggled?.call(_isSearchMode);
  }

  /// Handle search query change
  ///
  /// Parameters:
  /// - query: New search query text
  /// - results: List of matching messages
  void handleSearchQuery(String query, List<SearchResult> results) {
    _searchQuery = query;
    _logger.info(
      '🔍 Search query updated: "$query" (${results.length} results)',
    );
    onSearchResultsChanged?.call(query, results);
  }

  /// Navigate to a specific search result
  ///
  /// Scrolls to the message at the given index in the message list.
  /// Uses a simple estimation of message height for positioning.
  ///
  /// Parameters:
  /// - messageIndex: Index of the message in the messages list
  /// - messageCount: Total number of messages (for bounds checking)
  void navigateToSearchResult(int messageIndex, int messageCount) {
    if (messageIndex < 0 || messageIndex >= messageCount) {
      _logger.warning(
        '🔍 Invalid search result index: $messageIndex (total: $messageCount)',
      );
      return;
    }

    if (scrollController == null) {
      _logger.warning('🔍 ScrollController not available for navigation');
      return;
    }

    // Calculate approximate position
    // This is a simple estimation - each message is roughly 120 points tall
    // In a real app, you might want to:
    // 1. Use a SliverList with exact position tracking
    // 2. Store actual message heights as they're rendered
    // 3. Use findRenderObject() to get actual offsets
    final targetOffset = messageIndex * 120.0;

    _logger.info(
      '🔍 Navigating to search result at index $messageIndex (offset: ${targetOffset.toStringAsFixed(1)})',
    );

    scrollController!.animateTo(
      targetOffset,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );

    onNavigateToResult?.call(messageIndex);
  }

  /// Clear search state
  ///
  /// Called when disposing or resetting the controller
  void clear() {
    _isSearchMode = false;
    _searchQuery = '';
    _logger.info('🔍 Search controller cleared');
  }
}
