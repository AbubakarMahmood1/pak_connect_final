import '../../domain/entities/chat_list_item.dart';

class HomeScreenState {
  const HomeScreenState({
    this.chats = const [],
    this.isLoading = true,
    this.isPaging = false,
    this.hasMore = true,
    this.searchQuery = '',
    this.unreadCountStream,
  });

  final List<ChatListItem> chats;
  final bool isLoading;
  final bool isPaging;
  final bool hasMore;
  final String searchQuery;
  final Stream<int>? unreadCountStream;

  HomeScreenState copyWith({
    List<ChatListItem>? chats,
    bool? isLoading,
    bool? isPaging,
    bool? hasMore,
    String? searchQuery,
    Stream<int>? unreadCountStream,
  }) {
    return HomeScreenState(
      chats: chats ?? this.chats,
      isLoading: isLoading ?? this.isLoading,
      isPaging: isPaging ?? this.isPaging,
      hasMore: hasMore ?? this.hasMore,
      searchQuery: searchQuery ?? this.searchQuery,
      unreadCountStream: unreadCountStream ?? this.unreadCountStream,
    );
  }
}
