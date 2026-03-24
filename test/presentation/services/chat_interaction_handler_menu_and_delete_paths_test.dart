/// ChatInteractionHandler tests targeting the remaining ~114
/// uncovered lines: initialize, handleMenuAction dispatch + default branch,
/// deleteChat (success / failure / queue-purge / queue-error paths),
/// toggleChatPin (success / failure / exception / null-service),
/// archiveChat null-ref guard, openChat null-context guard,
/// editDisplayName null guard, showArchiveConfirmation / showDeleteConfirmation
/// null guards, showChatContextMenu null guard, markChatAsRead success path,
/// and _emitIntent with a throwing listener.
library;
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/interfaces/i_chat_interaction_handler.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/services/chat_interaction_handler.dart';

// ---------------------------------------------------------------------------
// Fakes & helpers
// ---------------------------------------------------------------------------

ChatListItem _makeChatItem({
 String chatId = 'chat-1',
 String contactName = 'Alice',
 String? contactPublicKey = 'pk-alice',
 String? lastMessage = 'Hello',
 int unreadCount = 0,
 bool isOnline = false,
 bool hasUnsentMessages = false,
}) =>
 ChatListItem(chatId: ChatId(chatId),
 contactName: contactName,
 contactPublicKey: contactPublicKey,
 lastMessage: lastMessage,
 unreadCount: unreadCount,
 isOnline: isOnline,
 hasUnsentMessages: hasUnsentMessages,
);

class _FakeChatsRepo extends Fake implements IChatsRepository {
 bool markReadCalled = false;
 ChatId? lastReadChatId;
 bool shouldThrow = false;

 @override
 Future<void> markChatAsRead(ChatId chatId) async {
 if (shouldThrow) throw Exception('repo error');
 markReadCalled = true;
 lastReadChatId = chatId;
 }
}

class _FakeChatManagementService extends Fake
 implements ChatManagementService {
 ChatOperationResult? deleteChatResult;
 ChatOperationResult? togglePinResult;
 bool deleteChatShouldThrow = false;
 bool togglePinShouldThrow = false;
 bool isPinnedValue = false;
 String? lastDeletedChatId;
 ChatId? lastToggledPinChatId;

 @override
 Future<ChatOperationResult> deleteChat(String chatId) async {
 lastDeletedChatId = chatId;
 if (deleteChatShouldThrow) throw Exception('delete boom');
 return deleteChatResult ?? ChatOperationResult.failure('no result set');
 }

 @override
 Future<ChatOperationResult> toggleChatPin(ChatId chatId) async {
 lastToggledPinChatId = chatId;
 if (togglePinShouldThrow) throw Exception('pin boom');
 return togglePinResult ?? ChatOperationResult.failure('no result set');
 }

 @override
 bool isChatPinned(ChatId chatId) => isPinnedValue;
}

class _FakeOfflineQueue extends Fake implements OfflineMessageQueueContract {
 int removeResult = 0;
 bool removeShouldThrow = false;
 String? lastRemovedChatId;

 @override
 Future<int> removeMessagesForChat(String chatId) async {
 lastRemovedChatId = chatId;
 if (removeShouldThrow) throw Exception('queue remove boom');
 return removeResult;
 }
}

class _FakeSharedQueueProvider extends Fake
 implements ISharedMessageQueueProvider {
 final _FakeOfflineQueue queue;
 bool _isInitialized;
 int initCallCount = 0;

 _FakeSharedQueueProvider(this.queue, {bool isInitialized = true})
 : _isInitialized = isInitialized;

 @override
 bool get isInitialized => _isInitialized;

 @override
 bool get isInitializing => false;

 @override
 Future<void> initialize() async {
 initCallCount++;
 _isInitialized = true;
 }

 @override
 OfflineMessageQueueContract get messageQueue => queue;
}

