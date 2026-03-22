import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/archive_provider.dart';

class _TestArchiveManagementService implements ArchiveManagementService {
  _TestArchiveManagementService({
    required this.archiveUpdatesStream,
    Stream<ArchivePolicyEvent>? policyUpdatesStream,
    Stream<ArchiveMaintenanceEvent>? maintenanceUpdatesStream,
  }) : policyUpdatesStream = policyUpdatesStream ?? const Stream.empty(),
       maintenanceUpdatesStream =
           maintenanceUpdatesStream ?? const Stream.empty();

  final Stream<ArchiveUpdateEvent> archiveUpdatesStream;
  final Stream<ArchivePolicyEvent> policyUpdatesStream;
  final Stream<ArchiveMaintenanceEvent> maintenanceUpdatesStream;

  int initializeCalls = 0;
  int archiveChatCalls = 0;
  int restoreChatCalls = 0;
  int getSummariesCalls = 0;

  ArchiveSearchFilter? lastFilter;
  int? lastLimit;
  int? lastOffset;
  String? lastArchiveChatId;
  String? lastArchiveReason;
  Map<String, dynamic>? lastArchiveMetadata;
  bool? lastArchiveForce;
  ArchiveId? lastRestoreArchiveId;
  String? lastRestoreTargetChatId;
  bool? lastRestoreOverwriteExisting;

  Future<ArchiveAnalytics> Function()? analyticsHandler;
  Future<List<EnhancedArchiveSummary>> Function({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  })?
  summariesHandler;
  Future<ArchiveOperationResult> Function({
    required String chatId,
    String? reason,
    Map<String, dynamic>? metadata,
    bool force,
  })?
  archiveHandler;
  Future<ArchiveOperationResult> Function({
    required ArchiveId archiveId,
    String? targetChatId,
    bool overwriteExisting,
  })?
  restoreHandler;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Stream<ArchiveUpdateEvent> get archiveUpdates => archiveUpdatesStream;

  @override
  Stream<ArchivePolicyEvent> get policyUpdates => policyUpdatesStream;

  @override
  Stream<ArchiveMaintenanceEvent> get maintenanceUpdates =>
      maintenanceUpdatesStream;

  @override
  Future<ArchiveAnalytics> getArchiveAnalytics({
    DateTime? since,
    ArchiveAnalyticsScope scope = ArchiveAnalyticsScope.all,
  }) async {
    if (analyticsHandler != null) return analyticsHandler!();
    return ArchiveAnalytics.empty();
  }

  @override
  Future<List<EnhancedArchiveSummary>> getEnhancedArchiveSummaries({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async {
    getSummariesCalls++;
    lastFilter = filter;
    lastLimit = limit;
    lastOffset = offset;
    if (summariesHandler != null) {
      return summariesHandler!(filter: filter, limit: limit, offset: offset);
    }
    return const [];
  }

  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? reason,
    Map<String, dynamic>? metadata,
    bool force = false,
  }) async {
    archiveChatCalls++;
    lastArchiveChatId = chatId;
    lastArchiveReason = reason;
    lastArchiveMetadata = metadata;
    lastArchiveForce = force;
    if (archiveHandler != null) {
      return archiveHandler!(
        chatId: chatId,
        reason: reason,
        metadata: metadata,
        force: force,
      );
    }
    return ArchiveOperationResult.success(
      message: 'ok',
      operationType: ArchiveOperationType.archive,
      operationTime: Duration.zero,
    );
  }

