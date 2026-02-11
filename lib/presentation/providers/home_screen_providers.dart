import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_chat_interaction_handler.dart';
import '../../domain/interfaces/i_home_screen_facade.dart';
import '../../domain/interfaces/i_home_screen_facade_factory.dart';
import '../../domain/services/chat_management_service.dart';
import '../controllers/chat_list_controller.dart';
import '../services/chat_interaction_handler.dart';
import 'ble_providers.dart';

class HomeScreenProviderArgs {
  const HomeScreenProviderArgs({
    required this.context,
    required this.ref,
    required this.chatsRepository,
    required this.chatManagementService,
    this.homeScreenFacade,
    this.chatListController,
    this.logger,
  });

  final BuildContext context;
  final WidgetRef ref;
  final IChatsRepository chatsRepository;
  final ChatManagementService chatManagementService;
  final IHomeScreenFacade? homeScreenFacade;
  final ChatListController? chatListController;
  final Logger? logger;
}

class ChatInteractionHandlerArgs {
  const ChatInteractionHandlerArgs({
    required this.context,
    required this.ref,
    required this.chatsRepository,
    required this.chatManagementService,
  });

  final BuildContext context;
  final WidgetRef ref;
  final IChatsRepository chatsRepository;
  final ChatManagementService chatManagementService;
}

final chatListControllerProvider = Provider<ChatListController>(
  (ref) => ChatListController(),
);

final chatInteractionHandlerProvider = Provider.autoDispose
    .family<ChatInteractionHandler, ChatInteractionHandlerArgs>((ref, args) {
      final handler = ChatInteractionHandler(
        context: args.context,
        ref: args.ref,
        chatsRepository: args.chatsRepository,
        chatManagementService: args.chatManagementService,
      );
      ref.onDispose(() {
        unawaited(handler.dispose());
      });
      return handler;
    });

/// StreamProvider bridge for interaction intents emitted by ChatInteractionHandler.
final chatInteractionIntentProvider = StreamProvider.autoDispose
    .family<ChatInteractionIntent, ChatInteractionHandlerArgs>((ref, args) {
      final handler = ref.watch(chatInteractionHandlerProvider(args));
      return handler.interactionIntentStream;
    });

final homeScreenFacadeProvider = Provider.autoDispose
    .family<IHomeScreenFacade, HomeScreenProviderArgs>((ref, args) {
      if (args.homeScreenFacade != null) return args.homeScreenFacade!;

      // Use a single args instance so the handler and intent listener share the same provider instance.
      final handlerArgs = ChatInteractionHandlerArgs(
        context: args.context,
        ref: args.ref,
        chatsRepository: args.chatsRepository,
        chatManagementService: args.chatManagementService,
      );

      final interactionHandler = ref.watch(
        chatInteractionHandlerProvider(handlerArgs),
      );

      final facadeFactory = _resolveHomeScreenFacadeFactory();
      final facade = facadeFactory.create(
        chatsRepository: args.chatsRepository,
        bleService: ref.read(connectionServiceProvider),
        chatManagementService: args.chatManagementService,
        context: args.context,
        ref: args.ref,
        interactionHandlerBuilder:
            ({context, ref, chatsRepository, chatManagementService}) =>
                interactionHandler,
        enableInternalIntentListener: false,
      );

      ref.listen<AsyncValue<ChatInteractionIntent>>(
        chatInteractionIntentProvider(handlerArgs),
        (previous, next) {
          next.whenData((intent) async {
            if (intent is ChatOpenedIntent ||
                intent is ChatArchivedIntent ||
                intent is ChatDeletedIntent ||
                intent is ChatPinToggleIntent) {
              scheduleMicrotask(() => unawaited(facade.loadChats()));
            }
          });
        },
      );

      ref.onDispose(() {
        unawaited(facade.dispose());
      });
      return facade;
    });

IHomeScreenFacadeFactory _resolveHomeScreenFacadeFactory() {
  final locator = GetIt.instance;
  if (locator.isRegistered<IHomeScreenFacadeFactory>()) {
    return locator<IHomeScreenFacadeFactory>();
  }
  throw StateError(
    'IHomeScreenFacadeFactory is not registered. '
    'Register it in service locator before using HomeScreen providers.',
  );
}
