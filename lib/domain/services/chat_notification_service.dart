import 'dart:async';
import 'package:logging/logging.dart';
import 'chat_management_models.dart';

/// Handles chat/message event streams for chat management
class ChatNotificationService {
  final _logger = Logger('ChatNotificationService');

  final _chatUpdatesController = StreamController<ChatUpdateEvent>.broadcast();
  final _messageUpdatesController =
      StreamController<MessageUpdateEvent>.broadcast();

  Stream<ChatUpdateEvent> get chatUpdates => _chatUpdatesController.stream;
  Stream<MessageUpdateEvent> get messageUpdates =>
      _messageUpdatesController.stream;

  void emitChatUpdate(ChatUpdateEvent event) {
    _chatUpdatesController.add(event);
  }

  void emitMessageUpdate(MessageUpdateEvent event) {
    _messageUpdatesController.add(event);
  }

  Future<void> dispose() async {
    await _chatUpdatesController.close();
    await _messageUpdatesController.close();
    _logger.info('ChatNotificationService disposed');
  }
}
