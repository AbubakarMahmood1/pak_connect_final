import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/core/interfaces/i_chats_repository.dart';
import 'package:pak_connect/core/interfaces/i_message_repository.dart';
import 'package:pak_connect/core/interfaces/i_archive_repository.dart';
import 'package:pak_connect/core/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/core/services/home_screen_facade.dart';
import 'package:pak_connect/core/models/archive_models.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/presentation/controllers/home_screen_controller.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import '../../test_helpers/test_setup.dart';

class _FakeChatsRepository implements IChatsRepository {
  int totalUnreadCountCalls = 0;

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;

  @override
  Future<int> getArchivedChatCount() async => 0;

  @override
  Future<int> getChatCount() async => 0;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async => <ChatListItem>[];

  @override
  Future<List<Contact>> getContactsWithoutChats() async => <Contact>[];

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  Future<int> getTotalUnreadCount() async {
    totalUnreadCountCalls++;
    return 0;
  }

  @override
  Future<void> incrementUnreadCount(String chatId) async {}

  @override
  Future<void> markChatAsRead(String chatId) async {}

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<void> updateContactLastSeen(String publicKey) async {}
}

class _FakeMessageRepository implements IMessageRepository {
  @override
  Future<void> clearMessages(String chatId) async {}

  @override
  Future<bool> deleteMessage(String messageId) async => true;

  @override
  Future<List<Message>> getAllMessages() async => <Message>[];

  @override
  Future<Message?> getMessageById(String messageId) async => null;

  @override
  Future<List<Message>> getMessages(String chatId) async => <Message>[];

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      <Message>[];

  @override
  Future<void> saveMessage(Message message) async {}

  @override
  Future<void> updateMessage(Message message) async {}
}

class _FakeArchiveRepository implements IArchiveRepository {
  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async => ArchiveOperationResult.success(
    message: 'ok',
    operationType: ArchiveOperationType.archive,
    archiveId: chatId,
    operationTime: Duration.zero,
  );

  @override
  Future<void> dispose() async {}

  @override
  Future<ArchiveStatistics?> getArchiveStatistics() async => null;

  @override
  Future<ArchivedChat?> getArchivedChat(String archiveId) async => null;

  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(
    String chatId,
  ) async => null;

  @override
  Future<int> getArchivedChatsCount() async => 0;

  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async => <ArchivedChatSummary>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> permanentlyDeleteArchive(String archivedChatId) async {}

  @override
  Future<ArchiveOperationResult> restoreChat(String archiveId) async =>
      ArchiveOperationResult.success(
        message: 'ok',
        operationType: ArchiveOperationType.restore,
        archiveId: archiveId,
        operationTime: Duration.zero,
      );

  @override
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async => ArchiveSearchResult(
    messages: const [],
    chats: const [],
    messagesByChat: const {},
    query: query,
    filter: filter,
    totalResults: 0,
    totalChatsFound: 0,
    searchTime: Duration.zero,
    hasMore: false,
    metadata: ArchiveSearchMetadata.empty(),
  );

  @override
  void clearCache() {}
}

class _InMemorySeenMessageStore implements ISeenMessageStore {
  final Set<String> _delivered = {};
  final Set<String> _read = {};

  @override
  Future<void> clear() async {
    _delivered.clear();
    _read.clear();
  }

  @override
  Map<String, dynamic> getStatistics() => {
    'delivered': _delivered.length,
    'read': _read.length,
  };

  @override
  bool hasDelivered(String messageId) => _delivered.contains(messageId);

  @override
  bool hasRead(String messageId) => _read.contains(messageId);

  @override
  Future<void> markDelivered(String messageId) async {
    _delivered.add(messageId);
  }

  @override
  Future<void> markRead(String messageId) async {
    _read.add(messageId);
  }

  @override
  Future<void> performMaintenance() async {}
}

class _TestHomeScreenController extends HomeScreenController {
  _TestHomeScreenController(HomeScreenControllerArgs args) : super(args);

  int loadCount = 0;

  @override
  Future<void> loadChats({bool reset = true}) async {
    loadCount++;
  }
}

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('HomeScreenController', () {
    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    testWidgets('search sentinel shows bar and clears with reload', (
      tester,
    ) async {
      late _TestHomeScreenController controller;
      final fakeRepo = _FakeChatsRepository();
      final fakeMessageRepo = _FakeMessageRepository();
      final fakeArchiveRepo = _FakeArchiveRepository();

      await TestSetup.configureTestDI(
        messageRepository: fakeMessageRepo,
        chatsRepository: fakeRepo,
        archiveRepository: fakeArchiveRepo,
        seenMessageStore: _InMemorySeenMessageStore(),
      );
      addTearDown(() async {
        await TestSetup.resetDIServiceLocator();
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return Consumer(
                  builder: (context, ref, _) {
                    controller = _TestHomeScreenController(
                      HomeScreenControllerArgs(
                        context: context,
                        ref: ref,
                        chatsRepository: fakeRepo,
                        chatManagementService: ChatManagementService(),
                        homeScreenFacade: HomeScreenFacade(
                          chatsRepository: fakeRepo,
                          bleService: null,
                          chatManagementService: null,
                          context: context,
                          ref: ref,
                          enableListCoordinatorInitialization: false,
                        ),
                      ),
                    );
                    return const SizedBox.shrink();
                  },
                );
              },
            ),
          ),
        ),
      );

      // Sentinel should only show the search bar without triggering a reload.
      controller.onSearchChanged(' ');
      expect(controller.searchQuery, ' ');
      expect(controller.loadCount, 0);

      // Typing a real query schedules a debounced reload.
      controller.onSearchChanged('hello');
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.searchQuery, 'hello');
      expect(controller.loadCount, 1);

      // Clearing the query should trigger an immediate reload.
      controller.onSearchChanged('');
      await tester.pump();
      expect(controller.searchQuery, '');
      expect(controller.loadCount, 2);

      controller.dispose();
    });
  });
}
