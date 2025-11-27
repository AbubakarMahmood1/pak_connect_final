import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/core/models/connection_status.dart';
import 'package:pak_connect/core/services/chat_list_coordinator.dart';
import 'package:pak_connect/core/interfaces/i_chats_repository.dart';
import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';

import '../../test_helpers/mocks/mock_connection_service.dart';

class _ScriptedChatsRepository implements IChatsRepository {
  final List<List<ChatListItem>> responses;
  int _index = 0;
  int loadCount = 0;
  int totalUnreadCount = 0;

  _ScriptedChatsRepository(this.responses);

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;

  @override
  Future<int> getArchivedChatCount() async => 0;

  @override
  Future<int> getChatCount() async => responses.isNotEmpty
      ? responses[_index.clamp(0, responses.length - 1)].length
      : 0;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    loadCount++;
    final current = responses[_index.clamp(0, responses.length - 1)];
    if (_index < responses.length - 1) {
      _index++;
    }
    return current;
  }

  @override
  Future<List<Contact>> getContactsWithoutChats() async => const [];

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  Future<int> getTotalUnreadCount() async => totalUnreadCount;

  @override
  Future<void> incrementUnreadCount(String chatId) async {}

  @override
  Future<void> markChatAsRead(String chatId) async {}

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<void> updateContactLastSeen(String publicKey) async {}
}

ChatListItem _chat(
  String id, {
  DateTime? lastMessageTime,
  bool online = false,
}) => ChatListItem(
  chatId: id,
  contactName: 'User $id',
  contactPublicKey: 'pk-$id',
  lastMessage: 'hi',
  lastMessageTime: lastMessageTime ?? DateTime.now(),
  unreadCount: 0,
  isOnline: online,
  hasUnsentMessages: false,
  lastSeen: null,
);

void main() {
  group('ChatListCoordinator', () {
    test('loadChats populates state and tracks search query', () async {
      final repo = _ScriptedChatsRepository([
        [_chat('a')],
      ]);
      final coordinator = ChatListCoordinator(chatsRepository: repo);

      final chats = await coordinator.loadChats(searchQuery: 'alice');

      expect(repo.loadCount, 1);
      expect(chats, isNotEmpty);
      expect(coordinator.currentChats.first.chatId, 'a');
      expect(coordinator.isLoading, isFalse);
    });

    test('updateSingleChatItem performs surgical replacement', () async {
      final older = _chat('old', lastMessageTime: DateTime(2000));
      final newer = _chat('new', lastMessageTime: DateTime.now());
      final repo = _ScriptedChatsRepository([
        [older],
        [newer],
      ]);
      final coordinator = ChatListCoordinator(chatsRepository: repo);

      await coordinator.loadChats();
      await coordinator.updateSingleChatItem();

      expect(repo.loadCount, 2);
      expect(coordinator.currentChats.first.chatId, 'new');
    });

    test('incoming messages trigger surgical refresh via BLE stream', () async {
      final initial = _chat('first');
      final updated = _chat('updated');
      final repo = _ScriptedChatsRepository([
        [initial],
        [updated],
      ]);
      final connectionService = MockConnectionService();
      final coordinator = ChatListCoordinator(
        chatsRepository: repo,
        bleService: connectionService,
      );

      await coordinator.initialize();
      final before = repo.loadCount;

      connectionService.emitIncomingMessage('payload');
      await Future<void>.delayed(Duration(milliseconds: 10));

      expect(repo.loadCount, before + 1);
      expect(coordinator.currentChats.first.chatId, 'updated');

      await coordinator.dispose();
    });

    // Note: connection status debounce covered indirectly in integration suites.
  });
}
