import '../values/id_types.dart';

class ChatListItem {
  final ChatId chatId;
  final String contactName;
  final String? contactPublicKey;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final bool isOnline;
  final bool hasUnsentMessages;
  final DateTime? lastSeen;

  const ChatListItem({
    required this.chatId,
    required this.contactName,
    this.contactPublicKey,
    this.lastMessage,
    this.lastMessageTime,
    required this.unreadCount,
    required this.isOnline,
    required this.hasUnsentMessages,
    this.lastSeen,
  });

  bool get hasMessages => lastMessage != null;

  String get displayLastSeen {
    if (isOnline) return 'Online';
    if (lastSeen == null) return 'Last seen unknown';

    final diff = DateTime.now().difference(lastSeen!);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
