// SearchCacheManager coverage
// Targets: cacheSearchResult, getCachedResult, cacheSuggestions,
// getCachedSuggestions, invalidation, clearAll, clearExpired,
// getCacheStats, LRU eviction, containsX checks

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_search_models.dart';
import 'package:pak_connect/domain/services/search_cache_manager.dart';

AdvancedSearchResult _makeResult(String query) {
 return AdvancedSearchResult(searchResult: ArchiveSearchResult.empty(query),
 query: query,
 searchTime: const Duration(milliseconds: 50),
 suggestions: [],
);
}

SearchSuggestion _makeSuggestion(String text) {
 return SearchSuggestion(text: text,
 type: SearchSuggestionType.history,
 relevanceScore: 0.8,
);
}

void main() {
 Logger.root.level = Level.OFF;

 late SearchCacheManager manager;

 setUp(() {
 manager = SearchCacheManager(getConfig: () => SearchServiceConfig.defaultConfig(),
);
 });

 group('cacheSearchResult + getCachedResult', () {
 test('caches and retrieves result', () {
 final result = _makeResult('hello');
 manager.cacheSearchResult('key1', result);

 final cached = manager.getCachedResult('key1');
 expect(cached, isNotNull);
 expect(cached!.query, 'hello');
 });

 test('returns null for non-existent key', () {
 expect(manager.getCachedResult('missing'), isNull);
 });

 test('containsSearchCache reflects cached state', () {
 expect(manager.containsSearchCache('k'), isFalse);
 manager.cacheSearchResult('k', _makeResult('q'));
 expect(manager.containsSearchCache('k'), isTrue);
 });
 });

 group('cacheSuggestions + getCachedSuggestions', () {
 test('caches and retrieves suggestions', () {
 final suggestions = [_makeSuggestion('hello'), _makeSuggestion('world')];
 manager.cacheSuggestions('sug1', suggestions);

 final cached = manager.getCachedSuggestions('sug1');
 expect(cached, isNotNull);
 expect(cached!.length, 2);
 expect(cached[0].text, 'hello');
 });

 test('returns null for non-existent suggestion key', () {
 expect(manager.getCachedSuggestions('missing'), isNull);
 });

 test('containsSuggestionCache reflects state', () {
 expect(manager.containsSuggestionCache('s'), isFalse);
 manager.cacheSuggestions('s', [_makeSuggestion('t')]);
 expect(manager.containsSuggestionCache('s'), isTrue);
 });
 });

 group('cache invalidation', () {
 test('invalidateSearchCache removes entry and calls callback', () {
 String? callbackKey;
 manager.onCacheInvalidated = (key) => callbackKey = key;

 manager.cacheSearchResult('k1', _makeResult('q'));
 expect(manager.containsSearchCache('k1'), isTrue);

 manager.invalidateSearchCache('k1');
 expect(manager.containsSearchCache('k1'), isFalse);
 expect(callbackKey, 'k1');
 });

 test('invalidateSearchCache no-op for missing key', () {
 String? callbackKey;
 manager.onCacheInvalidated = (key) => callbackKey = key;

 manager.invalidateSearchCache('nonexistent');
 expect(callbackKey, isNull);
 });

 test('invalidateSuggestionCache removes entry and calls callback', () {
 String? callbackKey;
 manager.onSuggestionCacheInvalidated = (key) => callbackKey = key;

 manager.cacheSuggestions('s1', [_makeSuggestion('x')]);
 manager.invalidateSuggestionCache('s1');

 expect(manager.containsSuggestionCache('s1'), isFalse);
 expect(callbackKey, 's1');
 });

 test('invalidateSuggestionCache no-op for missing key', () {
 String? callbackKey;
 manager.onSuggestionCacheInvalidated = (key) => callbackKey = key;

 manager.invalidateSuggestionCache('nonexistent');
 expect(callbackKey, isNull);
 });
 });

 group('clearAllCaches', () {
 test('clears both search and suggestion caches', () {
 manager.cacheSearchResult('a', _makeResult('q'));
 manager.cacheSuggestions('b', [_makeSuggestion('s')]);

 manager.clearAllCaches();

 expect(manager.containsSearchCache('a'), isFalse);
 expect(manager.containsSuggestionCache('b'), isFalse);
 });
 });

 group('clearExpiredCaches', () {
 test('removes expired entries only', () {
 // Use a config with very short validity (0 minutes = immediate expiry)
 manager = SearchCacheManager(getConfig: () => const SearchServiceConfig(enableFuzzySearch: true,
 maxCacheSize: 100,
 cacheValidityMinutes: 0, // immediately expired
 maxHistorySize: 500,
 enableSuggestions: true,
 fuzzyThreshold: 0.7,
),
);

 manager.cacheSearchResult('expired', _makeResult('old'));

 // Should clear expired
 manager.clearExpiredCaches();
 expect(manager.containsSearchCache('expired'), isFalse);
 });

 test('keeps non-expired entries', () {
 // Default config: 30 min validity
 manager.cacheSearchResult('fresh', _makeResult('new'));

 manager.clearExpiredCaches();
 expect(manager.containsSearchCache('fresh'), isTrue);
 });
 });

 group('getCacheStats', () {
 test('returns correct statistics', () {
 manager.cacheSearchResult('s1', _makeResult('q1'));
 manager.cacheSearchResult('s2', _makeResult('q2'));
 manager.cacheSuggestions('sg1', [_makeSuggestion('a')]);

 final stats = manager.getCacheStats();
 expect(stats['searchCacheSize'], 2);
 expect(stats['suggestionCacheSize'], 1);
 expect(stats['maxCacheSize'], 100);
 expect(stats['maxSuggestionCacheSize'], 50);
 });
 });

 group('LRU eviction', () {
 test('search cache evicts oldest when exceeding maxCacheSize', () {
 manager = SearchCacheManager(getConfig: () => const SearchServiceConfig(enableFuzzySearch: true,
 maxCacheSize: 3,
 cacheValidityMinutes: 30,
 maxHistorySize: 500,
 enableSuggestions: true,
 fuzzyThreshold: 0.7,
),
);

 manager.cacheSearchResult('k1', _makeResult('q1'));
 manager.cacheSearchResult('k2', _makeResult('q2'));
 manager.cacheSearchResult('k3', _makeResult('q3'));
 // k4 pushes past limit → k1 evicted
 manager.cacheSearchResult('k4', _makeResult('q4'));

 expect(manager.containsSearchCache('k1'), isFalse);
 expect(manager.containsSearchCache('k4'), isTrue);
 expect(manager.getCacheStats()['searchCacheSize'], 3);
 });

 test('suggestion cache evicts oldest at half maxCacheSize', () {
 manager = SearchCacheManager(getConfig: () => const SearchServiceConfig(enableFuzzySearch: true,
 maxCacheSize: 4, // suggestion max = 2
 cacheValidityMinutes: 30,
 maxHistorySize: 500,
 enableSuggestions: true,
 fuzzyThreshold: 0.7,
),
);

 manager.cacheSuggestions('s1', [_makeSuggestion('a')]);
 manager.cacheSuggestions('s2', [_makeSuggestion('b')]);
 // s3 pushes past limit → s1 evicted
 manager.cacheSuggestions('s3', [_makeSuggestion('c')]);

 expect(manager.containsSuggestionCache('s1'), isFalse);
 expect(manager.containsSuggestionCache('s3'), isTrue);
 expect(manager.getCacheStats()['suggestionCacheSize'], 2);
 });
 });

 group('cache expiry via getCachedResult', () {
 test('expired result returns null', () {
 manager = SearchCacheManager(getConfig: () => const SearchServiceConfig(enableFuzzySearch: true,
 maxCacheSize: 100,
 cacheValidityMinutes: 0,
 maxHistorySize: 500,
 enableSuggestions: true,
 fuzzyThreshold: 0.7,
),
);

 manager.cacheSearchResult('k', _makeResult('q'));
 // With 0 min validity, should be expired immediately
 expect(manager.getCachedResult('k'), isNull);
 });
 });
}
