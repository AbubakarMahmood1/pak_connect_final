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
  ChatSessionStateStore() : super(const ChatUIState()) {
    _snapshot = state;
  }

  bool _disposed = false;
  bool _mounted = true;
  late ChatUIState _snapshot;
  bool get isDisposed => _disposed;
  bool get isMounted => _mounted;

  bool get _canUpdate => !_disposed && _mounted;

  /// Safe accessor that avoids throwing after disposal.
  ChatUIState get current => _snapshot;

  void markMounted(bool mounted) {
    _mounted = mounted;
  }

  @override
  void dispose() {
    _snapshot = state;
    _mounted = false;
    _disposed = true;
    super.dispose();
  }

  void replace(ChatUIState newState) {
    if (!_canUpdate) return;
    state = newState;
    _snapshot = newState;
  }

  void update(ChatUIState Function(ChatUIState) updater) {
    if (!_canUpdate) return;
    final updated = updater(state);
    state = updated;
    _snapshot = updated;
  }

  void setMessages(List<Message> messages) {
    if (!_canUpdate) return;
    final updated = state.copyWith(messages: messages);
    state = updated;
    _snapshot = updated;
  }

  void appendMessage(Message message) {
    if (!_canUpdate) return;
    final updated = state.copyWith(messages: [...state.messages, message]);
    state = updated;
    _snapshot = updated;
  }

  void updateMessage(Message updatedMessage) {
    if (!_canUpdate) return;
    final updatedState = state.copyWith(
      messages: state.messages
          .map((m) => m.id == updatedMessage.id ? updatedMessage : m)
          .toList(),
    );
    state = updatedState;
    _snapshot = updatedState;
  }

  void updateMessageStatus(MessageId messageId, MessageStatus newStatus) {
    if (!_canUpdate) return;
    final updatedState = state.copyWith(
      messages: state.messages
          .map((m) => m.id == messageId ? m.copyWith(status: newStatus) : m)
          .toList(),
    );
    state = updatedState;
    _snapshot = updatedState;
  }

  void removeMessage(MessageId messageId) {
    if (!_canUpdate) return;
    final updatedState = state.copyWith(
      messages: state.messages.where((m) => m.id != messageId).toList(),
    );
    state = updatedState;
    _snapshot = updatedState;
  }

  void setLoading(bool isLoading) {
    if (!_canUpdate) return;
    final updated = state.copyWith(isLoading: isLoading);
    state = updated;
    _snapshot = updated;
  }

  void setUnreadCount(int count) {
    if (!_canUpdate) return;
    final updated = state.copyWith(unreadMessageCount: count);
    state = updated;
    _snapshot = updated;
  }

  void clearNewWhileScrolledUp() {
    if (!_canUpdate) return;
    final updated = state.copyWith(newMessagesWhileScrolledUp: 0);
    state = updated;
    _snapshot = updated;
  }

  void setSearchMode(bool isSearchMode) {
    if (!_canUpdate) return;
    final updated = state.copyWith(isSearchMode: isSearchMode);
    state = updated;
    _snapshot = updated;
  }

  void setSearchQuery(String query) {
    if (!_canUpdate) return;
    final updated = state.copyWith(searchQuery: query);
    state = updated;
    _snapshot = updated;
  }

  void setMeshState({
    required bool meshInitializing,
    required String initializationStatus,
  }) {
    if (!_canUpdate) return;
    final updatedState = state.copyWith(
      meshInitializing: meshInitializing,
      initializationStatus: initializationStatus,
    );
    state = updatedState;
    _snapshot = updatedState;
  }

  void setInitializationStatus(String initializationStatus) {
    if (!_canUpdate) return;
    final updated = state.copyWith(initializationStatus: initializationStatus);
    state = updated;
    _snapshot = updated;
  }
}
