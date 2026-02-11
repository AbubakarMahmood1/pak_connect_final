// Search analytics and metrics tracking
// Extracted from ArchiveSearchService as part of Phase 4D refactoring

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'archive_search_models.dart';
import '../models/archive_models.dart';

/// Callback for analytics update events
typedef AnalyticsUpdateCallback = void Function();

/// Manages search analytics and usage metrics with persistence
class SearchAnalyticsTracker {
  static final _logger = Logger('SearchAnalyticsTracker');

  // Storage key
  static const String _searchAnalyticsKey = 'archive_search_analytics_v2';

  // State
  final Map<String, SearchAnalytics> _queryAnalytics = {};
  int _totalSearches = 0;

  // Optional callback for analytics events (used by facade)
  AnalyticsUpdateCallback? onAnalyticsUpdated;

  SearchAnalyticsTracker() {
    _logger.fine('SearchAnalyticsTracker initialized');
  }

  // ============================================================================
  // Initialization & Persistence
  // ============================================================================

  /// Initialize by loading persisted analytics
  Future<void> initialize() async {
    try {
      await _loadSearchAnalytics();
      _logger.info('SearchAnalyticsTracker initialized successfully');
    } catch (e) {
      _logger.severe('Failed to initialize SearchAnalyticsTracker: $e');
      rethrow;
    }
  }

  /// Load analytics from SharedPreferences
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

        _logger.fine(
          'Loaded analytics: $_totalSearches total searches, ${_queryAnalytics.length} unique queries',
        );
      }
    } catch (e) {
      _logger.warning('Failed to load search analytics: $e');
    }
  }

  /// Save analytics to SharedPreferences
  Future<void> _saveSearchAnalytics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final analyticsData = {
        'totalSearches': _totalSearches,
        'queryAnalytics': _queryAnalytics.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

      await prefs.setString(_searchAnalyticsKey, jsonEncode(analyticsData));
      _logger.fine('Saved analytics: $_totalSearches total searches');
    } catch (e) {
      _logger.warning('Failed to save search analytics: $e');
    }
  }

  // ============================================================================
  // Analytics Recording
  // ============================================================================

  /// Record a search execution for analytics
  Future<void> recordSearch({
    required String query,
    required AdvancedSearchResult result,
    required Duration searchTime,
    required bool cacheHit,
  }) async {
    try {
      _totalSearches++;

      final analytics = _queryAnalytics.putIfAbsent(
        query,
        () => SearchAnalytics(query: query),
      );
      analytics.recordSearch(result.totalResults, searchTime, cacheHit);

      // Persist analytics (debounced - save every 10 searches)
      if (_totalSearches % 10 == 0) {
        await _saveSearchAnalytics();
      }

      onAnalyticsUpdated?.call();

      _logger.fine(
        'Recorded search: "$query" (${result.totalResults} results, ${searchTime.inMilliseconds}ms, cache: $cacheHit)',
      );
    } catch (e) {
      _logger.warning('Failed to record search analytics: $e');
    }
  }

  // ============================================================================
  // Analytics Reporting
  // ============================================================================

  /// Generate analytics report for a time period
  Future<SearchAnalyticsReport> getAnalyticsReport({
    DateTime? since,
    SearchAnalyticsScope scope = SearchAnalyticsScope.all,
    required List<ArchiveSearchEntry> searchHistory,
  }) async {
    try {
      final cutoffDate =
          since ?? DateTime.now().subtract(const Duration(days: 30));

      // Filter history based on date
      final recentHistory = searchHistory
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
      final cacheHitRate = _calculateCacheHitRate();

      return SearchAnalyticsReport(
        period: ArchiveDateRange(start: cutoffDate, end: DateTime.now()),
        totalSearches: totalSearches,
        uniqueQueries: uniqueQueries,
        averageResultsPerSearch: averageResults,
        averageSearchTime: averageTime,
        topQueries: topQueries.take(10).toList(),
        hourlySearchPatterns: hourlyPatterns,
        successRate: successRate,
        cacheHitRate: cacheHitRate,
        scope: scope,
        generatedAt: DateTime.now(),
      );
    } catch (e) {
      _logger.severe('Failed to generate search analytics: $e');
      return SearchAnalyticsReport.empty();
    }
  }

  /// Get top queries by frequency
  List<MapEntry<String, int>> getTopQueries({int limit = 10}) {
    final queryFrequency = <String, int>{};

    for (final analytics in _queryAnalytics.values) {
      queryFrequency[analytics.query] = analytics.searchCount;
    }

    final topQueries = queryFrequency.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return topQueries.take(limit).toList();
  }

  /// Get average search time across all queries
  Duration getAverageSearchTime() {
    if (_queryAnalytics.isEmpty) return Duration.zero;

    final totalTime = _queryAnalytics.values.fold(
      Duration.zero,
      (sum, analytics) => sum + analytics.totalSearchTime,
    );

    return totalTime ~/ _totalSearches;
  }

  /// Calculate cache hit rate
  double getCacheHitRate() => _calculateCacheHitRate();

  // ============================================================================
  // Private Analytics Calculations
  // ============================================================================

  /// Calculate hourly search patterns
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

  /// Calculate success rate (queries with results / total queries)
  double _calculateSuccessRate(List<ArchiveSearchEntry> history) {
    if (history.isEmpty) return 0.0;

    final successfulSearches = history.where((e) => e.resultCount > 0).length;
    return successfulSearches / history.length;
  }

  /// Calculate cache hit rate
  double _calculateCacheHitRate() {
    if (_totalSearches == 0) return 0.0;

    final cacheHits = _queryAnalytics.values.fold(
      0,
      (sum, analytics) => sum + analytics.cacheHits,
    );

    return cacheHits / _totalSearches;
  }

  // ============================================================================
  // Analytics Management
  // ============================================================================

  /// Clear all analytics
  Future<void> clearAnalytics() async {
    try {
      _queryAnalytics.clear();
      _totalSearches = 0;

      await _saveSearchAnalytics();
      onAnalyticsUpdated?.call();

      _logger.info('Cleared all analytics');
    } catch (e) {
      _logger.severe('Failed to clear analytics: $e');
    }
  }

  /// Force save analytics (useful before app shutdown)
  Future<void> forceSave() async {
    await _saveSearchAnalytics();
  }

  // ============================================================================
  // Stats & Inspection
  // ============================================================================

  /// Get analytics statistics
  Map<String, dynamic> getAnalyticsStats() {
    return {
      'totalSearches': _totalSearches,
      'uniqueQueries': _queryAnalytics.length,
      'cacheHitRate': _calculateCacheHitRate(),
      'averageSearchTime': getAverageSearchTime().inMilliseconds,
    };
  }

  /// Get total searches count
  int get totalSearches => _totalSearches;

  /// Get unique queries count
  int get uniqueQueriesCount => _queryAnalytics.length;
}
