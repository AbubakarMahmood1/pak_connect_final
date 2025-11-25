import 'package:flutter/material.dart';
import '../../domain/entities/message.dart';

class SearchResult {
  final int messageIndex;
  final List<int> matchPositions;
  final String highlightedContent;

  SearchResult({
    required this.messageIndex,
    required this.matchPositions,
    required this.highlightedContent,
  });
}

class ChatSearchBar extends StatefulWidget {
  final List<Message> messages;
  final Function(String query, List<SearchResult> results) onSearch;
  final Function(int messageIndex) onNavigateToResult;
  final VoidCallback onExitSearch;

  const ChatSearchBar({
    super.key,
    required this.messages,
    required this.onSearch,
    required this.onNavigateToResult,
    required this.onExitSearch,
  });

  @override
  State<ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends State<ChatSearchBar> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<SearchResult> _searchResults = [];
  int _currentResultIndex = -1;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.requestFocus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _performSearch(query.trim());
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _currentResultIndex = -1;
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    final results = <SearchResult>[];
    final lowerQuery = query.toLowerCase();

    for (int i = 0; i < widget.messages.length; i++) {
      final message = widget.messages[i];
      final lowerContent = message.content.toLowerCase();

      if (lowerContent.contains(lowerQuery)) {
        final matchPositions = _findMatchPositions(message.content, query);
        final highlightedContent = _highlightText(
          message.content,
          matchPositions,
        );

        results.add(
          SearchResult(
            messageIndex: i,
            matchPositions: matchPositions,
            highlightedContent: highlightedContent,
          ),
        );
      }
    }

    setState(() {
      _searchResults = results;
      _currentResultIndex = results.isNotEmpty ? 0 : -1;
      _isSearching = false;
    });

    // Notify parent of search completion
    widget.onSearch(query, results);

    // Auto-navigate to first result if available
    if (_searchResults.isNotEmpty) {
      _navigateToResult(0);
    }
  }

  List<int> _findMatchPositions(String text, String query) {
    final positions = <int>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) break;
      positions.add(index);
      start = index + 1;
    }

    return positions;
  }

  String _highlightText(String text, List<int> positions) {
    // For now, return original text - highlighting will be handled in MessageBubble
    return text;
  }

  void _navigateToResult(int index) {
    if (index >= 0 && index < _searchResults.length) {
      setState(() {
        _currentResultIndex = index;
      });
      widget.onNavigateToResult(_searchResults[index].messageIndex);
    }
  }

  void _previousResult() {
    if (_searchResults.isEmpty) return;
    final newIndex = _currentResultIndex > 0
        ? _currentResultIndex - 1
        : _searchResults.length - 1;
    _navigateToResult(newIndex);
  }

  void _nextResult() {
    if (_searchResults.isEmpty) return;
    final newIndex = _currentResultIndex < _searchResults.length - 1
        ? _currentResultIndex + 1
        : 0;
    _navigateToResult(newIndex);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchResults = [];
      _currentResultIndex = -1;
      _isSearching = false;
    });
    widget.onExitSearch();
  }

  String _getResultCounterText() {
    if (_searchResults.isEmpty) return '';
    return '${_currentResultIndex + 1} of ${_searchResults.length}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(),
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back),
                onPressed: widget.onExitSearch,
                tooltip: 'Exit search',
              ),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  decoration: InputDecoration(
                    hintText: 'Search messages...',
                    border: InputBorder.none,
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear),
                            onPressed: _clearSearch,
                            tooltip: 'Clear search',
                          )
                        : null,
                  ),
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                ),
              ),
            ],
          ),
          if (_searchResults.isNotEmpty || _isSearching) ...[
            SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isSearching)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (_searchResults.isNotEmpty) ...[
                  IconButton(
                    icon: Icon(Icons.keyboard_arrow_up),
                    onPressed: _previousResult,
                    tooltip: 'Previous result',
                    iconSize: 20,
                  ),
                  IconButton(
                    icon: Icon(Icons.keyboard_arrow_down),
                    onPressed: _nextResult,
                    tooltip: 'Next result',
                    iconSize: 20,
                  ),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _getResultCounterText(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                Spacer(),
                if (_searchResults.isEmpty &&
                    !_isSearching &&
                    _searchController.text.isNotEmpty)
                  Flexible(
                    child: Text(
                      'No results found',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
