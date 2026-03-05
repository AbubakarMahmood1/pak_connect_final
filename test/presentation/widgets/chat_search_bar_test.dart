import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/widgets/chat_search_bar.dart';

Message _message({required String id, required String content}) {
  return Message(
    id: MessageId(id),
    chatId: const ChatId('chat-1'),
    content: content,
    timestamp: DateTime(2026, 3, 1, 9, 0),
    isFromMe: false,
    status: MessageStatus.sent,
  );
}

Future<void> _pumpSearchBar(
  WidgetTester tester, {
  required List<Message> messages,
  required void Function(String query, List<SearchResult> results) onSearch,
  required void Function(int messageIndex) onNavigateToResult,
  required VoidCallback onExitSearch,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatSearchBar(
          messages: messages,
          onSearch: onSearch,
          onNavigateToResult: onNavigateToResult,
          onExitSearch: onExitSearch,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final messages = [
    _message(id: 'm1', content: 'Hello from chat one'),
    _message(id: 'm2', content: 'Nothing interesting here'),
    _message(id: 'm3', content: 'Second HELLO appears'),
  ];

  group('ChatSearchBar', () {
    testWidgets(
      'searches case-insensitively and auto-navigates to first match',
      (tester) async {
        String? observedQuery;
        List<SearchResult>? observedResults;
        final navigatedIndexes = <int>[];
        var exitCalls = 0;

        await _pumpSearchBar(
          tester,
          messages: messages,
          onSearch: (query, results) {
            observedQuery = query;
            observedResults = results;
          },
          onNavigateToResult: navigatedIndexes.add,
          onExitSearch: () => exitCalls++,
        );

        await tester.enterText(find.byType(TextField), 'hello');
        await tester.pumpAndSettle();

        expect(observedQuery, 'hello');
        expect(observedResults, isNotNull);
        expect(observedResults!.length, 2);
        expect(observedResults!.first.messageIndex, 0);
        expect(observedResults!.last.messageIndex, 2);
        expect(observedResults!.first.matchPositions, isNotEmpty);
        expect(navigatedIndexes, [0]);
        expect(find.text('1 of 2'), findsOneWidget);
        expect(find.byTooltip('Previous result'), findsOneWidget);
        expect(find.byTooltip('Next result'), findsOneWidget);
        expect(exitCalls, 0);
      },
    );

    testWidgets('next and previous navigation wraps around result list', (
      tester,
    ) async {
      final navigatedIndexes = <int>[];

      await _pumpSearchBar(
        tester,
        messages: messages,
        onSearch: (query, results) {},
        onNavigateToResult: navigatedIndexes.add,
        onExitSearch: () {},
      );

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Next result'));
      await tester.pumpAndSettle();
      expect(navigatedIndexes.last, 2);
      expect(find.text('2 of 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Next result'));
      await tester.pumpAndSettle();
      expect(navigatedIndexes.last, 0);
      expect(find.text('1 of 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous result'));
      await tester.pumpAndSettle();
      expect(navigatedIndexes.last, 2);
      expect(find.text('2 of 2'), findsOneWidget);
    });

    testWidgets('shows no-results text and does not auto-navigate for misses', (
      tester,
    ) async {
      List<SearchResult>? observedResults;
      final navigatedIndexes = <int>[];

      await _pumpSearchBar(
        tester,
        messages: messages,
        onSearch: (query, results) => observedResults = results,
        onNavigateToResult: navigatedIndexes.add,
        onExitSearch: () {},
      );

      await tester.enterText(find.byType(TextField), 'zzzzz');
      await tester.pumpAndSettle();

      expect(observedResults, isNotNull);
      expect(observedResults, isEmpty);
      expect(navigatedIndexes, isEmpty);
      expect(find.text('No results found'), findsOneWidget);
      expect(find.byTooltip('Previous result'), findsNothing);
      expect(find.byTooltip('Next result'), findsNothing);
    });

    testWidgets('clear action resets state and triggers exit callback', (
      tester,
    ) async {
      var exitCalls = 0;

      await _pumpSearchBar(
        tester,
        messages: messages,
        onSearch: (query, results) {},
        onNavigateToResult: (_) {},
        onExitSearch: () => exitCalls++,
      );

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.byTooltip('Clear search'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      expect(exitCalls, 1);
      expect(find.text('1 of 2'), findsNothing);
      expect(find.text('No results found'), findsNothing);
      expect(find.byTooltip('Clear search'), findsNothing);
    });

    testWidgets('exit button callback is invoked', (tester) async {
      var exitCalls = 0;

      await _pumpSearchBar(
        tester,
        messages: messages,
        onSearch: (query, results) {},
        onNavigateToResult: (_) {},
        onExitSearch: () => exitCalls++,
      );

      await tester.tap(find.byTooltip('Exit search'));
      await tester.pumpAndSettle();

      expect(exitCalls, 1);
    });

    testWidgets(
      'blank query clears current result state without new search callback',
      (tester) async {
        var searchCallCount = 0;

        await _pumpSearchBar(
          tester,
          messages: messages,
          onSearch: (query, results) => searchCallCount++,
          onNavigateToResult: (_) {},
          onExitSearch: () {},
        );

        await tester.enterText(find.byType(TextField), 'hello');
        await tester.pumpAndSettle();
        expect(searchCallCount, 1);
        expect(find.text('1 of 2'), findsOneWidget);

        await tester.enterText(find.byType(TextField), '   ');
        await tester.pumpAndSettle();

        expect(searchCallCount, 1);
        expect(find.text('1 of 2'), findsNothing);
        expect(find.text('No results found'), findsNothing);
      },
    );
  });
}
