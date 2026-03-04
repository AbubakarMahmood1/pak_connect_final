import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/connection_status.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/models/home_screen_state.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/chat_notification_providers.dart';
import 'package:pak_connect/presentation/providers/home_screen_providers.dart';
import 'package:pak_connect/presentation/viewmodels/home_screen_view_model.dart';

class _FakeChatsRepository extends Fake implements IChatsRepository {
  int getAllChatsCalls = 0;
  final List<String?> seenSearchQueries = <String?>[];
  final List<int?> seenLimits = <int?>[];
  final List<int?> seenOffsets = <int?>[];
  final List<List<ChatListItem>> scriptedResponses = <List<ChatListItem>>[];
  bool throwOnNextGetAll = false;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    getAllChatsCalls++;
    seenSearchQueries.add(searchQuery);
    seenLimits.add(limit);
    seenOffsets.add(offset);

    if (throwOnNextGetAll) {
      throwOnNextGetAll = false;
      throw StateError('forced getAllChats failure');
    }

    if (scriptedResponses.isNotEmpty) {
      return List<ChatListItem>.from(scriptedResponses.removeAt(0));
    }

    return <ChatListItem>[];
  }
}

class _FakeChatManagementService extends Fake implements ChatManagementService {
  int initializeCalls = 0;
  final Set<ChatId> pinnedChats = <ChatId>{};

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  bool isChatPinned(ChatId chatId) => pinnedChats.contains(chatId);
}

class _FakeHomeScreenFacade extends Fake implements IHomeScreenFacade {
  int initializeCalls = 0;
  int openChatCalls = 0;
  int archiveChatCalls = 0;
  int deleteChatCalls = 0;
  int togglePinCalls = 0;
  int markReadCalls = 0;
  int openContactsCalls = 0;
  int openArchivesCalls = 0;
  int openSettingsCalls = 0;
  int openProfileCalls = 0;
  int disposeCalls = 0;

  String? editDisplayNameResponse;
  ConnectionStatus statusToReturn = ConnectionStatus.offline;

  final StreamController<int> _unreadController =
      StreamController<int>.broadcast();
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  bool _closed = false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Stream<int> get unreadCountStream => _unreadController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  Future<void> openChat(ChatListItem chat) async {
    openChatCalls++;
  }

  @override
  Future<void> archiveChat(ChatListItem chat) async {
    archiveChatCalls++;
  }

  @override
  Future<void> deleteChat(ChatListItem chat) async {
    deleteChatCalls++;
  }

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {
    togglePinCalls++;
  }

  @override
  Future<void> markChatAsRead(ChatId chatId) async {
    markReadCalls++;
  }

  @override
  void openContacts() {
    openContactsCalls++;
  }

  @override
  void openArchives() {
    openArchivesCalls++;
  }

  @override
  void openSettings() {
    openSettingsCalls++;
  }

  @override
  void openProfile() {
    openProfileCalls++;
  }

  @override
  Future<String?> editDisplayName(String currentName) async {
    return editDisplayNameResponse;
  }

  @override
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  }) {
    return statusToReturn;
  }

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async => true;

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async => true;

  @override
  List<ChatListItem> get chats => const <ChatListItem>[];

  @override
  bool get isLoading => false;

  @override
  void refreshUnreadCount() {}

  @override
  void toggleSearch() {}

  @override
  void showSearch() {}

  @override
  Future<void> clearSearch() async {}

  @override
  void showChatContextMenu(ChatListItem chat) {}

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async =>
      <ChatListItem>[];

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (_closed) return;
    _closed = true;
    await _unreadController.close();
    await _connectionStatusController.close();
  }
}

ChatListItem _chat({required String id, DateTime? time}) {
  return ChatListItem(
    chatId: ChatId(id),
    contactName: 'Contact $id',
    contactPublicKey: id,
    lastMessage: 'hello',
    lastMessageTime: time ?? DateTime(2026, 1, 1),
    unreadCount: 0,
    isOnline: false,
    hasUnsentMessages: false,
  );
}

List<ChatListItem> _chatPage(int count, {required String prefix}) {
  return List<ChatListItem>.generate(
    count,
    (int index) =>
        _chat(id: '$prefix-$index', time: DateTime(2026, 1, 1, 0, index)),
  );
}