  @override
  Future<ArchiveOperationResult> restoreChat({
    required ArchiveId archiveId,
    String? targetChatId,
    bool overwriteExisting = false,
  }) async {
    restoreChatCalls++;
    lastRestoreArchiveId = archiveId;
    lastRestoreTargetChatId = targetChatId;
    lastRestoreOverwriteExisting = overwriteExisting;
    if (restoreHandler != null) {
      return restoreHandler!(
        archiveId: archiveId,
        targetChatId: targetChatId,
        overwriteExisting: overwriteExisting,
      );
    }
    return ArchiveOperationResult.success(
      message: 'restored',
      operationType: ArchiveOperationType.restore,
      operationTime: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestArchiveSearchService implements ArchiveSearchService {
  int initializeCalls = 0;
  int searchCalls = 0;
  int suggestionCalls = 0;

  String? lastSearchQuery;
  ArchiveSearchFilter? lastSearchFilter;
  SearchOptions? lastSearchOptions;
  int? lastSearchLimit;
  String? lastPartialQuery;
  int? lastSuggestionLimit;

  Future<AdvancedSearchResult> Function({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    int limit,
  })?
  searchHandler;
  Future<List<SearchSuggestion>> Function({
    required String partialQuery,
    int limit,
  })?
  suggestionsHandler;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<AdvancedSearchResult> search({
    required String query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    int limit = 50,
  }) async {
    searchCalls++;
    lastSearchQuery = query;
    lastSearchFilter = filter;
    lastSearchOptions = options;
    lastSearchLimit = limit;
    if (searchHandler != null) {
      return searchHandler!(
        query: query,
        filter: filter,
        options: options,
        limit: limit,
      );
    }
    return AdvancedSearchResult.error(
      query: query,
      error: 'not configured',
      searchTime: Duration.zero,
    );
  }

  @override
  Future<List<SearchSuggestion>> getSearchSuggestions({
    required String partialQuery,
    int limit = 10,
  }) async {
    suggestionCalls++;
    lastPartialQuery = partialQuery;
    lastSuggestionLimit = limit;
    if (suggestionsHandler != null) {
      return suggestionsHandler!(partialQuery: partialQuery, limit: limit);
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ArchiveStatistics _statistics({required int totalArchives}) {
  return ArchiveStatistics(
    totalArchives: totalArchives,
    totalMessages: 12,
    compressedArchives: 3,
    searchableArchives: 4,
    totalSizeBytes: 2048,
    compressedSizeBytes: 1024,
    archivesByMonth: const {'2026-03': 4},
    messagesByContact: const {'Alice': 12},
    averageCompressionRatio: 0.5,
    averageArchiveAge: const Duration(days: 2),
    performanceStats: ArchivePerformanceStats.empty(),
  );
}

ArchiveAnalytics _analytics(ArchiveStatistics statistics) {
  return ArchiveAnalytics(
    statistics: statistics,
    businessMetrics: ArchiveBusinessMetrics.empty(),
    policyMetrics: ArchivePolicyMetrics.empty(),
    performanceTrends: ArchivePerformanceTrends.empty(),
    storageMetrics: ArchiveStorageMetrics.empty(),
    generatedAt: DateTime(2026, 3, 1),
    scope: ArchiveAnalyticsScope.all,
  );
}

EnhancedArchiveSummary _enhancedSummary({
  required String archiveId,
  required String chatId,
  required String contactName,
}) {
  final summary = ArchivedChatSummary(
    id: ArchiveId(archiveId),
    originalChatId: ChatId(chatId),
    contactName: contactName,
    archivedAt: DateTime(2026, 3, 1),
    messageCount: 4,
    estimatedSize: 512,
    isCompressed: false,
    tags: const ['tag-a'],
    isSearchable: true,
  );
  return EnhancedArchiveSummary.fromSummary(
    summary,
    ArchiveBusinessMetadata.empty(),
  );
}

AdvancedSearchResult _searchResult(String query) {
  return AdvancedSearchResult.fromSearchResult(
    searchResult: ArchiveSearchResult.empty(query),
    query: query,
    searchTime: const Duration(milliseconds: 20),
    suggestions: const [],
  );
}

void main() {
  group('archive provider state models', () {
    test('ArchiveOperationsState copyWith and active-operation flag', () {
      const initial = ArchiveOperationsState();
      expect(initial.hasActiveOperation, isFalse);

      final busy = initial.copyWith(
        isArchiving: true,
        currentOperation: 'Archiving chat...',
      );
      expect(busy.hasActiveOperation, isTrue);
      expect(busy.currentOperation, 'Archiving chat...');

      final reset = busy.copyWith(isArchiving: false, currentOperation: null);
      expect(reset.hasActiveOperation, isFalse);
    });

    test('ArchiveListFilter copyWith applies overrides', () {
      const filter = ArchiveListFilter(limit: 10, ascending: false);
      final updated = filter.copyWith(limit: 25, ascending: true);

      expect(updated.limit, 25);
      expect(updated.ascending, isTrue);
      expect(updated.searchFilter, filter.searchFilter);
    });

    test('ArchiveSearchQuery copyWith/equality/hashCode are stable', () {
      const query = ArchiveSearchQuery(query: 'hello');
      final updated = query.copyWith(limit: 20);

      expect(updated.limit, 20);
      expect(query == const ArchiveSearchQuery(query: 'hello'), isTrue);
      expect(query.hashCode, const ArchiveSearchQuery(query: 'hello').hashCode);
    });

    test('ArchiveUIState copyWith updates selected fields', () {
      const state = ArchiveUIState();
      final updated = state.copyWith(
        isSearchMode: true,
        searchQuery: 'alice',
        selectedArchiveId: const ArchiveId('archive-1'),
        showStatistics: false,
      );

      expect(updated.isSearchMode, isTrue);
      expect(updated.searchQuery, 'alice');
      expect(updated.selectedArchiveId, const ArchiveId('archive-1'));
      expect(updated.showStatistics, isFalse);
    });
  });

  group('archive service-backed providers', () {
    test('management/search providers use injected overrides', () async {
      final updates = StreamController<ArchiveUpdateEvent>.broadcast();
      addTearDown(updates.close);

      final management = _TestArchiveManagementService(
        archiveUpdatesStream: updates.stream,
      );
      final search = _TestArchiveSearchService();

      final container = ProviderContainer(
        overrides: [
          archiveManagementServiceProvider.overrideWithValue(management),
          archiveSearchServiceProvider.overrideWithValue(search),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(archiveManagementServiceProvider), management);
      expect(container.read(archiveSearchServiceProvider), search);

      await Future<void>.delayed(Duration.zero);
      // overrideWithValue bypasses provider factory initialization hooks.
      expect(management.initializeCalls, 0);
      expect(search.initializeCalls, 0);
    });

    test(
      'archiveStatisticsProvider returns service analytics statistics',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        final expectedStats = _statistics(totalArchives: 7);
        management.analyticsHandler = () async => _analytics(expectedStats);

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
          ],
        );
        addTearDown(container.dispose);

        final stats = await container.read(archiveStatisticsProvider.future);
        expect(stats.totalArchives, 7);
        expect(stats.totalMessages, expectedStats.totalMessages);
      },
    );

    test(
      'archiveStatisticsProvider returns empty statistics on failure',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        management.analyticsHandler = () async =>
            throw Exception('analytics-failed');

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
          ],
        );
        addTearDown(container.dispose);

        final stats = await container.read(archiveStatisticsProvider.future);
        expect(stats.totalArchives, 0);
        expect(stats.totalMessages, 0);
      },
    );

    test(
      'archiveListProvider maps enhanced summaries and filter paging args',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        final searchFilter = ArchiveSearchFilter.forContact('Alice');
        final filter = ArchiveListFilter(
          searchFilter: searchFilter,
          limit: 20,
          afterCursor: '12',
        );
        management.summariesHandler =
            ({ArchiveSearchFilter? filter, int? limit, int? offset}) async => [
              _enhancedSummary(
                archiveId: 'archive-1',
                chatId: 'chat-1',
                contactName: 'Alice',
              ),
            ];

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
          ],
        );
        addTearDown(container.dispose);

        final summaries = await container.read(
          archiveListProvider(filter).future,
        );
        expect(summaries, hasLength(1));
        expect(summaries.first.contactName, 'Alice');
        expect(summaries.first.id, const ArchiveId('archive-1'));
        expect(management.lastFilter, searchFilter);
        expect(management.lastLimit, 20);
        expect(management.lastOffset, 12);
      },
    );

