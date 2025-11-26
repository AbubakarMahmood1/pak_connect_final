// Search cache manager for result and suggestion caching
// Extracted from ArchiveSearchService as part of Phase 4D refactoring

import 'package:logging/logging.dart';
import 'archive_search_models.dart';

/// Callback for cache invalidation events
typedef CacheInvalidationCallback = void Function(String cacheKey);

/// Manages search result and suggestion caching with expiry and size limits
/// Single writer pattern - all cache mutations go through this manager
class SearchCacheManager {
  static final _logger = Logger('SearchCacheManager');

  // Cache storage
  final Map<String, SearchResultCache> _searchCache = {};
  final Map<String, SearchSuggestionCache> _suggestionCache = {};

  // Configuration (injected)
  final SearchServiceConfig Function() _getConfig;

  // Optional callbacks for cache events (used by facade)
  CacheInvalidationCallback? onCacheInvalidated;
  CacheInvalidationCallback? onSuggestionCacheInvalidated;

  SearchCacheManager({required SearchServiceConfig Function() getConfig})
    : _getConfig = getConfig {
    _logger.fine('SearchCacheManager initialized');
  }

  // ============================================================================
  // Search Result Cache Methods
  // ============================================================================

  /// Cache a search result
  void cacheSearchResult(String cacheKey, AdvancedSearchResult result) {
    _searchCache[cacheKey] = SearchResultCache(
      result: result,
      cachedAt: DateTime.now(),
    );

    _maintainSearchCacheSize();
    _logger.fine('Cached search result: $cacheKey');
  }

  /// Get cached search result if valid, otherwise null
  AdvancedSearchResult? getCachedResult(String cacheKey) {
    if (_searchCache.containsKey(cacheKey) && _isCacheValid(cacheKey)) {
      _logger.fine('Cache hit: $cacheKey');
      return _searchCache[cacheKey]!.result;
    }

    _logger.fine('Cache miss: $cacheKey');
    return null;
  }

  /// Check if cache entry is still valid
  bool _isCacheValid(String cacheKey) {
    final cache = _searchCache[cacheKey];
    if (cache == null) return false;

    final age = DateTime.now().difference(cache.cachedAt);
    return age.inMinutes < _getConfig().cacheValidityMinutes;
  }

  /// Maintain search cache size limit
  void _maintainSearchCacheSize() {
    final maxSize = _getConfig().maxCacheSize;

    while (_searchCache.length > maxSize) {
      final oldestKey = _searchCache.keys.first;
      _searchCache.remove(oldestKey);
      _logger.fine('Evicted old cache entry: $oldestKey');
    }
  }

  // ============================================================================
  // Suggestion Cache Methods
  // ============================================================================

  /// Cache search suggestions
  void cacheSuggestions(String cacheKey, List<SearchSuggestion> suggestions) {
    _suggestionCache[cacheKey] = SearchSuggestionCache(
      suggestions: suggestions,
      cachedAt: DateTime.now(),
    );

    _maintainSuggestionCacheSize();
    _logger.fine('Cached suggestions: $cacheKey');
  }

  /// Get cached suggestions if valid, otherwise null
  List<SearchSuggestion>? getCachedSuggestions(String cacheKey) {
    if (_suggestionCache.containsKey(cacheKey) &&
        _isSuggestionCacheValid(cacheKey)) {
      _logger.fine('Suggestion cache hit: $cacheKey');
      return _suggestionCache[cacheKey]!.suggestions;
    }

    _logger.fine('Suggestion cache miss: $cacheKey');
    return null;
  }

  /// Check if suggestion cache entry is still valid
  bool _isSuggestionCacheValid(String cacheKey) {
    final cache = _suggestionCache[cacheKey];
    if (cache == null) return false;

    final age = DateTime.now().difference(cache.cachedAt);
    return age.inMinutes < 5; // Short cache for suggestions (5 minutes)
  }

  /// Maintain suggestion cache size limit (half of main cache)
  void _maintainSuggestionCacheSize() {
    final maxSize = _getConfig().maxCacheSize ~/ 2;

    while (_suggestionCache.length > maxSize) {
      final oldestKey = _suggestionCache.keys.first;
      _suggestionCache.remove(oldestKey);
      _logger.fine('Evicted old suggestion cache entry: $oldestKey');
    }
  }

  // ============================================================================
  // Cache Invalidation Methods
  // ============================================================================

  /// Invalidate a specific search cache entry
  void invalidateSearchCache(String cacheKey) {
    if (_searchCache.remove(cacheKey) != null) {
      _logger.info('Invalidated search cache: $cacheKey');
      onCacheInvalidated?.call(cacheKey);
    }
  }

  /// Invalidate a specific suggestion cache entry
  void invalidateSuggestionCache(String cacheKey) {
    if (_suggestionCache.remove(cacheKey) != null) {
      _logger.info('Invalidated suggestion cache: $cacheKey');
      onSuggestionCacheInvalidated?.call(cacheKey);
    }
  }

  /// Clear all caches (search results + suggestions)
  void clearAllCaches() {
    final searchCount = _searchCache.length;
    final suggestionCount = _suggestionCache.length;

    _searchCache.clear();
    _suggestionCache.clear();

    _logger.info(
      'Cleared all caches ($searchCount search results, $suggestionCount suggestions)',
    );
  }

  /// Clear only expired cache entries
  void clearExpiredCaches() {
    // Remove expired search results
    final expiredSearchKeys = _searchCache.keys
        .where((key) => !_isCacheValid(key))
        .toList();

    for (final key in expiredSearchKeys) {
      _searchCache.remove(key);
    }

    // Remove expired suggestions
    final expiredSuggestionKeys = _suggestionCache.keys
        .where((key) => !_isSuggestionCacheValid(key))
        .toList();

    for (final key in expiredSuggestionKeys) {
      _suggestionCache.remove(key);
    }

    if (expiredSearchKeys.isNotEmpty || expiredSuggestionKeys.isNotEmpty) {
      _logger.info(
        'Cleared expired caches (${expiredSearchKeys.length} search results, ${expiredSuggestionKeys.length} suggestions)',
      );
    }
  }

  // ============================================================================
  // Stats & Inspection
  // ============================================================================

  /// Get current cache statistics
  Map<String, int> getCacheStats() {
    return {
      'searchCacheSize': _searchCache.length,
      'suggestionCacheSize': _suggestionCache.length,
      'maxCacheSize': _getConfig().maxCacheSize,
      'maxSuggestionCacheSize': _getConfig().maxCacheSize ~/ 2,
    };
  }

  /// Check if search cache contains a key
  bool containsSearchCache(String cacheKey) =>
      _searchCache.containsKey(cacheKey);

  /// Check if suggestion cache contains a key
  bool containsSuggestionCache(String cacheKey) =>
      _suggestionCache.containsKey(cacheKey);
}
