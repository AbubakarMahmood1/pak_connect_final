import '../../domain/interfaces/i_chat_list_coordinator.dart';
import '../../domain/interfaces/i_chat_list_coordinator_factory.dart';
import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/models/connection_status.dart';
import 'chat_list_coordinator.dart';

class ChatListCoordinatorFactory implements IChatListCoordinatorFactory {
  const ChatListCoordinatorFactory();

  @override
  IChatListCoordinator create({
    IChatsRepository? chatsRepository,
    IConnectionService? bleService,
    Stream<ConnectionStatus>? connectionStatusStream,
  }) {
    return ChatListCoordinator(
      chatsRepository: chatsRepository,
      bleService: bleService,
      connectionStatusStream: connectionStatusStream,
    );
  }
}
