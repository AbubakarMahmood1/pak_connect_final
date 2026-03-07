/// Phase 13c — ChatInteractionHandler: BuildContext-dependent code coverage
/// Targets uncovered lines requiring real BuildContext and/or WidgetRef:
///   openChat body (85-104), openSettings body (131-138),
///   openProfile body (147-154), editDisplayName body (163-248),
///   handleMenuAction switch (253-268), openContacts body (271-284),
///   openArchives body (286-301), showArchiveConfirmation (303-306).
///
/// NOTE: Tests in test/presentation/ must NOT import from package:pak_connect/core/
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/interfaces/i_chat_interaction_handler.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/services/chat_interaction_handler.dart';

// ---------------------------------------------------------------------------
// Fakes & helpers
// ---------------------------------------------------------------------------

ChatListItem _chat({
  String chatId = 'chat-x',
  String contactName = 'Bob',
  String? contactPublicKey = 'pk-bob',
  String? lastMessage = 'Hi',
  int unreadCount = 0,
}) =>
    ChatListItem(
      chatId: ChatId(chatId),
      contactName: contactName,
      contactPublicKey: contactPublicKey,
      lastMessage: lastMessage,
      unreadCount: unreadCount,
      isOnline: false,
      hasUnsentMessages: false,
    );

class _FakeChatsRepo extends Fake implements IChatsRepository {
  bool markReadCalled = false;
  ChatId? lastReadChatId;
  bool shouldThrow = false;

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    if (shouldThrow) throw Exception('repo boom');
    markReadCalled = true;
    lastReadChatId = chatId;
  }
}

class _FakeChatMgmt extends Fake implements ChatManagementService {
  ChatOperationResult? deleteResult;
  ChatOperationResult? togglePinResult;
  bool isPinnedVal = false;

  @override
  Future<ChatOperationResult> deleteChat(String chatId) async =>
      deleteResult ?? ChatOperationResult.failure('no result');

  @override
  Future<ChatOperationResult> toggleChatPin(ChatId chatId) async =>
      togglePinResult ?? ChatOperationResult.failure('no result');

  @override
  bool isChatPinned(ChatId chatId) => isPinnedVal;
}

class _FakeQueue extends Fake implements OfflineMessageQueueContract {
  @override
  Future<int> removeMessagesForChat(String chatId) async => 0;
}

class _FakeQueueProvider extends Fake implements ISharedMessageQueueProvider {
  final _FakeQueue queue;
  bool _initialized;

  _FakeQueueProvider(this.queue, {bool initialized = true})
      : _initialized = initialized;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isInitializing => false;

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  OfflineMessageQueueContract get messageQueue => queue;
}

/// Fake UsernameNotifier that avoids real BLE / preferences dependencies.
class _StubUsernameNotifier extends UsernameNotifier {
  String _name;
  bool updateCalled = false;

  _StubUsernameNotifier([this._name = 'TestUser']);

  @override
  Future<String> build() async => _name;

  @override
  Future<void> updateUsername(String newUsername) async {
    updateCalled = true;
    _name = newUsername;
    state = AsyncValue.data(newUsername);
  }
}

/// Pump a minimal ProviderScope + MaterialApp and capture the BuildContext.
Future<BuildContext> _pumpCtx(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    ),
  );
  return ctx;
}

