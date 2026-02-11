import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Interface for message starring and pinning operations.
abstract class IPinningService {
  /// Star/unstar message.
  Future<ChatOperationResult> toggleMessageStar(MessageId messageId);

  /// Get all starred messages.
  Future<List<EnhancedMessage>> getStarredMessages();

  /// Check if message is starred.
  bool isMessageStarred(MessageId messageId);

  /// Get pinned chats count.
  int get pinnedChatsCount;

  /// Get starred messages count.
  int get starredMessagesCount;

  /// Stream of message update events.
  Stream<MessageUpdateEvent> get messageUpdates;

  /// Initialize the service.
  Future<void> initialize();

  /// Dispose of resources.
  Future<void> dispose();
}
