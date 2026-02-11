import '../entities/message.dart';
import '../values/id_types.dart';

/// Interface for message repository operations
///
/// Abstracts message storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations (e.g., in-memory for tests)
///
/// **Phase 1 Note**: Interface defines all public methods from MessageRepository
abstract class IMessageRepository {
  /// Get all messages for a specific chat, sorted by timestamp
  Future<List<Message>> getMessages(ChatId chatId);

  /// Get a single message by ID (for duplicate checking)
  Future<Message?> getMessageById(MessageId messageId);

  /// Save a new message (with duplicate prevention)
  Future<void> saveMessage(Message message);

  /// Update an existing message
  Future<void> updateMessage(Message message);

  /// Clear all messages for a specific chat
  Future<void> clearMessages(ChatId chatId);

  /// Delete a specific message by ID
  Future<bool> deleteMessage(MessageId messageId);

  /// Get all messages for interaction calculations
  Future<List<Message>> getAllMessages();

  /// Get messages for a specific contact (by public key/chat ID)
  Future<List<Message>> getMessagesForContact(String publicKey);

  /// Migrate messages from one chat ID to another
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId);
}
