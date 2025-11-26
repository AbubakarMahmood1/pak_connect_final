import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/interfaces/i_chats_repository.dart';
import '../../core/services/home_screen_facade.dart';
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
  final HomeScreenFacade? homeScreenFacade;
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

final homeScreenFacadeProvider = Provider.autoDispose
    .family<HomeScreenFacade, HomeScreenProviderArgs>((ref, args) {
      if (args.homeScreenFacade != null) return args.homeScreenFacade!;

      final interactionHandler = ref.watch(
        chatInteractionHandlerProvider(
          ChatInteractionHandlerArgs(
            context: args.context,
            ref: args.ref,
            chatsRepository: args.chatsRepository,
            chatManagementService: args.chatManagementService,
          ),
        ),
      );

      final facade = HomeScreenFacade(
        chatsRepository: args.chatsRepository,
        bleService: ref.read(connectionServiceProvider),
        chatManagementService: args.chatManagementService,
        context: args.context,
        ref: args.ref,
        interactionHandlerBuilder:
            ({context, ref, chatsRepository, chatManagementService}) =>
                interactionHandler,
      );
      ref.onDispose(() {
        unawaited(facade.dispose());
      });
      return facade;
    });
