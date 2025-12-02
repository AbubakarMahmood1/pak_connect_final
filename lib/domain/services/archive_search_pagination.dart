import '../../core/models/archive_models.dart';
import '../../domain/entities/archived_message.dart';

/// Helper to enforce pagination/limits on archive search results
class ArchiveSearchPagination {
  ArchiveSearchResult applyLimit(ArchiveSearchResult result, int limit) {
    final shouldLimit =
        result.messages.length > limit || result.chats.length > limit;

    if (!shouldLimit) {
      return result;
    }

    // Use take() to safely limit results without index out-of-bounds errors
    final limitedMessages = result.messages.take(limit).toList();
    final limitedChats = result.chats.take(limit).toList();
    final messagesByChat = _groupMessagesByChat(limitedMessages);

    return ArchiveSearchResult(
      messages: limitedMessages,
      chats: limitedChats,
      messagesByChat: messagesByChat,
      query: result.query,
      filter: result.filter,
      totalResults: result.totalResults,
      totalChatsFound: result.totalChatsFound,
      searchTime: result.searchTime,
      hasMore: true,
      nextPageToken: result.nextPageToken,
      metadata: result.metadata,
    );
  }

  Map<String, List<ArchivedMessage>> _groupMessagesByChat(
    List<ArchivedMessage> messages,
  ) {
    final grouped = <String, List<ArchivedMessage>>{};

    for (final message in messages) {
      grouped.putIfAbsent(message.chatId.value, () => []).add(message);
    }

    return grouped;
  }
}
