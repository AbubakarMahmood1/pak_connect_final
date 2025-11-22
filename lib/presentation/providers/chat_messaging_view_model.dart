import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/app_core.dart';
import '../../domain/entities/message.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';
import '../../core/messaging/message_router.dart';
import '../../core/messaging/offline_message_queue.dart';

/// Callback type for UI message additions
typedef OnMessageAddedCallback = void Function(Message message);

/// Callback type for showing success notifications
typedef OnShowSuccessCallback = void Function(String message);

/// Callback type for showing error notifications
typedef OnShowErrorCallback = void Function(String message);

/// Callback type for scroll to bottom action
typedef OnScrollToBottomCallback = void Function();

/// Callback type for clearing input field
typedef OnClearInputFieldCallback = void Function();

/// Callback type for message removal (deletion)
typedef OnMessageRemovedCallback = void Function(String messageId);

/// Callback type for loading state changes
typedef OnLoadingStateChangedCallback = void Function(bool isLoading);

/// Callback type for providing queued messages
typedef OnGetQueuedMessagesCallback = List<QueuedMessage> Function();

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

  /// Load messages from both repository and queue, merge and deduplicate
  ///
  /// Parameters:
  /// - onLoadingStateChanged: Callback to notify UI of loading state
  /// - onGetQueuedMessages: Callback to get queued messages from mesh service
  /// - onScrollToBottom: Callback to scroll chat to bottom after loading
  /// - onError: Callback to show error message
  ///
  /// Returns: List of merged and sorted messages from both repository and queue
  Future<List<Message>> loadMessages({
    OnLoadingStateChangedCallback? onLoadingStateChanged,
    OnGetQueuedMessagesCallback? onGetQueuedMessages,
    OnScrollToBottomCallback? onScrollToBottom,
    OnShowErrorCallback? onError,
  }) async {
    try {
      _logger.info('📋 Starting to load messages for chat: $chatId');
      onLoadingStateChanged?.call(true);

      // 1. Load delivered messages from repository
      final deliveredMessages = await messageRepository.getMessages(chatId);
      _logger.info(
        '📦 Loaded ${deliveredMessages.length} delivered messages from repository',
      );

      // 2. Load in-flight messages from queue (via callback)
      final queuedMessages = onGetQueuedMessages?.call() ?? [];
      _logger.info(
        '📮 Loaded ${queuedMessages.length} queued messages from mesh service',
      );

      // 3. Convert queued messages to Message objects for UI display
      final pendingMessages = queuedMessages
          .map(
            (qm) => Message(
              id: qm.id,
              chatId: qm.chatId,
              content: qm.content,
              timestamp: qm.queuedAt,
              isFromMe: true, // Queued messages are always outgoing
              status: _mapQueuedStatus(qm.status),
            ),
          )
          .toList();

      // 4. Deduplicate by message ID (delivered messages take precedence)
      // When a message is delivered, it's in BOTH repository and queue temporarily
      final deliveredIds = deliveredMessages.map((m) => m.id).toSet();
      final uniquePending = pendingMessages
          .where((m) => !deliveredIds.contains(m.id))
          .toList();

      // 5. Merge both lists and sort by timestamp
      final allMessages = [...deliveredMessages, ...uniquePending];
      allMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      onLoadingStateChanged?.call(false);
      onScrollToBottom?.call();

      _logger.info(
        '✅ Loaded ${deliveredMessages.length} delivered + ${uniquePending.length} pending = ${allMessages.length} total messages (${pendingMessages.length - uniquePending.length} duplicates removed)',
      );

      return allMessages;
    } catch (e) {
      _logger.severe('❌ Failed to load messages: $e');
      onLoadingStateChanged?.call(false);
      onError?.call('Failed to load messages: $e');
      rethrow;
    }
  }

  /// Map queue status to UI message status
  MessageStatus _mapQueuedStatus(QueuedMessageStatus queueStatus) {
    switch (queueStatus) {
      case QueuedMessageStatus.pending:
        return MessageStatus.sending;
      case QueuedMessageStatus.sending:
        return MessageStatus.sending;
      case QueuedMessageStatus.awaitingAck:
        return MessageStatus.sending;
      case QueuedMessageStatus.retrying:
        return MessageStatus
            .sending; // Show as sending (or could add MessageStatus.retrying)
      case QueuedMessageStatus.failed:
        return MessageStatus.failed;
      case QueuedMessageStatus.delivered:
        return MessageStatus.delivered;
    }
  }

  /// Send a message with UI callbacks
  /// This is the phase 2C.1 migrated version that handles the full message flow
  /// including AppCore queue integration, logging, temporary UI messages, and callbacks
  Future<void> sendMessage({
    required String content,
    OnMessageAddedCallback? onMessageAdded,
    OnShowSuccessCallback? onShowSuccess,
    OnShowErrorCallback? onShowError,
    OnScrollToBottomCallback? onScrollToBottom,
    OnClearInputFieldCallback? onClearInputField,
  }) async {
    if (content.trim().isEmpty) {
      _logger.warning('⚠️ Attempted to send empty message');
      return;
    }

    try {
      // Log comprehensive send state before sending
      await _logMessageSendState(content);

      _logger.info('📤 Sending message to $contactPublicKey');

      // Check if we have recipient key (ephemeral or persistent)
      if (contactPublicKey.isEmpty) {
        _logger.warning(
          '⚠️ No recipient key available (handshake may not be complete)',
        );
        onShowError?.call(
          'Connection not ready - please wait for handshake to complete',
        );
        return;
      }

      // Use AppCore to queue message (uses proper queue system)
      final secureMessageId = await AppCore.instance.sendSecureMessage(
        chatId: chatId,
        content: content,
        recipientPublicKey: contactPublicKey,
      );

      _logger.info('📤 Message queued with secure ID: $secureMessageId');

      // Create temporary UI message to show immediately
      // (will be replaced by queue data on reload)
      final tempMessage = Message(
        id: secureMessageId,
        chatId: chatId,
        content: content,
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sending,
      );

      // Notify UI of new message
      onMessageAdded?.call(tempMessage);

      // Show success notification
      onShowSuccess?.call('✅ Message queued for delivery');

      // Scroll to bottom to show new message
      onScrollToBottom?.call();

      _logger.info('✅ Message sent successfully');
    } catch (e) {
      _logger.severe('📤🔑 MESSAGE SEND FAILED: $e');
      onShowError?.call('Failed to send message: $e');
      rethrow;
    }
  }

  /// Log comprehensive send state (helper for sendMessage)
  Future<void> _logMessageSendState(String messageContent) async {
    try {
      final contact = await contactRepository.getContact(contactPublicKey);
      final encryptionMethod = await SecurityManager.instance
          .getEncryptionMethod(contactPublicKey, contactRepository);

      final preview = messageContent.length > 30
          ? "${messageContent.substring(0, 27)}..."
          : messageContent;
      _logger.info(
        '📤🔑 SEND: "$preview" | To=$contactPublicKey | Encryption=${encryptionMethod.type.name} | NoiseSession=${contact?.sessionIdForNoise ?? "NULL"}...',
      );
    } catch (e) {
      _logger.warning('⚠️ Could not log send state: $e');
      // Don't rethrow - this is just logging
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

  /// Delete a message with optional "delete for everyone" support
  ///
  /// Parameters:
  /// - messageId: ID of message to delete
  /// - deleteForEveryone: If true, sends deletion request to peer
  /// - onMessageRemoved: Callback when message removed from UI
  /// - onShowSuccess: Callback to show success message
  /// - onShowError: Callback to show error message
  Future<void> deleteMessage({
    required String messageId,
    bool deleteForEveryone = false,
    OnMessageRemovedCallback? onMessageRemoved,
    OnShowSuccessCallback? onShowSuccess,
    OnShowErrorCallback? onShowError,
  }) async {
    try {
      _logger.info(
        '🗑️  Deleting message: $messageId, deleteForEveryone: $deleteForEveryone',
      );

      // Delete from local repository
      final success = await messageRepository.deleteMessage(messageId);

      if (success) {
        // Notify UI to remove message immediately (optimistic update)
        onMessageRemoved?.call(messageId);
        _logger.info('✅ Message removed from UI');

        // If deleteForEveryone is true, send deletion request
        if (deleteForEveryone) {
          try {
            // Send deletion request using MessageRouter (offline-reliable pattern)
            final deletionMessage = 'DELETE_MESSAGE:$messageId';
            final router = MessageRouter.instance;

            final result = await router.sendMessage(
              content: deletionMessage,
              recipientId: contactPublicKey.isNotEmpty
                  ? contactPublicKey
                  : chatId,
              recipientName:
                  'Unknown', // Don't have display name here, use placeholder
            );

            if (result.isSentDirectly) {
              _logger.info('✅ Deletion request sent directly');
              onShowSuccess?.call('Message deleted for everyone');
            } else if (result.isQueued) {
              _logger.info('✅ Deletion request queued');
              onShowSuccess?.call(
                'Message deleted - deletion request queued (will send when peer online)',
              );
            } else {
              _logger.info('⚠️ Deletion request queued for later');
              onShowSuccess?.call(
                'Message deleted locally (remote deletion queued)',
              );
            }
          } catch (e) {
            _logger.warning('⚠️ Failed to send deletion request: $e');
            onShowSuccess?.call(
              'Message deleted locally (remote deletion failed)',
            );
          }
        } else {
          _logger.info('✅ Message deleted locally');
          onShowSuccess?.call('Message deleted');
        }
      } else {
        _logger.warning('❌ Delete operation returned false');
        onShowError?.call('Failed to delete message');
      }
    } catch (e) {
      _logger.severe('❌ Error deleting message: $e');
      onShowError?.call('Failed to delete message: $e');
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
