import 'dart:async';
import 'package:logging/logging.dart';
import 'chat_management_models.dart';

/// Handles chat/message event streams for chat management
class ChatNotificationService {
  final _logger = Logger('ChatNotificationService');

  final Set<void Function(ChatUpdateEvent)> _chatListeners = {};
  final Set<void Function(MessageUpdateEvent)> _messageListeners = {};

  Stream<ChatUpdateEvent> get chatUpdates =>
      Stream<ChatUpdateEvent>.multi((controller) {
        void listener(ChatUpdateEvent event) {
          controller.add(event);
        }

        _chatListeners.add(listener);
        controller.onCancel = () {
          _chatListeners.remove(listener);
        };
      });
  Stream<MessageUpdateEvent> get messageUpdates =>
      Stream<MessageUpdateEvent>.multi((controller) {
        void listener(MessageUpdateEvent event) {
          controller.add(event);
        }

        _messageListeners.add(listener);
        controller.onCancel = () {
          _messageListeners.remove(listener);
        };
      });

  void emitChatUpdate(ChatUpdateEvent event) {
    for (final listener in List.of(_chatListeners)) {
      try {
        listener(event);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying chat update listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  void emitMessageUpdate(MessageUpdateEvent event) {
    for (final listener in List.of(_messageListeners)) {
      try {
        listener(event);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying message update listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  Future<void> dispose() async {
    _chatListeners.clear();
    _messageListeners.clear();
    _logger.info('ChatNotificationService disposed');
  }
}
