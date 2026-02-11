import 'i_chat_connection_manager.dart';
import 'i_connection_service.dart';

/// Factory contract for creating [IChatConnectionManager] instances.
abstract interface class IChatConnectionManagerFactory {
  IChatConnectionManager create({IConnectionService? bleService});
}