    test(
      'archiveListProvider returns empty list when service throws',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        management.summariesHandler =
            ({ArchiveSearchFilter? filter, int? limit, int? offset}) async =>
                throw Exception('list-failed');

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
          ],
        );
        addTearDown(container.dispose);

        final summaries = await container.read(
          archiveListProvider(null).future,
        );
        expect(summaries, isEmpty);
      },
    );

    test(
      'archiveSearchProvider rejects blank query without search call',
      () async {
        final search = _TestArchiveSearchService();

        final container = ProviderContainer(
          overrides: [archiveSearchServiceProvider.overrideWithValue(search)],
        );
        addTearDown(container.dispose);

        const query = ArchiveSearchQuery(query: '   ');
        final result = await container.read(
          archiveSearchProvider(query).future,
        );
        expect(result.hasError, isTrue);
        expect(result.error, 'Empty query');
        expect(search.searchCalls, 0);
      },
    );

    test('archiveSearchProvider delegates successful search', () async {
      final search = _TestArchiveSearchService();
      search.searchHandler =
          ({
            required String query,
            ArchiveSearchFilter? filter,
            SearchOptions? options,
            int limit = 50,
          }) async => _searchResult(query);
      const query = ArchiveSearchQuery(query: 'alpha', limit: 25);

      final container = ProviderContainer(
        overrides: [archiveSearchServiceProvider.overrideWithValue(search)],
      );
      addTearDown(container.dispose);

      final result = await container.read(archiveSearchProvider(query).future);
      expect(result.hasError, isFalse);
      expect(result.query, 'alpha');
      expect(search.searchCalls, 1);
      expect(search.lastSearchQuery, 'alpha');
      expect(search.lastSearchLimit, 25);
    });

    test(
      'archiveSearchProvider returns error result when service throws',
      () async {
        final search = _TestArchiveSearchService();
        search.searchHandler =
            ({
              required String query,
              ArchiveSearchFilter? filter,
              SearchOptions? options,
              int limit = 50,
            }) async => throw Exception('search exploded');
        const query = ArchiveSearchQuery(query: 'boom');

        final container = ProviderContainer(
          overrides: [archiveSearchServiceProvider.overrideWithValue(search)],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          archiveSearchProvider(query).future,
        );
        expect(result.hasError, isTrue);
        expect(result.error, contains('Search failed'));
        expect(search.searchCalls, 1);
      },
    );

    test(
      'archiveSearchSuggestionsProvider handles empty, success, and error',
      () async {
        final search = _TestArchiveSearchService();
        search.suggestionsHandler =
            ({required String partialQuery, int limit = 10}) async {
              if (partialQuery == 'err') throw Exception('suggest-fail');
              return [
                SearchSuggestion.relatedTerm('alpha'),
                SearchSuggestion.refinement('alpha beta'),
              ];
            };

        final container = ProviderContainer(
          overrides: [archiveSearchServiceProvider.overrideWithValue(search)],
        );
        addTearDown(container.dispose);

        expect(
          await container.read(archiveSearchSuggestionsProvider('   ').future),
          isEmpty,
        );
        expect(
          await container.read(archiveSearchSuggestionsProvider('al').future),
          hasLength(2),
        );
        expect(
          await container.read(archiveSearchSuggestionsProvider('err').future),
          isEmpty,
        );
        expect(search.suggestionCalls, 2);
      },
    );

    test('archivedChatProvider returns null when archive is missing', () async {
      final updates = StreamController<ArchiveUpdateEvent>.broadcast();
      addTearDown(updates.close);

      final management = _TestArchiveManagementService(
        archiveUpdatesStream: updates.stream,
      );
      management.summariesHandler =
          ({ArchiveSearchFilter? filter, int? limit, int? offset}) async =>
              const [];

      final container = ProviderContainer(
        overrides: [
          archiveManagementServiceProvider.overrideWithValue(management),
        ],
      );
      addTearDown(container.dispose);

      final archived = await container.read(
        archivedChatProvider(const ArchiveId('missing')).future,
      );
      expect(archived, isNull);
    });

    test(
      'archivedChatProvider builds ArchivedChat from matching summary',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        final enhanced = _enhancedSummary(
          archiveId: 'archive-42',
          chatId: 'chat-42',
          contactName: 'Bob',
        );
        management.summariesHandler =
            ({ArchiveSearchFilter? filter, int? limit, int? offset}) async => [
              enhanced,
            ];

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
          ],
        );
        addTearDown(container.dispose);

        final archived = await container.read(
          archivedChatProvider(const ArchiveId('archive-42')).future,
        );
        expect(archived, isNotNull);
        expect(archived!.id, const ArchiveId('archive-42'));
        expect(archived.contactName, 'Bob');
        expect(archived.originalChatId, const ChatId('chat-42'));
        expect(archived.metadata.tags, ['tag-a']);
      },
    );

    test('archivedChatProvider returns null when service throws', () async {
      final updates = StreamController<ArchiveUpdateEvent>.broadcast();
      addTearDown(updates.close);

      final management = _TestArchiveManagementService(
        archiveUpdatesStream: updates.stream,
      );
      management.summariesHandler =
          ({ArchiveSearchFilter? filter, int? limit, int? offset}) async =>
              throw Exception('archive-read-failed');

      final container = ProviderContainer(
        overrides: [
          archiveManagementServiceProvider.overrideWithValue(management),
        ],
      );
      addTearDown(container.dispose);

      final archived = await container.read(
        archivedChatProvider(const ArchiveId('archive-error')).future,
      );
      expect(archived, isNull);
    });
  });

  group('ArchiveUIStateNotifier', () {
    test('mutations update provider state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(archiveUIStateProvider.notifier);

      expect(container.read(archiveUIStateProvider).isSearchMode, isFalse);

      notifier.toggleSearchMode();
      notifier.updateSearchQuery('project');
      notifier.updateFilter(const ArchiveListFilter(limit: 5));
      notifier.selectArchive(const ArchiveId('archive-7'));
      notifier.toggleStatistics();

      final current = container.read(archiveUIStateProvider);
      expect(current.isSearchMode, isTrue);
      expect(current.searchQuery, 'project');
      expect(current.currentFilter?.limit, 5);
      expect(current.selectedArchiveId, const ArchiveId('archive-7'));
      expect(current.showStatistics, isFalse);

      notifier.clearSearch();
      final cleared = container.read(archiveUIStateProvider);
      expect(cleared.isSearchMode, isFalse);
      expect(cleared.searchQuery, isEmpty);
    });

    test('toggleSearchMode clears existing query when disabling search', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(archiveUIStateProvider.notifier);
      notifier.updateSearchQuery('keep-me');
      notifier.toggleSearchMode();
      notifier.toggleSearchMode();

      final state = container.read(archiveUIStateProvider);
      expect(state.isSearchMode, isFalse);
      expect(state.searchQuery, isEmpty);
    });
  });

  group('ArchiveOperationsNotifier', () {
    test(
      'archive update events reset active flags and append success message',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        management.archiveHandler =
            ({
              required String chatId,
              String? reason,
              Map<String, dynamic>? metadata,
              bool force = false,
            }) async => ArchiveOperationResult.success(
              message: 'ok',
              operationType: ArchiveOperationType.archive,
              operationTime: Duration.zero,
            );
        final search = _TestArchiveSearchService();

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
            archiveSearchServiceProvider.overrideWithValue(search),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(archiveOperationsProvider.notifier);
        container.read(archiveOperationsProvider);
        final updatesSub = container.listen<AsyncValue<ArchiveUpdateEvent>>(
          archiveUpdatesProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(updatesSub.close);
        await notifier.archiveChat(chatId: const ChatId('chat-evt'));
        expect(container.read(archiveOperationsProvider).isArchiving, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 10));
        updates.add(
          ArchiveUpdateEvent.archived(
            'chat-evt',
            const ArchiveId('archive-evt'),
            'manual',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final state = container.read(archiveOperationsProvider);
        expect(state.isArchiving, isFalse);
        expect(state.currentOperation, 'Archiving chat...');
        expect(state.recentSuccesses.last, contains('completed'));
      },
    );

    test(
      'archiveChat failure and exception paths update error state',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        management.archiveHandler =
            ({
              required String chatId,
              String? reason,
              Map<String, dynamic>? metadata,
              bool force = false,
            }) async {
              if (chatId == 'chat-fail') {
                return ArchiveOperationResult.failure(
                  message: 'archive failed',
                  operationType: ArchiveOperationType.archive,
                  operationTime: Duration.zero,
                );
              }
              throw Exception('archive boom');
            };
        final search = _TestArchiveSearchService();

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
            archiveSearchServiceProvider.overrideWithValue(search),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(archiveOperationsProvider.notifier);
        final failed = await notifier.archiveChat(
          chatId: const ChatId('chat-fail'),
        );
        expect(failed.success, isFalse);
        expect(
          container.read(archiveOperationsProvider).recentErrors.last,
          'archive failed',
        );

        final thrown = await notifier.archiveChat(
          chatId: const ChatId('chat-throw'),
          reason: 'manual',
          metadata: const {'src': 'ui'},
        );
        expect(thrown.success, isFalse);
        expect(
          container.read(archiveOperationsProvider).recentErrors.last,
          contains('Archive failed:'),
        );
        expect(management.lastArchiveReason, 'manual');
        expect(management.lastArchiveMetadata, const {'src': 'ui'});
      },
    );

    test(
      'restoreChat failure and exception paths update error state',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        management.restoreHandler =
            ({
              required ArchiveId archiveId,
              String? targetChatId,
              bool overwriteExisting = false,
            }) async {
              if (archiveId == const ArchiveId('archive-fail')) {
                return ArchiveOperationResult.failure(
                  message: 'restore failed',
                  operationType: ArchiveOperationType.restore,
                  operationTime: Duration.zero,
                );
              }
              throw Exception('restore boom');
            };
        final search = _TestArchiveSearchService();

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
            archiveSearchServiceProvider.overrideWithValue(search),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(archiveOperationsProvider.notifier);
        final failed = await notifier.restoreChat(
          archiveId: const ArchiveId('archive-fail'),
        );
        expect(failed.success, isFalse);
        expect(
          container.read(archiveOperationsProvider).recentErrors.last,
          'restore failed',
        );

        final thrown = await notifier.restoreChat(
          archiveId: const ArchiveId('archive-throw'),
          targetChatId: 'chat-new',
          overwriteExisting: true,
        );
        expect(thrown.success, isFalse);
        expect(
          container.read(archiveOperationsProvider).recentErrors.last,
          contains('Restore failed:'),
        );
        expect(management.lastRestoreTargetChatId, 'chat-new');
        expect(management.lastRestoreOverwriteExisting, isTrue);
      },
    );

    test('delete and clearRecentMessages update operation state', () async {
      final updates = StreamController<ArchiveUpdateEvent>.broadcast();
      addTearDown(updates.close);

      final management = _TestArchiveManagementService(
        archiveUpdatesStream: updates.stream,
      );
      final search = _TestArchiveSearchService();

      final container = ProviderContainer(
        overrides: [
          archiveManagementServiceProvider.overrideWithValue(management),
          archiveSearchServiceProvider.overrideWithValue(search),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(archiveOperationsProvider.notifier);
      final deleted = await notifier.deleteArchivedChat(
        const ArchiveId('archive-delete'),
      );
      expect(deleted, isTrue);
      expect(
        container.read(archiveOperationsProvider).recentSuccesses.last,
        contains('archive-delete'),
      );

      notifier.clearRecentMessages();
      final state = container.read(archiveOperationsProvider);
      expect(state.recentErrors, isEmpty);
      expect(state.recentSuccesses, isEmpty);
    });

    test(
      'debouncedSearch updates query and dispatches service search',
      () async {
        final updates = StreamController<ArchiveUpdateEvent>.broadcast();
        addTearDown(updates.close);

        final management = _TestArchiveManagementService(
          archiveUpdatesStream: updates.stream,
        );
        final search = _TestArchiveSearchService();
        search.searchHandler =
            ({
              required String query,
              ArchiveSearchFilter? filter,
              SearchOptions? options,
              int limit = 50,
            }) async => _searchResult(query);

        final container = ProviderContainer(
          overrides: [
            archiveManagementServiceProvider.overrideWithValue(management),
            archiveSearchServiceProvider.overrideWithValue(search),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(archiveOperationsProvider.notifier);
        notifier.debouncedSearch('debounced');
        await Future<void>.delayed(const Duration(milliseconds: 350));

        expect(container.read(archiveUIStateProvider).searchQuery, 'debounced');
        expect(search.searchCalls, 1);
        expect(search.lastSearchQuery, 'debounced');
        expect(search.lastSearchLimit, 50);
      },
    );

    test('archiveOperationsProvider mirrors notifier state', () {
      final updates = StreamController<ArchiveUpdateEvent>.broadcast();
      addTearDown(updates.close);

      final management = _TestArchiveManagementService(
        archiveUpdatesStream: updates.stream,
      );
      final search = _TestArchiveSearchService();

      final container = ProviderContainer(
        overrides: [
          archiveManagementServiceProvider.overrideWithValue(management),
          archiveSearchServiceProvider.overrideWithValue(search),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(archiveOperationsProvider.notifier);
      notifier.clearRecentMessages();

      expect(notifier.state, container.read(archiveOperationsProvider));
    });
  });
}
