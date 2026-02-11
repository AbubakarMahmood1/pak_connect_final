import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_chat_interaction_handler.dart';
import '../../domain/services/chat_management_service.dart';
import '../../presentation/services/chat_interaction_handler.dart';

final _logger = Logger('ChatInteractionIntentProvider');

/// ✅ Phase 6D: Riverpod provider for ChatInteractionHandler
/// Manages UI interaction handler lifecycle and dependency injection
/// Provider.autoDispose ensures handler is cleaned up when no longer watched
final chatInteractionHandlerProvider = Provider.autoDispose
    .family<
      ChatInteractionHandler,
      ({
        IChatsRepository chatsRepository,
        ChatManagementService chatManagementService,
      })
    >((ref, args) {
      // Create handler with all dependencies
      final handler = ChatInteractionHandler(
        context: null, // Context provided by consumer (HomeScreen)
        ref: null, // WidgetRef provided by consumer
        chatsRepository: args.chatsRepository,
        chatManagementService: args.chatManagementService,
      );

      // Cleanup on disposal
      ref.onDispose(handler.dispose);
      _logger.fine('✅ ChatInteractionHandler provider created');

      return handler;
    });

/// ✅ Phase 6D: StreamProvider for chat interaction intents
/// Wraps ChatInteractionHandler's interactionIntentStream for Riverpod consumers
/// Emits intent events from user actions (open chat, archive, delete, etc.)
final chatInteractionIntentStreamProvider = StreamProvider.autoDispose
    .family<
      ChatInteractionIntent,
      ({
        IChatsRepository chatsRepository,
        ChatManagementService chatManagementService,
      })
    >((ref, args) async* {
      final handler = ref.watch(chatInteractionHandlerProvider(args));
      yield* handler.interactionIntentStream;
    });
