import 'package:flutter/material.dart';

import '../../domain/entities/message.dart';
import '../../domain/values/id_types.dart';
import '../controllers/chat_scrolling_controller.dart' as chat_controller;
import '../controllers/chat_search_controller.dart';
import '../models/chat_ui_state.dart';
import 'chat_screen_helpers.dart';
import 'chat_search_bar.dart';
import 'message_bubble.dart';

class ChatMessagesSection extends StatelessWidget {
  const ChatMessagesSection({
    required this.uiState,
    required this.messages,
    required this.searchController,
    required this.scrollingController,
    required this.onToggleSearchMode,
    required this.onRetryFailedMessages,
    required this.retryHandlerFor,
    required this.onDeleteMessage,
    super.key,
  });

  final ChatUIState uiState;
  final List<Message> messages;
  final ChatSearchController searchController;
  final chat_controller.ChatScrollingController scrollingController;
  final VoidCallback onToggleSearchMode;
  final VoidCallback onRetryFailedMessages;
  final VoidCallback? Function(Message message) retryHandlerFor;
  final Future<void> Function(MessageId messageId, bool deleteForEveryone)
  onDeleteMessage;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          if (searchController.isSearchMode)
            ChatSearchBar(
              messages: messages,
              onSearch: searchController.handleSearchQuery,
              onNavigateToResult: (index) => searchController
                  .navigateToSearchResult(index, messages.length),
              onExitSearch: onToggleSearchMode,
            ),
          Expanded(
            child: uiState.isLoading
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                ? const EmptyChatPlaceholder()
                : ListView.builder(
                    controller: scrollingController.scrollController,
                    padding: EdgeInsets.zero,
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
                        final failedCount = uiState.messages
                            .where(
                              (message) =>
                                  message.isFromMe &&
                                  message.status == MessageStatus.failed,
                            )
                            .length;
                        return RetryIndicator(
                          failedCount: failedCount,
                          onRetry: onRetryFailedMessages,
                        );
                      }

                      final message = messages[index];
                      final retryHandler = retryHandlerFor(message);
                      Widget messageWidget = MessageBubble(
                        message: message,
                        showAvatar: true,
                        showStatus: true,
                        searchQuery: searchController.isSearchMode
                            ? searchController.searchQuery
                            : null,
                        onRetry: retryHandler,
                        onDelete: onDeleteMessage,
                      );

                      if (uiState.showUnreadSeparator &&
                          index ==
                              scrollingController.lastReadMessageIndex + 1 &&
                          scrollingController.unreadMessageCount > 0) {
                        return Column(
                          children: [const UnreadSeparator(), messageWidget],
                        );
                      }

                      return messageWidget;
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.messageController,
    required this.hintText,
    required this.canSendImage,
    required this.onPickImage,
    required this.onSendMessage,
    super.key,
  });

  final TextEditingController messageController;
  final String hintText;
  final bool canSendImage;
  final VoidCallback onPickImage;
  final VoidCallback onSendMessage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.image),
            tooltip: 'Send image',
            onPressed: canSendImage ? onPickImage : null,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: messageController,
              decoration: InputDecoration(
                hintText: hintText,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.send), onPressed: onSendMessage),
        ],
      ),
    );
  }
}

class ChatScrollDownFab extends StatelessWidget {
  const ChatScrollDownFab({
    required this.newMessagesWhileScrolledUp,
    required this.onPressed,
    super.key,
  });

  final int newMessagesWhileScrolledUp;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 80),
      child: FloatingActionButton(
        mini: true,
        onPressed: onPressed,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.arrow_downward),
            if (newMessagesWhileScrolledUp > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  child: Text(
                    newMessagesWhileScrolledUp > 99
                        ? '99+'
                        : '$newMessagesWhileScrolledUp',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
