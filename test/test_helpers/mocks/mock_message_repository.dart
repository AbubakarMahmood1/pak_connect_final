import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';

class MockMessageRepository extends MessageRepository {
  final Map<String, Message> _messages = {};

  @override
  Future<void> saveMessage(Message message) async {
    _messages[message.id] = message;
  }

  @override
  Future<List<Message>> getMessages(String chatId) async {
    return _messages.values.where((m) => m.chatId == chatId).toList();
  }
}