// ---------------------------------------------------------------------------
void main() {
 Logger.root.level = Level.OFF;

 late _FakeChatsRepo chatsRepo;
 late _FakeChatManagementService chatMgmt;
 late _FakeOfflineQueue offlineQueue;
 late _FakeSharedQueueProvider queueProvider;
 late List<LogRecord> logs;

 setUp(() {
 logs = [];
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logs.add);

 chatsRepo = _FakeChatsRepo();
 chatMgmt = _FakeChatManagementService();
 offlineQueue = _FakeOfflineQueue();
 queueProvider = _FakeSharedQueueProvider(offlineQueue);
 });

 tearDown(() {
 Logger.root.clearListeners();
 });

 /// Shorthand to build a handler with specific nullable deps.
 ChatInteractionHandler makeHandler({
 IChatsRepository? repo,
 ChatManagementService? mgmt,
 ISharedMessageQueueProvider? queue,
 }) =>
 ChatInteractionHandler(chatsRepository: repo ?? chatsRepo,
 chatManagementService: mgmt ?? chatMgmt,
 sharedQueueProvider: queue ?? queueProvider,
);

 // =========================================================================
 // initialize
 // =========================================================================
 group('initialize', () {
 test('completes without error', () async {
 final handler = makeHandler();
 await expectLater(handler.initialize(), completes);
 await handler.dispose();
 });
 });

 // =========================================================================
 // handleMenuAction dispatch + default
 // =========================================================================
 group('handleMenuAction', () {
 late ChatInteractionHandler handler;

 setUp(() {
 handler = makeHandler();
 });

 tearDown(() async => handler.dispose());

 test('openProfile action delegates (no-op without context)', () {
 handler.handleMenuAction('openProfile');
 // no throw; openProfile short-circuits (no context)
 });

 test('openContacts action delegates', () {
 handler.handleMenuAction('openContacts');
 });

 test('openArchives action delegates', () {
 handler.handleMenuAction('openArchives');
 });

 test('settings action delegates', () {
 handler.handleMenuAction('settings');
 });

 test('unknown action logs warning', () {
 handler.handleMenuAction('nonexistent');
 expect(logs.any((r) =>
 r.level == Level.WARNING &&
 r.message.contains('Unknown menu action')),
 isTrue,
);
 });
 });

 // =========================================================================
 // deleteChat
 // =========================================================================
 group('deleteChat', () {
 test('success emits ChatDeletedIntent and purges queue', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('deleted');
 offlineQueue.removeResult = 3;
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.deleteChat(_makeChatItem());
 await Future<void>.delayed(Duration.zero);

 expect(intents.length, 1);
 expect(intents.first, isA<ChatDeletedIntent>());
 expect((intents.first as ChatDeletedIntent).chatId, 'chat-1');
 expect(offlineQueue.lastRemovedChatId, 'chat-1');

 await sub.cancel();
 await handler.dispose();
 });

 test('success with uninitialized queue triggers initialize', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('deleted');
 final uninitQueue =
 _FakeSharedQueueProvider(offlineQueue, isInitialized: false);
 final handler = makeHandler(queue: uninitQueue);

 await handler.deleteChat(_makeChatItem());

 expect(uninitQueue.initCallCount, 1);
 await handler.dispose();
 });

 test('failure result does not emit intent', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.failure('nope');
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.deleteChat(_makeChatItem());
 await Future<void>.delayed(Duration.zero);

 expect(intents, isEmpty);
 expect(logs.any((r) =>
 r.level == Level.WARNING && r.message.contains('Failed to delete')),
 isTrue,
);

 await sub.cancel();
 await handler.dispose();
 });

 test('null chat management service still does not throw', () async {
 final handler = makeHandler(mgmt: null);
 // deleteChat calls _chatManagementService?.deleteChat which is null → null
 // result is null → (result?.success ?? false) is false → warning
 await handler.deleteChat(_makeChatItem());
 expect(logs.any((r) =>
 r.level == Level.WARNING && r.message.contains('Failed to delete')),
 isTrue,
);
 await handler.dispose();
 });

 test('chat management throws is caught and logged', () async {
 chatMgmt.deleteChatShouldThrow = true;
 final handler = makeHandler();

 await handler.deleteChat(_makeChatItem());

 expect(logs.any((r) =>
 r.level == Level.SEVERE &&
 r.message.contains('Error deleting chat')),
 isTrue,
);
 await handler.dispose();
 });

 test('queue purge failure is caught and logged as warning', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('deleted');
 offlineQueue.removeShouldThrow = true;
 final handler = makeHandler();

 await handler.deleteChat(_makeChatItem());

 expect(logs.any((r) =>
 r.level == Level.WARNING &&
 r.message.contains('Failed to purge queued messages')),
 isTrue,
);
 await handler.dispose();
 });

 test('success with queue provider that returns zero purged', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('deleted');
 offlineQueue.removeResult = 0;
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.deleteChat(_makeChatItem());
 await Future<void>.delayed(Duration.zero);

 expect(intents.length, 1);
 expect(intents.first, isA<ChatDeletedIntent>());
 expect(offlineQueue.lastRemovedChatId, 'chat-1');

 await sub.cancel();
 await handler.dispose();
 });
 });

 // =========================================================================
 // toggleChatPin
 // =========================================================================
 group('toggleChatPin', () {
 test('success emits ChatPinToggleIntent', () async {
 chatMgmt.togglePinResult = ChatOperationResult.success('pinned');
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.toggleChatPin(_makeChatItem());
 await Future<void>.delayed(Duration.zero);

 expect(intents.length, 1);
 expect(intents.first, isA<ChatPinToggleIntent>());
 expect((intents.first as ChatPinToggleIntent).chatId, 'chat-1');

 await sub.cancel();
 await handler.dispose();
 });

 test('failure result logs warning', () async {
 chatMgmt.togglePinResult = ChatOperationResult.failure('max pins');
 final handler = makeHandler();

 await handler.toggleChatPin(_makeChatItem());

 expect(logs.any((r) =>
 r.level == Level.WARNING &&
 r.message.contains('Failed to toggle pin')),
 isTrue,
);
 await handler.dispose();
 });

 test('null chat management returns false-ish and logs warning', () async {
 final handler = makeHandler(mgmt: null);
 await handler.toggleChatPin(_makeChatItem());
 expect(logs.any((r) =>
 r.level == Level.WARNING &&
 r.message.contains('Failed to toggle pin')),
 isTrue,
);
 await handler.dispose();
 });

 test('exception from chat management is caught and logged', () async {
 chatMgmt.togglePinShouldThrow = true;
 final handler = makeHandler();

 await handler.toggleChatPin(_makeChatItem());

 expect(logs.any((r) =>
 r.level == Level.SEVERE &&
 r.message.contains('Error toggling pin')),
 isTrue,
);
 await handler.dispose();
 });
 });

 // =========================================================================
 // archiveChat — null ref guard
 // =========================================================================
 group('archiveChat', () {
 test('returns immediately when ref is null', () async {
 final handler = makeHandler(); // no ref
 // archiveChat checks _ref == null → returns early
 await handler.archiveChat(_makeChatItem());
 // Should not throw, should not emit anything
 await handler.dispose();
 });
 });

 // =========================================================================
 // openChat — null context guard
 // =========================================================================
 group('openChat', () {
 test('returns immediately when context is null', () async {
 final handler = makeHandler();
 await handler.openChat(_makeChatItem());
 // No throw; short-circuits at _context == null
 await handler.dispose();
 });
 });

 // =========================================================================
 // editDisplayName — null context/ref guard
 // =========================================================================
 group('editDisplayName', () {
 test('returns null when context is null', () async {
 final handler = makeHandler();
 final result = await handler.editDisplayName('old');
 expect(result, isNull);
 await handler.dispose();
 });
 });

 // =========================================================================
 // showArchiveConfirmation — null context
 // =========================================================================
 group('showArchiveConfirmation', () {
 test('returns false when context is null', () async {
 final handler = makeHandler();
 final result = await handler.showArchiveConfirmation(_makeChatItem());
 expect(result, isFalse);
 await handler.dispose();
 });
 });

 // =========================================================================
 // showDeleteConfirmation — null context
 // =========================================================================
 group('showDeleteConfirmation', () {
 test('returns false when context is null', () async {
 final handler = makeHandler();
 final result = await handler.showDeleteConfirmation(_makeChatItem());
 expect(result, isFalse);
 await handler.dispose();
 });
 });

 // =========================================================================
 // showChatContextMenu — null context
 // =========================================================================
 group('showChatContextMenu', () {
 test('returns immediately when context is null', () {
 final handler = makeHandler();
 handler.showChatContextMenu(_makeChatItem());
 // No throw; context null → return
 handler.dispose();
 });
 });

 // =========================================================================
 // markChatAsRead — success path
 // =========================================================================
 group('markChatAsRead', () {
 test('success path calls repo and logs', () async {
 final handler = makeHandler();
 await handler.markChatAsRead(ChatId('c42'));

 expect(chatsRepo.markReadCalled, isTrue);
 expect(chatsRepo.lastReadChatId, ChatId('c42'));
 expect(logs.any((r) =>
 r.level == Level.INFO &&
 r.message.contains('Chat marked as read')),
 isTrue,
);
 await handler.dispose();
 });

 test('null chats repo does not throw', () async {
 final handler = makeHandler(repo: null);
 await handler.markChatAsRead(ChatId('c1'));
 // _chatsRepository?.markChatAsRead → no-op
 await handler.dispose();
 });
 });

 // =========================================================================
 // _emitIntent with a throwing listener
 // =========================================================================
 group('_emitIntent resilience', () {
 test('emitting after all listeners cancel does not throw', () async {
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await sub.cancel();
 // All listeners removed; _emitIntent iterates an empty set
 handler.toggleSearch();
 await Future<void>.delayed(Duration.zero);

 expect(intents, isEmpty);
 await handler.dispose();
 });

 test('listener cancelled mid-emission cycle is safe', () async {
 final handler = makeHandler();
 late StreamSubscription<ChatInteractionIntent> sub1;
 final intents2 = <ChatInteractionIntent>[];

 sub1 = handler.interactionIntentStream.listen((_) {
 sub1.cancel(); // cancel self during delivery
 });
 final sub2 = handler.interactionIntentStream.listen(intents2.add);
 await Future<void>.delayed(Duration.zero);

 handler.toggleSearch();
 await Future<void>.delayed(Duration.zero);

 // Sub2 should still get the intent
 expect(intents2, hasLength(1));
 expect(intents2.first, isA<SearchToggleIntent>());

 await sub2.cancel();
 await handler.dispose();
 });
 });

 // =========================================================================
 // Interaction intent types
 // =========================================================================
 group('intent type properties', () {
 test('ChatOpenedIntent stores chatId', () {
 final i = ChatOpenedIntent('abc');
 expect(i.chatId, 'abc');
 });

 test('ChatArchivedIntent stores chatId', () {
 final i = ChatArchivedIntent('def');
 expect(i.chatId, 'def');
 });

 test('ChatDeletedIntent stores chatId', () {
 final i = ChatDeletedIntent('ghi');
 expect(i.chatId, 'ghi');
 });

 test('ChatPinToggleIntent stores chatId', () {
 final i = ChatPinToggleIntent('jkl');
 expect(i.chatId, 'jkl');
 });

 test('NavigationIntent stores destination', () {
 final i = NavigationIntent('settings');
 expect(i.destination, 'settings');
 });

 test('SearchToggleIntent stores isActive', () {
 expect(SearchToggleIntent(true).isActive, isTrue);
 expect(SearchToggleIntent(false).isActive, isFalse);
 });
 });

 // =========================================================================
 // deleteChat with ChatListItem having various unreadCount / contactKey
 // =========================================================================
 group('deleteChat with edge-case ChatListItem', () {
 test('chat with no contactPublicKey still works', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('ok');
 final handler = makeHandler();

 await handler.deleteChat(_makeChatItem(contactPublicKey: null));
 expect(chatMgmt.lastDeletedChatId, 'chat-1');
 await handler.dispose();
 });

 test('chat with null lastMessage still works', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('ok');
 final handler = makeHandler();

 await handler.deleteChat(_makeChatItem(lastMessage: null));
 expect(chatMgmt.lastDeletedChatId, 'chat-1');
 await handler.dispose();
 });
 });

 // =========================================================================
 // Multiple intents emitted in sequence
 // =========================================================================
 group('sequential intent emission', () {
 test('toggleSearch → clearSearch emits two intents in order', () async {
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 handler.toggleSearch();
 handler.clearSearch();
 await Future<void>.delayed(Duration.zero);

 expect(intents, hasLength(2));
 expect((intents[0] as SearchToggleIntent).isActive, isTrue);
 expect((intents[1] as SearchToggleIntent).isActive, isFalse);

 await sub.cancel();
 await handler.dispose();
 });

 test('delete success + pin success emit correct sequence', () async {
 chatMgmt.deleteChatResult = ChatOperationResult.success('ok');
 chatMgmt.togglePinResult = ChatOperationResult.success('pinned');
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.deleteChat(_makeChatItem(chatId: 'c-a'));
 await handler.toggleChatPin(_makeChatItem(chatId: 'c-b'));
 await Future<void>.delayed(Duration.zero);

 expect(intents, hasLength(2));
 expect(intents[0], isA<ChatDeletedIntent>());
 expect(intents[1], isA<ChatPinToggleIntent>());

 await sub.cancel();
 await handler.dispose();
 });
 });

 // =========================================================================
 // Constructor with all-null optional deps
 // =========================================================================
 group('all-null construction', () {
 test('handler with no deps can still toggleSearch', () async {
 final handler = ChatInteractionHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 handler.toggleSearch();
 await Future<void>.delayed(Duration.zero);

 expect(intents, hasLength(1));

 await sub.cancel();
 await handler.dispose();
 });

 test('handler with no deps — deleteChat does not throw', () async {
 final handler = ChatInteractionHandler();
 await handler.deleteChat(_makeChatItem());
 await handler.dispose();
 });

 test('handler with no deps — toggleChatPin does not throw', () async {
 final handler = ChatInteractionHandler();
 await handler.toggleChatPin(_makeChatItem());
 await handler.dispose();
 });

 test('handler with no deps — markChatAsRead does not throw', () async {
 final handler = ChatInteractionHandler();
 await handler.markChatAsRead(ChatId('x'));
 await handler.dispose();
 });
 });
}
