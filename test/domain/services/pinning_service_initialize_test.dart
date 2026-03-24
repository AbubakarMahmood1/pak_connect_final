// PinningService coverage
// Targets: toggleMessageStar, toggleChatPin, getStarredMessages,
// isMessageStarred, isChatPinned, addPinnedChat, removePinnedChat,
// removeStarredMessagesForChat, messageUpdates stream, dispose

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/services/pinning_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeChatsRepo extends Fake implements IChatsRepository {
 List<ChatListItem> chats = [];

 @override
 Future<List<ChatListItem>> getAllChats({
 List<dynamic>? nearbyDevices,
 Map<String, dynamic>? discoveryData,
 String? searchQuery,
 int? limit,
 int? offset,
 }) async =>
 chats;
}

class _FakeMessageRepo extends Fake implements IMessageRepository {
 final Map<String, List<Message>> messages = {};

 @override
 Future<List<Message>> getMessages(ChatId chatId) async =>
 messages[chatId.value] ?? [];
}

void main() {
 Logger.root.level = Level.OFF;

 late _FakeChatsRepo chatsRepo;
 late _FakeMessageRepo messageRepo;
 late PinningService service;

 setUp(() {
 WidgetsFlutterBinding.ensureInitialized();
 SharedPreferences.setMockInitialValues({});
 chatsRepo = _FakeChatsRepo();
 messageRepo = _FakeMessageRepo();
 service = PinningService(chatsRepository: chatsRepo,
 messageRepository: messageRepo,
);
 });

 tearDown(() async {
 await service.dispose();
 });

 group('initialize', () {
 test('loads from empty SharedPreferences', () async {
 await service.initialize();
 expect(service.pinnedChatsCount, 0);
 expect(service.starredMessagesCount, 0);
 });

 test('restores saved state from SharedPreferences', () async {
 SharedPreferences.setMockInitialValues({
 'starred_messages': ['msg-1', 'msg-2'],
 'pinned_chats': ['chat-a'],
 });

 await service.initialize();

 expect(service.starredMessagesCount, 2);
 expect(service.isMessageStarred(MessageId('msg-1')), isTrue);
 expect(service.pinnedChatsCount, 1);
 expect(service.isChatPinned('chat-a'), isTrue);
 });
 });

 group('toggleMessageStar', () {
 test('stars an unstarred message', () async {
 final msgId = MessageId('m1');
 final result = await service.toggleMessageStar(msgId);

 expect(result.success, isTrue);
 expect(result.message, 'Message starred');
 expect(service.isMessageStarred(msgId), isTrue);
 expect(service.starredMessagesCount, 1);
 });

 test('unstars a starred message', () async {
 final msgId = MessageId('m1');
 await service.toggleMessageStar(msgId); // star
 final result = await service.toggleMessageStar(msgId); // unstar

 expect(result.success, isTrue);
 expect(result.message, 'Message unstarred');
 expect(service.isMessageStarred(msgId), isFalse);
 });

 test('emits events on star/unstar', () async {
 final events = <MessageUpdateEvent>[];
 final sub = service.messageUpdates.listen(events.add);
 await Future<void>.delayed(Duration.zero);

 await service.toggleMessageStar(MessageId('m1'));
 await Future<void>.delayed(Duration.zero);

 expect(events, hasLength(1));
 expect(events[0].messageId, MessageId('m1'));

 await sub.cancel();
 });
 });

 group('toggleChatPin', () {
 test('pins a chat', () async {
 final result = await service.toggleChatPin('chat-1');

 expect(result.success, isTrue);
 expect(result.message, 'Chat pinned');
 expect(service.isChatPinned('chat-1'), isTrue);
 expect(service.pinnedChatsCount, 1);
 });

 test('unpins a pinned chat', () async {
 await service.toggleChatPin('chat-1'); // pin
 final result = await service.toggleChatPin('chat-1'); // unpin

 expect(result.success, isTrue);
 expect(result.message, 'Chat unpinned');
 expect(service.isChatPinned('chat-1'), isFalse);
 });

 test('enforces maximum 3 pinned chats', () async {
 await service.toggleChatPin('c1');
 await service.toggleChatPin('c2');
 await service.toggleChatPin('c3');
 final result = await service.toggleChatPin('c4');

 expect(result.success, isFalse);
 expect(result.message, 'Maximum 3 chats can be pinned');
 expect(service.pinnedChatsCount, 3);
 });
 });

 group('getStarredMessages', () {
 test('returns starred messages from chats', () async {
 chatsRepo.chats = [
 ChatListItem(chatId: ChatId('chat-1'),
 contactName: 'Alice',
 unreadCount: 0,
 isOnline: false,
 hasUnsentMessages: false,
),
];

 final msg = Message(id: MessageId('m1'),
 chatId: ChatId('chat-1'),
 content: 'Hello',
 timestamp: DateTime.now(),
 isFromMe: true,
 status: MessageStatus.sent,
);
 messageRepo.messages['chat-1'] = [msg];

 await service.toggleMessageStar(MessageId('m1'));

 final starred = await service.getStarredMessages();
 expect(starred, hasLength(1));
 expect(starred[0].isStarred, isTrue);
 });

 test('returns empty list when no starred messages', () async {
 final starred = await service.getStarredMessages();
 expect(starred, isEmpty);
 });
 });

 group('addPinnedChat / removePinnedChat / isPinnedChat', () {
 test('add and check pinned chat', () {
 service.addPinnedChat('chat-x');
 expect(service.isPinnedChat('chat-x'), isTrue);
 expect(service.pinnedChatsCount, 1);
 });

 test('remove pinned chat', () {
 service.addPinnedChat('chat-x');
 service.removePinnedChat('chat-x');
 expect(service.isPinnedChat('chat-x'), isFalse);
 });
 });

 group('removeStarredMessagesForChat', () {
 test('removes starred message IDs by list', () async {
 await service.toggleMessageStar(MessageId('m1'));
 await service.toggleMessageStar(MessageId('m2'));
 await service.toggleMessageStar(MessageId('m3'));

 service.removeStarredMessagesForChat(['m1', 'm3']);

 expect(service.isMessageStarred(MessageId('m1')), isFalse);
 expect(service.isMessageStarred(MessageId('m2')), isTrue);
 expect(service.isMessageStarred(MessageId('m3')), isFalse);
 });
 });

 group('savePinnedChats / saveStarredMessages', () {
 test('savePinnedChats completes', () async {
 service.addPinnedChat('chat-1');
 await expectLater(service.savePinnedChats(), completes);
 });

 test('saveStarredMessages completes', () async {
 await service.toggleMessageStar(MessageId('m1'));
 await expectLater(service.saveStarredMessages(), completes);
 });
 });

 group('dispose', () {
 test('clears listeners', () async {
 final events = <MessageUpdateEvent>[];
 final sub = service.messageUpdates.listen(events.add);
 await Future<void>.delayed(Duration.zero);

 await service.dispose();
 // After dispose, new stars should not emit to listener
 await service.toggleMessageStar(MessageId('m-post-dispose'));
 await Future<void>.delayed(Duration.zero);

 expect(events, isEmpty);
 await sub.cancel();
 });
 });
}
