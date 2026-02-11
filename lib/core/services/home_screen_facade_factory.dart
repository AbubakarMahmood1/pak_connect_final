import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade_factory.dart';
import 'home_screen_facade.dart';

class HomeScreenFacadeFactory implements IHomeScreenFacadeFactory {
  const HomeScreenFacadeFactory();

  @override
  IHomeScreenFacade create({
    IChatsRepository? chatsRepository,
    IConnectionService? bleService,
    ChatManagementService? chatManagementService,
    BuildContext? context,
    WidgetRef? ref,
    HomeScreenInteractionHandlerBuilder? interactionHandlerBuilder,
    bool enableListCoordinatorInitialization = true,
    bool enableInternalIntentListener = true,
  }) {
    return HomeScreenFacade(
      chatsRepository: chatsRepository,
      bleService: bleService,
      chatManagementService: chatManagementService,
      context: context,
      ref: ref,
      interactionHandlerBuilder: interactionHandlerBuilder,
      enableListCoordinatorInitialization: enableListCoordinatorInitialization,
      enableInternalIntentListener: enableInternalIntentListener,
    );
  }
}
