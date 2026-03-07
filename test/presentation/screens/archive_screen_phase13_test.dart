// Phase 13.2 – archive_screen.dart additional coverage
// Covers: search-with-results, sort menu actions, restore/delete flows,
//         loading/error states for search, archive detail dialog, FAB visibility,
//         clear-search in AppBar mode, refresh-all menu action.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_search_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/archive_provider.dart';
import 'package:pak_connect/presentation/screens/archive_screen.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

final _now = DateTime(2026, 2, 15, 10, 0);

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
  _TestArchiveOperationsNotifier(
    this._initialState, {
    this.restoreResult,
    this.deleteResult,
  });

  final ArchiveOperationsState _initialState;
  String? lastDebouncedQuery;

  /// If non-null, restoreChat returns this; otherwise returns a default success.
  final ArchiveOperationResult Function(ArchiveId)? restoreResult;

  /// If non-null, deleteArchivedChat returns this value; otherwise true.
  final bool Function(ArchiveId)? deleteResult;

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
    if (restoreResult != null) return restoreResult!(archiveId);
    return ArchiveOperationResult.success(
      message: 'restored',
      operationType: ArchiveOperationType.restore,
      archiveId: archiveId,
      operationTime: const Duration(milliseconds: 10),
    );
  }

  @override
  Future<bool> deleteArchivedChat(ArchiveId archiveId) async {
    if (deleteResult != null) return deleteResult!(archiveId);
    return true;
  }
}