Future<void> _settleAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<({ProviderContainer container, HomeScreenProviderArgs args})>
_buildHarness(
  WidgetTester tester, {
  required _FakeChatsRepository chatsRepository,
  required _FakeChatManagementService managementService,
  required _FakeHomeScreenFacade facade,
}) async {
  late ProviderContainer container;
  HomeScreenProviderArgs? args;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        discoveredDevicesProvider.overrideWith(
          (ref) => const AsyncValue.loading(),
        ),
        discoveryDataProvider.overrideWith((ref) => const AsyncValue.loading()),
        receivedMessagesProvider.overrideWith(
          (ref) => const Stream<String>.empty(),
        ),
        chatUpdatesStreamProvider.overrideWith(
          (ref) => const Stream<ChatUpdateEvent>.empty(),
        ),
        messageUpdatesStreamProvider.overrideWith(
          (ref) => const Stream<MessageUpdateEvent>.empty(),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            args ??= HomeScreenProviderArgs(
              context: context,
              ref: ref,
              chatsRepository: chatsRepository,
              chatManagementService: managementService,
              homeScreenFacade: facade,
            );
            // Ensure provider family is instantiated.
            ref.watch(homeScreenViewModelProvider(args!));
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );

  await tester.pump();
  await _settleAsync(tester);

  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  return (container: container, args: args!);
}

HomeScreenViewModel _vm(
  ({ProviderContainer container, HomeScreenProviderArgs args}) harness,
) {
  return harness.container.read(
    homeScreenViewModelProvider(harness.args).notifier,
  );
}

HomeScreenState _state(
  ({ProviderContainer container, HomeScreenProviderArgs args}) harness,
) {
  return harness.container.read(homeScreenViewModelProvider(harness.args));
}

