import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/archive_provider.dart';
import 'package:pak_connect/presentation/widgets/archive_context_menu.dart';
import 'package:pak_connect/presentation/widgets/archive_statistics_card.dart';
import 'package:pak_connect/presentation/widgets/archived_chat_tile.dart';

ArchivedChatSummary _archive({
  String id = 'archive-1',
  String chatId = 'chat-1',
  String contactName = 'Alice',
  DateTime? archivedAt,
  int messageCount = 42,
  DateTime? lastMessageTime,
  int estimatedSize = 2048,
  bool isCompressed = false,
  List<String> tags = const ['family', 'travel', 'notes', 'extra'],
  bool isSearchable = true,
}) {
  return ArchivedChatSummary(
    id: ArchiveId(id),
    originalChatId: ChatId(chatId),
    contactName: contactName,
    archivedAt: archivedAt ?? DateTime.now().subtract(const Duration(days: 2)),
    messageCount: messageCount,
    lastMessageTime: lastMessageTime,
    estimatedSize: estimatedSize,
    isCompressed: isCompressed,
    tags: tags,
    isSearchable: isSearchable,
  );
}

ArchiveStatistics _stats({int searchMs = 120}) {
  return ArchiveStatistics(
    totalArchives: 12,
    totalMessages: 340,
    compressedArchives: 7,
    searchableArchives: 10,
    totalSizeBytes: 3 * 1024 * 1024,
    compressedSizeBytes: 2 * 1024 * 1024,
    archivesByMonth: const {'2026-03': 5},
    messagesByContact: const {'Alice': 120, 'Bob': 80},
    averageCompressionRatio: 0.66,
    oldestArchive: DateTime.now().subtract(const Duration(days: 400)),
    newestArchive: DateTime.now().subtract(const Duration(days: 2)),
    averageArchiveAge: const Duration(days: 100),
    performanceStats: ArchivePerformanceStats(
      averageArchiveTime: const Duration(milliseconds: 320),
      averageRestoreTime: const Duration(milliseconds: 450),
      averageSearchTime: Duration(milliseconds: searchMs),
      averageMemoryUsage: 4 * 1024 * 1024,
      operationsCount: 17,
      operationCounts: const {'archive': 10, 'restore': 7},
      recentOperationTimes: const [Duration(milliseconds: 30)],
    ),
  );
}

