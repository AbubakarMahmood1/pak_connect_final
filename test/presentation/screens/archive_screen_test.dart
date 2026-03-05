import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_search_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/archive_provider.dart';
import 'package:pak_connect/presentation/screens/archive_screen.dart';

final _now = DateTime(2026, 1, 10, 12, 0);

class _TestArchiveUINotifier extends ArchiveUIStateNotifier {
  _TestArchiveUINotifier(this._initialState);

  final ArchiveUIState _initialState;

  @override
  ArchiveUIState build() => _initialState;

  @override
  void toggleSearchMode() {
    state = state.copyWith(
      isSearchMode: !state.isSearchMode,
      searchQuery: state.isSearchMode ? '' : state.searchQuery,
    );
  }

  @override
  void updateSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  @override
  void updateFilter(ArchiveListFilter? filter) {
    state = state.copyWith(currentFilter: filter);
  }

  @override
  void clearSearch() {
    state = state.copyWith(
      isSearchMode: false,
      searchQuery: '',
      currentFilter: null,
    );
  }
}

class _TestArchiveOperationsNotifier extends ArchiveOperationsNotifier {
  _TestArchiveOperationsNotifier(this._initialState);

  final ArchiveOperationsState _initialState;
  String? lastDebouncedQuery;

  @override
  ArchiveOperationsState build() => _initialState;

  @override
  void debouncedSearch(String query) {
    lastDebouncedQuery = query;
    ref.read(archiveUIStateProvider.notifier).updateSearchQuery(query);
  }

  @override
  Future<ArchiveOperationResult> restoreChat({
    required ArchiveId archiveId,
    String? targetChatId,
    bool overwriteExisting = false,
  }) async {
    return ArchiveOperationResult.success(
      message: 'restored',
      operationType: ArchiveOperationType.restore,
      archiveId: archiveId,
      operationTime: const Duration(milliseconds: 10),
    );
  }

  @override
  Future<bool> deleteArchivedChat(ArchiveId archiveId) async => true;
}

ArchivedChatSummary _archive({
  required String id,
  required String contactName,
  int messageCount = 8,
  bool compressed = false,
}) {
  return ArchivedChatSummary(
    id: ArchiveId(id),
    originalChatId: ChatId('chat_$id'),
    contactName: contactName,
    archivedAt: _now.subtract(const Duration(days: 2)),
    messageCount: messageCount,
    lastMessageTime: _now.subtract(const Duration(days: 3)),
    estimatedSize: 2048,
    isCompressed: compressed,
    tags: const <String>['work'],
    isSearchable: true,
  );
}

ArchiveStatistics _stats() {
  return ArchiveStatistics(
    totalArchives: 2,
    totalMessages: 24,
    compressedArchives: 1,
    searchableArchives: 2,
    totalSizeBytes: 8192,
    compressedSizeBytes: 4096,
    archivesByMonth: const <String, int>{'2026-01': 2},
    messagesByContact: const <String, int>{'Alice': 12, 'Bob': 12},
    averageCompressionRatio: 0.5,
    oldestArchive: _now.subtract(const Duration(days: 90)),
    newestArchive: _now.subtract(const Duration(days: 1)),
    averageArchiveAge: const Duration(days: 20),
    performanceStats: ArchivePerformanceStats.empty(),
  );
}

AdvancedSearchResult _searchNoResults(String query) {
  return AdvancedSearchResult.error(
    query: query,
    error: 'no-results',
    searchTime: const Duration(milliseconds: 14),
  );
}

AdvancedSearchResult _searchWithMessage(String query) {
  final message = Message(
    id: MessageId('msg_archive_1'),
    chatId: ChatId('chat_archive_1'),
    content: 'hello from archived message',
    timestamp: _now.subtract(const Duration(days: 4)),
    isFromMe: false,
    status: MessageStatus.delivered,
  );
  final archivedMessage = ArchivedMessage.fromMessage(
    message,
    _now,
    customArchiveId: ArchiveId('archive_1'),
  );
  final result = ArchiveSearchResult.fromResults(
    messages: <ArchivedMessage>[archivedMessage],
    chats: <ArchivedChatSummary>[
      _archive(id: 'archive_1', contactName: 'Alice'),
    ],
    query: query,
    searchTime: const Duration(milliseconds: 18),
  );

  return AdvancedSearchResult.fromSearchResult(
    searchResult: result,
    query: query,
    searchTime: const Duration(milliseconds: 18),
    suggestions: const <SearchSuggestion>[],
  );
}

