// Archive search service with advanced full-text search and query processing

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../interfaces/i_archive_repository.dart';
import '../models/archive_models.dart';
import 'archive_search_indexing.dart';
import 'archive_search_query_builder.dart';
import 'archive_search_pagination.dart';
import 'archive_search_models.dart';
import 'search_cache_manager.dart';
import 'search_history_manager.dart';
import 'search_analytics_tracker.dart';

export 'archive_search_models.dart';

/// Advanced search service for archived chats and messages with full-text capabilities
/// Singleton pattern to prevent multiple service instances
class ArchiveSearchService {
  static final _logger = Logger('ArchiveSearchService');

  // Singleton instance
  static ArchiveSearchService? _instance;

  /// Get the singleton instance
  static ArchiveSearchService get instance {
    _instance ??= ArchiveSearchService._internal();
    return _instance!;
  }

  /// Private constructor for singleton
  ArchiveSearchService._internal({
    IArchiveRepository? archiveRepository,
    ArchiveSearchIndexing? indexing,
    ArchiveSearchQueryBuilder? queryBuilder,
    ArchiveSearchPagination? pagination,
    SearchCacheManager? cacheManager,
    SearchHistoryManager? historyManager,
    SearchAnalyticsTracker? analyticsTracker,
  }) : _archiveRepository =
           archiveRepository ?? GetIt.instance<IArchiveRepository>(),
       _indexing =
           indexing ??
           ArchiveSearchIndexing(
             archiveRepository:
                 archiveRepository ?? GetIt.instance<IArchiveRepository>(),
           ),
       _queryBuilder = queryBuilder ?? ArchiveSearchQueryBuilder(),
       _pagination = pagination ?? ArchiveSearchPagination() {
    // Initialize extracted services (Phase 4D)
    _cacheManager =
        cacheManager ?? SearchCacheManager(getConfig: () => _config);
    _historyManager =
        historyManager ?? SearchHistoryManager(getConfig: () => _config);
    _analyticsTracker = analyticsTracker ?? SearchAnalyticsTracker();

    _logger.info('✅ ArchiveSearchService singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ArchiveSearchService() => instance;

  // Dependencies (injected for testability)
  final IArchiveRepository _archiveRepository;
  final ArchiveSearchIndexing _indexing;
  final ArchiveSearchQueryBuilder _queryBuilder;
  final ArchiveSearchPagination _pagination;

  // Extracted services (Phase 4D refactoring)
  late final SearchCacheManager _cacheManager;
  late final SearchHistoryManager _historyManager;
  late final SearchAnalyticsTracker _analyticsTracker;

  // Storage key (config only)
  static const String _searchPreferencesKey = 'archive_search_preferences_v2';

  // Configuration (kept in facade per Codex recommendation)
  SearchServiceConfig _config = SearchServiceConfig.defaultConfig();

  // Event listeners
  final Set<void Function(ArchiveSearchEvent)> _searchUpdateListeners = {};
  final Set<void Function(SearchSuggestionEvent)> _suggestionListeners = {};

  /// Stream of search events
  Stream<ArchiveSearchEvent> get searchUpdates =>
      Stream<ArchiveSearchEvent>.multi((controller) {
        void listener(ArchiveSearchEvent event) {
          controller.add(event);
        }

        _searchUpdateListeners.add(listener);
        controller.onCancel = () {
          _searchUpdateListeners.remove(listener);
        };
      });

  /// Stream of suggestion events
  Stream<SearchSuggestionEvent> get suggestionUpdates =>
      Stream<SearchSuggestionEvent>.multi((controller) {
        void listener(SearchSuggestionEvent event) {
          controller.add(event);
        }

        _suggestionListeners.add(listener);
        controller.onCancel = () {
          _suggestionListeners.remove(listener);
        };
      });

  bool _isInitialized = false;

  /// Initialize the archive search service (idempotent - safe to call multiple times)
  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.fine('ArchiveSearchService already initialized - skipping');
      return;
    }

    try {
      _logger.info('Initializing archive search service');

      // Initialize repository
      await _archiveRepository.initialize();

      // Initialize extracted services (Phase 4D)
      await _historyManager.initialize();
      await _analyticsTracker.initialize();

      // Load config
      await _loadSearchPreferences();

      // Build search indexes
      await _indexing.rebuildIndexes();

      _isInitialized = true;
      _logger.info('Archive search service initialized successfully');
    } catch (e) {
      _logger.severe('Failed to initialize archive search service: $e');
      rethrow;
    }
  }

