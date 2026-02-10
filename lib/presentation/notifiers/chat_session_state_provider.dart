import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_ui_state.dart';
import '../controllers/chat_screen_controller.dart';
import '../providers/chat_session_providers.dart';

/// Temporary provider to expose ChatUIState directly from controller.
final chatSessionStateMirrorProvider =
    Provider.family<ChatUIState, ChatScreenControllerArgs>((ref, args) {
      return ref.watch(chatSessionStateStoreProvider(args));
    });

/// Preferred state provider for migrated consumers (owned notifier).
final chatSessionStateProvider =
    Provider.family<ChatUIState, ChatScreenControllerArgs>((ref, args) {
      return ref.watch(chatSessionStateStoreProvider(args));
    });
