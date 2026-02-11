import 'dart:math';
import '../../domain/entities/archived_message.dart';
import '../models/archive_models.dart';

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

extension FirstWhereOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}
