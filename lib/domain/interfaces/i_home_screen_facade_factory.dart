import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chat_management_service.dart';
import 'i_chat_interaction_handler.dart';
import 'i_chats_repository.dart';
import 'i_connection_service.dart';
import 'i_home_screen_facade.dart';

typedef HomeScreenInteractionHandlerBuilder =
    IChatInteractionHandler Function({
      BuildContext? context,
      WidgetRef? ref,
      IChatsRepository? chatsRepository,
      ChatManagementService? chatManagementService,
    });

/// Factory contract for creating [IHomeScreenFacade] instances.
abstract interface class IHomeScreenFacadeFactory {
  IHomeScreenFacade create({
    IChatsRepository? chatsRepository,
    IConnectionService? bleService,
    ChatManagementService? chatManagementService,
    BuildContext? context,
    WidgetRef? ref,
    HomeScreenInteractionHandlerBuilder? interactionHandlerBuilder,
    bool enableListCoordinatorInitialization = true,
    bool enableInternalIntentListener = true,
  });
}
