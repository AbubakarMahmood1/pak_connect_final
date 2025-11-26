import '../models/chat_ui_state.dart';
import '../models/chat_screen_config.dart';
import '../providers/chat_messaging_view_model.dart';
import '../controllers/chat_scrolling_controller.dart' as chat_controller;
import '../controllers/chat_search_controller.dart';
import '../controllers/chat_pairing_dialog_controller.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/message.dart';
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
  ChatSessionStateStore? stateStore;

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
}
