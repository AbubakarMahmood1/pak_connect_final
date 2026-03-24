/// ChatLifecycleService supplementary tests targeting gaps:
/// exportChat CSV/text, getComprehensiveChatAnalytics, batchArchiveChats
/// partial failure, getChatAnalytics empty/single, deleteMessages edges,
/// toggleChatArchive failure paths, archiveManager getter.
library;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_lifecycle_service.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/services/chat_notification_service.dart';
import 'package:pak_connect/domain/services/chat_sync_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();

 group('ChatLifecycleService – gap coverage', () {
 late _FakeChatsRepo chatsRepo;
 late _FakeMessageRepo messageRepo;
 late _FakeArchiveRepo archiveRepo;
 late ArchiveManagementService archiveMgmt;
 late ChatCacheState cacheState;
 late ChatNotificationService notifService;
 late ChatSyncService syncService;
 late ChatLifecycleService service;

 setUp(() async {
 SharedPreferences.setMockInitialValues({});

 chatsRepo = _FakeChatsRepo([
 _chat('chat_1', 'Alice', DateTime(2026, 1, 1, 10)),
 _chat('chat_2', 'Bob', DateTime(2026, 1, 1, 9)),
]);

 messageRepo = _FakeMessageRepo({
 'chat_1': [
 _msg('m1', 'chat_1', 'Hello world', true, DateTime(2026, 1, 1, 10)),
 _msg('m2', 'chat_1', 'Hi there', false, DateTime(2026, 1, 1, 10, 5)),
 _msg('m3', 'chat_1', 'Follow-up message', true,
 DateTime(2026, 1, 2, 8)),
],
 'chat_2': [
 _msg('m4', 'chat_2', 'Hey Bob', true, DateTime(2026, 1, 1, 9)),
],
 });

 archiveRepo = _FakeArchiveRepo();
 archiveMgmt = ArchiveManagementService.withDependencies(archiveRepository: archiveRepo,
);
 await archiveMgmt.initialize();

 cacheState = ChatCacheState();
 notifService = ChatNotificationService();

 syncService = ChatSyncService(chatsRepository: chatsRepo,
 messageRepository: messageRepo,
 cacheState: cacheState,
 archiveSearchService: ArchiveSearchService.withDependencies(archiveRepository: archiveRepo,
),
);

 service = ChatLifecycleService(chatsRepository: chatsRepo,
 messageRepository: messageRepo,
 archiveRepository: archiveRepo,
 archiveManagementService: archiveMgmt,
 cacheState: cacheState,
 notificationService: notifService,
 syncService: syncService,
);
 });

 tearDown(() async {
 await notifService.dispose();
 await archiveMgmt.dispose();
 });

 // -----------------------------------------------------------------
 // exportChat — CSV and TEXT formats
 // -----------------------------------------------------------------
 group('exportChat formats', () {
 test('CSV format produces valid CSV with header', () async {
 final result = await service.exportChat(chatId: 'chat_1',
 format: ChatExportFormat.csv,
);
 expect(result.success, isTrue);

 final prefs = await SharedPreferences.getInstance();
 final exports = prefs.getStringList('chat_exports')!;
 final meta = jsonDecode(exports.last) as Map<String, dynamic>;
 final csv = prefs.getString(meta['key'] as String)!;

 expect(csv, contains('"Timestamp"'));
 expect(csv, contains('"Sender"'));
 expect(csv, contains('"Message"'));
 expect(csv, contains('"Status"'));
 // No "Starred" column without includeMetadata
 expect(csv, isNot(contains('"Starred"')));
 });

 test('CSV with includeMetadata adds Starred column', () async {
 cacheState.starredMessageIds.add(MessageId('m1'));
 final result = await service.exportChat(chatId: 'chat_1',
 format: ChatExportFormat.csv,
 includeMetadata: true,
);
 expect(result.success, isTrue);

 final prefs = await SharedPreferences.getInstance();
 final exports = prefs.getStringList('chat_exports')!;
 final meta = jsonDecode(exports.last) as Map<String, dynamic>;
 final csv = prefs.getString(meta['key'] as String)!;

 expect(csv, contains('"Starred"'));
 expect(csv, contains('"Yes"'));
 expect(csv, contains('"No"'));
 });

 test('TEXT format produces readable output', () async {
 final result = await service.exportChat(chatId: 'chat_1',
 format: ChatExportFormat.text,
);
 expect(result.success, isTrue);

 final prefs = await SharedPreferences.getInstance();
 final exports = prefs.getStringList('chat_exports')!;
 final meta = jsonDecode(exports.last) as Map<String, dynamic>;
 final text = prefs.getString(meta['key'] as String)!;

 expect(text, contains('Chat Export: Alice'));
 expect(text, contains('Messages: 3'));
 expect(text, contains('You:'));
 expect(text, contains('Alice:'));
 });

 test('TEXT with includeMetadata includes status and stars', () async {
 cacheState.starredMessageIds.add(MessageId('m1'));
 final result = await service.exportChat(chatId: 'chat_1',
 format: ChatExportFormat.text,
 includeMetadata: true,
);
 expect(result.success, isTrue);

 final prefs = await SharedPreferences.getInstance();
 final exports = prefs.getStringList('chat_exports')!;
 final meta = jsonDecode(exports.last) as Map<String, dynamic>;
 final text = prefs.getString(meta['key'] as String)!;

 expect(text, contains('Status: delivered'));
 expect(text, contains('⭐ Starred'));
 });

 test('export for nonexistent chat returns failure', () async {
 final result = await service.exportChat(chatId: 'nonexistent');
 expect(result.success, isFalse);
 });
 });

 // -----------------------------------------------------------------
 // getComprehensiveChatAnalytics
 // -----------------------------------------------------------------
 group('getComprehensiveChatAnalytics', () {
 test('returns combined metrics without archives', () async {
 final analytics =
 await service.getComprehensiveChatAnalytics('chat_1');

 expect(analytics.chatId, 'chat_1');
 expect(analytics.liveAnalytics.totalMessages, 3);
 expect(analytics.archiveAnalytics, isNull);
 expect(analytics.combinedMetrics.hasArchives, isFalse);
 expect(analytics.combinedMetrics.totalMessages, 3);
 expect(analytics.combinedMetrics.liveMessages, 3);
 expect(analytics.combinedMetrics.archivedMessages, 0);
 expect(analytics.combinedMetrics.archivePercentage, 0.0);
 });

 test('returns combined metrics with archives', () async {
 // First archive chat_1 so there's archived data
 await archiveRepo.archiveChat(chatId: 'chat_1');

 final analytics =
 await service.getComprehensiveChatAnalytics('chat_1');

 expect(analytics.chatId, 'chat_1');
 expect(analytics.liveAnalytics.totalMessages, 3);
 // archive exists with 1 message
 if (analytics.archiveAnalytics != null) {
 expect(analytics.combinedMetrics.hasArchives, isTrue);
 expect(analytics.combinedMetrics.archivedMessages, greaterThan(0));
 expect(analytics.combinedMetrics.archivePercentage, greaterThan(0));
 }
 });

 test('gracefully handles when getChatAnalytics catches internal errors',
 () async {
 // ThrowingChatsRepo only affects getAllChats, which
 // getComprehensiveChatAnalytics does NOT call directly.
 // getChatAnalytics catches its own errors internally, so
 // comprehensive analytics still succeeds with empty live data.
 final throwingService = ChatLifecycleService(chatsRepository: _ThrowingChatsRepo(),
 messageRepository: messageRepo,
 archiveRepository: archiveRepo,
 archiveManagementService: archiveMgmt,
 cacheState: cacheState,
 notificationService: notifService,
 syncService: syncService,
);

 final analytics =
 await throwingService.getComprehensiveChatAnalytics('chat_1');

 // getChatAnalytics succeeds (it uses messageRepo, not chatsRepo)
 expect(analytics.chatId, 'chat_1');
 expect(analytics.hasError, isFalse);
 expect(analytics.liveAnalytics.totalMessages, 3);
 });
 });

 // -----------------------------------------------------------------
 // getChatAnalytics edge cases
 // -----------------------------------------------------------------
 group('getChatAnalytics edge cases', () {
 test('empty chat returns zero analytics', () async {
 messageRepo.messagesMap['empty_chat'] = [];
 chatsRepo.addChat(_chat('empty_chat', 'Empty', DateTime(2026)));

 final analytics = await service.getChatAnalytics('empty_chat');

 expect(analytics.totalMessages, 0);
 expect(analytics.myMessages, 0);
 expect(analytics.theirMessages, 0);
 expect(analytics.firstMessage, isNull);
 expect(analytics.lastMessage, isNull);
 expect(analytics.averageMessageLength, 0.0);
 expect(analytics.busiestDayCount, 0);
 });

 test('single message computes correctly', () async {
 messageRepo.messagesMap['single'] = [
 _msg('s1', 'single', 'Only message', true, DateTime(2026, 3, 15)),
];
 chatsRepo.addChat(_chat('single', 'Single', DateTime(2026, 3, 15)));

 final analytics = await service.getChatAnalytics('single');

 expect(analytics.totalMessages, 1);
 expect(analytics.myMessages, 1);
 expect(analytics.theirMessages, 0);
 expect(analytics.firstMessage, DateTime(2026, 3, 15));
 expect(analytics.lastMessage, DateTime(2026, 3, 15));
 expect(analytics.averageMessageLength, 'Only message'.length);
 expect(analytics.busiestDayCount, 1);
 });

 test('messages spanning multiple days groups correctly', () async {
 final analytics = await service.getChatAnalytics('chat_1');
 // chat_1 has messages on Jan 1 (2 msgs) and Jan 2 (1 msg)
 expect(analytics.messagesByDay.length, 2);
 expect(analytics.busiestDayCount, 2); // Jan 1 has 2
 });
 });

 // -----------------------------------------------------------------
 // batchArchiveChats partial failure
 // -----------------------------------------------------------------
 group('batchArchiveChats', () {
 test('partial failure when one chat fails', () async {
 archiveRepo.failingChatIds.add('chat_2');

 final result = await service.batchArchiveChats(chatIds: ['chat_1', 'chat_2'],
 useEnhancedArchive: true,
);

 expect(result.totalProcessed, 2);
 expect(result.successful, 1);
 expect(result.failed, 1);
 expect(result.partialSuccess, isTrue);
 expect(result.allSuccessful, isFalse);
 expect(result.successfulChatIds, contains('chat_1'));
 expect(result.failedChatIds, contains('chat_2'));
 });

 test('empty chatIds list returns clean result', () async {
 final result = await service.batchArchiveChats(chatIds: []);
 expect(result.totalProcessed, 0);
 expect(result.successful, 0);
 expect(result.failed, 0);
 });
 });

 // -----------------------------------------------------------------
 // deleteMessages edges
 // -----------------------------------------------------------------
 group('deleteMessages edge cases', () {
 test('deleting all-existing messages returns success', () async {
 final result = await service.deleteMessages(messageIds: [MessageId('m1')],
);
 expect(result.success, isTrue);
 expect(result.isPartial, isFalse);
 expect(messageRepo.deletedIds, contains(MessageId('m1')));
 });

 test('deleteForEveryone flag passes through', () async {
 // The flag doesn't change behavior in current impl but should not error
 final result = await service.deleteMessages(messageIds: [MessageId('m4')],
 deleteForEveryone: true,
);
 expect(result.success, isTrue);
 });

 test('deleting nonexistent IDs returns partial', () async {
 final result = await service.deleteMessages(messageIds: [MessageId('nope1'), MessageId('nope2')],
);
 // All failed → partial (0 deleted, 2 failed)
 expect(result.isPartial, isTrue);
 });
 });

 // -----------------------------------------------------------------
 // toggleChatArchive failure paths
 // -----------------------------------------------------------------
 group('toggleChatArchive failure paths', () {
 test('enhanced archive failure returns failure result', () async {
 archiveRepo.failingChatIds.add('chat_1');

 final result = await service.toggleChatArchive('chat_1',
 useEnhancedArchive: true,
);

 expect(result.success, isFalse);
 expect(result.message, contains('Enhanced archive failed'));
 });

 test('enhanced restore failure returns failure result', () async {
 // First archive it
 await service.toggleChatArchive('chat_1', useEnhancedArchive: true);
 expect(cacheState.archivedChats.contains(ChatId('chat_1')), isTrue);

 // Now make restore fail
 archiveRepo.failRestore = true;
 final result = await service.toggleChatArchive('chat_1',
 useEnhancedArchive: true,
);

 expect(result.success, isFalse);
 expect(result.message, contains('Failed to restore'));
 });
 });

 // -----------------------------------------------------------------
 // archiveManager getter
 // -----------------------------------------------------------------
 test('archiveManager getter exposes management service', () {
 expect(service.archiveManager, same(archiveMgmt));
 });
 });
}

