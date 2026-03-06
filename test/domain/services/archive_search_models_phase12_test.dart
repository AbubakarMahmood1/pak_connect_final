// Phase 12.12: archive_search_models.dart coverage
// Targets: SearchServiceConfig, SearchSuggestion factories, AdvancedSearchResult,
//          ArchiveSearchEntry, SavedSearch toJson/fromJson, SearchAnalytics,
//          SearchAnalyticsReport, ArchiveSearchEvent factories, caches, extension

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/archive_search_models.dart';
import 'package:pak_connect/domain/models/archive_models.dart';

void main() {
  // ─── SearchServiceConfig ──────────────────────────────────────────────
  group('SearchServiceConfig', () {
    test('defaultConfig has expected values', () {
      final config = SearchServiceConfig.defaultConfig();
      expect(config.enableFuzzySearch, isTrue);
      expect(config.maxCacheSize, 100);
      expect(config.cacheValidityMinutes, 30);
      expect(config.maxHistorySize, 500);
      expect(config.enableSuggestions, isTrue);
      expect(config.fuzzyThreshold, 0.7);
    });

    test('toJson serializes all fields', () {
      final config = SearchServiceConfig.defaultConfig();
      final json = config.toJson();
      expect(json['enableFuzzySearch'], isTrue);
      expect(json['maxCacheSize'], 100);
      expect(json['cacheValidityMinutes'], 30);
      expect(json['maxHistorySize'], 500);
      expect(json['enableSuggestions'], isTrue);
      expect(json['fuzzyThreshold'], 0.7);
    });

    test('fromJson round-trips correctly', () {
      final original = const SearchServiceConfig(
        enableFuzzySearch: false,
        maxCacheSize: 50,
        cacheValidityMinutes: 15,
        maxHistorySize: 200,
        enableSuggestions: false,
        fuzzyThreshold: 0.5,
      );
      final restored = SearchServiceConfig.fromJson(original.toJson());
      expect(restored.enableFuzzySearch, isFalse);
      expect(restored.maxCacheSize, 50);
      expect(restored.cacheValidityMinutes, 15);
      expect(restored.maxHistorySize, 200);
      expect(restored.enableSuggestions, isFalse);
      expect(restored.fuzzyThreshold, 0.5);
    });
  });

  // ─── SearchOptions ────────────────────────────────────────────────────
  group('SearchOptions', () {
    test('default values are correct', () {
      const opts = SearchOptions();
      expect(opts.fuzzySearch, isFalse);
      expect(opts.similarityThreshold, 0.7);
      expect(opts.expandQuery, isFalse);
      expect(opts.temporalRanking, isFalse);
      expect(opts.temporalMode, TemporalSearchMode.archived);
      expect(opts.boostRecent, isFalse);
    });

    test('custom values propagate', () {
      const opts = SearchOptions(
        fuzzySearch: true,
        similarityThreshold: 0.9,
        expandQuery: true,
        temporalRanking: true,
        temporalMode: TemporalSearchMode.recent,
        boostRecent: true,
      );
      expect(opts.fuzzySearch, isTrue);
      expect(opts.similarityThreshold, 0.9);
      expect(opts.temporalMode, TemporalSearchMode.recent);
    });
  });

  // ─── SearchSuggestion factories ───────────────────────────────────────
  group('SearchSuggestion', () {
    test('fromHistory calculates relevance min(resultCount/10, 1)', () {
      final s1 = SearchSuggestion.fromHistory('query', 5);
      expect(s1.relevanceScore, 0.5);
      expect(s1.type, SearchSuggestionType.history);
      expect(s1.metadata?['resultCount'], 5);

      final s2 = SearchSuggestion.fromHistory('query', 20);
      expect(s2.relevanceScore, 1.0); // capped at 1.0
    });

    test('contentBased calculates relevance min(frequency/100, 1)', () {
      final s = SearchSuggestion.contentBased('term', 50);
      expect(s.relevanceScore, 0.5);
      expect(s.type, SearchSuggestionType.content);
      expect(s.metadata?['frequency'], 50);

      final capped = SearchSuggestion.contentBased('term', 200);
      expect(capped.relevanceScore, 1.0);
    });

    test('savedSearch returns relevance 1.0', () {
      final s = SearchSuggestion.savedSearch('My Search', 'test query');
      expect(s.text, 'test query');
      expect(s.type, SearchSuggestionType.saved);
      expect(s.relevanceScore, 1.0);
      expect(s.metadata?['name'], 'My Search');
    });

    test('relatedTerm returns relevance 0.8', () {
      final s = SearchSuggestion.relatedTerm('related');
      expect(s.relevanceScore, 0.8);
      expect(s.type, SearchSuggestionType.related);
      expect(s.metadata, isNull);
    });

    test('refinement returns relevance 0.6', () {
      final s = SearchSuggestion.refinement('refined query');
      expect(s.relevanceScore, 0.6);
      expect(s.type, SearchSuggestionType.refinement);
    });

    test('fromHistory with zero results gives 0.0', () {
      final s = SearchSuggestion.fromHistory('q', 0);
      expect(s.relevanceScore, 0.0);
    });

    test('contentBased with zero frequency gives 0.0', () {
      final s = SearchSuggestion.contentBased('t', 0);
      expect(s.relevanceScore, 0.0);
    });
  });

  // ─── AdvancedSearchResult ─────────────────────────────────────────────
  group('AdvancedSearchResult', () {
    test('fromSearchResult populates all fields', () {
      final sr = ArchiveSearchResult.empty('test');
      final asr = AdvancedSearchResult.fromSearchResult(
        searchResult: sr,
        query: 'test',
        searchTime: const Duration(milliseconds: 42),
        suggestions: [SearchSuggestion.relatedTerm('a')],
        searchStrategy: SearchStrategy.fuzzy,
        parsedQuery: const ParsedSearchQuery(
          originalQuery: 'test',
          tokens: ['test'],
          phrases: [],
          excludedTerms: [],
          operators: [],
        ),
      );
      expect(asr.query, 'test');
      expect(asr.totalResults, 0);
      expect(asr.messages, isEmpty);
      expect(asr.hasError, isFalse);
      expect(asr.hasResults, isFalse);
      expect(asr.searchStrategy, SearchStrategy.fuzzy);
      expect(asr.suggestions, hasLength(1));
    });

    test('error factory sets error field', () {
      final asr = AdvancedSearchResult.error(
        query: 'fail',
        error: 'Something went wrong',
        searchTime: const Duration(milliseconds: 10),
      );
      expect(asr.hasError, isTrue);
      expect(asr.error, 'Something went wrong');
      expect(asr.query, 'fail');
      expect(asr.totalResults, 0);
      expect(asr.suggestions, isEmpty);
    });

    test('formattedSearchTime delegates to searchResult', () {
      final sr = ArchiveSearchResult.empty('q');
      final asr = AdvancedSearchResult(
        searchResult: sr,
        query: 'q',
        searchTime: Duration.zero,
        suggestions: [],
      );
      expect(asr.formattedSearchTime, isNotEmpty);
    });
  });

  // ─── ParsedSearchQuery ────────────────────────────────────────────────
  group('ParsedSearchQuery', () {
    test('stores all fields correctly', () {
      const q = ParsedSearchQuery(
        originalQuery: 'hello -world "exact phrase"',
        tokens: ['hello'],
        phrases: ['exact phrase'],
        excludedTerms: ['world'],
        operators: [SearchOperator.not],
      );
      expect(q.originalQuery, 'hello -world "exact phrase"');
      expect(q.tokens, ['hello']);
      expect(q.phrases, ['exact phrase']);
      expect(q.excludedTerms, ['world']);
      expect(q.operators, [SearchOperator.not]);
    });
  });

  // ─── ArchiveSearchEntry ───────────────────────────────────────────────
  group('ArchiveSearchEntry', () {
    test('toJson serializes duration and datetime', () {
      final ts = DateTime(2025, 1, 15, 10, 30);
      final entry = ArchiveSearchEntry(
        query: 'test',
        resultCount: 42,
        searchTime: const Duration(milliseconds: 150),
        timestamp: ts,
      );
      final json = entry.toJson();
      expect(json['query'], 'test');
      expect(json['resultCount'], 42);
      expect(json['searchTime'], 150);
      expect(json['timestamp'], ts.millisecondsSinceEpoch);
    });

    test('fromJson round-trips correctly', () {
      final ts = DateTime(2025, 6, 1);
      final original = ArchiveSearchEntry(
        query: 'round trip',
        resultCount: 10,
        searchTime: const Duration(milliseconds: 250),
        timestamp: ts,
      );
      final restored = ArchiveSearchEntry.fromJson(original.toJson());
      expect(restored.query, 'round trip');
      expect(restored.resultCount, 10);
      expect(restored.searchTime.inMilliseconds, 250);
      expect(restored.timestamp, ts);
    });
  });

  // ─── SavedSearch ──────────────────────────────────────────────────────
  group('SavedSearch', () {
    test('toJson with null filter and options', () {
      final ts = DateTime(2025, 3, 1);
      final saved = SavedSearch(
        id: 'ss1',
        name: 'My Search',
        query: 'test query',
        createdAt: ts,
      );
      final json = saved.toJson();
      expect(json['id'], 'ss1');
      expect(json['name'], 'My Search');
      expect(json['query'], 'test query');
      expect(json['filter'], isNull);
      expect(json['options'], isA<Map>());
      expect(json['createdAt'], ts.millisecondsSinceEpoch);
    });

    test('fromJson with null filter and options', () {
      final ts = DateTime(2025, 3, 1);
      final json = {
        'id': 'ss2',
        'name': 'Null Test',
        'query': 'q',
        'filter': null,
        'options': null,
        'createdAt': ts.millisecondsSinceEpoch,
      };
      final saved = SavedSearch.fromJson(json);
      expect(saved.id, 'ss2');
      expect(saved.filter, isNull);
      expect(saved.options, isNull);
    });

    test('round-trip with SearchOptions preserves temporal mode', () {
      final ts = DateTime(2025, 4, 1);
      final original = SavedSearch(
        id: 'ss3',
        name: 'Temporal',
        query: 'hello',
        options: const SearchOptions(
          fuzzySearch: true,
          similarityThreshold: 0.85,
          expandQuery: true,
          temporalRanking: true,
          temporalMode: TemporalSearchMode.original,
          boostRecent: true,
        ),
        createdAt: ts,
      );
      final json = original.toJson();
      final restored = SavedSearch.fromJson(json);
      expect(restored.options, isNotNull);
      expect(restored.options!.fuzzySearch, isTrue);
      expect(restored.options!.similarityThreshold, 0.85);
      expect(restored.options!.temporalMode, TemporalSearchMode.original);
      expect(restored.options!.boostRecent, isTrue);
    });

    test('_optionsFromJson provides defaults for missing keys', () {
      final ts = DateTime(2025, 5, 1);
      final json = {
        'id': 'ss4',
        'name': 'Defaults',
        'query': 'q',
        'options': <String, dynamic>{},
        'createdAt': ts.millisecondsSinceEpoch,
      };
      final saved = SavedSearch.fromJson(json);
      expect(saved.options!.fuzzySearch, isFalse);
      expect(saved.options!.similarityThreshold, 0.7);
      expect(saved.options!.temporalMode, TemporalSearchMode.archived);
    });

    test('_optionsToJson for null options returns empty map', () {
      final ts = DateTime(2025, 5, 1);
      final saved = SavedSearch(
        id: 'ss5',
        name: 'NoOpts',
        query: 'q',
        createdAt: ts,
      );
      final json = saved.toJson();
      expect(json['options'], isA<Map>());
      expect((json['options'] as Map).isEmpty, isTrue);
    });
  });

  // ─── SearchAnalytics ──────────────────────────────────────────────────
  group('SearchAnalytics', () {
    test('initial state has zero counters', () {
      final a = SearchAnalytics(query: 'test');
      expect(a.searchCount, 0);
      expect(a.totalResults, 0);
      expect(a.cacheHits, 0);
      expect(a.averageResults, 0.0);
      expect(a.averageSearchTime, Duration.zero);
      expect(a.cacheHitRate, 0.0);
    });

    test('recordSearch accumulates counts', () {
      final a = SearchAnalytics(query: 'q');
      a.recordSearch(10, const Duration(milliseconds: 100), false);
      expect(a.searchCount, 1);
      expect(a.totalResults, 10);
      expect(a.cacheHits, 0);

      a.recordSearch(20, const Duration(milliseconds: 200), true);
      expect(a.searchCount, 2);
      expect(a.totalResults, 30);
      expect(a.cacheHits, 1);
    });

    test('averageResults computes correctly', () {
      final a = SearchAnalytics(query: 'q');
      a.recordSearch(10, Duration.zero, false);
      a.recordSearch(30, Duration.zero, false);
      expect(a.averageResults, 20.0);
    });

    test('averageSearchTime uses integer division', () {
      final a = SearchAnalytics(query: 'q');
      a.recordSearch(0, const Duration(milliseconds: 100), false);
      a.recordSearch(0, const Duration(milliseconds: 200), false);
      expect(a.averageSearchTime.inMilliseconds, 150);
    });

    test('cacheHitRate computes correctly', () {
      final a = SearchAnalytics(query: 'q');
      a.recordSearch(0, Duration.zero, true);
      a.recordSearch(0, Duration.zero, true);
      a.recordSearch(0, Duration.zero, false);
      expect(a.cacheHitRate, closeTo(0.667, 0.01));
    });

    test('toJson/fromJson round-trip', () {
      final a = SearchAnalytics(query: 'round');
      a.recordSearch(5, const Duration(milliseconds: 50), true);
      a.recordSearch(15, const Duration(milliseconds: 150), false);

      final json = a.toJson();
      final restored = SearchAnalytics.fromJson(json);
      expect(restored.query, 'round');
      expect(restored.searchCount, 2);
      expect(restored.totalResults, 20);
      expect(restored.totalSearchTime.inMilliseconds, 200);
      expect(restored.cacheHits, 1);
    });
  });

  // ─── SearchAnalyticsSummary ───────────────────────────────────────────
  group('SearchAnalyticsSummary', () {
    test('stores all required fields', () {
      final ts = DateTime(2025, 1, 1);
      final s = SearchAnalyticsSummary(
        query: 'test',
        resultCount: 42,
        searchTime: const Duration(milliseconds: 99),
        cacheHit: true,
        timestamp: ts,
      );
      expect(s.query, 'test');
      expect(s.resultCount, 42);
      expect(s.searchTime.inMilliseconds, 99);
      expect(s.cacheHit, isTrue);
      expect(s.timestamp, ts);
    });
  });

  // ─── SearchAnalyticsReport ────────────────────────────────────────────
  group('SearchAnalyticsReport', () {
    test('empty factory creates zeroed report', () {
      final r = SearchAnalyticsReport.empty();
      expect(r.totalSearches, 0);
      expect(r.uniqueQueries, 0);
      expect(r.averageResultsPerSearch, 0.0);
      expect(r.averageSearchTime, Duration.zero);
      expect(r.topQueries, isEmpty);
      expect(r.hourlySearchPatterns, isEmpty);
      expect(r.successRate, 0.0);
      expect(r.cacheHitRate, 0.0);
      expect(r.scope, SearchAnalyticsScope.all);
    });
  });

  // ─── ArchiveSearchEvent factories ─────────────────────────────────────
  group('ArchiveSearchEvent', () {
    test('started creates event with timestamp', () {
      final e = ArchiveSearchEvent.started('s1', 'query');
      expect(e.timestamp, isNotNull);
      expect(e, isA<ArchiveSearchEvent>());
    });

    test('completed creates event with result', () {
      final result = AdvancedSearchResult.error(
        query: 'q',
        error: 'err',
        searchTime: Duration.zero,
      );
      final e = ArchiveSearchEvent.completed('s2', result);
      expect(e.timestamp, isNotNull);
    });

    test('failed creates event with error', () {
      final e = ArchiveSearchEvent.failed('s3', 'q', 'boom');
      expect(e.timestamp, isNotNull);
    });
  });

  // ─── SearchSuggestionEvent ────────────────────────────────────────────
  group('SearchSuggestionEvent', () {
    test('generated creates event with suggestions', () {
      final suggestions = [SearchSuggestion.relatedTerm('x')];
      final e = SearchSuggestionEvent.generated('q', suggestions);
      expect(e.timestamp, isNotNull);
    });
  });

  // ─── Cache classes ────────────────────────────────────────────────────
  group('SearchResultCache', () {
    test('stores result and timestamp', () {
      final result = AdvancedSearchResult.error(
        query: 'q',
        error: 'err',
        searchTime: Duration.zero,
      );
      final cache = SearchResultCache(
        result: result,
        cachedAt: DateTime.now(),
      );
      expect(cache.result.query, 'q');
      expect(cache.cachedAt, isNotNull);
    });
  });

  group('SearchSuggestionCache', () {
    test('stores suggestions and timestamp', () {
      final cache = SearchSuggestionCache(
        suggestions: [SearchSuggestion.refinement('r')],
        cachedAt: DateTime.now(),
      );
      expect(cache.suggestions, hasLength(1));
    });
  });

  // ─── FirstWhereOrNullExtension ────────────────────────────────────────
  group('FirstWhereOrNullExtension', () {
    test('returns first element for non-empty iterable', () {
      expect([1, 2, 3].firstOrNull, 1);
    });

    test('returns null for empty iterable', () {
      expect(<int>[].firstOrNull, isNull);
    });

    test('works on sets', () {
      expect({42}.firstOrNull, 42);
    });

    test('works on empty set', () {
      expect(<String>{}.firstOrNull, isNull);
    });
  });

  // ─── Enums ────────────────────────────────────────────────────────────
  group('Enum coverage', () {
    test('TemporalSearchMode values', () {
      expect(TemporalSearchMode.values, hasLength(3));
      expect(TemporalSearchMode.archived.index, 0);
      expect(TemporalSearchMode.original.index, 1);
      expect(TemporalSearchMode.recent.index, 2);
    });

    test('SearchStrategy values', () {
      expect(SearchStrategy.values, hasLength(5));
    });

    test('SearchOperator values', () {
      expect(SearchOperator.values, hasLength(4));
    });

    test('SearchSuggestionType values', () {
      expect(SearchSuggestionType.values, hasLength(5));
    });

    test('SearchAnalyticsScope values', () {
      expect(SearchAnalyticsScope.values, hasLength(3));
    });
  });
}
