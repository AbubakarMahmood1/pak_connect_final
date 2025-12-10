import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';

import '../controllers/chat_screen_controller.dart';
import '../models/chat_ui_state.dart';
import '../../domain/entities/message.dart';
import '../../domain/values/id_types.dart';

/// State notifier that mirrors ChatScreenController state for provider reads.
class ChatSessionStateNotifier extends Notifier<ChatUIState> {
  ChatSessionStateNotifier(this.args);
  final ChatScreenControllerArgs args;

  @override
  ChatUIState build() {
    final controller = ref.watch(chatScreenControllerProvider(args));
    state = controller.state;
    ref.listen<ChatScreenController>(chatScreenControllerProvider(args), (
      previous,
      next,
    ) {
      state = next.state;
    });
    return state;
  }

  // Future migration: accept direct state updates to own state instead of mirroring.
  void updateState(ChatUIState newState) {
    state = newState;
  }
}

/// Provider-owned state (opt-in path uses this; controller currently publishes
/// into it).
class ChatSessionOwnedStateNotifier extends Notifier<ChatUIState> {
  ChatSessionOwnedStateNotifier(this.args);
  final ChatScreenControllerArgs args;

  @override
  ChatUIState build() {
    ref.keepAlive(); // Keep legacy consumers alive across rebuilds/navigation.
    return const ChatUIState();
  }

  void replace(ChatUIState newState) {
    state = newState;
  }

  void update(void Function(ChatUIState) updater) {
    updater(state);
  }
}

/// Primary state store for ChatScreen when migrating off the controller.
class ChatSessionStateStore extends StateNotifier<ChatUIState> {
  ChatSessionStateStore() : super(const ChatUIState());

  bool _disposed = false;
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  ChatUIState get current => state;

  void replace(ChatUIState newState) {
    if (_disposed) return;
    state = newState;
  }

  void update(ChatUIState Function(ChatUIState) updater) {
    if (_disposed) return;
    state = updater(state);
  }

  void setMessages(List<Message> messages) {
    if (_disposed) return;
    state = state.copyWith(messages: messages);
  }

  void appendMessage(Message message) {
    if (_disposed) return;
    state = state.copyWith(messages: [...state.messages, message]);
  }

  void updateMessage(Message updatedMessage) {
    if (_disposed) return;
    state = state.copyWith(
      messages: state.messages
          .map((m) => m.id == updatedMessage.id ? updatedMessage : m)
          .toList(),
    );
  }

  void updateMessageStatus(MessageId messageId, MessageStatus newStatus) {
    if (_disposed) return;
    state = state.copyWith(
      messages: state.messages
          .map((m) => m.id == messageId ? m.copyWith(status: newStatus) : m)
          .toList(),
    );
  }

  void removeMessage(MessageId messageId) {
    if (_disposed) return;
    state = state.copyWith(
      messages: state.messages.where((m) => m.id != messageId).toList(),
    );
  }

  void setLoading(bool isLoading) {
    if (_disposed) return;
    state = state.copyWith(isLoading: isLoading);
  }

  void setUnreadCount(int count) {
    if (_disposed) return;
    state = state.copyWith(unreadMessageCount: count);
  }

  void clearNewWhileScrolledUp() {
    if (_disposed) return;
    state = state.copyWith(newMessagesWhileScrolledUp: 0);
  }

  void setSearchMode(bool isSearchMode) {
    if (_disposed) return;
    state = state.copyWith(isSearchMode: isSearchMode);
  }

  void setSearchQuery(String query) {
    if (_disposed) return;
    state = state.copyWith(searchQuery: query);
  }

  void setMeshState({
    required bool meshInitializing,
    required String initializationStatus,
  }) {
    if (_disposed) return;
    state = state.copyWith(
      meshInitializing: meshInitializing,
      initializationStatus: initializationStatus,
    );
  }

  void setInitializationStatus(String initializationStatus) {
    if (_disposed) return;
    state = state.copyWith(initializationStatus: initializationStatus);
  }
}
