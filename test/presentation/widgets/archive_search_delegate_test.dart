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
import 'package:pak_connect/presentation/widgets/archive_search_delegate.dart';

class _SearchHost extends ConsumerWidget {
  const _SearchHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Open archive search',
            onPressed: () {
              showSearch<String>(
                context: context,
                delegate: ArchiveSearchDelegate(ref),
              );
            },
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: const Center(child: Text('Archive Host')),
    );
  }
}

ArchivedChatSummary _summary({
  String id = 'archive-1',
  String chatId = 'chat-1',
  String contactName = 'Alice',
}) {
  return ArchivedChatSummary(
    id: ArchiveId(id),
    originalChatId: ChatId(chatId),
    contactName: contactName,
    archivedAt: DateTime.now().subtract(const Duration(days: 2)),
    messageCount: 4,
    lastMessageTime: DateTime.now().subtract(const Duration(hours: 3)),
    estimatedSize: 1400,
    isCompressed: false,
    tags: const ['project'],
    isSearchable: true,
  );
}

ArchivedMessage _message({
  String id = 'msg-1',
  String chatId = 'chat-1',
  String content = 'hello from archive',
  bool isFromMe = false,
  DateTime? originalTimestamp,
}) {
  final ts =
      originalTimestamp ?? DateTime.now().subtract(const Duration(minutes: 5));
  return ArchivedMessage(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: content,
    timestamp: ts,
    isFromMe: isFromMe,
    status: MessageStatus.sent,
    archivedAt: DateTime.now(),
    originalTimestamp: ts,
    archiveId: ArchiveId('archive-$id'),
    archiveMetadata: const ArchiveMessageMetadata(
      archiveVersion: '1.0',
      preservationLevel: ArchivePreservationLevel.complete,
      indexingStatus: ArchiveIndexingStatus.indexed,
      compressionApplied: false,
      originalSize: 256,
      additionalData: {},
    ),
  );
}

AdvancedSearchResult _result({
  required String query,
  List<ArchivedChatSummary> chats = const [],
  List<ArchivedMessage> messages = const [],
  List<SearchSuggestion> suggestions = const [],
}) {
  final searchResult = ArchiveSearchResult.fromResults(
    messages: messages,
    chats: chats,
    query: query,
    searchTime: const Duration(milliseconds: 33),
  );

  return AdvancedSearchResult.fromSearchResult(
    searchResult: searchResult,
    query: query,
    searchTime: const Duration(milliseconds: 33),
    suggestions: suggestions,
  );
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: _SearchHost())),
  );

  await tester.tap(find.byTooltip('Open archive search'));
  await tester.pumpAndSettle();
}

Future<void> _openSearchWithOverrides(
  WidgetTester tester, {
  required dynamic overrides,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: _SearchHost()),
    ),
  );

  await tester.tap(find.byTooltip('Open archive search'));
  await tester.pumpAndSettle();
}

Future<void> _enterQuery(WidgetTester tester, String value) async {
  await tester.enterText(find.byType(TextField), value);
  await tester.pumpAndSettle();
}

