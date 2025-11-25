import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_ui_state.dart';
import '../controllers/chat_screen_controller.dart';

/// Temporary provider to expose ChatUIState directly from controller.
final chatSessionStateMirrorProvider =
    Provider.family<ChatUIState, ChatScreenControllerArgs>((ref, args) {
      final controller = ref.watch(chatScreenControllerProvider(args));
      return controller.state;
    });
