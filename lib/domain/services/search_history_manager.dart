// Search history and saved search management
// Extracted from ArchiveSearchService as part of Phase 4D refactoring

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'archive_search_models.dart';
import '../models/archive_models.dart';

/// Callback for history update events
typedef HistoryUpdateCallback = void Function();

/// Manages search history and saved searches with persistence
class SearchHistoryManager {
  static final _logger = Logger('SearchHistoryManager');

  // Storage keys
  static const String _searchHistoryKey = 'archive_search_history_v2';
  static const String _savedSearchesKey = 'archive_saved_searches_v2';

  // State
  final List<ArchiveSearchEntry> _searchHistory = [];
  final List<SavedSearch> _savedSearches = [];

  // Configuration (injected)
  final SearchServiceConfig Function() _getConfig;

  // Optional callbacks for history events (used by facade)
  HistoryUpdateCallback? onHistoryUpdated;
  HistoryUpdateCallback? onSavedSearchesUpdated;

  SearchHistoryManager({required SearchServiceConfig Function() getConfig})
    : _getConfig = getConfig {
    _logger.fine('SearchHistoryManager initialized');
  }

  // ============================================================================
  // Initialization & Persistence
  // ============================================================================

  /// Initialize by loading persisted data
  Future<void> initialize() async {
    try {
      await _loadSearchHistory();
      await _loadSavedSearches();
      _logger.info('SearchHistoryManager initialized successfully');
    } catch (e) {
      _logger.severe('Failed to initialize SearchHistoryManager: $e');
      rethrow;
    }
  }

