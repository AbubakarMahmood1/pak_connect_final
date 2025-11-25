import '../../domain/entities/chat_list_item.dart';

class ChatListController {
  List<ChatListItem> mergeChats({
    required List<ChatListItem> existing,
    required List<ChatListItem> incoming,
    required bool reset,
    bool isSearching = false,
    int pageSize = 50,
  }) {
    if (reset) {
      return _sorted(incoming);
    }
    final merged = [...existing, ...incoming];
    return _sorted(merged);
  }

  List<ChatListItem> applySurgicalUpdate({
    required List<ChatListItem> existing,
    required ChatListItem updated,
  }) {
    final chats = [...existing];
    final idx = chats.indexWhere((c) => c.chatId == updated.chatId);
    if (idx != -1) {
      chats[idx] = updated;
    } else {
      chats.insert(0, updated);
    }
    return _sorted(chats);
  }

  List<ChatListItem> _sorted(List<ChatListItem> list) {
    final chats = [...list];
    chats.sort((a, b) {
      if (a.isOnline && !b.isOnline) return -1;
      if (!a.isOnline && b.isOnline) return 1;
      final aTime = a.lastMessageTime ?? DateTime(1970);
      final bTime = b.lastMessageTime ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    return chats;
  }
}
