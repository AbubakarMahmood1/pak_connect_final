// Archive search service with advanced full-text search and query processing

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/repositories/archive_repository.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../core/models/archive_models.dart';

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
  ArchiveSearchService._internal({ArchiveRepository? archiveRepository})
    : _archiveRepository = archiveRepository ?? ArchiveRepository.instance {
    _logger.info('✅ ArchiveSearchService singleton instance created');
  }

  /// Factory constructor (redirects to instance getter)
  factory ArchiveSearchService() => instance;

  // Dependencies (injected for testability)
  final ArchiveRepository _archiveRepository;

  // Storage keys
  static const String _searchHistoryKey = 'archive_search_history_v2';
  static const String _searchPreferencesKey = 'archive_search_preferences_v2';
  static const String _searchAnalyticsKey = 'archive_search_analytics_v2';
  static const String _savedSearchesKey = 'archive_saved_searches_v2';

  // Search index and cache
  final Map<String, Set<String>> _termIndex = {}; // term -> archive IDs
  final Map<String, Set<String>> _fuzzyIndex = {}; // soundex -> archive IDs
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
      await _rebuildSearchIndexes();

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
      final parsedQuery = _parseSearchQuery(query);
      final normalizedQuery = _normalizeQuery(parsedQuery);

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
      final searchStrategy = _determineSearchStrategy(
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

      // Build advanced result
      final searchTime = DateTime.now().difference(searchStartTime);
      final advancedResult = AdvancedSearchResult.fromSearchResult(
        searchResult: enhancedResult,
        query: query,
        parsedQuery: parsedQuery,
        searchTime: searchTime,
        searchStrategy: searchStrategy,
        suggestions: await _generateSearchSuggestions(query, enhancedResult),
        analytics: _buildSearchAnalytics(query, enhancedResult, searchTime),
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
      final fuzzyTerms = _generateFuzzyTerms(query, similarityThreshold);

      // Build expanded query with fuzzy terms
      final expandedQuery = _buildFuzzyQuery(query, fuzzyTerms);

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
      await _rebuildSearchIndexes();
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

  ParsedSearchQuery _parseSearchQuery(String query) {
    // Advanced query parsing with operators, phrases, exclusions
    final tokens = <String>[];
    final phrases = <String>[];
    final excludedTerms = <String>[];
    final operators = <SearchOperator>[];

    // Simple parsing implementation (would be more sophisticated in real app)
    final words = query
        .toLowerCase()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();

    for (final word in words) {
      if (word.startsWith('-')) {
        excludedTerms.add(word.substring(1));
      } else if (word.startsWith('"') && word.endsWith('"')) {
        phrases.add(word.substring(1, word.length - 1));
      } else {
        tokens.add(word);
      }
    }

    return ParsedSearchQuery(
      originalQuery: query,
      tokens: tokens,
      phrases: phrases,
      excludedTerms: excludedTerms,
      operators: operators,
    );
  }

  String _normalizeQuery(ParsedSearchQuery query) {
    // Normalize terms for consistent searching
    return query.tokens.join(' ');
  }

  SearchStrategy _determineSearchStrategy(
    ParsedSearchQuery query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
  ) {
    if (query.phrases.isNotEmpty) return SearchStrategy.phrase;
    if (options?.fuzzySearch == true) return SearchStrategy.fuzzy;
    if (filter?.dateRange != null) return SearchStrategy.temporal;
    if (query.tokens.length > 3) return SearchStrategy.complex;
    return SearchStrategy.simple;
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
      final commonTerms = _extractCommonTerms(result);
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
    // Generate suggestions from indexed content
    final suggestions = <SearchSuggestion>[];

    for (final term in _termIndex.keys) {
      if (term.contains(partial) && suggestions.length < limit) {
        final frequency = _termIndex[term]?.length ?? 0;
        suggestions.add(SearchSuggestion.contentBased(term, frequency));
      }
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

  List<String> _generateFuzzyTerms(String query, double threshold) {
    final fuzzyTerms = <String>[];

    // Generate variations using different algorithms
    // 1. Edit distance variations
    // 2. Phonetic variations (soundex)
    // 3. Common misspellings

    // Simplified implementation
    final variations = _generateEditDistanceVariations(query, 1);
    fuzzyTerms.addAll(variations);

    return fuzzyTerms.take(10).toList();
  }

  List<String> _generateEditDistanceVariations(String word, int maxDistance) {
    // Generate variations within edit distance
    // Simplified implementation
    return [word]; // Would implement proper edit distance algorithm
  }

  String _buildFuzzyQuery(String original, List<String> fuzzyTerms) {
    final queryBuilder = StringBuffer(original);

    for (final term in fuzzyTerms.take(3)) {
      queryBuilder.write(' OR $term');
    }

    return queryBuilder.toString();
  }

  List<String> _extractCommonTerms(ArchiveSearchResult result) {
    final termFrequency = <String, int>{};

    for (final message in result.messages) {
      final words = message.content.toLowerCase().split(' ');
      for (final word in words) {
        if (word.length > 3) {
          termFrequency[word] = (termFrequency[word] ?? 0) + 1;
        }
      }
    }

    final sortedTerms = termFrequency.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedTerms.map((e) => e.key).take(5).toList();
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

  Future<void> _rebuildSearchIndexes() async {
    try {
      _termIndex.clear();
      _fuzzyIndex.clear();

      // Get all archived chats and build indexes
      final summaries = await _archiveRepository.getArchivedChats();

      for (final summary in summaries) {
        final archive = await _archiveRepository.getArchivedChat(summary.id);
        if (archive != null) {
          _indexArchiveContent(archive);
        }
      }

      _logger.info('Rebuilt search indexes for ${summaries.length} archives');
    } catch (e) {
      _logger.severe('Failed to rebuild search indexes: $e');
    }
  }

  void _indexArchiveContent(ArchivedChat archive) {
    // Index contact name
    final contactTerms = _tokenizeText(archive.contactName);
    for (final term in contactTerms) {
      _termIndex.putIfAbsent(term, () => {}).add(archive.id);
    }

    // Index message content
    for (final message in archive.messages) {
      final messageTerms = _tokenizeText(message.searchableText);
      for (final term in messageTerms) {
        _termIndex.putIfAbsent(term, () => {}).add(archive.id);
      }
    }
  }

  Set<String> _tokenizeText(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 2)
        .toSet();
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

// Supporting classes and enums

class SearchServiceConfig {
  final bool enableFuzzySearch;
  final int maxCacheSize;
  final int cacheValidityMinutes;
  final int maxHistorySize;
  final bool enableSuggestions;
  final double fuzzyThreshold;

  const SearchServiceConfig({
    required this.enableFuzzySearch,
    required this.maxCacheSize,
    required this.cacheValidityMinutes,
    required this.maxHistorySize,
    required this.enableSuggestions,
    required this.fuzzyThreshold,
  });

  factory SearchServiceConfig.defaultConfig() => const SearchServiceConfig(
    enableFuzzySearch: true,
    maxCacheSize: 100,
    cacheValidityMinutes: 30,
    maxHistorySize: 500,
    enableSuggestions: true,
    fuzzyThreshold: 0.7,
  );

  Map<String, dynamic> toJson() => {
    'enableFuzzySearch': enableFuzzySearch,
    'maxCacheSize': maxCacheSize,
    'cacheValidityMinutes': cacheValidityMinutes,
    'maxHistorySize': maxHistorySize,
    'enableSuggestions': enableSuggestions,
    'fuzzyThreshold': fuzzyThreshold,
  };

  factory SearchServiceConfig.fromJson(Map<String, dynamic> json) =>
      SearchServiceConfig(
        enableFuzzySearch: json['enableFuzzySearch'],
        maxCacheSize: json['maxCacheSize'],
        cacheValidityMinutes: json['cacheValidityMinutes'],
        maxHistorySize: json['maxHistorySize'],
        enableSuggestions: json['enableSuggestions'],
        fuzzyThreshold: json['fuzzyThreshold'],
      );
}

class SearchOptions {
  final bool fuzzySearch;
  final double similarityThreshold;
  final bool expandQuery;
  final bool temporalRanking;
  final TemporalSearchMode temporalMode;
  final bool boostRecent;

  const SearchOptions({
    this.fuzzySearch = false,
    this.similarityThreshold = 0.7,
    this.expandQuery = false,
    this.temporalRanking = false,
    this.temporalMode = TemporalSearchMode.archived,
    this.boostRecent = false,
  });
}

enum TemporalSearchMode { archived, original, recent }

enum SearchStrategy { simple, phrase, fuzzy, temporal, complex }

enum SearchAnalyticsScope { all, recent, popular }

class AdvancedSearchResult {
  final ArchiveSearchResult searchResult;
  final String query;
  final ParsedSearchQuery? parsedQuery;
  final Duration searchTime;
  final SearchStrategy? searchStrategy;
  final List<SearchSuggestion> suggestions;
  final SearchAnalyticsSummary? analytics;
  final String? error;

  const AdvancedSearchResult({
    required this.searchResult,
    required this.query,
    this.parsedQuery,
    required this.searchTime,
    this.searchStrategy,
    required this.suggestions,
    this.analytics,
    this.error,
  });

  factory AdvancedSearchResult.fromSearchResult({
    required ArchiveSearchResult searchResult,
    required String query,
    ParsedSearchQuery? parsedQuery,
    required Duration searchTime,
    SearchStrategy? searchStrategy,
    required List<SearchSuggestion> suggestions,
    SearchAnalyticsSummary? analytics,
  }) => AdvancedSearchResult(
    searchResult: searchResult,
    query: query,
    parsedQuery: parsedQuery,
    searchTime: searchTime,
    searchStrategy: searchStrategy,
    suggestions: suggestions,
    analytics: analytics,
  );

  factory AdvancedSearchResult.error({
    required String query,
    required String error,
    required Duration searchTime,
  }) => AdvancedSearchResult(
    searchResult: ArchiveSearchResult.empty(query),
    query: query,
    searchTime: searchTime,
    suggestions: [],
    error: error,
  );

  int get totalResults => searchResult.totalResults;
  List<ArchivedMessage> get messages => searchResult.messages;
  String get formattedSearchTime => searchResult.formattedSearchTime;
  bool get hasError => error != null;
  bool get hasResults => searchResult.hasResults;
}

class ParsedSearchQuery {
  final String originalQuery;
  final List<String> tokens;
  final List<String> phrases;
  final List<String> excludedTerms;
  final List<SearchOperator> operators;

  const ParsedSearchQuery({
    required this.originalQuery,
    required this.tokens,
    required this.phrases,
    required this.excludedTerms,
    required this.operators,
  });
}

enum SearchOperator { and, or, not, near }

class SearchSuggestion {
  final String text;
  final SearchSuggestionType type;
  final double relevanceScore;
  final Map<String, dynamic>? metadata;

  const SearchSuggestion({
    required this.text,
    required this.type,
    required this.relevanceScore,
    this.metadata,
  });

  factory SearchSuggestion.fromHistory(String query, int resultCount) =>
      SearchSuggestion(
        text: query,
        type: SearchSuggestionType.history,
        relevanceScore: min(resultCount / 10.0, 1.0),
        metadata: {'resultCount': resultCount},
      );

  factory SearchSuggestion.contentBased(String term, int frequency) =>
      SearchSuggestion(
        text: term,
        type: SearchSuggestionType.content,
        relevanceScore: min(frequency / 100.0, 1.0),
        metadata: {'frequency': frequency},
      );

  factory SearchSuggestion.savedSearch(String name, String query) =>
      SearchSuggestion(
        text: query,
        type: SearchSuggestionType.saved,
        relevanceScore: 1.0,
        metadata: {'name': name},
      );

  factory SearchSuggestion.relatedTerm(String term) => SearchSuggestion(
    text: term,
    type: SearchSuggestionType.related,
    relevanceScore: 0.8,
  );

  factory SearchSuggestion.refinement(String suggestion) => SearchSuggestion(
    text: suggestion,
    type: SearchSuggestionType.refinement,
    relevanceScore: 0.6,
  );
}

enum SearchSuggestionType { history, content, saved, related, refinement }

class ArchiveSearchEntry {
  final String query;
  final int resultCount;
  final Duration searchTime;
  final DateTime timestamp;

  const ArchiveSearchEntry({
    required this.query,
    required this.resultCount,
    required this.searchTime,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'query': query,
    'resultCount': resultCount,
    'searchTime': searchTime.inMilliseconds,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  factory ArchiveSearchEntry.fromJson(Map<String, dynamic> json) =>
      ArchiveSearchEntry(
        query: json['query'],
        resultCount: json['resultCount'],
        searchTime: Duration(milliseconds: json['searchTime']),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      );
}

class SavedSearch {
  final String id;
  final String name;
  final String query;
  final ArchiveSearchFilter? filter;
  final SearchOptions? options;
  final DateTime createdAt;

  const SavedSearch({
    required this.id,
    required this.name,
    required this.query,
    this.filter,
    this.options,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'query': query,
    'filter': filter?.toJson(),
    'options': _optionsToJson(options),
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  factory SavedSearch.fromJson(Map<String, dynamic> json) => SavedSearch(
    id: json['id'],
    name: json['name'],
    query: json['query'],
    filter: json['filter'] != null
        ? ArchiveSearchFilter.fromJson(json['filter'])
        : null,
    options: json['options'] != null ? _optionsFromJson(json['options']) : null,
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt']),
  );

  static Map<String, dynamic> _optionsToJson(SearchOptions? options) {
    if (options == null) return {};
    return {
      'fuzzySearch': options.fuzzySearch,
      'similarityThreshold': options.similarityThreshold,
      'expandQuery': options.expandQuery,
      'temporalRanking': options.temporalRanking,
      'temporalMode': options.temporalMode.index,
      'boostRecent': options.boostRecent,
    };
  }

  static SearchOptions _optionsFromJson(Map<String, dynamic> json) {
    return SearchOptions(
      fuzzySearch: json['fuzzySearch'] ?? false,
      similarityThreshold: json['similarityThreshold'] ?? 0.7,
      expandQuery: json['expandQuery'] ?? false,
      temporalRanking: json['temporalRanking'] ?? false,
      temporalMode: TemporalSearchMode.values[json['temporalMode'] ?? 0],
      boostRecent: json['boostRecent'] ?? false,
    );
  }
}

class SearchAnalytics {
  final String query;
  int searchCount = 0;
  int totalResults = 0;
  Duration totalSearchTime = Duration.zero;
  int cacheHits = 0;
  DateTime lastSearched = DateTime.now();

  SearchAnalytics({required this.query});

  void recordSearch(int resultCount, Duration searchTime, bool cacheHit) {
    searchCount++;
    totalResults += resultCount;
    totalSearchTime += searchTime;
    if (cacheHit) cacheHits++;
    lastSearched = DateTime.now();
  }

  double get averageResults =>
      searchCount > 0 ? totalResults / searchCount : 0.0;
  Duration get averageSearchTime =>
      searchCount > 0 ? totalSearchTime ~/ searchCount : Duration.zero;
  double get cacheHitRate => searchCount > 0 ? cacheHits / searchCount : 0.0;

  Map<String, dynamic> toJson() => {
    'query': query,
    'searchCount': searchCount,
    'totalResults': totalResults,
    'totalSearchTime': totalSearchTime.inMilliseconds,
    'cacheHits': cacheHits,
    'lastSearched': lastSearched.millisecondsSinceEpoch,
  };

  factory SearchAnalytics.fromJson(Map<String, dynamic> json) {
    final analytics = SearchAnalytics(query: json['query']);
    analytics.searchCount = json['searchCount'];
    analytics.totalResults = json['totalResults'];
    analytics.totalSearchTime = Duration(milliseconds: json['totalSearchTime']);
    analytics.cacheHits = json['cacheHits'];
    analytics.lastSearched = DateTime.fromMillisecondsSinceEpoch(
      json['lastSearched'],
    );
    return analytics;
  }
}

class SearchAnalyticsSummary {
  final String query;
  final int resultCount;
  final Duration searchTime;
  final bool cacheHit;
  final DateTime timestamp;

  const SearchAnalyticsSummary({
    required this.query,
    required this.resultCount,
    required this.searchTime,
    required this.cacheHit,
    required this.timestamp,
  });
}

class SearchAnalyticsReport {
  final ArchiveDateRange period;
  final int totalSearches;
  final int uniqueQueries;
  final double averageResultsPerSearch;
  final Duration averageSearchTime;
  final List<MapEntry<String, int>> topQueries;
  final Map<int, int> hourlySearchPatterns;
  final double successRate;
  final double cacheHitRate;
  final SearchAnalyticsScope scope;
  final DateTime generatedAt;

  const SearchAnalyticsReport({
    required this.period,
    required this.totalSearches,
    required this.uniqueQueries,
    required this.averageResultsPerSearch,
    required this.averageSearchTime,
    required this.topQueries,
    required this.hourlySearchPatterns,
    required this.successRate,
    required this.cacheHitRate,
    required this.scope,
    required this.generatedAt,
  });

  factory SearchAnalyticsReport.empty() => SearchAnalyticsReport(
    period: ArchiveDateRange(start: DateTime.now(), end: DateTime.now()),
    totalSearches: 0,
    uniqueQueries: 0,
    averageResultsPerSearch: 0.0,
    averageSearchTime: Duration.zero,
    topQueries: [],
    hourlySearchPatterns: {},
    successRate: 0.0,
    cacheHitRate: 0.0,
    scope: SearchAnalyticsScope.all,
    generatedAt: DateTime.now(),
  );
}

// Event classes
abstract class ArchiveSearchEvent {
  final DateTime timestamp;

  const ArchiveSearchEvent(this.timestamp);

  factory ArchiveSearchEvent.started(String searchId, String query) =>
      _SearchStarted(searchId, query, DateTime.now());
  factory ArchiveSearchEvent.completed(
    String searchId,
    AdvancedSearchResult result,
  ) => _SearchCompleted(searchId, result, DateTime.now());
  factory ArchiveSearchEvent.failed(
    String searchId,
    String query,
    String error,
  ) => _SearchFailed(searchId, query, error, DateTime.now());
}

class _SearchStarted extends ArchiveSearchEvent {
  final String searchId;
  final String query;
  const _SearchStarted(this.searchId, this.query, DateTime timestamp)
    : super(timestamp);
}

class _SearchCompleted extends ArchiveSearchEvent {
  final String searchId;
  final AdvancedSearchResult result;
  const _SearchCompleted(this.searchId, this.result, DateTime timestamp)
    : super(timestamp);
}

class _SearchFailed extends ArchiveSearchEvent {
  final String searchId;
  final String query;
  final String error;
  const _SearchFailed(this.searchId, this.query, this.error, DateTime timestamp)
    : super(timestamp);
}

abstract class SearchSuggestionEvent {
  final DateTime timestamp;

  const SearchSuggestionEvent(this.timestamp);

  factory SearchSuggestionEvent.generated(
    String query,
    List<SearchSuggestion> suggestions,
  ) => _SuggestionsGenerated(query, suggestions, DateTime.now());
}

class _SuggestionsGenerated extends SearchSuggestionEvent {
  final String query;
  final List<SearchSuggestion> suggestions;
  const _SuggestionsGenerated(this.query, this.suggestions, DateTime timestamp)
    : super(timestamp);
}

// Cache classes
class SearchResultCache {
  final AdvancedSearchResult result;
  final DateTime cachedAt;

  const SearchResultCache({required this.result, required this.cachedAt});
}

class SearchSuggestionCache {
  final List<SearchSuggestion> suggestions;
  final DateTime cachedAt;

  const SearchSuggestionCache({
    required this.suggestions,
    required this.cachedAt,
  });
}

// Extension for firstOrNull
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
