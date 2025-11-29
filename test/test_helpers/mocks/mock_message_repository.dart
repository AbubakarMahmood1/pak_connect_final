import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class MockMessageRepository extends MessageRepository {
  final Map<String, Message> _messages = {};

  @override
  Future<void> saveMessage(Message message) async {
    _messages[message.id.value] = message;
  }

  @override
  Future<List<Message>> getMessages(String chatId) async {
    return _messages.values.where((m) => m.chatId == chatId).toList();
  }

  @override
  Future<Message?> getMessageById(MessageId messageId) async {
    return _messages[messageId.value];
  }

  @override
  Future<bool> deleteMessage(MessageId messageId) async {
    if (_messages.containsKey(messageId.value)) {
      _messages.remove(messageId.value);
      return true;
    }
    return false;
  }
}
