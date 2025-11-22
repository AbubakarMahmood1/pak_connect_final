import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/message.dart';

/// Handles all scroll-related logic for ChatScreen
/// Manages unread message state, scroll position tracking, and mark-as-read logic
class ChatScrollingController {
  final _logger = Logger('ChatScrollingController');
  final IChatsRepository chatsRepository;
  final String chatId;
  final VoidCallback onScrollToBottom;
  final Function(int) onUnreadCountChanged;
  final VoidCallback onStateChanged;

  // Scroll control
  late ScrollController scrollController;
  bool _isUserAtBottom = true;
  bool _hasScrolledAwayFromBottom = false;

  // Unread tracking
  int _lastReadMessageIndex = -1;
  int _unreadMessageCount = 0;
  Timer? _markAsReadDebounceTimer;
  Timer? _unreadSeparatorTimer;

  // Message state
  int _newMessagesWhileScrolledUp = 0;
  bool _messageListenerActive = false;
  bool _showUnreadSeparator = false;

  ChatScrollingController({
    required this.chatsRepository,
    required this.chatId,
    required this.onScrollToBottom,
    required this.onUnreadCountChanged,
    required this.onStateChanged,
  }) {
    scrollController = ScrollController();
    _setupScrollListener();
  }

  Future<void> syncUnreadCount({required List<Message> messages}) async {
    try {
      final chats = await chatsRepository.getAllChats();
      final currentChat = chats.firstWhere(
        (chat) => chat.chatId == chatId,
        orElse: () => ChatListItem(
          chatId: '',
          contactName: '',
          contactPublicKey: null,
          lastMessage: null,
          lastMessageTime: null,
          unreadCount: 0,
          isOnline: false,
          hasUnsentMessages: false,
          lastSeen: null,
        ),
      );

      _unreadMessageCount = currentChat.unreadCount;
      onUnreadCountChanged(_unreadMessageCount);

      if (_unreadMessageCount > 0 && messages.isNotEmpty) {
        _lastReadMessageIndex = messages.length - _unreadMessageCount - 1;
        _showUnreadSeparator = true;
        _startUnreadSeparatorTimer();
      } else {
        _lastReadMessageIndex = -1;
        _showUnreadSeparator = false;
      }

      _notifyStateChanged();
    } catch (e) {
      _logger.warning('⚠️ Failed to sync unread count: $e');
    }
  }

  Future<void> handleIncomingWhileScrolledAway() async {
    final shouldIncrementUnread =
        !_isUserAtBottom || _hasScrolledAwayFromBottom;
    if (!shouldIncrementUnread) return;

    _unreadMessageCount++;
    _newMessagesWhileScrolledUp++;
    onUnreadCountChanged(_unreadMessageCount);
    _showUnreadSeparator = true;

    try {
      await chatsRepository.incrementUnreadCount(chatId);
    } catch (e) {
      _logger.warning('⚠️ Failed to increment unread count: $e');
    }

    _notifyStateChanged();
  }

  bool get shouldAutoScrollOnIncoming =>
      _isUserAtBottom && !_hasScrolledAwayFromBottom;

  /// Initialize unread count (can be set by caller)
  void setUnreadCount(int count) {
    _unreadMessageCount = count;
    onUnreadCountChanged(count);
    _logger.info('✅ Set unread count: $count');
    _notifyStateChanged();
  }

  /// Set up scroll position listener
  void _setupScrollListener() {
    scrollController.addListener(_onScroll);
  }

  /// Handle scroll events
  void _onScroll() {
    final isUserAtBottom =
        scrollController.position.pixels >=
        scrollController.position.maxScrollExtent - 100;

    if (isUserAtBottom && !_isUserAtBottom) {
      // User scrolled to bottom
      _isUserAtBottom = true;
      _hasScrolledAwayFromBottom = false;
      _newMessagesWhileScrolledUp = 0;

      // Mark visible messages as read
      scheduleMarkAsRead();
      _logger.info('✅ User scrolled to bottom');
      _notifyStateChanged();
    } else if (!isUserAtBottom && _isUserAtBottom) {
      // User scrolled away from bottom
      _isUserAtBottom = false;
      _hasScrolledAwayFromBottom = true;
      _logger.info('⚠️ User scrolled up, tracking new messages');
      _notifyStateChanged();
    }
  }