  /// Perform comprehensive search across archived content
  Future<AdvancedSearchResult> search({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    int limit = 50,
  }) async {
    if (!_isInitialized) {
      throw StateError('Archive search service not initialized');
    }

    final searchStartTime = DateTime.now();
    final searchId = _generateSearchId();

    try {
      _logger.info('Starting advanced search: "$query"');

      // Parse and normalize query
      final parsedQuery = _queryBuilder.parse(query);
      final normalizedQuery = _queryBuilder.normalize(parsedQuery);

      // Check cache first (Phase 4D: delegated to SearchCacheManager)
      final cacheKey = _generateSearchCacheKey(
        normalizedQuery,
        filter,
        options,
      );
      final cachedResult = _cacheManager.getCachedResult(cacheKey);
      if (cachedResult != null) {
        // Record cache hit (Phase 4D: delegated to SearchAnalyticsTracker)
        await _analyticsTracker.recordSearch(
          query: query,
          result: cachedResult,
          searchTime: DateTime.now().difference(searchStartTime),
          cacheHit: true,
        );

        return cachedResult;
      }

      // Emit search started event
      _emitSearchUpdate(ArchiveSearchEvent.started(searchId, query));

      // Execute search strategy
      final searchStrategy = _queryBuilder.determineStrategy(
        parsedQuery,
        filter,
        options,
      );
      final searchResult = await _executeSearch(
        searchStrategy,
        normalizedQuery,
        filter,
        options,
        limit,
      );

      // Enhance results with additional data
      final enhancedResult = await _enhanceSearchResult(
        searchResult,
        parsedQuery,
        options,
      );
      final paginatedResult = _pagination.applyLimit(enhancedResult, limit);

      // Build advanced result
      final searchTime = DateTime.now().difference(searchStartTime);
      final advancedResult = AdvancedSearchResult.fromSearchResult(
        searchResult: paginatedResult,
        query: query,
        parsedQuery: parsedQuery,
        searchTime: searchTime,
        searchStrategy: searchStrategy,
        suggestions: await _generateSearchSuggestions(query, paginatedResult),
        analytics: _buildSearchAnalytics(query, paginatedResult, searchTime),
      );

      // Cache result (Phase 4D: delegated to SearchCacheManager)
      _cacheManager.cacheSearchResult(cacheKey, advancedResult);

      // Update search history and analytics (Phase 4D: delegated to services)
      await _historyManager.addToHistory(query, advancedResult);
      await _analyticsTracker.recordSearch(
        query: query,
        result: advancedResult,
        searchTime: searchTime,
        cacheHit: false,
      );

      // Emit search completed event
      _emitSearchUpdate(ArchiveSearchEvent.completed(searchId, advancedResult));

      _logger.info(
        'Search completed: ${advancedResult.totalResults} results in ${advancedResult.formattedSearchTime}',
      );

      return advancedResult;
    } catch (e) {
      final searchTime = DateTime.now().difference(searchStartTime);
      _logger.severe('Search failed for "$query": $e');

      // Emit search failed event
      _emitSearchUpdate(
        ArchiveSearchEvent.failed(searchId, query, e.toString()),
      );

      return AdvancedSearchResult.error(
        query: query,
        error: e.toString(),
        searchTime: searchTime,
      );
    }
  }

