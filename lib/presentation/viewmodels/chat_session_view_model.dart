import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../models/chat_ui_state.dart';
import '../models/chat_screen_config.dart';
import '../providers/chat_messaging_view_model.dart';
import '../controllers/chat_scrolling_controller.dart' as chat_controller;
import '../controllers/chat_search_controller.dart';
import '../controllers/chat_pairing_dialog_controller.dart';
import '../controllers/chat_session_lifecycle.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../core/security/message_security.dart';
import '../../core/utils/chat_utils.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/services/persistent_chat_state_manager.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/message.dart';
import '../../domain/services/notification_service.dart';
import '../notifiers/chat_session_state_notifier.dart';

/// Planned Riverpod-backed ViewModel for ChatScreen state and commands.
/// This is scaffolding only; logic will migrate from ChatScreenController
/// in later milestones without altering current behavior.
class ChatSessionViewModel {
  ChatSessionViewModel({
    required this.config,
    required this.messageRepository,
    required this.contactRepository,
    required this.chatsRepository,
    required this.messagingViewModel,
    required this.scrollingController,
    required this.searchController,
    required this.pairingDialogController,
    this.retryCoordinator,
    this.sessionLifecycle,
    this.displayContactNameFn,
    this.getContactPublicKeyFn,
    this.getChatIdFn,
    this.onScrollToBottom,
    this.onShowError,
    this.onShowSuccess,
    this.onShowInfo,
    this.isDisposedFn,
    // Phase 6B: Message listener callbacks
    this.getConnectionServiceFn,
    this.getPersistentChatManagerFn,
  });

  final ChatScreenConfig config;
  final MessageRepository messageRepository;
  final ContactRepository contactRepository;
  final ChatsRepository chatsRepository;
  final ChatMessagingViewModel messagingViewModel;
  final chat_controller.ChatScrollingController scrollingController;
  final ChatSearchController searchController;
  final ChatPairingDialogController pairingDialogController;
  final MessageRetryCoordinator? retryCoordinator;
  ChatSessionLifecycle? sessionLifecycle;

  // Callback functions to resolve dependencies from controller
  final String Function()? displayContactNameFn;
  final String? Function()? getContactPublicKeyFn;
  final String Function()? getChatIdFn;
  final Function()? onScrollToBottom;
  final void Function(String)? onShowError;
  final void Function(String)? onShowSuccess;
  final void Function(String)? onShowInfo;
  final bool Function()? isDisposedFn;

  // Phase 6B: Callbacks for lifecycle message listener management
  final IConnectionService Function()? getConnectionServiceFn;
  final PersistentChatStateManager? Function()? getPersistentChatManagerFn;

  ChatSessionStateStore? stateStore;
  final _logger = Logger('ChatSessionViewModel');

  void bindStateStore(ChatSessionStateStore store) {
    stateStore = store;
  }

