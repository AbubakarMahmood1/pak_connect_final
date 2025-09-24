// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/message.dart';
import '../../data/repositories/message_repository.dart';

/// Manages persistent chat state across navigation cycles
/// Prevents message loss during ChatScreen dispose/recreate cycles
class PersistentChatStateManager {
  static final PersistentChatStateManager _instance = PersistentChatStateManager._internal();
  factory PersistentChatStateManager() => _instance;
  PersistentChatStateManager._internal();

  // Message listeners that persist across screen lifecycles
  final Map<String, StreamSubscription<String>> _persistentMessageListeners = {};
  
  // Message buffers for each chat during navigation transitions
  final Map<String, Queue<String>> _messageBuffers = {};
  
  // Active chat screens to notify of new messages
  final Map<String, Function(String)> _activeMessageHandlers = {};
  
  // Navigation state tracking
  final Set<String> _activeChatIds = {};
  
  final MessageRepository _messageRepository = MessageRepository();

  /// Register a chat screen as active
  void registerChatScreen(String chatId, Function(String) messageHandler) {
    print('🔄 PERSISTENT: Registering chat screen for $chatId');
    _activeChatIds.add(chatId);
    _activeMessageHandlers[chatId] = messageHandler;
    
    // Process any buffered messages
    _processBufferedMessages(chatId);
  }

  /// Unregister a chat screen (temporarily inactive during navigation)
  void unregisterChatScreen(String chatId) {
    print('🔄 PERSISTENT: Unregistering chat screen for $chatId');
    _activeChatIds.remove(chatId);
    _activeMessageHandlers.remove(chatId);
    
    // Don't remove the persistent listener - keep it for buffering
  }

  /// Setup persistent message listener for a chat
  void setupPersistentListener(String chatId, Stream<String> messageStream) {
    if (_persistentMessageListeners.containsKey(chatId)) {
      print('🔄 PERSISTENT: Listener already exists for $chatId');
      return;
    }

    print('🔄 PERSISTENT: Setting up persistent listener for $chatId');
    _messageBuffers[chatId] ??= Queue<String>();

    _persistentMessageListeners[chatId] = messageStream.listen(
      (content) async {
        print('🔄 PERSISTENT: Received message for $chatId (${content.length} chars)');
        
        if (_activeChatIds.contains(chatId) && _activeMessageHandlers.containsKey(chatId)) {
          // Chat screen is active - deliver directly
          print('🔄 PERSISTENT: Delivering to active chat screen');
          _activeMessageHandlers[chatId]!(content);
        } else {
          // Chat screen not active - buffer the message
          print('🔄 PERSISTENT: Buffering message during navigation');
          _messageBuffers[chatId]!.add(content);
          
          // Also persist to repository immediately
          await _persistMessageToRepository(chatId, content);
        }
      },
      onError: (error) {
        print('🔄 PERSISTENT: Error in message listener for $chatId: $error');
      },
    );
  }

  /// Process buffered messages when chat screen becomes active
  void _processBufferedMessages(String chatId) {
    final buffer = _messageBuffers[chatId];
    if (buffer == null || buffer.isEmpty) return;

    print('🔄 PERSISTENT: Processing ${buffer.length} buffered messages for $chatId');
    
    final handler = _activeMessageHandlers[chatId];
    if (handler != null) {
      while (buffer.isNotEmpty) {
        final content = buffer.removeFirst();
        handler(content);
      }
    }
  }

  /// Persist message directly to repository during navigation
  Future<void> _persistMessageToRepository(String chatId, String content) async {
    try {
      final message = Message(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        chatId: chatId,
        content: content,
        timestamp: DateTime.now(),
        isFromMe: false,
        status: MessageStatus.delivered,
      );
      
      await _messageRepository.saveMessage(message);
      print('🔄 PERSISTENT: Message persisted to repository for $chatId');
    } catch (e) {
      print('🔄 PERSISTENT: Failed to persist message: $e');
    }
  }

  /// Get number of buffered messages for a chat
  int getBufferedMessageCount(String chatId) {
    return _messageBuffers[chatId]?.length ?? 0;
  }

  /// Check if chat has active listener
  bool hasActiveListener(String chatId) {
    return _persistentMessageListeners.containsKey(chatId);
  }

  /// Cleanup persistent listener when chat is permanently closed
  void cleanupChatListener(String chatId) {
    print('🔄 PERSISTENT: Cleaning up listener for $chatId');
    _persistentMessageListeners[chatId]?.cancel();
    _persistentMessageListeners.remove(chatId);
    _messageBuffers.remove(chatId);
    _activeMessageHandlers.remove(chatId);
    _activeChatIds.remove(chatId);
  }

  /// Cleanup all listeners (app shutdown)
  void cleanupAll() {
    print('🔄 PERSISTENT: Cleaning up all persistent listeners');
    for (final subscription in _persistentMessageListeners.values) {
      subscription.cancel();
    }
    _persistentMessageListeners.clear();
    _messageBuffers.clear();
    _activeMessageHandlers.clear();
    _activeChatIds.clear();
  }

  /// Get debug info
  Map<String, dynamic> getDebugInfo() {
    return {
      'activeListeners': _persistentMessageListeners.keys.toList(),
      'activeChatIds': _activeChatIds.toList(),
      'bufferedMessages': _messageBuffers.map((key, value) => MapEntry(key, value.length)),
      'activeHandlers': _activeMessageHandlers.keys.toList(),
    };
  }
}

/// Provider for persistent chat state manager
final persistentChatStateManagerProvider = Provider<PersistentChatStateManager>((ref) {
  return PersistentChatStateManager();
});