  /// Get search suggestions as user types
  Future<List<SearchSuggestion>> getSearchSuggestions({
    required String partialQuery,
    int limit = 10,
  }) async {
    if (!_isInitialized || partialQuery.trim().isEmpty) {
      return [];
    }

    try {
      // Check cache first (Phase 4D: delegated to SearchCacheManager)
      final cacheKey = 'suggestions_${partialQuery.toLowerCase()}';
      final cachedSuggestions = _cacheManager.getCachedSuggestions(cacheKey);
      if (cachedSuggestions != null) {
        return cachedSuggestions;
      }

      final suggestions = <SearchSuggestion>[];
      final partialLower = partialQuery.toLowerCase();

      // 1. History-based suggestions (Phase 4D: delegated to SearchHistoryManager)
      final historySuggestions = _historyManager.getHistorySuggestions(
        partialLower,
        limit ~/ 3,
      );
      suggestions.addAll(historySuggestions);

      // 2. Content-based suggestions
      final contentSuggestions = await _getContentSuggestions(
        partialLower,
        limit ~/ 3,
      );
      suggestions.addAll(contentSuggestions);

      // 3. Saved search suggestions (Phase 4D: delegated to SearchHistoryManager)
      final savedSuggestions = _historyManager.getSavedSearchSuggestions(
        partialLower,
        limit ~/ 3,
      );
      suggestions.addAll(savedSuggestions);

      // Remove duplicates and sort by relevance
      final uniqueSuggestions = _deduplicateAndRankSuggestions(suggestions);
      final limitedSuggestions = uniqueSuggestions.take(limit).toList();

      // Cache suggestions (Phase 4D: delegated to SearchCacheManager)
      _cacheManager.cacheSuggestions(cacheKey, limitedSuggestions);

      // Emit suggestion event
      _emitSuggestionUpdate(
        SearchSuggestionEvent.generated(partialQuery, limitedSuggestions),
      );

      return limitedSuggestions;
    } catch (e) {
      _logger.warning('Failed to generate search suggestions: $e');
      return [];
    }
  }

  /// Perform fuzzy search with typo tolerance
  Future<AdvancedSearchResult> fuzzySearch({
    required String query,
    double similarityThreshold = 0.7,
    ArchiveSearchFilter? filter,
    int limit = 30,
  }) async {
    try {
      _logger.info('Performing fuzzy search: "$query"');

      // Generate similar terms using various algorithms
      final fuzzyTerms = _queryBuilder.generateFuzzyTerms(
        query,
        similarityThreshold,
      );

      // Build expanded query with fuzzy terms
      final expandedQuery = _queryBuilder.buildFuzzyQuery(query, fuzzyTerms);

      // Execute search with fuzzy options
      final options = SearchOptions(
        fuzzySearch: true,
        similarityThreshold: similarityThreshold,
        expandQuery: true,
      );

      return await search(
        query: expandedQuery,
        filter: filter,
        options: options,
        limit: limit,
      );
    } catch (e) {
      _logger.severe('Fuzzy search failed: $e');
      return AdvancedSearchResult.error(
        query: query,
        error: 'Fuzzy search failed: $e',
        searchTime: Duration.zero,
      );
    }
  }

  /// Search within date range with temporal ranking
  Future<AdvancedSearchResult> searchByDateRange({
    required String query,
    required DateTime startDate,
    required DateTime endDate,
    TemporalSearchMode mode = TemporalSearchMode.archived,
    int limit = 50,
  }) async {
    try {
      final dateFilter = ArchiveDateRange(start: startDate, end: endDate);
      final filter = ArchiveSearchFilter(dateRange: dateFilter);

      final options = SearchOptions(
        temporalRanking: true,
        temporalMode: mode,
        boostRecent: mode == TemporalSearchMode.recent,
      );

      return await search(
        query: query,
        filter: filter,
        options: options,
        limit: limit,
      );
    } catch (e) {
      _logger.severe('Date range search failed: $e');
      return AdvancedSearchResult.error(
        query: query,
        error: 'Date range search failed: $e',
        searchTime: Duration.zero,
      );
    }
  }

