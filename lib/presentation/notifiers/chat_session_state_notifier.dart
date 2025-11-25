import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/chat_screen_controller.dart';
import '../models/chat_ui_state.dart';

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
  ChatUIState build() => const ChatUIState();

  void replace(ChatUIState newState) {
    state = newState;
  }

  void update(void Function(ChatUIState) updater) {
    updater(state);
  }
}
