import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/services/search_cache_manager.dart';
import 'package:pak_connect/domain/services/search_history_manager.dart';
import 'package:pak_connect/domain/services/search_analytics_tracker.dart';
import 'package:pak_connect/domain/services/archive_search_models.dart';
import 'package:pak_connect/domain/models/archive_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AdvancedSearchResult buildResult(String query, {int totalResults = 1}) {
    final searchResult = ArchiveSearchResult(
      messages: const [],
      chats: const [],
      messagesByChat: const {},
      query: query,
      filter: null,
      totalResults: totalResults,
      totalChatsFound: 0,
      searchTime: const Duration(milliseconds: 10),
      hasMore: false,
      metadata: ArchiveSearchMetadata.empty(),
    );

    return AdvancedSearchResult.fromSearchResult(
      searchResult: searchResult,
      query: query,
      parsedQuery: null,
      searchTime: const Duration(milliseconds: 10),
      searchStrategy: SearchStrategy.simple,
      suggestions: const [],
    );
  }

  group('SearchCacheManager', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    final config = SearchServiceConfig(
      enableFuzzySearch: false,
      maxCacheSize: 2,
      cacheValidityMinutes: 30,
      maxHistorySize: 10,
      enableSuggestions: true,
      fuzzyThreshold: 0.7,
    );

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('caches results and evicts oldest when max size exceeded', () {
      final manager = SearchCacheManager(getConfig: () => config);

      final result1 = buildResult('first');
      final result2 = buildResult('second');
      final result3 = buildResult('third');

      manager.cacheSearchResult('k1', result1);
      manager.cacheSearchResult('k2', result2);
      manager.cacheSearchResult('k3', result3);

      expect(manager.getCachedResult('k1'), isNull);
      expect(manager.getCachedResult('k2'), isNotNull);
      expect(manager.getCachedResult('k3'), isNotNull);
    });

    test('caches suggestions per key', () {
      final manager = SearchCacheManager(getConfig: () => config);
      final suggestions = [
        SearchSuggestion.contentBased('hello', 2),
        SearchSuggestion.relatedTerm('hi'),
      ];

      manager.cacheSuggestions('s1', suggestions);

      expect(manager.getCachedSuggestions('s1'), suggestions);
      expect(manager.getCachedSuggestions('missing'), isNull);
    });
  });

  group('SearchHistoryManager', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    final config = SearchServiceConfig(
      enableFuzzySearch: false,
      maxCacheSize: 5,
      cacheValidityMinutes: 30,
      maxHistorySize: 2,
      enableSuggestions: true,
      fuzzyThreshold: 0.7,
    );

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('trims history to maxHistorySize', () async {
      final manager = SearchHistoryManager(getConfig: () => config);
      await manager.initialize();

      await manager.addToHistory('one', buildResult('one'));
      await manager.addToHistory('two', buildResult('two'));
      await manager.addToHistory('three', buildResult('three'));

      final history = manager.getHistory();
      expect(history.length, 2);
      expect(history.first.query, 'two');
      expect(history.last.query, 'three');
    });

    test('saves and deletes saved searches', () async {
      final manager = SearchHistoryManager(getConfig: () => config);
      await manager.initialize();

      await manager.saveSearch(
        id: 'saved-1',
        name: 'Recent',
        query: 'chat:alice',
        filter: ArchiveSearchFilter.recent(days: 7),
      );

      expect(manager.getSavedSearches(), hasLength(1));
      expect(manager.getSavedSearchById('saved-1')?.name, 'Recent');

      await manager.deleteSavedSearch('saved-1');
      expect(manager.getSavedSearches(), isEmpty);
    });
  });

  group('SearchAnalyticsTracker', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('records searches and produces reports', () async {
      final tracker = SearchAnalyticsTracker();
      await tracker.initialize();

      final result = buildResult('query', totalResults: 2);
      await tracker.recordSearch(
        query: 'query',
        result: result,
        searchTime: const Duration(milliseconds: 20),
        cacheHit: true,
      );

      expect(tracker.totalSearches, 1);
      expect(tracker.getCacheHitRate(), closeTo(1.0, 0.001));

      final history = [
        ArchiveSearchEntry(
          query: 'query',
          resultCount: 2,
          searchTime: const Duration(milliseconds: 20),
          timestamp: DateTime.now(),
        ),
      ];

      final report = await tracker.getAnalyticsReport(searchHistory: history);

      expect(report.totalSearches, 1);
      expect(report.uniqueQueries, 1);
      expect(report.cacheHitRate, greaterThan(0.9));
    });
  });
}