Future<void> _submitSearch(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  group('ArchiveSearchDelegate', () {
    testWidgets('shows recent searches and clear-history snackbar', (
      tester,
    ) async {
      await _openSearch(tester);

      expect(find.text('Recent Searches'), findsOneWidget);
      expect(find.text('holiday photos'), findsOneWidget);

      await tester.tap(find.text('Clear search history'));
      await tester.pump();

      expect(find.text('Search history cleared'), findsOneWidget);
    });

    testWidgets('opens and applies filter dialog from actions', (tester) async {
      await _openSearch(tester);

      await tester.tap(find.byTooltip('Search filters'));
      await tester.pumpAndSettle();

      expect(find.text('Search Filters'), findsOneWidget);
      expect(find.text('Include compressed archives'), findsOneWidget);
      expect(find.text('Messages only'), findsOneWidget);
      expect(find.text('Chats only'), findsOneWidget);

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Search Filters'), findsNothing);
    });

    testWidgets(
      'shows empty-query results screen when submitting blank query',
      (tester) async {
        await _openSearch(tester);
        await _submitSearch(tester);

        expect(find.text('Search Archives'), findsOneWidget);
        expect(
          find.text('Search through your archived chats and messages'),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows no suggestions for unmatched query', (tester) async {
      await _openSearchWithOverrides(
        tester,
        overrides: [
          archiveSearchSuggestionsProvider.overrideWith((
            ref,
            partialQuery,
          ) async {
            return <SearchSuggestion>[];
          }),
        ],
      );

      await _enterQuery(tester, 'zzz');
      expect(find.text('No suggestions available'), findsOneWidget);
    });

    testWidgets(
      'renders suggestion metadata and opens results on suggestion tap',
      (tester) async {
        final suggestions = <SearchSuggestion>[
          SearchSuggestion.fromHistory('project meeting', 3),
          SearchSuggestion.contentBased('meeting notes', 7),
          SearchSuggestion.savedSearch('Pinned', 'daily standup'),
        ];

        await _openSearchWithOverrides(
          tester,
          overrides: [
            archiveSearchSuggestionsProvider.overrideWith((
              ref,
              partialQuery,
            ) async {
              return suggestions;
            }),
            archiveSearchProvider.overrideWith((ref, query) async {
              return _result(
                query: query.query,
                chats: [_summary()],
                messages: [_message()],
              );
            }),
          ],
        );

        await _enterQuery(tester, 'proj');
        expect(find.text('project meeting'), findsOneWidget);
        expect(find.text('meeting notes'), findsOneWidget);
        expect(find.text('daily standup'), findsOneWidget);
        expect(find.text('3 results'), findsOneWidget);
        expect(find.text('Found 7 times'), findsOneWidget);
        expect(find.text('Saved as "Pinned"'), findsOneWidget);

        await tester.tap(find.text('project meeting'));
        await tester.pumpAndSettle();

        expect(find.textContaining('results found in'), findsOneWidget);
        expect(find.text('Chats (1)'), findsOneWidget);
        expect(find.text('Messages (1)'), findsOneWidget);
      },
    );

    testWidgets('shows no-results state when search returns empty payload', (
      tester,
    ) async {
      await _openSearchWithOverrides(
        tester,
        overrides: [
          archiveSearchProvider.overrideWith((ref, query) async {
            return _result(query: query.query);
          }),
        ],
      );

      await _enterQuery(tester, 'nothing');
      await _submitSearch(tester);

      expect(find.text('No Results Found'), findsOneWidget);
      expect(
        find.text('Try different keywords or check your spelling'),
        findsOneWidget,
      );
    });

    testWidgets(
      'renders result tabs, message metadata, and suggestions dialog',
      (tester) async {
        await _openSearchWithOverrides(
          tester,
          overrides: [
            archiveSearchProvider.overrideWith((ref, query) async {
              return _result(
                query: query.query,
                chats: [_summary()],
                messages: [_message(content: 'message body', isFromMe: false)],
                suggestions: const [
                  SearchSuggestion(
                    text: 'refine: last week',
                    type: SearchSuggestionType.refinement,
                    relevanceScore: 0.9,
                  ),
                ],
              );
            }),
          ],
        );

        await _enterQuery(tester, 'message');
        await _submitSearch(tester);

        expect(find.text('Chats (1)'), findsOneWidget);
        expect(find.text('Messages (1)'), findsOneWidget);

        await tester.tap(find.text('Messages (1)'));
        await tester.pumpAndSettle();

        expect(find.text('message body'), findsOneWidget);
        expect(find.text('From: Contact'), findsOneWidget);

        await tester.tap(find.text('Suggestions'));
        await tester.pumpAndSettle();

        expect(find.text('Search Suggestions'), findsOneWidget);
        expect(find.text('refine: last week'), findsOneWidget);

        await tester.tap(find.text('refine: last week'));
        await tester.pumpAndSettle();

        expect(find.text('Search Suggestions'), findsNothing);
      },
    );

    testWidgets('shows search error state when provider throws', (
      tester,
    ) async {
      await _openSearchWithOverrides(
        tester,
        overrides: [
          archiveSearchProvider.overrideWith((ref, query) async {
            throw StateError('forced search error');
          }),
        ],
      );

      await _enterQuery(tester, 'boom');
      await _submitSearch(tester);

      expect(find.text('Search Error'), findsOneWidget);
      expect(find.textContaining('forced search error'), findsOneWidget);
    });

    testWidgets('clear action resets query back to recent searches', (
      tester,
    ) async {
      await _openSearchWithOverrides(
        tester,
        overrides: [
          archiveSearchSuggestionsProvider.overrideWith((
            ref,
            partialQuery,
          ) async {
            return [SearchSuggestion.relatedTerm('quick result')];
          }),
        ],
      );

      await _enterQuery(tester, 'quick');
      expect(find.text('quick result'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      expect(find.text('Recent Searches'), findsOneWidget);
    });

    testWidgets('leading back action closes delegate', (tester) async {
      await _openSearch(tester);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('Archive Host'), findsOneWidget);
    });
  });
}
