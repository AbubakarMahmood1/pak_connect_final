// ChatInteractionHandler supplementary coverage
// Targets: handleMenuAction, deleteChat, toggleChatPin, initialize,
// markChatAsRead success path, interactionIntentStream emit

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

// ─── Fakes ───────────────────────────────────────────────────────────

class _FakeChatsRepository extends Fake implements IChatsRepository {
 final List<ChatId> markedAsRead = [];
 bool shouldThrow = false;

 @override
 Future<void> markChatAsRead(ChatId chatId) async {
 if (shouldThrow) throw Exception('markChatAsRead failed');
 markedAsRead.add(chatId);
 }
}

class _FakeQueue extends Fake implements OfflineMessageQueueContract {
 int removedCount = 0;

 @override
 Future<int> removeMessagesForChat(String chatId) async {
 removedCount++;
 return 3;
 }
}

class _FakeQueueProvider extends Fake implements ISharedMessageQueueProvider {
 final _FakeQueue _queue = _FakeQueue();
 bool _initialized = true;

 @override
 bool get isInitialized => _initialized;

 @override
 Future<void> initialize() async {
 _initialized = true;
 }

 @override
 OfflineMessageQueueContract get messageQueue => _queue;
}

class _FakeChatManagementService extends Fake
 implements ChatManagementService {
 ChatOperationResult? deleteChatResult;
 ChatOperationResult? togglePinResult;
 final bool _isPinned = false;

 @override
 Future<ChatOperationResult> deleteChat(String chatId) async {
 return deleteChatResult ?? ChatOperationResult.failure('not set');
 }

 @override
 Future<ChatOperationResult> toggleChatPin(ChatId chatId) async {
 return togglePinResult ?? ChatOperationResult.failure('not set');
 }

 @override
 bool isChatPinned(ChatId chatId) => _isPinned;
}

ChatListItem _makeChat({String id = 'chat-1', String name = 'Alice'}) {
 return ChatListItem(chatId: ChatId(id),
 contactName: name,
 contactPublicKey: 'pk-$id',
 unreadCount: 0,
 isOnline: false,
 hasUnsentMessages: false,
);
}