  /// Check if scroll-down button should be visible
  bool shouldShowScrollDownButton(int messageCount) {
    return !_isUserAtBottom &&
        messageCount > 0 &&
        (_newMessagesWhileScrolledUp > 0 || _hasScrolledAwayFromBottom);
  }

  /// Scroll to bottom of message list
  Future<void> scrollToBottom() async {
    if (!scrollController.hasClients) return;

    try {
      await scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      _logger.info('✅ Scrolled to bottom');
      onScrollToBottom();
    } catch (e) {
      _logger.warning('⚠️ Failed to scroll to bottom: $e');
    }
  }

  /// Decrement unread count (when new message arrives while scrolled up)
  void decrementUnreadCount() {
    if (_unreadMessageCount > 0) {
      _unreadMessageCount--;
      _newMessagesWhileScrolledUp++;
      onUnreadCountChanged(_unreadMessageCount);
      _logger.info(
        'ℹ️ Unread count: $_unreadMessageCount, new while scrolled: $_newMessagesWhileScrolledUp',
      );
      _notifyStateChanged();
    }
  }

  /// Mark visible messages as read
  Future<void> _markAsRead() async {
    try {
      _markAsReadDebounceTimer?.cancel();
      _lastReadMessageIndex = -1;
      _unreadMessageCount = 0;
      _newMessagesWhileScrolledUp = 0;
      _hasScrolledAwayFromBottom = false;
      onUnreadCountChanged(0);
      await chatsRepository.markChatAsRead(chatId);
      _logger.info('✅ Marked messages as read');
      _notifyStateChanged();
    } catch (e) {
      _logger.warning('⚠️ Failed to mark messages as read: $e');
    }
  }

  Future<void> markAsRead() => _markAsRead();

  void scheduleMarkAsRead() {
    _markAsReadDebounceTimer?.cancel();
    if (_newMessagesWhileScrolledUp > 0 || _unreadMessageCount > 0) {
      _markAsReadDebounceTimer = Timer(const Duration(milliseconds: 1500), () {
        if (_isUserAtBottom) {
          _markAsRead();
        }
      });
    }
  }

  /// Start timer to hide unread separator after 2 seconds
  void startUnreadSeparatorTimer(Function() hideCallback) {
    _unreadSeparatorTimer?.cancel();
    _unreadSeparatorTimer = Timer(const Duration(seconds: 2), () {
      hideCallback();
    });
  }

  /// Reset scroll state when switching chats
  void resetScrollState() {
    _isUserAtBottom = true;
    _hasScrolledAwayFromBottom = false;
    _lastReadMessageIndex = -1;
    _unreadMessageCount = 0;
    _newMessagesWhileScrolledUp = 0;
    _messageListenerActive = false;
    _markAsReadDebounceTimer?.cancel();
    _unreadSeparatorTimer?.cancel();
  }

  /// Check if user is at bottom
  bool get isUserAtBottom => _isUserAtBottom;

  /// Get unread message count
  int get unreadMessageCount => _unreadMessageCount;

  /// Get count of new messages while scrolled up
  int get newMessagesWhileScrolledUp => _newMessagesWhileScrolledUp;

  int get lastReadMessageIndex => _lastReadMessageIndex;

  bool get showUnreadSeparator => _showUnreadSeparator;

  /// Get last read message index
  bool get hasScrolledAwayFromBottom => _hasScrolledAwayFromBottom;

  /// Update message listener state
  void setMessageListenerActive(bool active) {
    _messageListenerActive = active;
  }

  /// Dispose resources
  void dispose() {
    scrollController.dispose();
    _markAsReadDebounceTimer?.cancel();
    _unreadSeparatorTimer?.cancel();
  }

  void _notifyStateChanged() {
    onStateChanged();
  }

  void _startUnreadSeparatorTimer() {
    _unreadSeparatorTimer?.cancel();
    _unreadSeparatorTimer = Timer(const Duration(seconds: 3), () {
      _showUnreadSeparator = false;
      _notifyStateChanged();
      _markAsRead();
    });
  }
}
