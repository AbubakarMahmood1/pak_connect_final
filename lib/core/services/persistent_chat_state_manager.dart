import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

/// Manages persistent chat state across navigation cycles
/// Prevents message loss during ChatScreen dispose/recreate cycles
class PersistentChatStateManager {
  final _logger = Logger('PersistentChatStateManager');
  static final PersistentChatStateManager _instance =
      PersistentChatStateManager._internal();
  factory PersistentChatStateManager() => _instance;
  PersistentChatStateManager._internal();

  // Message listeners that persist across screen lifecycles
  final Map<String, StreamSubscription<String>> _persistentMessageListeners =
      {};

  // Message buffers for each chat during navigation transitions
  final Map<String, Queue<String>> _messageBuffers = {};

  // Active chat screens to notify of new messages
  final Map<String, Function(String)> _activeMessageHandlers = {};

  // Navigation state tracking
  final Set<String> _activeChatIds = {};

  /// Register a chat screen as active
  void registerChatScreen(String chatId, Function(String) messageHandler) {
    _logger.fine('🔄 PERSISTENT: Registering chat screen for $chatId');
    _activeChatIds.add(chatId);
    _activeMessageHandlers[chatId] = messageHandler;

    // Process any buffered messages
    _processBufferedMessages(chatId);
  }

  /// Unregister a chat screen (temporarily inactive during navigation)
  void unregisterChatScreen(String chatId) {
    _logger.fine('🔄 PERSISTENT: Unregistering chat screen for $chatId');
    _activeChatIds.remove(chatId);
    _activeMessageHandlers.remove(chatId);

    // Don't remove the persistent listener - keep it for buffering
  }

  /// Setup persistent message listener for a chat
  void setupPersistentListener(String chatId, Stream<String> messageStream) {
    if (_persistentMessageListeners.containsKey(chatId)) {
      _logger.fine('🔄 PERSISTENT: Listener already exists for $chatId');
      return;
    }

    _logger.fine('🔄 PERSISTENT: Setting up persistent listener for $chatId');
    _messageBuffers[chatId] ??= Queue<String>();

    _persistentMessageListeners[chatId] = messageStream.listen(
      (content) async {
        _logger.fine('🟡🟡🟡 PERSISTENT MANAGER RECEIVED MESSAGE 🟡🟡🟡');
        _logger.fine('🟡 Chat ID: $chatId');
        _logger.fine('🟡 Content length: ${content.length}');
        _logger.fine('🟡 Is chat active: ${_activeChatIds.contains(chatId)}');
        _logger.fine(
          '🟡 Has handler: ${_activeMessageHandlers.containsKey(chatId)}',
        );

        if (_activeChatIds.contains(chatId) &&
            _activeMessageHandlers.containsKey(chatId)) {
          // Chat screen is active - deliver directly
          _logger.fine('➡️ DELIVERING TO ACTIVE CHAT SCREEN');
          _activeMessageHandlers[chatId]!(content);
        } else {
          // Chat screen not active - buffer the message
          _logger.fine('🟡 BUFFERING MESSAGE (chat not active)');
          _messageBuffers[chatId]!.add(content);

          // 🔧 FIX: Don't persist here - it will be persisted when chat screen processes the buffer
          // This prevents duplicate messages (was saving once here, once in _addReceivedMessage)
        }
      },
      onError: (error) {
        _logger.warning(
          '🔄 PERSISTENT: Error in message listener for $chatId: $error',
        );
      },
    );
  }

  /// Process buffered messages when chat screen becomes active
  void _processBufferedMessages(String chatId) {
    final buffer = _messageBuffers[chatId];
    if (buffer == null || buffer.isEmpty) return;

    _logger.fine(
      '🔄 PERSISTENT: Processing ${buffer.length} buffered messages for $chatId',
    );

    final handler = _activeMessageHandlers[chatId];
    if (handler != null) {
      while (buffer.isNotEmpty) {
        final content = buffer.removeFirst();
        handler(content);
      }
    }
  }

  // 🔧 REMOVED: _persistMessageToRepository()
  // This method was causing duplicate messages by saving once during buffering
  // and again when ChatScreen processed the buffer through _addReceivedMessage.
  // Messages are now only persisted through _addReceivedMessage for consistency.

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
    _logger.fine('🔄 PERSISTENT: Cleaning up listener for $chatId');
    _persistentMessageListeners[chatId]?.cancel();
    _persistentMessageListeners.remove(chatId);
    _messageBuffers.remove(chatId);
    _activeMessageHandlers.remove(chatId);
    _activeChatIds.remove(chatId);
  }

  /// Cleanup all listeners (app shutdown)
  void cleanupAll() {
    _logger.fine('🔄 PERSISTENT: Cleaning up all persistent listeners');
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
      'bufferedMessages': _messageBuffers.map(
        (key, value) => MapEntry(key, value.length),
      ),
      'activeHandlers': _activeMessageHandlers.keys.toList(),
    };
  }
}

/// Provider for persistent chat state manager
final persistentChatStateManagerProvider = Provider<PersistentChatStateManager>(
  (ref) {
    return PersistentChatStateManager();
  },
);