Future<void> _pumpWithStatsOverride(
  WidgetTester tester,
  Widget child, {
  required Future<ArchiveStatistics> Function() loader,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [archiveStatisticsProvider.overrideWith((ref) => loader())],
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpWidgetHarness(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('ArchiveStatisticsCard', () {
    testWidgets('renders loading state', (tester) async {
      final pending = Completer<ArchiveStatistics>();
      await _pumpWithStatsOverride(
        tester,
        const ArchiveStatisticsCard(),
        loader: () => pending.future,
      );

      expect(find.text('Loading Statistics...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders error state', (tester) async {
      await _pumpWithStatsOverride(
        tester,
        const ArchiveStatisticsCard(),
        loader: () async => throw StateError('forced statistics error'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Statistics Unavailable'), findsOneWidget);
      expect(find.textContaining('forced statistics error'), findsOneWidget);
    });

    testWidgets('renders collapsed statistics and toggle callback', (
      tester,
    ) async {
      var toggleCalls = 0;
      await _pumpWithStatsOverride(
        tester,
        ArchiveStatisticsCard(
          isExpanded: false,
          onToggleExpanded: () => toggleCalls++,
        ),
        loader: () async => _stats(searchMs: 720),
      );
      await tester.pumpAndSettle();

      expect(find.text('Archive Statistics'), findsOneWidget);
      expect(find.text('Total Archives'), findsOneWidget);
      expect(find.text('Total Messages'), findsOneWidget);
      expect(find.text('Storage Used'), findsOneWidget);
      expect(find.text('Performance Metrics'), findsNothing);

      await tester.tap(find.byTooltip('Show more'));
      await tester.pump();
      expect(toggleCalls, 1);
    });

    testWidgets('renders expanded statistics with details', (tester) async {
      await _pumpWithStatsOverride(
        tester,
        const ArchiveStatisticsCard(isExpanded: true),
        loader: () async => _stats(searchMs: 720),
      );
      await tester.pumpAndSettle();

      expect(find.text('Compression Efficiency'), findsOneWidget);
      expect(find.text('Searchable Archives'), findsOneWidget);
      expect(find.text('Archive Age Range'), findsOneWidget);
      expect(find.text('Performance Metrics'), findsOneWidget);
      expect(find.text('Avg Search Time'), findsOneWidget);
      expect(find.text('Operations'), findsOneWidget);
      expect(find.text('17'), findsOneWidget);
    });
  });

  group('CompactArchiveStatistics', () {
    testWidgets('renders data state', (tester) async {
      await _pumpWithStatsOverride(
        tester,
        const CompactArchiveStatistics(),
        loader: () async => _stats(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Archives'), findsOneWidget);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
    });

    testWidgets('renders loading state', (tester) async {
      final pending = Completer<ArchiveStatistics>();
      await _pumpWithStatsOverride(
        tester,
        const CompactArchiveStatistics(),
        loader: () => pending.future,
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders error state', (tester) async {
      await _pumpWithStatsOverride(
        tester,
        const CompactArchiveStatistics(),
        loader: () async => throw StateError('boom'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Statistics unavailable'), findsOneWidget);
    });
  });

  group('ArchivedChatTile', () {
    testWidgets('renders metadata, tags, and handles tap', (tester) async {
      var tapped = 0;
      final archive = _archive(
        lastMessageTime: DateTime.now().subtract(const Duration(hours: 2)),
      );

      await _pumpWidgetHarness(
        tester,
        ArchivedChatTile(
          archive: archive,
          isSelected: true,
          showContextMenu: false,
          onTap: () => tapped++,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('42 messages'), findsOneWidget);
      expect(find.text('2.0KB'), findsOneWidget);
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('family'), findsOneWidget);
      expect(find.text('travel'), findsOneWidget);
      expect(find.text('notes'), findsOneWidget);
      expect(find.text('extra'), findsNothing);
      expect(find.text('2h ago'), findsOneWidget);

      await tester.tap(find.text('Alice'));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('renders status variants and compact/search tiles', (
      tester,
    ) async {
      var restoreCalls = 0;
      await _pumpWidgetHarness(
        tester,
        Column(
          children: [
            ArchivedChatTile(
              archive: _archive(isSearchable: false, isCompressed: false),
              showContextMenu: false,
            ),
            ArchivedChatTile(
              archive: _archive(
                id: 'archive-2',
                isSearchable: true,
                isCompressed: true,
              ),
              showContextMenu: false,
            ),
            CompactArchivedChatTile(
              archive: _archive(id: 'archive-3'),
              onRestore: () => restoreCalls++,
            ),
            SearchResultArchivedChatTile(
              archive: _archive(id: 'archive-4'),
              searchQuery: 'ali',
              highlights: const ['first hit', 'second hit', 'third hit'],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not Indexed'), findsOneWidget);
      expect(find.text('Compressed'), findsOneWidget);
      expect(find.text('Archived'), findsWidgets);
      expect(find.text('42 msgs • 2.0KB'), findsOneWidget);
      expect(find.text('first hit'), findsOneWidget);
      expect(find.text('second hit'), findsOneWidget);
      expect(find.text('third hit'), findsNothing);

      await tester.tap(find.byTooltip('Restore chat'));
      await tester.pump();
      expect(restoreCalls, 1);
    });
  });

  group('ArchiveContextMenu', () {
    testWidgets('handles view details action', (tester) async {
      var viewCalls = 0;
      await _pumpWidgetHarness(
        tester,
        ArchiveContextMenu(
          archive: _archive(isSearchable: true),
          onViewDetails: () => viewCalls++,
          child: const Icon(Icons.more_vert),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Export Archive'), findsOneWidget);

      await tester.tap(find.text('View Details'));
      await tester.pumpAndSettle();
      expect(viewCalls, 1);
    });

    testWidgets('handles restore confirmation cancel and confirm', (
      tester,
    ) async {
      var restoreCalls = 0;
      await _pumpWidgetHarness(
        tester,
        ArchiveContextMenu(
          archive: _archive(isSearchable: true),
          onRestore: () => restoreCalls++,
          child: const Icon(Icons.more_vert),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore Chat'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Restore archived chat with Alice?'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(restoreCalls, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore Chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(restoreCalls, 1);
    });

    testWidgets('handles export confirmation', (tester) async {
      var exportCalls = 0;
      await _pumpWidgetHarness(
        tester,
        ArchiveContextMenu(
          archive: _archive(isSearchable: true),
          onExport: () => exportCalls++,
          child: const Icon(Icons.more_vert),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export Archive'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Export archived chat with Alice?'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(exportCalls, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export Archive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(exportCalls, 1);
    });

    testWidgets('handles delete confirmation cancel and confirm', (
      tester,
    ) async {
      var deleteCalls = 0;
      await _pumpWidgetHarness(
        tester,
        ArchiveContextMenu(
          archive: _archive(isSearchable: true),
          onDelete: () => deleteCalls++,
          child: const Icon(Icons.more_vert),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Permanently'));
      await tester.pumpAndSettle();
      expect(find.text('This action cannot be undone!'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 0);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Permanently'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Forever'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 1);
    });

    testWidgets('hides export action when archive is not searchable', (
      tester,
    ) async {
      await _pumpWidgetHarness(
        tester,
        ArchiveContextMenu(
          archive: _archive(isSearchable: false),
          child: const Icon(Icons.more_vert),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Export Archive'), findsNothing);
    });
  });

  group('SimpleArchiveContextMenu', () {
    testWidgets('handles restore and quick delete actions', (tester) async {
      var restoreCalls = 0;
      var deleteCalls = 0;
      await _pumpWidgetHarness(
        tester,
        SimpleArchiveContextMenu(
          archive: _archive(),
          onRestore: () => restoreCalls++,
          onDelete: () => deleteCalls++,
        ),
      );

      await tester.tap(find.byTooltip('Restore chat'));
      await tester.pump();
      expect(restoreCalls, 1);

      await tester.tap(find.byTooltip('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Archive?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 0);

      await tester.tap(find.byTooltip('Delete permanently'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 1);
    });
  });
}
