// Archive search service with advanced full-text search and query processing

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../../core/interfaces/i_archive_repository.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../core/models/archive_models.dart';
import 'archive_search_indexing.dart';
import 'archive_search_query_builder.dart';
import 'archive_search_pagination.dart';
import 'archive_search_models.dart';

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
    _logger.info('✅ ArchiveSearchService singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ArchiveSearchService() => instance;

  // Dependencies (injected for testability)
  final IArchiveRepository _archiveRepository;
  final ArchiveSearchIndexing _indexing;
  final ArchiveSearchQueryBuilder _queryBuilder;
  final ArchiveSearchPagination _pagination;

  // Storage keys
  static const String _searchHistoryKey = 'archive_search_history_v2';
  static const String _searchPreferencesKey = 'archive_search_preferences_v2';
  static const String _searchAnalyticsKey = 'archive_search_analytics_v2';
  static const String _savedSearchesKey = 'archive_saved_searches_v2';

  // Search cache
  final Map<String, SearchResultCache> _searchCache = {};
  final Map<String, SearchSuggestionCache> _suggestionCache = {};

  // Configuration
  SearchServiceConfig _config = SearchServiceConfig.defaultConfig();

  // Search history and analytics
  final List<ArchiveSearchEntry> _searchHistory = [];
  final Map<String, SearchAnalytics> _queryAnalytics = {};
  final List<SavedSearch> _savedSearches = [];

  // Performance tracking
  //final Map<String, Duration> _searchTimes = {};
  int _totalSearches = 0;

  // Event streams
  final _searchUpdatesController =
      StreamController<ArchiveSearchEvent>.broadcast();
  final _suggestionUpdatesController =
      StreamController<SearchSuggestionEvent>.broadcast();

  /// Stream of search events
  Stream<ArchiveSearchEvent> get searchUpdates =>
      _searchUpdatesController.stream;

  /// Stream of suggestion events
  Stream<SearchSuggestionEvent> get suggestionUpdates =>
      _suggestionUpdatesController.stream;

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

      // Load search data
      await _loadSearchHistory();
      await _loadSearchPreferences();
      await _loadSavedSearches();
      await _loadSearchAnalytics();

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

      // Check cache first
      final cacheKey = _generateSearchCacheKey(
        normalizedQuery,
        filter,
        options,
      );
      if (_searchCache.containsKey(cacheKey) && _isCacheValid(cacheKey)) {
        final cachedResult = _searchCache[cacheKey]!.result;

        // Record cache hit
        _recordSearchAnalytics(
          query,
          cachedResult,
          DateTime.now().difference(searchStartTime),
          true,
        );

        return cachedResult;
      }

      // Emit search started event
      _searchUpdatesController.add(ArchiveSearchEvent.started(searchId, query));

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

      // Cache result
      _cacheSearchResult(cacheKey, advancedResult);

      // Update search history and analytics
      await _updateSearchHistory(query, advancedResult);
      _recordSearchAnalytics(query, advancedResult, searchTime, false);

      // Emit search completed event
      _searchUpdatesController.add(
        ArchiveSearchEvent.completed(searchId, advancedResult),
      );

      _logger.info(
        'Search completed: ${advancedResult.totalResults} results in ${advancedResult.formattedSearchTime}',
      );

      return advancedResult;
    } catch (e) {
      final searchTime = DateTime.now().difference(searchStartTime);
      _logger.severe('Search failed for "$query": $e');

      // Emit search failed event
      _searchUpdatesController.add(
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
      // Check cache first
      final cacheKey = 'suggestions_${partialQuery.toLowerCase()}';
      if (_suggestionCache.containsKey(cacheKey) &&
          _isSuggestionCacheValid(cacheKey)) {
        return _suggestionCache[cacheKey]!.suggestions;
      }

      final suggestions = <SearchSuggestion>[];
      final partialLower = partialQuery.toLowerCase();

      // 1. History-based suggestions
      final historySuggestions = _getHistorySuggestions(
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

      // 3. Saved search suggestions
      final savedSuggestions = _getSavedSearchSuggestions(
        partialLower,
        limit ~/ 3,
      );
      suggestions.addAll(savedSuggestions);

      // Remove duplicates and sort by relevance
      final uniqueSuggestions = _deduplicateAndRankSuggestions(suggestions);
      final limitedSuggestions = uniqueSuggestions.take(limit).toList();

      // Cache suggestions
      _cacheSuggestions(cacheKey, limitedSuggestions);

      // Emit suggestion event
      _suggestionUpdatesController.add(
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
      final savedSearch = SavedSearch(
        id: _generateSavedSearchId(),
        name: name,
        query: query,
        filter: filter,
        options: options,
        createdAt: DateTime.now(),
      );

      _savedSearches.add(savedSearch);
      await _saveSavedSearches();

      _logger.info('Saved search: "$name"');
    } catch (e) {
      _logger.severe('Failed to save search: $e');
    }
  }

  /// Execute saved search
  Future<AdvancedSearchResult> executeSavedSearch(String savedSearchId) async {
    try {
      final savedSearch = _savedSearches
          .where((s) => s.id == savedSearchId)
          .firstOrNull;
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
      final cutoffDate =
          since ?? DateTime.now().subtract(const Duration(days: 30));

      // Filter history based on date
      final recentHistory = _searchHistory
          .where((entry) => entry.timestamp.isAfter(cutoffDate))
          .toList();

      // Calculate metrics
      final totalSearches = recentHistory.length;
      final uniqueQueries = recentHistory.map((e) => e.query).toSet().length;
      final averageResults = recentHistory.isNotEmpty
          ? recentHistory.fold(0, (sum, entry) => sum + entry.resultCount) /
                recentHistory.length
          : 0.0;

      final averageTime = recentHistory.isNotEmpty
          ? recentHistory.fold(
                  Duration.zero,
                  (sum, entry) => sum + entry.searchTime,
                ) ~/
                recentHistory.length
          : Duration.zero;

      // Top queries
      final queryFrequency = <String, int>{};
      for (final entry in recentHistory) {
        queryFrequency[entry.query] = (queryFrequency[entry.query] ?? 0) + 1;
      }

      final topQueries = queryFrequency.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // Search patterns
      final hourlyPatterns = _calculateHourlySearchPatterns(recentHistory);
      final successRate = _calculateSuccessRate(recentHistory);

      return SearchAnalyticsReport(
        period: ArchiveDateRange(start: cutoffDate, end: DateTime.now()),
        totalSearches: totalSearches,
        uniqueQueries: uniqueQueries,
        averageResultsPerSearch: averageResults,
        averageSearchTime: averageTime,
        topQueries: topQueries.take(10).toList(),
        hourlySearchPatterns: hourlyPatterns,
        successRate: successRate,
        cacheHitRate: _calculateCacheHitRate(),
        scope: scope,
        generatedAt: DateTime.now(),
      );
    } catch (e) {
      _logger.severe('Failed to generate search analytics: $e');
      return SearchAnalyticsReport.empty();
    }
  }

  /// Update search service configuration
  Future<void> updateConfiguration(SearchServiceConfig config) async {
    try {
      _config = config;
      await _saveSearchPreferences();

      // Clear caches if configuration changed significantly
      if (config.enableFuzzySearch != _config.enableFuzzySearch ||
          config.maxCacheSize != _config.maxCacheSize) {
        _clearCaches();
      }

      _logger.info('Search service configuration updated');
    } catch (e) {
      _logger.severe('Failed to update search configuration: $e');
    }
  }

  /// Clear search history
  Future<void> clearSearchHistory() async {
    try {
      _searchHistory.clear();
      await _saveSearchHistory();
      _logger.info('Search history cleared');
    } catch (e) {
      _logger.severe('Failed to clear search history: $e');
    }
  }

  /// Clear search caches
  void clearCaches() {
    _clearCaches();
    _logger.info('Search caches cleared');
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
  List<ArchiveSearchEntry> get searchHistory =>
      List.unmodifiable(_searchHistory);

  /// Get saved searches
  List<SavedSearch> get savedSearches => List.unmodifiable(_savedSearches);

  /// Dispose and cleanup
  Future<void> dispose() async {
    await _searchUpdatesController.close();
    await _suggestionUpdatesController.close();

    _isInitialized = false;
    _logger.info('Archive search service disposed');
  }

  // Private methods

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

  void _cacheSearchResult(String cacheKey, AdvancedSearchResult result) {
    _searchCache[cacheKey] = SearchResultCache(
      result: result,
      cachedAt: DateTime.now(),
    );

    // Maintain cache size
    _maintainSearchCacheSize();
  }

  void _maintainSearchCacheSize() {
    while (_searchCache.length > _config.maxCacheSize) {
      final oldestKey = _searchCache.keys.first;
      _searchCache.remove(oldestKey);
    }
  }

  bool _isCacheValid(String cacheKey) {
    final cache = _searchCache[cacheKey];
    if (cache == null) return false;

    final age = DateTime.now().difference(cache.cachedAt);
    return age.inMinutes < _config.cacheValidityMinutes;
  }

  void _cacheSuggestions(String cacheKey, List<SearchSuggestion> suggestions) {
    _suggestionCache[cacheKey] = SearchSuggestionCache(
      suggestions: suggestions,
      cachedAt: DateTime.now(),
    );

    // Maintain cache size
    while (_suggestionCache.length > _config.maxCacheSize ~/ 2) {
      final oldestKey = _suggestionCache.keys.first;
      _suggestionCache.remove(oldestKey);
    }
  }

  bool _isSuggestionCacheValid(String cacheKey) {
    final cache = _suggestionCache[cacheKey];
    if (cache == null) return false;

    final age = DateTime.now().difference(cache.cachedAt);
    return age.inMinutes < 5; // Short cache for suggestions
  }

  List<SearchSuggestion> _getHistorySuggestions(String partial, int limit) {
    final suggestions = <SearchSuggestion>[];

    for (final entry in _searchHistory.reversed) {
      if (entry.query.toLowerCase().contains(partial) &&
          suggestions.length < limit) {
        suggestions.add(
          SearchSuggestion.fromHistory(entry.query, entry.resultCount),
        );
      }
    }

    return suggestions;
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

  List<SearchSuggestion> _getSavedSearchSuggestions(String partial, int limit) {
    final suggestions = <SearchSuggestion>[];

    for (final saved in _savedSearches) {
      if (saved.query.toLowerCase().contains(partial) &&
          suggestions.length < limit) {
        suggestions.add(SearchSuggestion.savedSearch(saved.name, saved.query));
      }
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

  Map<int, int> _calculateHourlySearchPatterns(
    List<ArchiveSearchEntry> history,
  ) {
    final hourlyCount = <int, int>{};

    for (final entry in history) {
      final hour = entry.timestamp.hour;
      hourlyCount[hour] = (hourlyCount[hour] ?? 0) + 1;
    }

    return hourlyCount;
  }

  double _calculateSuccessRate(List<ArchiveSearchEntry> history) {
    if (history.isEmpty) return 0.0;

    final successfulSearches = history.where((e) => e.resultCount > 0).length;
    return successfulSearches / history.length;
  }

  double _calculateCacheHitRate() {
    if (_totalSearches == 0) return 0.0;

    final cacheHits = _queryAnalytics.values.fold(
      0,
      (sum, analytics) => sum + analytics.cacheHits,
    );

    return cacheHits / _totalSearches;
  }

  void _clearCaches() {
    _searchCache.clear();
    _suggestionCache.clear();
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

  Future<void> _updateSearchHistory(
    String query,
    AdvancedSearchResult result,
  ) async {
    final entry = ArchiveSearchEntry(
      query: query,
      resultCount: result.totalResults,
      searchTime: result.searchTime,
      timestamp: DateTime.now(),
    );

    _searchHistory.add(entry);

    // Keep only recent history
    while (_searchHistory.length > _config.maxHistorySize) {
      _searchHistory.removeAt(0);
    }

    await _saveSearchHistory();
  }

  void _recordSearchAnalytics(
    String query,
    AdvancedSearchResult result,
    Duration searchTime,
    bool cacheHit,
  ) {
    _totalSearches++;

    final analytics = _queryAnalytics.putIfAbsent(
      query,
      () => SearchAnalytics(query: query),
    );
    analytics.recordSearch(result.totalResults, searchTime, cacheHit);
  }

  // Storage methods

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
      }
    } catch (e) {
      _logger.warning('Failed to load search history: $e');
    }
  }

  Future<void> _saveSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = jsonEncode(
        _searchHistory.map((e) => e.toJson()).toList(),
      );
      await prefs.setString(_searchHistoryKey, historyJson);
    } catch (e) {
      _logger.warning('Failed to save search history: $e');
    }
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
      }
    } catch (e) {
      _logger.warning('Failed to load saved searches: $e');
    }
  }

  Future<void> _saveSavedSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = jsonEncode(
        _savedSearches.map((s) => s.toJson()).toList(),
      );
      await prefs.setString(_savedSearchesKey, savedJson);
    } catch (e) {
      _logger.warning('Failed to save saved searches: $e');
    }
  }

  Future<void> _loadSearchAnalytics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final analyticsJson = prefs.getString(_searchAnalyticsKey);

      if (analyticsJson != null) {
        final analyticsData = jsonDecode(analyticsJson) as Map<String, dynamic>;
        _totalSearches = analyticsData['totalSearches'] ?? 0;

        final queryData =
            analyticsData['queryAnalytics'] as Map<String, dynamic>? ?? {};
        _queryAnalytics.clear();
        for (final entry in queryData.entries) {
          _queryAnalytics[entry.key] = SearchAnalytics.fromJson(entry.value);
        }
      }
    } catch (e) {
      _logger.warning('Failed to load search analytics: $e');
    }
  }
}