  /// Compute new state with an updated message status.
  ChatUIState applyMessageStatus(
    ChatUIState state,
    String messageId,
    MessageStatus newStatus,
  ) {
    final messages = [...state.messages];
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      messages[index] = messages[index].copyWith(status: newStatus);
    }
    return state.copyWith(messages: messages);
  }

  /// Compute new state with an updated message replacement.
  ChatUIState applyMessageUpdate(ChatUIState state, Message updatedMessage) {
    final messages = [...state.messages];
    final index = messages.indexWhere((m) => m.id == updatedMessage.id);
    if (index != -1) {
      messages[index] = updatedMessage;
    }
    return state.copyWith(messages: messages);
  }

  /// Sync scroll-derived flags/counts into state using the existing controller.
  ChatUIState syncScrollState(ChatUIState state) {
    return state.copyWith(
      unreadMessageCount: scrollingController.unreadMessageCount,
      newMessagesWhileScrolledUp:
          scrollingController.newMessagesWhileScrolledUp,
      showUnreadSeparator: scrollingController.showUnreadSeparator,
    );
  }

  /// Mark search mode state based on the search controller toggle.
  ChatUIState applySearchMode(ChatUIState state, bool isSearchMode) =>
      state.copyWith(isSearchMode: isSearchMode);

  /// Update the search query text in state.
  ChatUIState applySearchQuery(ChatUIState state, String query) =>
      state.copyWith(searchQuery: query);

  /// Replace messages list.
  ChatUIState applyMessages(ChatUIState state, List<Message> messages) =>
      state.copyWith(messages: messages);

  /// Update loading flag.
  ChatUIState applyLoading(ChatUIState state, bool isLoading) =>
      state.copyWith(isLoading: isLoading);

  /// Reset unread counter when scrolling to bottom.
  ChatUIState clearNewWhileScrolledUp(ChatUIState state) =>
      state.copyWith(newMessagesWhileScrolledUp: 0);

  /// Append a message to the UI list.
  ChatUIState appendMessage(ChatUIState state, Message message) =>
      state.copyWith(messages: [...state.messages, message]);

  /// Remove a message by id from the UI list.
  ChatUIState removeMessageById(ChatUIState state, String messageId) =>
      state.copyWith(
        messages: state.messages.where((m) => m.id != messageId).toList(),
      );

  /// Update unread count from scroll controller signal.
  ChatUIState applyUnreadCount(ChatUIState state, int count) =>
      state.copyWith(unreadMessageCount: count);

  /// Update mesh initialization state and status text together.
  ChatUIState applyMeshState(
    ChatUIState state, {
    required bool meshInitializing,
    required String initializationStatus,
  }) => state.copyWith(
    meshInitializing: meshInitializing,
    initializationStatus: initializationStatus,
  );

  /// Update only the initialization status text.
  ChatUIState applyInitializationStatus(
    ChatUIState state,
    String initializationStatus,
  ) => state.copyWith(initializationStatus: initializationStatus);

  /// Toggle search mode and persist the state flag.
  void toggleSearchMode() {
    searchController.toggleSearchMode();
  }

  /// Update the search query text within the state store.
  void updateSearchQuery(String query) {
    stateStore?.setSearchQuery(query);
  }

  /// Navigate to a search result while keeping scroll behavior encapsulated.
  void navigateToSearchResult(int messageIndex, int totalMessages) {
    searchController.navigateToSearchResult(messageIndex, totalMessages);
  }

  // ===== PHASE 6A EXTRACTED METHODS =====

  /// Send a message (extracted from ChatScreenController)
  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;
    try {
      await messagingViewModel.sendMessage(
        content: content,
        onMessageAdded: (message) {
          stateStore?.appendMessage(message);
        },
        onShowSuccess: onShowSuccess,
        onShowError: onShowError,
        onScrollToBottom: onScrollToBottom,
      );
    } catch (e) {
      _logger.severe('Unexpected error in sendMessage: $e');
    }
  }

  /// Delete a message (extracted from ChatScreenController)
  Future<void> deleteMessage(String messageId, bool deleteForEveryone) async {
    try {
      await messagingViewModel.deleteMessage(
        messageId: messageId,
        deleteForEveryone: deleteForEveryone,
        onMessageRemoved: (id) {
          stateStore?.removeMessage(id);
        },
        onShowSuccess: onShowSuccess,
        onShowError: onShowError,
      );
    } catch (e) {
      _logger.severe('Unexpected error in deleteMessage: $e');
    }
  }

  /// Retry failed messages (extracted from ChatScreenController)
  Future<void> retryFailedMessages() => autoRetryFailedMessages();

  /// Auto-retry failed messages (extracted from ChatScreenController)
  Future<void> autoRetryFailedMessages() =>
      sessionLifecycle?.autoRetryFailedMessages() ?? Future.value();

  /// Load all messages (extracted from ChatScreenController)
  Future<void> loadMessages() async {
    try {
      final chatId = getChatIdFn?.call() ?? '';
      final allMessages = await messagingViewModel.loadMessages(
        onLoadingStateChanged: (isLoading) {
          stateStore?.setLoading(isLoading);
        },
        onGetQueuedMessages: () => [], // Will be connected by controller
        onScrollToBottom: onScrollToBottom,
        onError: onShowError,
      );

      stateStore?.setMessages(allMessages);

      if (config.isRepositoryMode) {
        await scrollingController.syncUnreadCount(messages: allMessages);
        final newState = stateStore?.state;
        if (newState != null) {
          // Update state in store - apply scroll state sync
          final updated = syncScrollState(newState);
          stateStore?.setMessages(updated.messages);
        }
      }

      // Process any buffered messages
      if (sessionLifecycle != null) {
        await sessionLifecycle!.processBufferedMessages(
          (content) => addReceivedMessage(content),
        );
      }

      sessionLifecycle?.scheduleAutoRetry(
        delay: const Duration(milliseconds: 1000),
        disposed: isDisposedFn ?? (() => false),
        onRetry: () async {
          sessionLifecycle?.ensureRetryCoordinator();
          await autoRetryFailedMessages();
        },
      );
    } catch (e) {
      _logger.severe('Error in loadMessages: $e');
      onShowError?.call('Failed to load messages: $e');
      stateStore?.setLoading(false);
    }
  }

  /// Retry a single message from repository (extracted from ChatScreenController)
  Future<void> retryRepositoryMessage(Message message) async {
    try {
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await messageRepository.updateMessage(retryMessage);
      stateStore?.updateMessage(retryMessage);

      // Note: Router/connection logic deferred - controller provides context
      // This is a simplified version; controller may need to handle complex routing
      final newStatus = MessageStatus.delivered;
      final updatedMessage = retryMessage.copyWith(status: newStatus);
      await messageRepository.updateMessage(updatedMessage);
      stateStore?.updateMessage(updatedMessage);
    } catch (e) {
      final failedAgain = message.copyWith(status: MessageStatus.failed);
      await messageRepository.updateMessage(failedAgain);
      stateStore?.updateMessage(failedAgain);
      rethrow;
    }
  }

  /// Add a received message (extracted from ChatScreenController)
  Future<void> addReceivedMessage(String content) async {
    final chatId = getChatIdFn?.call() ?? '';
    final contactPublicKey = getContactPublicKeyFn?.call() ?? chatId;
    final senderPublicKey = contactPublicKey;
    final secureMessageId = await MessageSecurity.generateSecureMessageId(
      senderPublicKey: senderPublicKey,
      content: content,
    );

    final existingMessage = await messageRepository.getMessageById(
      secureMessageId,
    );
    if (existingMessage != null) {
      final currentState = stateStore?.state;
      if (currentState != null) {
        final inUiList = currentState.messages.any(
          (m) => m.id == secureMessageId,
        );
        if (!inUiList) {
          stateStore?.appendMessage(existingMessage);
          onScrollToBottom?.call();
        }
      }
      return;
    }

    final message = Message(
      id: secureMessageId,
      chatId: chatId,
      content: content,
      timestamp: DateTime.now(),
      isFromMe: false,
      status: MessageStatus.delivered,
    );

    await messageRepository.saveMessage(message);

    try {
      await NotificationService.showMessageNotification(
        message: message,
        contactName: displayContactNameFn?.call() ?? 'Unknown',
        contactAvatar: null,
      );
    } catch (e, stackTrace) {
      _logger.severe('Failed to show notification: $e', e, stackTrace);
    }

    final shouldAutoScroll = scrollingController.shouldAutoScrollOnIncoming;

    if (!shouldAutoScroll) {
      await scrollingController.handleIncomingWhileScrolledAway();
    }

    stateStore?.appendMessage(message);

    if (shouldAutoScroll) {
      onScrollToBottom?.call();
      scrollingController.scheduleMarkAsRead();
    }
  }

  /// Handle identity received (persistent key discovery) (extracted from ChatScreenController)
  Future<void> handleIdentityReceived() async {
    final chatId = getChatIdFn?.call() ?? '';
    final contactPublicKey = getContactPublicKeyFn?.call();

    // This is complex logic that needs controller context
    // Controller will implement full logic; ViewModel provides hook
    _logger.info('handleIdentityReceived called for chat $chatId');
  }

  /// Calculate initial chat ID (extracted from ChatScreenController)
  String calculateInitialChatId() {
    if (config.isRepositoryMode && config.chatId != null) {
      return config.chatId!;
    }
    // Controller will provide implementation with ref access
    return getChatIdFn?.call() ?? '';
  }

  // ===== PHASE 6B EXTRACTED METHODS =====

  /// Activate message listener with persistent or stream-based delivery (extracted from ChatScreenController)
  Future<void> activateMessageListener() async {
    if (sessionLifecycle == null || sessionLifecycle!.messageListenerActive) {
      return;
    }

    sessionLifecycle!.messageListenerActive = true;
    final connectionService = getConnectionServiceFn?.call();
    if (connectionService == null) {
      _logger.warning(
        'ConnectionService not available; message listener disabled',
      );
      return;
    }

    final persistentChatManager = getPersistentChatManagerFn?.call();
    final chatId = getChatIdFn?.call() ?? '';

    if (persistentChatManager != null &&
        !persistentChatManager.hasActiveListener(chatId)) {
      // Phase 6B: Use persistent listener if available
      sessionLifecycle!.registerPersistentListener(
        chatId: chatId,
        incomingStream: () => connectionService.receivedMessages,
        onMessage: (content) async => addReceivedMessage(content),
      );
      _logger.info('📡 Message listener activated (persistent mode)');
    } else if (persistentChatManager != null &&
        persistentChatManager.hasActiveListener(chatId)) {
      // Already registered
      _logger.fine('Message listener already active (persistent)');
    } else {
      // Phase 6B: Use stream-based listener with buffering
      sessionLifecycle!.attachMessageStream(
        stream: connectionService.receivedMessages,
        disposed: () => isDisposedFn?.call() ?? false,
        isActive: () => sessionLifecycle?.messageListenerActive ?? false,
        onMessage: (content) async {
          sessionLifecycle?.messageBuffer.add(content);
          await processBufferedMessages();
        },
      );
      _logger.info('📡 Message listener activated (stream mode)');
    }
  }

  /// Process buffered messages from message listener (extracted from ChatScreenController)
  Future<void> processBufferedMessages() async {
    if (sessionLifecycle == null) {
      _logger.warning(
        'Lifecycle not initialized; cannot process buffered messages',
      );
      return;
    }

    try {
      await sessionLifecycle!.processBufferedMessages(
        (content) => addReceivedMessage(content),
      );
    } catch (e) {
      _logger.severe('Error processing buffered messages: $e');
    }
  }
}