  /// Save search query for later use
  Future<void> saveSearch({
    required String name,
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
  }) async {
    try {
      await _historyManager.saveSearch(
        id: _generateSavedSearchId(),
        name: name,
        query: query,
        filter: filter,
        options: options,
      );
      _logger.info('Saved search: "$name"');
    } catch (e) {
      _logger.severe('Failed to save search: $e');
    }
  }

  /// Execute saved search
  Future<AdvancedSearchResult> executeSavedSearch(String savedSearchId) async {
    try {
      final savedSearch = _historyManager.getSavedSearchById(savedSearchId);
      if (savedSearch == null) {
        throw ArgumentError('Saved search not found: $savedSearchId');
      }

      _logger.info('Executing saved search: "${savedSearch.name}"');

      return await search(
        query: savedSearch.query,
        filter: savedSearch.filter,
        options: savedSearch.options,
      );
    } catch (e) {
      _logger.severe('Failed to execute saved search: $e');
      return AdvancedSearchResult.error(
        query: '',
        error: 'Saved search execution failed: $e',
        searchTime: Duration.zero,
      );
    }
  }

  /// Get search analytics and insights
  Future<SearchAnalyticsReport> getSearchAnalytics({
    DateTime? since,
    SearchAnalyticsScope scope = SearchAnalyticsScope.all,
  }) async {
    try {
      return await _analyticsTracker.getAnalyticsReport(
        since: since,
        scope: scope,
        searchHistory: _historyManager.getHistory(),
      );
    } catch (e) {
      _logger.severe('Failed to generate search analytics: $e');
      return SearchAnalyticsReport.empty();
    }
  }

  /// Update search service configuration
  Future<void> updateConfiguration(SearchServiceConfig config) async {
    try {
      final previousConfig = _config;
      _config = config;
      await _saveSearchPreferences();

      // Clear caches if configuration changed significantly
      if (config.enableFuzzySearch != previousConfig.enableFuzzySearch ||
          config.maxCacheSize != previousConfig.maxCacheSize) {
        _cacheManager.clearAllCaches();
      }

      _logger.info('Search service configuration updated');
    } catch (e) {
      _logger.severe('Failed to update search configuration: $e');
    }
  }

  /// Clear search history
  Future<void> clearSearchHistory() async {
    try {
      await _historyManager.clearHistory();
      _logger.info('Search history cleared');
    } catch (e) {
      _logger.severe('Failed to clear search history: $e');
    }
  }

  /// Clear search caches
  void clearCaches() {
    _cacheManager.clearAllCaches();
    _logger.info('Search caches cleared');
  }

  /// Clear saved searches
  Future<void> clearSavedSearches() async {
    await _historyManager.clearSavedSearches();
    _logger.info('Saved searches cleared');
  }

  /// Clear analytics data
  Future<void> clearAnalytics() async {
    await _analyticsTracker.clearAnalytics();
    _logger.info('Search analytics cleared');
  }

  /// Rebuild search indexes
  Future<void> rebuildIndexes() async {
    try {
      _logger.info('Rebuilding search indexes');
      await _indexing.rebuildIndexes();
      _logger.info('Search indexes rebuilt successfully');
    } catch (e) {
      _logger.severe('Failed to rebuild search indexes: $e');
    }
  }

  /// Get current configuration
  SearchServiceConfig get configuration => _config;

  /// Get search history
  List<ArchiveSearchEntry> get searchHistory => _historyManager.getHistory();

  /// Get saved searches
  List<SavedSearch> get savedSearches => _historyManager.getSavedSearches();

  /// Dispose and cleanup
  Future<void> dispose() async {
    await _analyticsTracker.forceSave();
    _searchUpdateListeners.clear();
    _suggestionListeners.clear();

    _isInitialized = false;
    _logger.info('Archive search service disposed');
  }

  // Private methods
  void _emitSearchUpdate(ArchiveSearchEvent event) {
    for (final listener in List.of(_searchUpdateListeners)) {
      try {
        listener(event);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying search listener: $e', e, stackTrace);
      }
    }
  }