void main() {
 Logger.root.level = Level.OFF;

 late _FakeChatsRepository chatsRepo;
 late _FakeChatManagementService mgmtService;
 late _FakeQueueProvider queueProvider;

 setUp(() {
 chatsRepo = _FakeChatsRepository();
 mgmtService = _FakeChatManagementService();
 queueProvider = _FakeQueueProvider();
 });

 ChatInteractionHandler makeHandler({bool includeQueue = true}) {
 return ChatInteractionHandler(chatsRepository: chatsRepo,
 chatManagementService: mgmtService,
 sharedQueueProvider: includeQueue ? queueProvider : null,
);
 }

 group('initialize', () {
 test('completes without error', () async {
 final handler = makeHandler();
 await expectLater(handler.initialize(), completes);
 });
 });

 group('handleMenuAction', () {
 test('unknown action does not throw (logs warning)', () {
 final handler = makeHandler();
 // No context, so open* calls are no-ops, but the switch default logs
 expect(() => handler.handleMenuAction('unknownAction'), returnsNormally);
 });

 test('openProfile action is no-op without context', () {
 final handler = makeHandler();
 expect(() => handler.handleMenuAction('openProfile'), returnsNormally);
 });

 test('openContacts action is no-op without context', () {
 final handler = makeHandler();
 expect(() => handler.handleMenuAction('openContacts'), returnsNormally);
 });

 test('openArchives action is no-op without context', () {
 final handler = makeHandler();
 expect(() => handler.handleMenuAction('openArchives'), returnsNormally);
 });

 test('settings action is no-op without context', () {
 final handler = makeHandler();
 expect(() => handler.handleMenuAction('settings'), returnsNormally);
 });
 });

 group('deleteChat', () {
 test('successful delete emits ChatDeletedIntent', () async {
 mgmtService.deleteChatResult = ChatOperationResult.success('Deleted');

 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.deleteChat(_makeChat());
 await Future<void>.delayed(Duration.zero);

 expect(intents, hasLength(1));
 expect(intents[0], isA<ChatDeletedIntent>());
 await sub.cancel();
 });

 test('successful delete purges queued messages', () async {
 mgmtService.deleteChatResult = ChatOperationResult.success('Deleted');

 final handler = makeHandler();
 await handler.deleteChat(_makeChat());

 expect(queueProvider._queue.removedCount, 1);
 });

 test('failed delete does not emit intent', () async {
 mgmtService.deleteChatResult = ChatOperationResult.failure('Error');

 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.deleteChat(_makeChat());
 await Future<void>.delayed(Duration.zero);

 expect(intents, isEmpty);
 await sub.cancel();
 });

 test('null management service returns safely', () async {
 final handler = ChatInteractionHandler(chatsRepository: chatsRepo,
);

 await expectLater(handler.deleteChat(_makeChat()), completes);
 });

 test('queue init is called when not initialized', () async {
 mgmtService.deleteChatResult = ChatOperationResult.success('OK');
 queueProvider._initialized = false;

 final handler = makeHandler();
 await handler.deleteChat(_makeChat());

 expect(queueProvider.isInitialized, isTrue);
 });
 });

 group('toggleChatPin', () {
 test('successful toggle emits ChatPinToggleIntent', () async {
 mgmtService.togglePinResult = ChatOperationResult.success('Pinned');

 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.toggleChatPin(_makeChat());
 await Future<void>.delayed(Duration.zero);

 expect(intents, hasLength(1));
 expect(intents[0], isA<ChatPinToggleIntent>());
 await sub.cancel();
 });

 test('failed toggle does not emit intent', () async {
 mgmtService.togglePinResult = ChatOperationResult.failure('Fail');

 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);
 await Future<void>.delayed(Duration.zero);

 await handler.toggleChatPin(_makeChat());
 await Future<void>.delayed(Duration.zero);

 expect(intents, isEmpty);
 await sub.cancel();
 });

 test('null management service returns safely', () async {
 final handler = ChatInteractionHandler();
 await expectLater(handler.toggleChatPin(_makeChat()), completes);
 });
 });

 group('markChatAsRead (success path)', () {
 test('marks read via repository', () async {
 final handler = makeHandler();
 final chatId = ChatId('test-chat');

 await handler.markChatAsRead(chatId);

 expect(chatsRepo.markedAsRead, [chatId]);
 });
 });

 group('interactionIntentStream advanced', () {
 test('search intents are emitted correctly', () async {
 final handler = makeHandler();
 final intents = <ChatInteractionIntent>[];
 final sub = handler.interactionIntentStream.listen(intents.add);

 handler.toggleSearch();
 handler.showSearch();
 handler.clearSearch();

 await Future.delayed(Duration.zero);

 expect(intents, hasLength(3));
 expect(intents[0], isA<SearchToggleIntent>());
 expect(intents[1], isA<SearchToggleIntent>());
 expect(intents[2], isA<SearchToggleIntent>());

 await sub.cancel();
 });
 });

 group('showArchiveConfirmation without context', () {
 test('returns false when no context', () async {
 final handler = makeHandler();
 final result = await handler.showArchiveConfirmation(_makeChat());
 expect(result, isFalse);
 });
 });

 group('showDeleteConfirmation without context', () {
 test('returns false when no context', () async {
 final handler = makeHandler();
 final result = await handler.showDeleteConfirmation(_makeChat());
 expect(result, isFalse);
 });
 });

 group('archiveChat without ref', () {
 test('returns early when ref is null', () async {
 final handler = makeHandler();
 await expectLater(handler.archiveChat(_makeChat()), completes);
 });
 });

 group('openChat without context', () {
 test('returns early when context is null', () async {
 final handler = makeHandler();
 await expectLater(handler.openChat(_makeChat()), completes);
 });
 });

 group('showChatContextMenu without context', () {
 test('returns early when context is null', () {
 final handler = makeHandler();
 // No context → immediate return
 handler.showChatContextMenu(_makeChat());
 });
 });
}
