import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/widgets/message_bubble.dart';

Message _message({
  required String id,
  bool isFromMe = true,
  MessageStatus status = MessageStatus.sent,
  String content = 'Hello world',
  DateTime? timestamp,
}) {
  return Message(
    id: MessageId(id),
    chatId: ChatId('chat-1'),
    content: content,
    timestamp: timestamp ?? DateTime(2026, 1, 1, 9, 5),
    isFromMe: isFromMe,
    status: status,
  );
}

EnhancedMessage _messageWithAttachment({
  required String id,
  bool isFromMe = true,
  String content = 'Attachment message',
}) {
  return EnhancedMessage(
    id: MessageId(id),
    chatId: ChatId('chat-1'),
    content: content,
    timestamp: DateTime(2026, 1, 1, 9, 5),
    isFromMe: isFromMe,
    status: MessageStatus.failed,
    attachments: const [
      MessageAttachment(
        id: 'attachment-1',
        type: 'image/png',
        name: 'photo.png',
        size: 2048,
      ),
    ],
  );
}

Future<void> _pumpBubble(
  WidgetTester tester, {
  required Message message,
  String? searchQuery,
  VoidCallback? onLongPress,
  VoidCallback? onRetry,
  Function(MessageId messageId, bool deleteForEveryone)? onDelete,
  bool showStatus = true,
}) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: MessageBubble(
            message: message,
            searchQuery: searchQuery,
            onLongPress: onLongPress,
            onRetry: onRetry,
            onDelete: onDelete,
            showStatus: showStatus,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('MessageBubble', () {
    testWidgets('renders plain text, time, and sent icon for own message', (
      tester,
    ) async {
      await _pumpBubble(tester, message: _message(id: 'm-1'));

      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('09:05'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('hides status icon when showStatus is false', (tester) async {
      await _pumpBubble(
        tester,
        message: _message(id: 'm-2'),
        showStatus: false,
      );

      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
    });

    testWidgets('shows retry pill for failed status and invokes callback', (
      tester,
    ) async {
      var retryCalls = 0;
      await _pumpBubble(
        tester,
        message: _message(id: 'm-3', status: MessageStatus.failed),
        onRetry: () => retryCalls++,
      );

      expect(find.text('Tap to retry'), findsOneWidget);
      await tester.tap(find.text('Tap to retry'));
      await tester.pump();

      expect(retryCalls, 1);
    });

    testWidgets('renders sending indicator and delivered icon branches', (
      tester,
    ) async {
      await _pumpBubble(
        tester,
        message: _message(id: 'm-4', status: MessageStatus.sending),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await _pumpBubble(
        tester,
        message: _message(id: 'm-5', status: MessageStatus.delivered),
      );
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });

    testWidgets(
      'renders attachment metadata and retry button for enhanced message',
      (tester) async {
        var retryCalls = 0;
        await _pumpBubble(
          tester,
          message: _messageWithAttachment(id: 'm-6'),
          onRetry: () => retryCalls++,
        );

        expect(find.text('photo.png'), findsOneWidget);
        expect(find.text('2.0 KB • image/png'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        expect(retryCalls, 1);
      },
    );

    testWidgets('uses highlighted rich text when search query is present', (
      tester,
    ) async {
      await _pumpBubble(
        tester,
        message: _message(id: 'm-7', content: 'Hello world hello'),
        searchQuery: 'hello',
      );

      expect(find.byType(RichText), findsWidgets);
      expect(find.text('Hello world hello'), findsNothing);
      expect(find.text('09:05'), findsOneWidget);
    });

    testWidgets(
      'shows context menu copy action and delete confirmation callback',
      (tester) async {
        var clipboardSet = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboardSet = true;
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        MessageId? deletedId;
        bool? deleteForEveryone;

        await _pumpBubble(
          tester,
          message: _message(id: 'm-8', status: MessageStatus.sent),
          onDelete: (id, deleteAll) {
            deletedId = id;
            deleteForEveryone = deleteAll;
          },
        );

        await tester.longPress(find.byType(MessageBubble));
        await tester.pumpAndSettle();

        expect(find.text('Copy Message'), findsOneWidget);
        expect(find.text('Delete Message'), findsOneWidget);

        await tester.tap(find.text('Copy Message'));
        await tester.pumpAndSettle();

        expect(clipboardSet, isTrue);
        expect(find.text('Copy Message'), findsNothing);

        await tester.longPress(find.byType(MessageBubble));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete Message'));
        await tester.pumpAndSettle();

        expect(find.text('Delete Message?'), findsOneWidget);
        expect(find.text('Delete for everyone'), findsOneWidget);

        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(deletedId?.value, 'm-8');
        expect(deleteForEveryone, isTrue);
      },
    );

    testWidgets('uses custom long press callback when provided', (tester) async {
      var longPressCalls = 0;
      await _pumpBubble(
        tester,
        message: _message(id: 'm-9'),
        onLongPress: () => longPressCalls++,
      );

      await tester.longPress(find.byType(MessageBubble));
      await tester.pumpAndSettle();

      expect(longPressCalls, 1);
      expect(find.text('Copy Message'), findsNothing);
    });
  });
}
