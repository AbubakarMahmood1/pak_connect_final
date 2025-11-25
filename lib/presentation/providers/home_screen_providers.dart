import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/interfaces/i_chats_repository.dart';
import '../../core/services/home_screen_facade.dart';
import '../../domain/services/chat_management_service.dart';
import '../viewmodels/home_screen_view_model.dart';

class HomeScreenProviderArgs {
  const HomeScreenProviderArgs({
    required this.chatsRepository,
    required this.chatManagementService,
    required this.homeScreenFacade,
    this.logger,
  });

  final IChatsRepository chatsRepository;
  final ChatManagementService chatManagementService;
  final HomeScreenFacade homeScreenFacade;
  final Logger? logger;
}
