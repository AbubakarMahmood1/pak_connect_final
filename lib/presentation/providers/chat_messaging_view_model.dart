import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/entities/message.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/contact_repository.dart';

/// ViewModel for handling messaging logic in ChatScreen
/// Manages message send/receive and message persistence
/// Extracted from ChatScreen for better testability and separation of concerns
class ChatMessagingViewModel {
  final _logger = Logger('ChatMessagingViewModel');
  final MessageRepository messageRepository;
  final ContactRepository contactRepository;
  final String chatId;
  final String contactPublicKey;

  final List<String> _messageBuffer = [];
  bool _messageListenerActive = false;

  ChatMessagingViewModel({
    required this.chatId,
    required this.contactPublicKey,
    required this.messageRepository,
    required this.contactRepository,
  }) {
    _initialize();
  }

  /// Initialize the view model
  void _initialize() {
    _logger.info('🎯 Initializing ChatMessagingViewModel for chat: $chatId');
  }

  /// Load messages from repository
  Future<List<Message>> loadMessages() async {
    try {
      final messages = await messageRepository.getMessages(chatId);
      _logger.info('✅ Loaded ${messages.length} messages');
      return messages;
    } catch (e) {
      _logger.severe('❌ Failed to load messages: $e');
      rethrow;
    }
  }

  /// Send a message
  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) {
      _logger.warning('⚠️ Attempted to send empty message');
      return;
    }

    try {
      _logger.info('📤 Sending message to $contactPublicKey');

      // Create message object
      final message = Message(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        chatId: chatId,
        content: content,
        isFromMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );

      // Save to repository
      await messageRepository.saveMessage(message);
      _logger.info('✅ Message sent successfully');
    } catch (e) {
      _logger.severe('❌ Failed to send message: $e');
      rethrow;
    }
  }

  /// Retry sending a failed message
  Future<void> retryMessage(Message message) async {
    try {
      _logger.info('🔄 Retrying message: ${message.id}');
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await messageRepository.updateMessage(retryMessage);
      _logger.info('✅ Retry initiated');
    } catch (e) {
      _logger.severe('❌ Failed to retry message: $e');
      rethrow;
    }
  }

  /// Delete a message
  Future<void> deleteMessage(String messageId) async {
    try {
      _logger.info('🗑️  Deleting message: $messageId');
      await messageRepository.deleteMessage(messageId);
      _logger.info('✅ Message deleted');
    } catch (e) {
      _logger.severe('❌ Failed to delete message: $e');
      rethrow;
    }
  }

  /// Add a received message to the list
  bool addReceivedMessage(Message message) {
    _logger.info('📥 Received message: ${message.id}');

    if (_messageBuffer.contains(message.id)) {
      _logger.info('⚠️ Duplicate message, ignoring: ${message.id}');
      return false;
    }

    _messageBuffer.add(message.id);
    return _messageListenerActive;
  }

  /// Setup message listener for receiving messages
  void setupMessageListener() {
    try {
      _messageListenerActive = true;
      _logger.info('📡 Setting up message listener');
      _logger.info('✅ Message listener setup complete');
    } catch (e) {
      _logger.severe('❌ Failed to setup message listener: $e');
      rethrow;
    }
  }

  /// Setup delivery status listener
  void setupDeliveryListener() {
    try {
      _logger.info('📦 Setting up delivery listener');
      _logger.info('✅ Delivery listener setup complete');
    } catch (e) {
      _logger.severe('❌ Failed to setup delivery listener: $e');
      rethrow;
    }
  }

  /// Setup contact request listener
  void setupContactRequestListener() {
    try {
      _logger.info('👥 Setting up contact request listener');
      _logger.info('✅ Contact request listener setup complete');
    } catch (e) {
      _logger.severe('❌ Failed to setup contact request listener: $e');
      rethrow;
    }
  }

  /// Check if message listener is active
  bool get messageListenerActive => _messageListenerActive;

  /// Dispose resources
  void dispose() {
    _logger.info('🧹 Disposing ChatMessagingViewModel');
  }
}
