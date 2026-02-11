// Pinning service implementation
// Extracted from ChatManagementService (~250 LOC)

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../interfaces/i_chats_repository.dart';
import '../interfaces/i_message_repository.dart';
import 'chat_management_service.dart';
import '../entities/enhanced_message.dart';
import '../values/id_types.dart';

/// Service for managing message starring and chat pinning
class PinningService {
  static final _logger = Logger('PinningService');

  // Dependencies (optional for DI/testing)
  final IChatsRepository? _chatsRepositoryOverride;
  final IMessageRepository? _messageRepositoryOverride;

  // Lazy-initialized dependencies
  late final IChatsRepository _chatsRepository;
  late final IMessageRepository _messageRepository;

  // Storage keys
  static const String _starredMessagesKey = 'starred_messages';
  static const String _pinnedChatsKey = 'pinned_chats';

  // In-memory state
  final Set<MessageId> _starredMessageIds = {};
  final Set<String> _pinnedChats = {};

  // Event listeners (replaces manual controller)
  final Set<void Function(MessageUpdateEvent)> _messageUpdateListeners = {};

  /// Stream of message updates
  Stream<MessageUpdateEvent> get messageUpdates =>
      Stream<MessageUpdateEvent>.multi((controller) {
        void listener(MessageUpdateEvent event) {
          controller.add(event);
        }

        _messageUpdateListeners.add(listener);
        controller.onCancel = () {
          _messageUpdateListeners.remove(listener);
        };
      });

  /// Constructor with optional dependency injection
  PinningService({
    IChatsRepository? chatsRepository,
    IMessageRepository? messageRepository,
  }) : _chatsRepositoryOverride = chatsRepository,
       _messageRepositoryOverride = messageRepository {
    _logger.info('✅ PinningService created');
  }

  /// Initialize the service
  Future<void> initialize() async {
    // Initialize dependencies (use overrides if provided, else defaults)
    _chatsRepository =
        _chatsRepositoryOverride ?? GetIt.instance<IChatsRepository>();
    _messageRepository =
        _messageRepositoryOverride ?? GetIt.instance<IMessageRepository>();

    // Load cached data
    await _loadStarredMessages();
    await _loadPinnedChats();

    _logger.info('Pinning service initialized');
  }

  /// Star/unstar message
  Future<ChatOperationResult> toggleMessageStar(MessageId messageId) async {
    try {
      if (_starredMessageIds.contains(messageId)) {
        _starredMessageIds.remove(messageId);
        await _saveStarredMessages();
        _emitUpdate(MessageUpdateEvent.unstarred(messageId));
        return ChatOperationResult.success('Message unstarred');
      } else {
        _starredMessageIds.add(messageId);
        await _saveStarredMessages();
        _emitUpdate(MessageUpdateEvent.starred(messageId));
        return ChatOperationResult.success('Message starred');
      }
    } catch (e) {
      _logger.severe('❌ Failed to toggle star: $e');
      return ChatOperationResult.failure('Failed to update star status: $e');
    }
  }

  /// Get all starred messages
  Future<List<EnhancedMessage>> getStarredMessages() async {
    try {
      final allChats = await _chatsRepository.getAllChats();
      final List<EnhancedMessage> starredMessages = [];

      for (final chat in allChats) {
        final messages = await _messageRepository.getMessages(chat.chatId);
        for (final message in messages) {
          if (_starredMessageIds.contains(message.id)) {
            final enhanced = EnhancedMessage.fromMessage(
              message,
            ).copyWith(isStarred: true);
            starredMessages.add(enhanced);
          }
        }
      }

      // Sort by timestamp (newest first)
      starredMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return starredMessages;
    } catch (e) {
      _logger.severe('❌ Failed to get starred messages: $e');
      return [];
    }
  }

  /// Pin or unpin a chat (max 3 pinned chats)
  Future<ChatOperationResult> toggleChatPin(String chatId) async {
    try {
      if (_pinnedChats.contains(chatId)) {
        _pinnedChats.remove(chatId);
        await _savePinnedChats();
        return ChatOperationResult.success('Chat unpinned');
      }

      if (_pinnedChats.length >= 3) {
        return ChatOperationResult.failure('Maximum 3 chats can be pinned');
      }

      _pinnedChats.add(chatId);
      await _savePinnedChats();
      return ChatOperationResult.success('Chat pinned');
    } catch (e) {
      _logger.severe('❌ Failed to toggle chat pin: $e');
      return ChatOperationResult.failure('Failed to toggle pin: $e');
    }
  }

  /// Check if message is starred
  bool isMessageStarred(MessageId messageId) =>
      _starredMessageIds.contains(messageId);

  /// Check if chat is pinned
  bool isChatPinned(String chatId) => _pinnedChats.contains(chatId);

  /// Get pinned chats count
  int get pinnedChatsCount => _pinnedChats.length;

  /// Get starred messages count
  int get starredMessagesCount => _starredMessageIds.length;

  /// Internal: Add pinned chat (used by ArchiveService via facade)
  void addPinnedChat(String chatId) {
    _pinnedChats.add(chatId);
  }

  /// Internal: Remove pinned chat (used by ArchiveService via facade)
  void removePinnedChat(String chatId) {
    _pinnedChats.remove(chatId);
  }

  /// Internal: Check if chat is pinned (used by ArchiveService via facade)
  bool isPinnedChat(String chatId) => _pinnedChats.contains(chatId);

  /// Internal: Save pinned chats (used by ArchiveService via facade)
  Future<void> savePinnedChats() async {
    await _savePinnedChats();
  }

  /// Internal: Remove starred message IDs for deleted chat
  void removeStarredMessagesForChat(List<String> messageIds) {
    for (final messageId in messageIds) {
      _starredMessageIds.remove(MessageId(messageId));
    }
  }

  /// Internal: Save starred messages (used by ChatManagementService)
  Future<void> saveStarredMessages() async {
    await _saveStarredMessages();
  }

  // Private helper methods

  /// Save starred messages to storage
  Future<void> _saveStarredMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _starredMessagesKey,
        _starredMessageIds.map((id) => id.value).toList(),
      );
    } catch (e) {
      _logger.warning('⚠️ Failed to save starred messages: $e');
    }
  }

  /// Load starred messages from storage
  Future<void> _loadStarredMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final starredList = prefs.getStringList(_starredMessagesKey) ?? [];
      _starredMessageIds.clear();
      _starredMessageIds.addAll(starredList.map(MessageId.new));
    } catch (e) {
      _logger.warning('⚠️ Failed to load starred messages: $e');
    }
  }

  /// Save pinned chats to storage
  Future<void> _savePinnedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pinnedChatsKey, _pinnedChats.toList());
    } catch (e) {
      _logger.warning('⚠️ Failed to save pinned chats: $e');
    }
  }

  /// Load pinned chats from storage
  Future<void> _loadPinnedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pinnedList = prefs.getStringList(_pinnedChatsKey) ?? [];
      _pinnedChats.clear();
      _pinnedChats.addAll(pinnedList);
    } catch (e) {
      _logger.warning('⚠️ Failed to load pinned chats: $e');
    }
  }

  /// Dispose of resources
  Future<void> dispose() async {
    _messageUpdateListeners.clear();
    _logger.info('Pinning service disposed');
  }

  void _emitUpdate(MessageUpdateEvent event) {
    for (final listener in List.of(_messageUpdateListeners)) {
      try {
        listener(event);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying pinning listener: $e', e, stackTrace);
      }
    }
  }
}
