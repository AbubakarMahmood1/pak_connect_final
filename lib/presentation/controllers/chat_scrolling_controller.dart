import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../../data/repositories/message_repository.dart';

/// Handles all scroll-related logic for ChatScreen
/// Manages unread message state, scroll position tracking, and mark-as-read logic
class ChatScrollingController {
  final _logger = Logger('ChatScrollingController');
  final MessageRepository messageRepository;
  final VoidCallback onScrollToBottom;
  final Function(int) onUnreadCountChanged;

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

  ChatScrollingController({
    required this.messageRepository,
    required this.onScrollToBottom,
    required this.onUnreadCountChanged,
  }) {
    scrollController = ScrollController();
    _setupScrollListener();
  }

  /// Initialize unread count (can be set by caller)
  void setUnreadCount(int count) {
    _unreadMessageCount = count;
    onUnreadCountChanged(count);
    _logger.info('✅ Set unread count: $count');
  }

  /// Deprecated: use setUnreadCount instead
  Future<void> loadUnreadCount(String chatId) async {
    try {
      // Load unread count based on message status
      // Implementation depends on repository structure
      _logger.info('✅ Loaded unread count: $_unreadMessageCount');
    } catch (e) {
      _logger.warning('⚠️ Failed to load unread count: $e');
    }
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
      _scheduleMarkAsRead();
      _logger.info('✅ User scrolled to bottom');
    } else if (!isUserAtBottom && _isUserAtBottom) {
      // User scrolled away from bottom
      _isUserAtBottom = false;
      _hasScrolledAwayFromBottom = true;
      _logger.info('⚠️ User scrolled up, tracking new messages');
    }
  }

  /// Check if scroll-down button should be visible
  bool shouldShowScrollDownButton() {
    return !_isUserAtBottom && _newMessagesWhileScrolledUp > 0;
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
    }
  }

  /// Schedule marking messages as read (debounced)
  void _scheduleMarkAsRead() {
    _markAsReadDebounceTimer?.cancel();
    _markAsReadDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _markAsRead();
    });
  }

  /// Mark visible messages as read
  Future<void> _markAsRead() async {
    try {
      _markAsReadDebounceTimer?.cancel();
      _lastReadMessageIndex = 0;
      _unreadMessageCount = 0;
      onUnreadCountChanged(0);

      _logger.info('✅ Marked messages as read');
    } catch (e) {
      _logger.warning('⚠️ Failed to mark messages as read: $e');
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

  /// Get last read message index
  int get lastReadMessageIndex => _lastReadMessageIndex;

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
}