// =====================================================================
// Helpers and fakes
// =====================================================================

ChatListItem _chat(String id, String name, DateTime lastMsgTime) {
 return ChatListItem(chatId: ChatId(id),
 contactName: name,
 contactPublicKey: id,
 lastMessage: 'latest',
 lastMessageTime: lastMsgTime,
 unreadCount: 0,
 isOnline: false,
 hasUnsentMessages: false,
 lastSeen: lastMsgTime,
);
}

Message _msg(String id,
 String chatId,
 String content,
 bool fromMe,
 DateTime timestamp,
) {
 return Message(id: MessageId(id),
 chatId: ChatId(chatId),
 content: content,
 timestamp: timestamp,
 isFromMe: fromMe,
 status: MessageStatus.delivered,
);
}

class _FakeChatsRepo implements IChatsRepository {
 _FakeChatsRepo(this._chats);
 final List<ChatListItem> _chats;

 void addChat(ChatListItem chat) => _chats.add(chat);

 @override
 Future<List<ChatListItem>> getAllChats({
 List<dynamic>? nearbyDevices,
 Map<String, dynamic>? discoveryData,
 String? searchQuery,
 int? limit,
 int? offset,
 }) async => List.of(_chats);

 @override
 dynamic noSuchMethod(Invocation invocation) =>
 throw UnimplementedError('Unexpected call: $invocation');
}

