import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class _FakeArchiveRepository implements IArchiveRepository {
  int searchCalls = 0;

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
  }

  // The remaining repository methods are not needed for these tests.
  @override
  Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async =>
      throw UnimplementedError();

  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async => throw UnimplementedError();

  @override
  Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async =>
      throw UnimplementedError();

  @override
  Future<int> getArchivedChatsCount() async => throw UnimplementedError();

  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async => const [];

  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(
    String chatId,
  ) async => throw UnimplementedError();

  @override
  Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async => null;

  @override
  Future<ArchiveStatistics?> getArchiveStatistics() async =>
      throw UnimplementedError();

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
    await GetIt.I.reset();
    repository = _FakeArchiveRepository();
    GetIt.I.registerSingleton<IArchiveRepository>(repository);

    service = ArchiveSearchService.instance;
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

  group('ArchiveSearchService integration', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

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

    test('uses cache on repeat searches and records analytics', () async {
      final result1 = await service.search(query: 'hello');
      expect(result1.query, 'hello');
      expect(repository.searchCalls, 1);

      final result2 = await service.search(query: 'hello');
      expect(result2.query, 'hello');
      expect(repository.searchCalls, 1, reason: 'second call should hit cache');

      expect(
        service.searchHistory.length,
        1,
        reason: 'history updated on miss only',
      );

      final analytics = await service.getSearchAnalytics();
      expect(analytics.cacheHitRate, closeTo(0.5, 0.01));
    });

    test('executes saved searches via history manager', () async {
      await service.saveSearch(name: 'saved', query: 'world');
      final savedId = service.savedSearches.first.id;

      final result = await service.executeSavedSearch(savedId);
      expect(result.query, 'world');
      expect(repository.searchCalls, 1);
      expect(service.searchHistory.length, 1);
    });

    test('suggestions include history and saved search entries', () async {
      // Populate history via search (cache miss).
      await service.search(query: 'hello world');

      // Add a saved search.
      await service.saveSearch(name: 'hello saved', query: 'hello query');

      final suggestions = await service.getSearchSuggestions(
        partialQuery: 'hello',
        limit: 10,
      );

      expect(
        suggestions.any((s) => s.type == SearchSuggestionType.history),
        isTrue,
      );
      expect(
        suggestions.any((s) => s.type == SearchSuggestionType.saved),
        isTrue,
      );
    });

    test(
      'updateConfiguration clears caches and forces repository lookup',
      () async {
        // First search populates cache.
        await service.search(query: 'ping');
        expect(repository.searchCalls, 1);

        // Second search should hit cache.
        await service.search(query: 'ping');
        expect(repository.searchCalls, 1);

        final prevConfig = service.configuration;
        final updatedConfig = SearchServiceConfig(
          enableFuzzySearch: prevConfig.enableFuzzySearch,
          maxCacheSize: prevConfig.maxCacheSize + 1,
          cacheValidityMinutes: prevConfig.cacheValidityMinutes,
          maxHistorySize: prevConfig.maxHistorySize,
          enableSuggestions: prevConfig.enableSuggestions,
          fuzzyThreshold: prevConfig.fuzzyThreshold,
        );

        await service.updateConfiguration(updatedConfig);

        // Cache cleared => repository called again.
        await service.search(query: 'ping');
        expect(repository.searchCalls, 2);
      },
    );
  });
}