  /// Load search history from SharedPreferences
  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_searchHistoryKey);

      if (historyJson != null) {
        final historyList = jsonDecode(historyJson) as List;
        _searchHistory.clear();
        _searchHistory.addAll(
          historyList.map((json) => ArchiveSearchEntry.fromJson(json)),
        );
        _logger.fine('Loaded ${_searchHistory.length} history entries');
      }
    } catch (e) {
      _logger.warning('Failed to load search history: $e');
    }
  }

  /// Save search history to SharedPreferences
  Future<void> _saveSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = jsonEncode(
        _searchHistory.map((e) => e.toJson()).toList(),
      );
      await prefs.setString(_searchHistoryKey, historyJson);
      _logger.fine('Saved ${_searchHistory.length} history entries');
    } catch (e) {
      _logger.warning('Failed to save search history: $e');
    }
  }

  /// Load saved searches from SharedPreferences
  Future<void> _loadSavedSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString(_savedSearchesKey);

      if (savedJson != null) {
        final savedList = jsonDecode(savedJson) as List;
        _savedSearches.clear();
        _savedSearches.addAll(
          savedList.map((json) => SavedSearch.fromJson(json)),
        );
        _logger.fine('Loaded ${_savedSearches.length} saved searches');
      }
    } catch (e) {
      _logger.warning('Failed to load saved searches: $e');
    }
  }

  /// Save saved searches to SharedPreferences
  Future<void> _saveSavedSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = jsonEncode(
        _savedSearches.map((s) => s.toJson()).toList(),
      );
      await prefs.setString(_savedSearchesKey, savedJson);
      _logger.fine('Saved ${_savedSearches.length} saved searches');
    } catch (e) {
      _logger.warning('Failed to save saved searches: $e');
    }
  }

  // ============================================================================
  // Search History Methods
  // ============================================================================

  /// Add search to history
  Future<void> addToHistory(String query, AdvancedSearchResult result) async {
    try {
      final entry = ArchiveSearchEntry(
        query: query,
        resultCount: result.totalResults,
        searchTime: result.searchTime,
        timestamp: DateTime.now(),
      );

      _searchHistory.add(entry);

      // Keep only recent history (enforce max size)
      while (_searchHistory.length > _getConfig().maxHistorySize) {
        _searchHistory.removeAt(0);
      }

      await _saveSearchHistory();
      onHistoryUpdated?.call();

      _logger.fine(
        'Added to history: "$query" (${result.totalResults} results)',
      );
    } catch (e) {
      _logger.warning('Failed to add to history: $e');
    }
  }

  /// Get search history (immutable copy)
  List<ArchiveSearchEntry> getHistory() {
    return List.unmodifiable(_searchHistory);
  }

  /// Clear search history
  Future<void> clearHistory() async {
    try {
      _searchHistory.clear();
      await _saveSearchHistory();
      onHistoryUpdated?.call();

      _logger.info('Search history cleared');
    } catch (e) {
      _logger.severe('Failed to clear search history: $e');
    }
  }

  /// Get history-based search suggestions
  List<SearchSuggestion> getHistorySuggestions(String partialQuery, int limit) {
    final suggestions = <SearchSuggestion>[];
    final partialLower = partialQuery.toLowerCase();

    for (final entry in _searchHistory.reversed) {
      if (entry.query.toLowerCase().contains(partialLower) &&
          suggestions.length < limit) {
        suggestions.add(
          SearchSuggestion.fromHistory(entry.query, entry.resultCount),
        );
      }
    }

    return suggestions;
  }

  // ============================================================================
  // Saved Search Methods
  // ============================================================================

  /// Save a search for later use
  Future<void> saveSearch({
    required String id,
    required String name,
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
  }) async {
    try {
      final savedSearch = SavedSearch(
        id: id,
        name: name,
        query: query,
        filter: filter,
        options: options,
        createdAt: DateTime.now(),
      );

      _savedSearches.add(savedSearch);
      await _saveSavedSearches();
      onSavedSearchesUpdated?.call();

      _logger.info('Saved search: "$name"');
    } catch (e) {
      _logger.severe('Failed to save search: $e');
    }
  }

  /// Get saved searches (immutable copy)
  List<SavedSearch> getSavedSearches() {
    return List.unmodifiable(_savedSearches);
  }

  /// Get saved search by ID
  SavedSearch? getSavedSearchById(String savedSearchId) {
    try {
      return _savedSearches.firstWhere((s) => s.id == savedSearchId);
    } catch (e) {
      return null;
    }
  }

  /// Delete saved search
  Future<void> deleteSavedSearch(String savedSearchId) async {
    try {
      _savedSearches.removeWhere((s) => s.id == savedSearchId);
      await _saveSavedSearches();
      onSavedSearchesUpdated?.call();

      _logger.info('Deleted saved search: $savedSearchId');
    } catch (e) {
      _logger.severe('Failed to delete saved search: $e');
    }
  }

  /// Clear all saved searches
  Future<void> clearSavedSearches() async {
    try {
      _savedSearches.clear();
      await _saveSavedSearches();
      onSavedSearchesUpdated?.call();

      _logger.info('Cleared all saved searches');
    } catch (e) {
      _logger.severe('Failed to clear saved searches: $e');
    }
  }

  /// Get saved search suggestions
  List<SearchSuggestion> getSavedSearchSuggestions(
    String partialQuery,
    int limit,
  ) {
    final suggestions = <SearchSuggestion>[];
    final partialLower = partialQuery.toLowerCase();

    for (final saved in _savedSearches) {
      if (saved.query.toLowerCase().contains(partialLower) &&
          suggestions.length < limit) {
        suggestions.add(SearchSuggestion.savedSearch(saved.name, saved.query));
      }
    }

    return suggestions;
  }

  // ============================================================================
  // Stats & Inspection
  // ============================================================================

  /// Get history statistics
  Map<String, int> getHistoryStats() {
    return {
      'historySize': _searchHistory.length,
      'maxHistorySize': _getConfig().maxHistorySize,
      'savedSearchesCount': _savedSearches.length,
    };
  }

  /// Check if history is empty
  bool get isHistoryEmpty => _searchHistory.isEmpty;

  /// Check if saved searches is empty
  bool get isSavedSearchesEmpty => _savedSearches.isEmpty;
}
