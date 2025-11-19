// Interface for pinning/starring service operations
// Extracted from ChatManagementService for better separation of concerns

import '../../domain/services/chat_management_service.dart';
import '../../domain/entities/enhanced_message.dart';

/// Interface for message starring and pinning operations
abstract class IPinningService {
  /// Star/unstar message
  Future<ChatOperationResult> toggleMessageStar(String messageId);

  /// Get all starred messages
  Future<List<EnhancedMessage>> getStarredMessages();

  /// Check if message is starred
  bool isMessageStarred(String messageId);

  /// Get pinned chats count
  int get pinnedChatsCount;

  /// Get starred messages count
  int get starredMessagesCount;

  /// Stream of message update events
  Stream<MessageUpdateEvent> get messageUpdates;

  /// Initialize the service
  Future<void> initialize();

  /// Dispose of resources
  Future<void> dispose();
}
