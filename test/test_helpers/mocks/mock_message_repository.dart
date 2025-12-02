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
  Future<List<Message>> getMessages(ChatId chatId) async {
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

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {
    final keysToMigrate = _messages.entries
        .where((e) => e.value.chatId == oldChatId)
        .map((e) => e.key)
        .toList();

    for (final key in keysToMigrate) {
      final msg = _messages[key]!;
      _messages[key] = msg.copyWith(chatId: newChatId);
    }
  }
}