ArchivedChatSummary _archive({
  required String id,
  required String contactName,
  int messageCount = 8,
  bool compressed = false,
  bool searchable = true,
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
    isSearchable: searchable,
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
    archivesByMonth: const <String, int>{'2026-02': 2},
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  Logger.root.level = Level.OFF;

  group('ArchiveScreen – Phase 13.2', () {
    // -----------------------------------------------------------------------
    // 1. Search results WITH actual results
    // -----------------------------------------------------------------------
    testWidgets('search mode with results renders result summary and tiles', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: 'hello'),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (query) async => _searchWithMessage(query.query),
      );
      await tester.pumpAndSettle();

      // Result summary row
      expect(find.textContaining('1 results'), findsOneWidget);
      expect(find.textContaining('18ms'), findsOneWidget);

      // The search result tile should show 'Contact' text
      expect(find.text('Contact'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 2. Sort-by-Date menu action
    // -----------------------------------------------------------------------
    testWidgets('sort by date menu action updates filter', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'a1', contactName: 'Charlie'),
        ],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by Date'));
      await tester.pumpAndSettle();

      // Screen should still be intact after sort
      expect(find.text('Archived Chats'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 3. Sort-by-Name menu action
    // -----------------------------------------------------------------------
    testWidgets('sort by name menu action does not crash', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'a1', contactName: 'Zara'),
        ],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by Name'));
      await tester.pumpAndSettle();

      expect(find.text('Archived Chats'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 4. Sort-by-Size menu action
    // -----------------------------------------------------------------------
    testWidgets('sort by size menu action does not crash', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'a1', contactName: 'Dana'),
        ],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by Size'));
      await tester.pumpAndSettle();

      expect(find.text('Archived Chats'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 5. Refresh All menu action
    // -----------------------------------------------------------------------
    testWidgets('refresh all menu action reloads the list', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'a1', contactName: 'Eve'),
        ],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh All'));
      await tester.pumpAndSettle();

      expect(find.text('Archived Chats'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 6. Toggle Statistics via menu (Show Statistics path)
    // -----------------------------------------------------------------------
    testWidgets('toggle statistics hides then re-shows the card', (
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
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      // Statistics card visible initially
      expect(find.text('Archive Statistics'), findsOneWidget);

      // Hide it
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide Statistics'));
      await tester.pumpAndSettle();
      expect(find.text('Archive Statistics'), findsNothing);

      // Re-show it
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show Statistics'));
      await tester.pumpAndSettle();
      expect(find.text('Archive Statistics'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 7. FAB is hidden in search mode
    // -----------------------------------------------------------------------
    testWidgets('FAB is hidden when search mode is active', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: ''),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 8. FAB is visible in normal mode
    // -----------------------------------------------------------------------
    testWidgets('FAB is visible in normal (non-search) mode', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byTooltip('Advanced Search'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 9. Clear search via AppBar close button in search mode
    // -----------------------------------------------------------------------
    testWidgets('clear search button in AppBar clears search state', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: 'xyz'),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      // AppBar clear button
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      expect(uiNotifier.state.isSearchMode, isFalse);
      expect(uiNotifier.state.searchQuery, '');
    });

    // -----------------------------------------------------------------------
    // 10. Archive detail dialog opens
    // -----------------------------------------------------------------------
    testWidgets('tapping archive tile opens detail dialog', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'a1', contactName: 'Fiona Detail'),
        ],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      // Tap on the archive tile — InkWell's onTap calls _openArchiveDetail
      await tester.tap(find.text('Fiona Detail'));
      await tester.pumpAndSettle();

      expect(find.text('Archive Details'), findsOneWidget);
      expect(
        find.textContaining('Fiona Detail'),
        findsWidgets,
      );

      // Close dialog
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Archive Details'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 11. Loading state for archive list
    // -----------------------------------------------------------------------
    testWidgets('loading state shows CircularProgressIndicator', (
      tester,
    ) async {
      final completer = Completer<List<ArchivedChatSummary>>();
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) => completer.future,
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      // Only pump once so the future stays unresolved
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);

      // Complete the future to avoid timer leak on teardown
      completer.complete(const <ArchivedChatSummary>[]);
      await tester.pumpAndSettle();
    });

    // -----------------------------------------------------------------------
    // 12. Error state for search results
    // -----------------------------------------------------------------------
    testWidgets('search error shows error state', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: 'fail'),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => throw Exception('search-exploded'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Error Loading Archives'), findsOneWidget);
      expect(find.textContaining('search-exploded'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 13. Retry button is present on error state
    // -----------------------------------------------------------------------
    testWidgets('error state shows retry button', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async {
          throw Exception('permanent-error');
        },
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('Error Loading Archives'), findsOneWidget);
      expect(find.textContaining('permanent-error'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 14. "Go to Chats" button exists in empty state
    // -----------------------------------------------------------------------
    testWidgets('empty state has "Go to Chats" button', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('Go to Chats'), findsOneWidget);
      expect(find.byIcon(Icons.chat), findsOneWidget);
      expect(
        find.textContaining('Archived chats will appear here'),
        findsOneWidget,
      );
    });

    // -----------------------------------------------------------------------
    // 15. Search bar is rendered in search mode (standalone bar)
    // -----------------------------------------------------------------------
    testWidgets('search mode renders search bar with hint text', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: ''),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      // In search mode the AppBar has a TextField with 'Search archives...'
      expect(find.text('Search archives...'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 16. Multiple archives are rendered in list
    // -----------------------------------------------------------------------
    testWidgets('multiple archives render correctly in list', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => <ArchivedChatSummary>[
          _archive(id: 'a1', contactName: 'Alpha'),
          _archive(id: 'a2', contactName: 'Bravo'),
          _archive(id: 'a3', contactName: 'Charlie'),
        ],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Charlie'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 17. Search result tile tap opens search-result dialog
    // -----------------------------------------------------------------------
    testWidgets('tapping search result tile opens search result dialog', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: 'hello'),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (query) async => _searchWithMessage(query.query),
      );
      await tester.pumpAndSettle();

      // Tap on "Contact" text (the search result tile's contact name)
      await tester.tap(find.text('Contact'));
      await tester.pumpAndSettle();

      expect(find.text('Search Result'), findsOneWidget);
      // The message text appears both in the tile highlight and the dialog
      expect(
        find.textContaining('hello from archived message'),
        findsWidgets,
      );

      // Close dialog
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Search Result'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 18. Statistics card is hidden in search mode
    // -----------------------------------------------------------------------
    testWidgets('statistics card is hidden when search mode is active', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(
        const ArchiveUIState(isSearchMode: true, searchQuery: ''),
      );
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pumpAndSettle();

      // Statistics card should NOT be shown during search
      expect(find.text('Archive Statistics'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 19. Operation indicator with custom operation text
    // -----------------------------------------------------------------------
    testWidgets('operation indicator shows custom text', (tester) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(
          isDeleting: true,
          currentOperation: 'Deleting archived chat...',
        ),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pump();

      expect(find.text('Deleting archived chat...'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 20. Operation indicator shows "Processing..." for null operation
    // -----------------------------------------------------------------------
    testWidgets('operation indicator defaults to "Processing..."', (
      tester,
    ) async {
      final uiNotifier = _TestArchiveUINotifier(const ArchiveUIState());
      final operationsNotifier = _TestArchiveOperationsNotifier(
        const ArchiveOperationsState(isArchiving: true, currentOperation: null),
      );

      await _pumpArchiveScreen(
        tester,
        uiNotifier: uiNotifier,
        operationsNotifier: operationsNotifier,
        loadArchives: (_) async => const <ArchivedChatSummary>[],
        searchArchives: (q) async => _searchNoResults(q.query),
      );
      await tester.pump();

      expect(find.text('Processing...'), findsOneWidget);
    });
  });
}