// ---------------------------------------------------------------------------
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LogRecord> logs;
  late _FakeChatsRepo repo;
  late _FakeChatMgmt mgmt;

  setUp(() {
    logs = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logs.add);

    repo = _FakeChatsRepo();
    mgmt = _FakeChatMgmt();
  });

  tearDown(() {
    Logger.root.clearListeners();
  });

  // =========================================================================
  // openSettings — happy path (lines 131-136) + error path (line 138)
  // =========================================================================
  group('openSettings with real context', () {
    testWidgets('pushes screen, emits intent, and logs', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.openSettings();

      // Lines 131-136 execute synchronously.
      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened settings screen'),
        ),
        isTrue,
      );

      // Replace widget tree so the pushed screen never builds.
      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('catches error when context is deactivated', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);
      await tester.pumpWidget(const SizedBox());

      handler.openSettings();

      expect(
        logs.any(
          (r) =>
              r.level == Level.SEVERE &&
              r.message.contains('Error opening settings'),
        ),
        isTrue,
      );
      await handler.dispose();
    });
  });

  // =========================================================================
  // openProfile — lines 147-154
  // =========================================================================
  group('openProfile with real context', () {
    testWidgets('pushes screen, emits intent, and logs', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.openProfile();

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened profile screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('catches error when context is deactivated', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);
      await tester.pumpWidget(const SizedBox());

      handler.openProfile();

      expect(
        logs.any(
          (r) =>
              r.level == Level.SEVERE &&
              r.message.contains('Error opening profile'),
        ),
        isTrue,
      );
      await handler.dispose();
    });
  });

  // =========================================================================
  // openContacts — lines 271-284
  // =========================================================================
  group('openContacts with real context', () {
    testWidgets('pushes screen, emits intent, and logs', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.openContacts();

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened contacts screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('catches error when context is deactivated', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);
      await tester.pumpWidget(const SizedBox());

      handler.openContacts();

      expect(
        logs.any(
          (r) =>
              r.level == Level.SEVERE &&
              r.message.contains('Error opening contacts'),
        ),
        isTrue,
      );
      await handler.dispose();
    });
  });

  // =========================================================================
  // openArchives — lines 286-301
  // =========================================================================
  group('openArchives with real context', () {
    testWidgets('pushes screen, emits intent, and logs', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.openArchives();

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened archives screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('catches error when context is deactivated', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);
      await tester.pumpWidget(const SizedBox());

      handler.openArchives();

      expect(
        logs.any(
          (r) =>
              r.level == Level.SEVERE &&
              r.message.contains('Error opening archives'),
        ),
        isTrue,
      );
      await handler.dispose();
    });
  });

  // =========================================================================
  // openChat — lines 85,87,89-95,98-99,102,104
  // =========================================================================
  group('openChat with real context', () {
    testWidgets('marks as read and begins navigation', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(
        context: ctx,
        chatsRepository: repo,
        chatManagementService: mgmt,
      );

      // Fire openChat without awaiting—it suspends at await Navigator.push.
      unawaited(handler.openChat(_chat()));

      // Give markChatAsRead a chance to resolve.
      await tester.pump(Duration.zero);
      tester.takeException();

      expect(repo.markReadCalled, isTrue);
      expect(repo.lastReadChatId, ChatId('chat-x'));

      // Tear down before the ChatScreen builds.
      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('catches error when context is deactivated', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(
        context: ctx,
        chatsRepository: repo,
      );
      await tester.pumpWidget(const SizedBox());

      await handler.openChat(_chat());

      expect(repo.markReadCalled, isTrue);
      expect(
        logs.any(
          (r) =>
              r.level == Level.SEVERE &&
              r.message.contains('Error opening chat'),
        ),
        isTrue,
      );
      await handler.dispose();
    });
  });

  // =========================================================================
  // showArchiveConfirmation — lines 303-306 + dialog body
  // =========================================================================
  group('showArchiveConfirmation with real context', () {
    testWidgets('confirm returns true', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      final future = handler.showArchiveConfirmation(_chat(contactName: 'Al'));
      await tester.pumpAndSettle();

      expect(find.text('Archive Chat'), findsOneWidget);
      expect(find.text('Archive chat with Al?'), findsOneWidget);

      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      expect(await future, isTrue);
      await handler.dispose();
    });

    testWidgets('cancel returns false', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      final future = handler.showArchiveConfirmation(_chat());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await future, isFalse);
      await handler.dispose();
    });

    testWidgets('dismiss returns false', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      final future = handler.showArchiveConfirmation(_chat());
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(await future, isFalse);
      await handler.dispose();
    });
  });

  // =========================================================================
  // showDeleteConfirmation
  // =========================================================================
  group('showDeleteConfirmation with real context', () {
    testWidgets('confirm returns true', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      final future =
          handler.showDeleteConfirmation(_chat(contactName: 'Carol'));
      await tester.pumpAndSettle();

      expect(find.text('Delete Chat'), findsOneWidget);
      expect(find.text('Delete chat with Carol?'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await future, isTrue);
      await handler.dispose();
    });

    testWidgets('cancel returns false', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      final future = handler.showDeleteConfirmation(_chat());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await future, isFalse);
      await handler.dispose();
    });
  });

  // =========================================================================
  // handleMenuAction with real context — lines 253-268
  // =========================================================================
  group('handleMenuAction with real context', () {
    testWidgets('openProfile dispatches', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.handleMenuAction('openProfile');

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened profile screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('openContacts dispatches', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.handleMenuAction('openContacts');

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened contacts screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('openArchives dispatches', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.handleMenuAction('openArchives');

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened archives screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('settings dispatches', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.handleMenuAction('settings');

      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Opened settings screen'),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await handler.dispose();
    });

    testWidgets('unknown action logs warning', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(context: ctx);

      handler.handleMenuAction('nope');

      expect(
        logs.any(
          (r) =>
              r.level == Level.WARNING &&
              r.message.contains('Unknown menu action'),
        ),
        isTrue,
      );
      await handler.dispose();
    });
  });

  // =========================================================================
  // editDisplayName — lines 163-248
  // =========================================================================
  group('editDisplayName with real context and ref', () {
    testWidgets('shows bottom sheet and returns new name on Save',
        (tester) async {
      late BuildContext capturedCtx;
      late WidgetRef capturedRef;
      final notifier = _StubUsernameNotifier('OldName');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usernameProvider.overrideWith(() => notifier),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedCtx = context;
                  capturedRef = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      final handler = ChatInteractionHandler(
        context: capturedCtx,
        ref: capturedRef,
        chatsRepository: repo,
      );

      final future = handler.editDisplayName('OldName');
      await tester.pumpAndSettle();

      expect(find.text('Edit Display Name'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'NewName');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final result = await future;
      expect(result, 'NewName');
      expect(notifier.updateCalled, isTrue);
      expect(
        logs.any(
          (r) =>
              r.level == Level.INFO &&
              r.message.contains('Display name updated'),
        ),
        isTrue,
      );
      await handler.dispose();
    });

    testWidgets('returns null when dismissed via close icon', (tester) async {
      late BuildContext capturedCtx;
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usernameProvider.overrideWith(() => _StubUsernameNotifier()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedCtx = context;
                  capturedRef = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      final handler = ChatInteractionHandler(
        context: capturedCtx,
        ref: capturedRef,
      );

      final future = handler.editDisplayName('OldName');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(await future, isNull);
      await handler.dispose();
    });

    testWidgets('returns null when same name is submitted', (tester) async {
      late BuildContext capturedCtx;
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usernameProvider.overrideWith(() => _StubUsernameNotifier()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedCtx = context;
                  capturedRef = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      final handler = ChatInteractionHandler(
        context: capturedCtx,
        ref: capturedRef,
      );

      final future = handler.editDisplayName('SameName');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'SameName');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await future, isNull);
      await handler.dispose();
    });

    testWidgets('onSubmitted via keyboard returns new name', (tester) async {
      late BuildContext capturedCtx;
      late WidgetRef capturedRef;
      final notifier = _StubUsernameNotifier();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usernameProvider.overrideWith(() => notifier),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedCtx = context;
                  capturedRef = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      final handler = ChatInteractionHandler(
        context: capturedCtx,
        ref: capturedRef,
      );

      final future = handler.editDisplayName('Old');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Submitted');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final result = await future;
      expect(result, 'Submitted');
      expect(notifier.updateCalled, isTrue);
      await handler.dispose();
    });

    testWidgets('empty input via Save does NOT dismiss', (tester) async {
      late BuildContext capturedCtx;
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usernameProvider.overrideWith(() => _StubUsernameNotifier()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  capturedCtx = context;
                  capturedRef = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      final handler = ChatInteractionHandler(
        context: capturedCtx,
        ref: capturedRef,
      );

      final future = handler.editDisplayName('Current');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Bottom sheet should still be open
      expect(find.text('Edit Display Name'), findsOneWidget);

      // Dismiss via close
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(await future, isNull);
      await handler.dispose();
    });
  });

  // =========================================================================
  // showChatContextMenu with real context
  // =========================================================================
  group('showChatContextMenu with real context (phase13c)', () {
    testWidgets('shows menu items for zero-unread chat', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(
        context: ctx,
        chatsRepository: repo,
        chatManagementService: mgmt,
      );

      handler.showChatContextMenu(_chat(unreadCount: 0));
      await tester.pumpAndSettle();

      expect(find.text('Archive Chat'), findsOneWidget);
      expect(find.text('Delete Chat'), findsOneWidget);
      expect(find.text('Mark as Unread'), findsOneWidget);
      expect(find.text('Pin Chat'), findsOneWidget);

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await handler.dispose();
    });

    testWidgets('shows Mark as Read for unread chat', (tester) async {
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(
        context: ctx,
        chatsRepository: repo,
        chatManagementService: mgmt,
      );

      handler.showChatContextMenu(_chat(unreadCount: 3));
      await tester.pumpAndSettle();

      expect(find.text('Mark as Read'), findsOneWidget);

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await handler.dispose();
    });

    testWidgets('shows Unpin Chat when pinned', (tester) async {
      mgmt.isPinnedVal = true;
      final ctx = await _pumpCtx(tester);
      final handler = ChatInteractionHandler(
        context: ctx,
        chatsRepository: repo,
        chatManagementService: mgmt,
      );

      handler.showChatContextMenu(_chat());
      await tester.pumpAndSettle();

      expect(find.text('Unpin Chat'), findsOneWidget);

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await handler.dispose();
    });
  });
}
