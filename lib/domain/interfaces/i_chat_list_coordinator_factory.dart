import '../models/connection_status.dart';
import 'i_chat_list_coordinator.dart';
import 'i_chats_repository.dart';
import 'i_connection_service.dart';

/// Factory contract for creating [IChatListCoordinator] instances.
abstract interface class IChatListCoordinatorFactory {
  IChatListCoordinator create({
    IChatsRepository? chatsRepository,
    IConnectionService? bleService,
    Stream<ConnectionStatus>? connectionStatusStream,
  });
}