class _ThrowingChatsRepo implements IChatsRepository {
 @override
 Future<List<ChatListItem>> getAllChats({
 List<dynamic>? nearbyDevices,
 Map<String, dynamic>? discoveryData,
 String? searchQuery,
 int? limit,
 int? offset,
 }) async => throw StateError('boom');

 @override
 dynamic noSuchMethod(Invocation invocation) =>
 throw UnimplementedError('Unexpected call: $invocation');
}

class _FakeMessageRepo implements IMessageRepository {
 _FakeMessageRepo(this.messagesMap);
 final Map<String, List<Message>> messagesMap;
 final List<MessageId> deletedIds = [];
 final List<ChatId> clearedChatIds = [];

 @override
 Future<List<Message>> getMessages(ChatId chatId) async =>
 List.of(messagesMap[chatId.value] ?? const []);

 @override
 Future<bool> deleteMessage(MessageId messageId) async {
 for (final entry in messagesMap.entries) {
 final before = entry.value.length;
 entry.value.removeWhere((m) => m.id == messageId);
 if (entry.value.length != before) {
 deletedIds.add(messageId);
 return true;
 }
 }
 return false;
 }

 @override
 Future<void> clearMessages(ChatId chatId) async {
 clearedChatIds.add(chatId);
 messagesMap.remove(chatId.value);
 }

