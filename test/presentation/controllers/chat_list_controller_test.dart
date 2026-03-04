import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/controllers/chat_list_controller.dart';

ChatListItem _chat({
  required String id,
  required bool isOnline,
  required DateTime? lastMessageTime,
}) {
  return ChatListItem(
    chatId: ChatId(id),
    contactName: id,
    lastMessage: lastMessageTime == null ? null : 'msg-$id',
    lastMessageTime: lastMessageTime,
    unreadCount: 0,
    isOnline: isOnline,
    hasUnsentMessages: false,
  );
}

void main() {
  group('ChatListController', () {
    late ChatListController controller;

    setUp(() {
      controller = ChatListController();
    });

    test('mergeChats reset returns sorted incoming only', () {
      final oldChat = _chat(
        id: 'old',
        isOnline: false,
        lastMessageTime: DateTime(2026, 1, 1),
      );
      final incomingOnline = _chat(
        id: 'new-online',
        isOnline: true,
        lastMessageTime: DateTime(2026, 1, 2),
      );
      final incomingOffline = _chat(
        id: 'new-offline',
        isOnline: false,
        lastMessageTime: DateTime(2026, 1, 3),
      );

      final result = controller.mergeChats(
        existing: [oldChat],
        incoming: [incomingOffline, incomingOnline],
        reset: true,
      );

      expect(result.map((chat) => chat.chatId.value), [
        'new-online',
        'new-offline',
      ]);
    });

    test(
      'mergeChats combines existing/incoming and sorts by online then recency',
      () {
        final existingOld = _chat(
          id: 'existing-old',
          isOnline: false,
          lastMessageTime: DateTime(2026, 1, 1),
        );
        final incomingNewestOffline = _chat(
          id: 'incoming-newest-offline',
          isOnline: false,
          lastMessageTime: DateTime(2026, 1, 4),
        );
        final incomingOnline = _chat(
          id: 'incoming-online',
          isOnline: true,
          lastMessageTime: DateTime(2026, 1, 2),
        );

        final result = controller.mergeChats(
          existing: [existingOld],
          incoming: [incomingNewestOffline, incomingOnline],
          reset: false,
        );

        expect(result.map((chat) => chat.chatId.value), [
          'incoming-online',
          'incoming-newest-offline',
          'existing-old',
        ]);
      },
    );

    test('sort treats null timestamps as oldest epoch value', () {
      final nullTimestamp = _chat(
        id: 'null-ts',
        isOnline: false,
        lastMessageTime: null,
      );
      final nonNullTimestamp = _chat(
        id: 'with-ts',
        isOnline: false,
        lastMessageTime: DateTime(2026, 1, 1),
      );

      final result = controller.mergeChats(
        existing: [nullTimestamp],
        incoming: [nonNullTimestamp],
        reset: false,
      );

      expect(result.map((chat) => chat.chatId.value), ['with-ts', 'null-ts']);
    });

    test('applySurgicalUpdate replaces existing chat and re-sorts', () {
      final onlineOld = _chat(
        id: 'online-old',
        isOnline: true,
        lastMessageTime: DateTime(2026, 1, 1),
      );
      final offlineNewer = _chat(
        id: 'offline-newer',
        isOnline: false,
        lastMessageTime: DateTime(2026, 1, 2),
      );

      final updatedOnline = _chat(
        id: 'online-old',
        isOnline: true,
        lastMessageTime: DateTime(2026, 1, 5),
      );

      final result = controller.applySurgicalUpdate(
        existing: [offlineNewer, onlineOld],
        updated: updatedOnline,
      );

      expect(result.first.chatId.value, 'online-old');
      expect(result.first.lastMessageTime, DateTime(2026, 1, 5));
    });

    test('applySurgicalUpdate inserts new chat when it does not exist', () {
      final existing = _chat(
        id: 'existing',
        isOnline: false,
        lastMessageTime: DateTime(2026, 1, 1),
      );
      final inserted = _chat(
        id: 'inserted',
        isOnline: true,
        lastMessageTime: DateTime(2026, 1, 3),
      );

      final result = controller.applySurgicalUpdate(
        existing: [existing],
        updated: inserted,
      );

      expect(result.map((chat) => chat.chatId.value), ['inserted', 'existing']);
    });
  });
}