  void _emitSuggestionUpdate(SearchSuggestionEvent event) {
    for (final listener in List.of(_suggestionListeners)) {
      try {
        listener(event);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying suggestion listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  Future<ArchiveSearchResult> _executeSearch(
    SearchStrategy strategy,
    String normalizedQuery,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    int limit,
  ) async {
    switch (strategy) {
      case SearchStrategy.simple:
        return await _archiveRepository.searchArchives(
          query: normalizedQuery,
          filter: filter,
          limit: limit,
        );
      case SearchStrategy.phrase:
      case SearchStrategy.fuzzy:
      case SearchStrategy.temporal:
      case SearchStrategy.complex:
        // For now, delegate to repository (would implement specific strategies)
        return await _archiveRepository.searchArchives(
          query: normalizedQuery,
          filter: filter,
          limit: limit,
        );
    }
  }

  Future<ArchiveSearchResult> _enhanceSearchResult(
    ArchiveSearchResult result,
    ParsedSearchQuery query,
    SearchOptions? options,
  ) async {
    // Enhance results with highlights, snippets, etc.
    return result; // Simplified for now
  }

  Future<List<SearchSuggestion>> _generateSearchSuggestions(
    String query,
    ArchiveSearchResult result,
  ) async {
    final suggestions = <SearchSuggestion>[];

    // Generate suggestions based on search results
    if (result.hasResults) {
      // Extract common terms from results
      final commonTerms = _queryBuilder.extractCommonTerms(result);
      for (final term in commonTerms.take(3)) {
        suggestions.add(SearchSuggestion.relatedTerm(term));
      }
    }

    // Add query refinement suggestions
    if (query.split(' ').length == 1) {
      suggestions.add(SearchSuggestion.refinement('Add date filter'));
      suggestions.add(
        SearchSuggestion.refinement('Search in specific contact'),
      );
    }

    return suggestions;
  }

  SearchAnalyticsSummary _buildSearchAnalytics(
    String query,
    ArchiveSearchResult result,
    Duration searchTime,
  ) {
    return SearchAnalyticsSummary(
      query: query,
      resultCount: result.totalResults,
      searchTime: searchTime,
      cacheHit: false,
      timestamp: DateTime.now(),
    );
  }

  Future<List<SearchSuggestion>> _getContentSuggestions(
    String partial,
    int limit,
  ) async {
    final suggestions = <SearchSuggestion>[];
    final matches = _indexing.findTermsContaining(partial, limit);

    for (final match in matches) {
      suggestions.add(
        SearchSuggestion.contentBased(match.term, match.frequency),
      );
    }

    return suggestions;
  }

  List<SearchSuggestion> _deduplicateAndRankSuggestions(
    List<SearchSuggestion> suggestions,
  ) {
    final seen = <String>{};
    final unique = <SearchSuggestion>[];

    for (final suggestion in suggestions) {
      if (!seen.contains(suggestion.text)) {
        seen.add(suggestion.text);
        unique.add(suggestion);
      }
    }

    // Sort by relevance score
    unique.sort((a, b) => b.relevanceScore.compareTo(a.relevanceScore));

    return unique;
  }

  String _generateSearchId() {
    return 'search_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';
  }

  String _generateSavedSearchId() {
    return 'saved_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';
  }

  String _generateSearchCacheKey(
    String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
  ) {
    final filterHash = filter?.toJson().toString().hashCode.abs() ?? 0;
    final optionsHash = options?.toString().hashCode.abs() ?? 0;
    return 'search_${query.hashCode.abs()}_${filterHash}_$optionsHash';
  }

  Future<void> _loadSearchPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configJson = prefs.getString(_searchPreferencesKey);

      if (configJson != null) {
        final json = jsonDecode(configJson);
        _config = SearchServiceConfig.fromJson(json);
      }
    } catch (e) {
      _logger.warning('Failed to load search preferences: $e');
    }
  }

  Future<void> _saveSearchPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _searchPreferencesKey,
        jsonEncode(_config.toJson()),
      );
    } catch (e) {
      _logger.warning('Failed to save search preferences: $e');
    }
  }
}