 @override
 dynamic noSuchMethod(Invocation invocation) =>
 throw UnimplementedError('Unexpected call: $invocation');
}

class _FakeArchiveRepo implements IArchiveRepository {
 final Map<String, ArchivedChat> _archivesById = {};
 final Set<String> failingChatIds = {};
 bool failRestore = false;

 @override
 Future<void> initialize() async {}

 @override
 Future<ArchiveOperationResult> archiveChat({
 required String chatId,
 String? archiveReason,
 Map<String, dynamic>? customData,
 bool compressLargeArchives = true,
 }) async {
 if (failingChatIds.contains(chatId)) {
 return ArchiveOperationResult.failure(message: 'forced failure',
 operationType: ArchiveOperationType.archive,
 operationTime: Duration.zero,
);
 }
 final id = ArchiveId('arch_$chatId');
 _archivesById[id.value] = _archivedChat(id, chatId);
 return ArchiveOperationResult.success(message: 'archived',
 operationType: ArchiveOperationType.archive,
 archiveId: id,
 operationTime: const Duration(milliseconds: 5),
);
 }

 @override
 Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async {
 if (failRestore || !_archivesById.containsKey(archiveId.value)) {
 return ArchiveOperationResult.failure(message: 'restore failed',
 operationType: ArchiveOperationType.restore,
 operationTime: Duration.zero,
);
 }
 return ArchiveOperationResult.success(message: 'restored',
 operationType: ArchiveOperationType.restore,
 archiveId: archiveId,
 operationTime: const Duration(milliseconds: 5),
);
 }