void main() {
  group('HomeScreenViewModel', () {
    testWidgets('initializes and loads chats through repository', (
      tester,
    ) async {
      final repository = _FakeChatsRepository()
        ..scriptedResponses.add(<ChatListItem>[_chat(id: 'init')]);
      final managementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();

      final harness = await _buildHarness(
        tester,
        chatsRepository: repository,
        managementService: managementService,
        facade: facade,
      );

      await _settleAsync(tester);

      expect(managementService.initializeCalls, 1);
      expect(facade.initializeCalls, 1);
      expect(repository.getAllChatsCalls, greaterThanOrEqualTo(1));
      expect(_state(harness).isLoading, isFalse);
      expect(_state(harness).chats.length, 1);
      expect(_state(harness).chats.first.chatId, const ChatId('init'));
      expect(_state(harness).unreadCountStream, isNotNull);
    });

    testWidgets('search changes update query and trigger reload behavior', (
      tester,
    ) async {
      final repository = _FakeChatsRepository()
        ..scriptedResponses.addAll(<List<ChatListItem>>[
          <ChatListItem>[_chat(id: 'base')],
          <ChatListItem>[_chat(id: 'search')],
          <ChatListItem>[_chat(id: 'cleared')],
        ]);
      final managementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();

      final harness = await _buildHarness(
        tester,
        chatsRepository: repository,
        managementService: managementService,
        facade: facade,
      );
      final viewModel = _vm(harness);
      final baselineCalls = repository.getAllChatsCalls;

      viewModel.onSearchChanged(' ');
      expect(_state(harness).searchQuery, ' ');
      expect(repository.getAllChatsCalls, baselineCalls);

      viewModel.onSearchChanged('hello');
      await _settleAsync(tester);
      expect(repository.getAllChatsCalls, greaterThan(baselineCalls));
      expect(_state(harness).searchQuery, 'hello');

      viewModel.onSearchChanged('');
      await _settleAsync(tester);
      expect(_state(harness).searchQuery, '');
    });

    testWidgets('chat operations delegate to facade and reload chats', (
      tester,
    ) async {
      final repository = _FakeChatsRepository()
        ..scriptedResponses.addAll(<List<ChatListItem>>[
          <ChatListItem>[_chat(id: 'init')],
          <ChatListItem>[_chat(id: 'after-open')],
          <ChatListItem>[_chat(id: 'after-archive')],
          <ChatListItem>[_chat(id: 'after-delete')],
          <ChatListItem>[_chat(id: 'after-pin')],
        ]);
      final managementService = _FakeChatManagementService()
        ..pinnedChats.add(const ChatId('chat-op'));
      final facade = _FakeHomeScreenFacade();
      final chat = _chat(id: 'chat-op');

      final harness = await _buildHarness(
        tester,
        chatsRepository: repository,
        managementService: managementService,
        facade: facade,
      );
      final viewModel = _vm(harness);

      await viewModel.openChat(chat);
      await viewModel.archiveChat(chat);
      await viewModel.deleteChat(chat);
      await viewModel.toggleChatPin(chat);
      await viewModel.markChatAsRead(chat.chatId);

      expect(facade.openChatCalls, 1);
      expect(facade.archiveChatCalls, 1);
      expect(facade.deleteChatCalls, 1);
      expect(facade.togglePinCalls, 1);
      expect(facade.markReadCalls, 1);
      expect(viewModel.isChatPinned(chat.chatId), isTrue);
      expect(repository.getAllChatsCalls, greaterThanOrEqualTo(5));
    });

    testWidgets(
      'updateSingleChatItem does surgical update and fallback reload',
      (tester) async {
        final repository = _FakeChatsRepository()
          ..scriptedResponses.addAll(<List<ChatListItem>>[
            <ChatListItem>[_chat(id: 'old')],
            <ChatListItem>[_chat(id: 'new')],
            <ChatListItem>[_chat(id: 'fallback')],
          ]);
        final managementService = _FakeChatManagementService();
        final facade = _FakeHomeScreenFacade();

        final harness = await _buildHarness(
          tester,
          chatsRepository: repository,
          managementService: managementService,
          facade: facade,
        );
        final viewModel = _vm(harness);

        await viewModel.updateSingleChatItem();
        expect(_state(harness).chats.first.chatId, const ChatId('new'));

        final beforeFallbackCalls = repository.getAllChatsCalls;
        repository.throwOnNextGetAll = true;
        await viewModel.updateSingleChatItem();
        expect(repository.getAllChatsCalls, greaterThan(beforeFallbackCalls));
      },
    );

    testWidgets('loadMoreChats paginates and clears paging flag', (
      tester,
    ) async {
      final repository = _FakeChatsRepository()
        ..scriptedResponses.addAll(<List<ChatListItem>>[
          _chatPage(50, prefix: 'p1'),
          _chatPage(10, prefix: 'p2'),
        ]);
      final managementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade();

      final harness = await _buildHarness(
        tester,
        chatsRepository: repository,
        managementService: managementService,
        facade: facade,
      );
      final viewModel = _vm(harness);

      expect(_state(harness).hasMore, isTrue);

      await viewModel.loadMoreChats();
      await _settleAsync(tester);

      expect(viewModel.isPaging, isFalse);
      expect(viewModel.hasMore, isFalse);
      expect(repository.getAllChatsCalls, greaterThanOrEqualTo(2));
    });

    testWidgets('navigation/status helpers proxy to facade', (tester) async {
      final repository = _FakeChatsRepository()
        ..scriptedResponses.add(<ChatListItem>[_chat(id: 'init')]);
      final managementService = _FakeChatManagementService();
      final facade = _FakeHomeScreenFacade()
        ..editDisplayNameResponse = 'Renamed'
        ..statusToReturn = ConnectionStatus.connected;

      final harness = await _buildHarness(
        tester,
        chatsRepository: repository,
        managementService: managementService,
        facade: facade,
      );
      final viewModel = _vm(harness);

      await viewModel.openContacts();
      await viewModel.openArchives();
      await viewModel.openSettings();
      await viewModel.openProfile();
      final newName = await viewModel.editDisplayName('Old Name');
      final status = viewModel.determineConnectionStatus(
        contactPublicKey: 'pk',
        contactName: 'Name',
        currentConnectionInfo: const ConnectionInfo(
          isConnected: true,
          isReady: true,
          statusMessage: 'ready',
        ),
        discoveredDevices: const <Peripheral>[],
        discoveryData: const <String, dynamic>{},
        lastSeenTime: DateTime(2026, 1, 1),
      );

      expect(facade.openContactsCalls, 1);
      expect(facade.openArchivesCalls, 1);
      expect(facade.openSettingsCalls, 1);
      expect(facade.openProfileCalls, 1);
      expect(newName, 'Renamed');
      expect(status, ConnectionStatus.connected);
    });
  });
}
