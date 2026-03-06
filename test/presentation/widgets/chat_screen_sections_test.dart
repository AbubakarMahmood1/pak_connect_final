import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import 'package:pak_connect/presentation/controllers/chat_search_controller.dart';
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/widgets/chat_screen_helpers.dart';
import 'package:pak_connect/presentation/widgets/chat_screen_sections.dart';
import 'package:pak_connect/presentation/widgets/chat_search_bar.dart';

class _FakeChatsRepository extends Fake implements IChatsRepository {}

Message _message({
  required String id,
  required String content,
  required bool isFromMe,
  required MessageStatus status,
}) {
  return Message(
    id: MessageId(id),
    chatId: const ChatId('chat-1'),
    content: content,
    timestamp: DateTime(2026, 3, 1, 12, 0, 0),
    isFromMe: isFromMe,
    status: status,
  );
}

chat_controller.ChatScrollingController _buildScrollingController() {
  return chat_controller.ChatScrollingController(
    chatsRepository: _FakeChatsRepository(),
    chatId: const ChatId('chat-1'),
    onScrollToBottom: () {},
    onUnreadCountChanged: (_) {},
    onStateChanged: () {},
  );
}

Widget _wrapSection(Widget section) {
  return MaterialApp(
    home: Scaffold(body: Column(children: <Widget>[section])),
  );
}

void main() {
  group('chat_screen_sections', () {
    testWidgets('ChatMessagesSection shows loading and empty states', (
      tester,
    ) async {
      final searchController = ChatSearchController();
      final scrollingController = _buildScrollingController();
      addTearDown(scrollingController.dispose);

      await tester.pumpWidget(
        _wrapSection(
          ChatMessagesSection(
            uiState: const ChatUIState(isLoading: true),
            messages: const <Message>[],
            searchController: searchController,
            scrollingController: scrollingController,
            onToggleSearchMode: () {},
            onRetryFailedMessages: () {},
            retryHandlerFor: (_) => null,
            onDeleteMessage: (_, __) async {},
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
        _wrapSection(
          ChatMessagesSection(
            uiState: const ChatUIState(isLoading: false),
            messages: const <Message>[],
            searchController: searchController,
            scrollingController: scrollingController,
            onToggleSearchMode: () {},
            onRetryFailedMessages: () {},
            retryHandlerFor: (_) => null,
            onDeleteMessage: (_, __) async {},
          ),
        ),
      );
      expect(find.byType(EmptyChatPlaceholder), findsOneWidget);
    });

    testWidgets(
      'ChatMessagesSection renders search bar, unread separator, and retry indicator',
      (tester) async {
        final searchController = ChatSearchController();
        final scrollingController = _buildScrollingController();
        addTearDown(scrollingController.dispose);
        searchController.toggleSearchMode();
        scrollingController.setUnreadCount(1);

        final messages = <Message>[
          _message(
            id: 'm1',
            content: 'Failed from me',
            isFromMe: true,
            status: MessageStatus.failed,
          ),
        ];
        var retryAllCalls = 0;

        await tester.pumpWidget(
          _wrapSection(
            ChatMessagesSection(
              uiState: ChatUIState(
                isLoading: false,
                messages: messages,
                showUnreadSeparator: true,
              ),
              messages: messages,
              searchController: searchController,
              scrollingController: scrollingController,
              onToggleSearchMode: () {},
              onRetryFailedMessages: () => retryAllCalls++,
              retryHandlerFor: (_) => null,
              onDeleteMessage: (_, __) async {},
            ),
          ),
        );

        expect(find.byType(ChatSearchBar), findsOneWidget);
        expect(find.byType(UnreadSeparator), findsOneWidget);
        expect(find.text('Failed from me'), findsOneWidget);
        expect(find.text('1 failed'), findsOneWidget);

        await tester.tap(find.text('retry'));
        await tester.pump();
        expect(retryAllCalls, 1);
      },
    );

    testWidgets('ChatComposer wiring for image picker and send action', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var pickImageCalls = 0;
      var sendCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              messageController: controller,
              hintText: 'Type message',
              canSendImage: true,
              onPickImage: () => pickImageCalls++,
              onSendMessage: () => sendCalls++,
            ),
          ),
        ),
      );

      expect(find.text('Type message'), findsOneWidget);

      await tester.tap(find.byTooltip('Send image'));
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(pickImageCalls, 1);
      expect(sendCalls, 1);
    });

    testWidgets(
      'ChatComposer disables image action when sending image is unavailable',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatComposer(
                messageController: controller,
                hintText: 'Disabled',
                canSendImage: false,
                onPickImage: () {},
                onSendMessage: () {},
              ),
            ),
          ),
        );

        final imageButtonFinder = find.ancestor(
          of: find.byIcon(Icons.image),
          matching: find.byType(IconButton),
        );
        final imageButton = tester.widget<IconButton>(imageButtonFinder);
        expect(imageButton.onPressed, isNull);
      },
    );

    testWidgets('ChatScrollDownFab shows badge count and invokes callback', (
      tester,
    ) async {
      var tapCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScrollDownFab(
              newMessagesWhileScrolledUp: 120,
              onPressed: () => tapCalls++,
            ),
          ),
        ),
      );

      expect(find.text('99+'), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      expect(tapCalls, 1);
    });
  });
}
