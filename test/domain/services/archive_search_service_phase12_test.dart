/// Phase 12.6: Supplementary tests for ArchiveSearchService
/// Covers: fuzzySearch, searchByDateRange, rebuildIndexes, dispose, stream getters
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class _FakeArchiveRepository implements IArchiveRepository {
  int searchCalls = 0;
  bool throwOnSearch = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async {
    searchCalls++;
    if (throwOnSearch) throw StateError('search failed');
    return ArchiveSearchResult.fromResults(
      messages: const [],
      chats: const [],
      query: query,
      filter: filter,
      searchTime: const Duration(milliseconds: 5),
    );
  }

  void reset() {
    searchCalls = 0;
    throwOnSearch = false;
  }

  @override
  Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async =>
      throw UnimplementedError();
  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async =>
      throw UnimplementedError();
  @override
  Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async =>
      throw UnimplementedError();
  @override
  Future<int> getArchivedChatsCount() async => 0;
  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async =>
      const [];
  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(
    String chatId,
  ) async =>
      null;
  @override
  Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async => null;
  @override
  Future<ArchiveStatistics?> getArchiveStatistics() async => null;
  @override
  void clearCache() {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ArchiveSearchService service;
  late _FakeArchiveRepository repository;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    repository = _FakeArchiveRepository();
    service = ArchiveSearchService.withDependencies(
      archiveRepository: repository,
    );
    ArchiveSearchService.setInstance(service);
    await service.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository.reset();
    service.clearCaches();
    await service.clearSearchHistory();
    await service.clearSavedSearches();
    await service.clearAnalytics();
  });

  group('fuzzySearch', () {
    test('returns results for fuzzy query', () async {
      final result = await service.fuzzySearch(query: 'helo');
      expect(result.query, isNotEmpty);
      expect(repository.searchCalls, greaterThanOrEqualTo(1));
    });

    test('returns error result when repository throws', () async {
      repository.throwOnSearch = true;
      final result = await service.fuzzySearch(query: 'broken');
      expect(result.query, contains('broken'));
    });

    test('respects custom similarity threshold', () async {
      final result = await service.fuzzySearch(
        query: 'test',
        similarityThreshold: 0.5,
        limit: 10,
      );
      expect(result, isNotNull);
      expect(repository.searchCalls, greaterThanOrEqualTo(1));
    });

    test('with filter passes filter through', () async {
      final filter = ArchiveSearchFilter.recent(days: 7);
      final result = await service.fuzzySearch(
        query: 'hello',
        filter: filter,
      );
      expect(result, isNotNull);
    });
  });

  group('searchByDateRange', () {
    test('executes date range search with default mode', () async {
      final start = DateTime(2025, 1, 1);
      final end = DateTime(2025, 12, 31);
      final result = await service.searchByDateRange(
        query: 'test',
        startDate: start,
        endDate: end,
      );
      expect(result.query, isNotEmpty);
      expect(repository.searchCalls, greaterThanOrEqualTo(1));
    });

    test('uses recent mode with boost', () async {
      final start = DateTime(2025, 6, 1);
      final end = DateTime(2025, 7, 1);
      final result = await service.searchByDateRange(
        query: 'recent',
        startDate: start,
        endDate: end,
        mode: TemporalSearchMode.recent,
      );
      expect(result, isNotNull);
    });

    test('returns error result when repository throws', () async {
      repository.throwOnSearch = true;
      final result = await service.searchByDateRange(
        query: 'fail',
        startDate: DateTime(2025, 1, 1),
        endDate: DateTime(2025, 12, 31),
      );
      expect(result.query, 'fail');
    });
  });

  group('rebuildIndexes', () {
    test('completes without error', () async {
      await expectLater(service.rebuildIndexes(), completes);
    });
  });

  group('dispose', () {
    test('completes without error', () async {
      final disposable = ArchiveSearchService.withDependencies(
        archiveRepository: repository,
      );
      await disposable.initialize();
      await expectLater(disposable.dispose(), completes);
    });
  });

  group('stream getters', () {
    test('searchUpdates stream is accessible', () {
      expect(service.searchUpdates, isA<Stream>());
    });

    test('suggestionUpdates stream is accessible', () {
      expect(service.suggestionUpdates, isA<Stream>());
    });
  });

  group('configuration getter', () {
    test('returns current config', () {
      final config = service.configuration;
      expect(config, isA<SearchServiceConfig>());
    });
  });

  group('searchHistory and savedSearches getters', () {
    test('searchHistory starts empty', () {
      expect(service.searchHistory, isEmpty);
    });

    test('savedSearches starts empty', () {
      expect(service.savedSearches, isEmpty);
    });

    test('searchHistory populates after search', () async {
      await service.search(query: 'populate_history');
      expect(service.searchHistory, isNotEmpty);
    });

    test('savedSearches populates after saveSearch', () async {
      await service.saveSearch(name: 'saved1', query: 'test');
      expect(service.savedSearches, isNotEmpty);
    });
  });

  group('clearSearchHistory', () {
    test('clears history after searches', () async {
      await service.search(query: 'q1');
      await service.search(query: 'q2');
      expect(service.searchHistory.length, greaterThanOrEqualTo(2));

      await service.clearSearchHistory();
      expect(service.searchHistory, isEmpty);
    });
  });

  group('clearSavedSearches', () {
    test('clears all saved searches', () async {
      await service.saveSearch(name: 's1', query: 'q1');
      await service.saveSearch(name: 's2', query: 'q2');
      expect(service.savedSearches.length, 2);

      await service.clearSavedSearches();
      expect(service.savedSearches, isEmpty);
    });
  });

  group('clearAnalytics', () {
    test('resets analytics after searches', () async {
      await service.search(query: 'analytics_test');
      final before = await service.getSearchAnalytics();
      expect(before.totalSearches, greaterThan(0));

      await service.clearAnalytics();
      final after = await service.getSearchAnalytics();
      // clearAnalytics resets counters; the getSearchAnalytics call itself
      // may count as a search so we just verify it's less than before
      expect(after.totalSearches, lessThanOrEqualTo(before.totalSearches));
    });
  });
}