Future<void> _pumpArchiveScreen(
  WidgetTester tester, {
  required _TestArchiveUINotifier uiNotifier,
  required _TestArchiveOperationsNotifier operationsNotifier,
  required Future<List<ArchivedChatSummary>> Function(ArchiveListFilter?)
  loadArchives,
  required Future<AdvancedSearchResult> Function(ArchiveSearchQuery)
  searchArchives,
  ArchiveStatistics? statistics,
}) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        archiveUIStateProvider.overrideWith(() => uiNotifier),
        archiveOperationsProvider.overrideWith(() => operationsNotifier),
        archiveStatisticsProvider.overrideWith((ref) async {
          return statistics ?? _stats();
        }),
        archiveListProvider.overrideWith((ref, filter) {
          return loadArchives(filter);
        }),
        archiveSearchProvider.overrideWith((ref, query) {
          return searchArchives(query);
        }),
      ],
      child: const MaterialApp(home: ArchiveScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  group('ArchiveScreen', () {
    testWidgets('renders empty-state and statistics card in normal mode', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (query) async => _searchNoResults(query.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('Archived Chats'), findsOneWidget);
      expect(find.text('Archive Statistics'), findsOneWidget);
      expect(find.text('No Archived Chats'), findsOneWidget);
      expect(find.text('Go to Chats'), findsOneWidget);
      expect(find.byTooltip('Advanced Search'), findsOneWidget);
    });

    testWidgets('shows operation indicator when operation is active', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(
          isRestoring: true,
          currentOperation: 'Restoring chat...',
        ),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (query) async => _searchNoResults(query.query),
      );
      await tester.pump();

      expect(find.text('Restoring chat...'), findsOneWidget);
    });

    testWidgets('renders archive row and toggles statistics via menu', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'archive_1', contactName: 'Alice Archive'),
        ],
        searchArchives: (query) async => _searchNoResults(query.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice Archive'), findsOneWidget);
      expect(find.text('Archive Statistics'), findsOneWidget);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide Statistics'));
      await tester.pumpAndSettle();

      expect(find.text('Archive Statistics'), findsNothing);
      expect(find.text('Alice Archive'), findsOneWidget);
    });

    testWidgets('search mode with empty results shows no-results copy', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: 'needle'),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (query) async => _searchNoResults(query.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Results Found'), findsOneWidget);
      expect(find.textContaining('"needle"'), findsOneWidget);

      await tester.tap(find.text('Clear Search'));
      await tester.pumpAndSettle();

      expect(uiNotifier.state.isSearchMode, isFalse);
      expect(find.text('No Archived Chats'), findsOneWidget);
    });

    testWidgets(
      'search query input updates search state through operations notifier',
      (tester) async {
        final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
        final operationsNotifier = _TestArchiveOperationsNotifier(
          const ArchiveOperationsState(),
        );

        await _pumpArchiveScreen(
          tester,
          uiNotifier: uiNotifier,
          operationsNotifier: operationsNotifier,
          loadArchives: (_) async => <ArchivedChatSummary>[
            _archive(id: 'archive_2', contactName: 'Bob Archive'),
          ],
          searchArchives: (query) async => _searchWithMessage(query.query),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Search archives'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'alpha');
        await tester.pumpAndSettle();

        expect(uiNotifier.state.isSearchMode, isTrue);
        expect(uiNotifier.state.searchQuery, 'alpha');
        expect(operationsNotifier.lastDebouncedQuery, 'alpha');
      },
    );

    testWidgets('shows error state when archive list load fails', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async {
          throw Exception('archive-list failed');
        },
        searchArchives: (query) async => _searchNoResults(query.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('Error Loading Archives'), findsOneWidget);
      expect(find.textContaining('archive-list failed'), findsOneWidget);
    });
  });
}
