import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/presentation/controllers/home_screen_controller.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

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
  Future<void> incrementUnreadCount(ChatId chatId) async {}

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<void> updateContactLastSeen(String publicKey) async {}
}

class _FakeHomeScreenFacade implements IHomeScreenFacade {
  final StreamController<int> _unreadController =
      StreamController<int>.broadcast();
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  final List<ChatListItem> _chats = <ChatListItem>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async => _chats;

  @override
  List<ChatListItem> get chats => _chats;

  @override
  bool get isLoading => false;

  @override
  void refreshUnreadCount() {}

  @override
  Stream<int> get unreadCountStream => _unreadController.stream;

  @override
  Future<void> openChat(ChatListItem chat) async {}

  @override
  void toggleSearch() {}

  @override
  void showSearch() {}

  @override
  Future<void> clearSearch() async {}

  @override
  void openSettings() {}

  @override
  void openProfile() {}

  @override
  Future<String?> editDisplayName(String currentName) async => currentName;

  @override
  void openContacts() {}

  @override
  void openArchives() {}

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async => true;

  @override
  Future<void> archiveChat(ChatListItem chat) async {}

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async => true;

  @override
  Future<void> deleteChat(ChatListItem chat) async {}

  @override
  void showChatContextMenu(ChatListItem chat) {}

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {}

  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

  @override
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  }) => ConnectionStatus.offline;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  Future<void> dispose() async {
    await _unreadController.close();
    await _connectionStatusController.close();
  }
}

class _TestHomeScreenController extends HomeScreenController {
  _TestHomeScreenController(super.args);

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
                        homeScreenFacade: _FakeHomeScreenFacade(),
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
