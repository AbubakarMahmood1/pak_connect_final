import '../../domain/interfaces/i_chat_connection_manager.dart';
import '../../domain/interfaces/i_chat_connection_manager_factory.dart';
import '../../domain/interfaces/i_connection_service.dart';
import 'chat_connection_manager.dart';

class ChatConnectionManagerFactory implements IChatConnectionManagerFactory {
  const ChatConnectionManagerFactory();

  @override
  IChatConnectionManager create({IConnectionService? bleService}) {
    return ChatConnectionManager(bleService: bleService);
  }
}