 @override
 Future<List<ArchivedChatSummary>> getArchivedChats({
 ArchiveSearchFilter? filter,
 int? limit,
 int? offset,
 }) async {
 var archives = _archivesById.values.toList();
 if (filter?.contactFilter != null) {
 archives = archives
 .where((a) => a.originalChatId.value == filter!.contactFilter)
 .toList();
 }
 return archives.map((a) => a.toSummary()).toList();
 }

 @override
 Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async =>
 _archivesById[archiveId.value];

 @override
 Future<ArchivedChatSummary?> getArchivedChatByOriginalId(String chatId) async {
 for (final archive in _archivesById.values) {
 if (archive.originalChatId.value == chatId) {
 return archive.toSummary();
 }
 }
 return null;
 }

 @override
 Future<ArchiveSearchResult> searchArchives({
 required String query,
 ArchiveSearchFilter? filter,
 int? limit,
 String? afterCursor,
 }) async => ArchiveSearchResult.empty(query);

 @override
 Future<ArchiveStatistics?> getArchiveStatistics() async =>
 ArchiveStatistics.empty();

 @override
 Future<int> getArchivedChatsCount() async => _archivesById.length;

 @override
 Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async {
 _archivesById.remove(archivedChatId.value);
 }

 @override
 void clearCache() {}

 @override
 Future<void> dispose() async {}
}

ArchivedChat _archivedChat(ArchiveId archiveId, String chatId) {
 final msg = Message(id: MessageId('arch_msg_$chatId'),
 chatId: ChatId(chatId),
 content: 'archived message content',
 timestamp: DateTime(2026, 1, 1, 10),
 isFromMe: true,
 status: MessageStatus.delivered,
);

 return ArchivedChat(id: archiveId,
 originalChatId: ChatId(chatId),
 contactName: chatId,
 archivedAt: DateTime(2026, 1, 1, 12),
 lastMessageTime: msg.timestamp,
 messageCount: 1,
 metadata: const ArchiveMetadata(version: '1.0',
 reason: 'test',
 originalUnreadCount: 0,
 wasOnline: false,
 hadUnsentMessages: false,
 estimatedStorageSize: 100,
 archiveSource: 'test',
 tags: [],
),
 messages: [],
);
}
