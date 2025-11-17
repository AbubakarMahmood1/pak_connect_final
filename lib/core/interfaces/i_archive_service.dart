import '../models/archive_models.dart';
import '../../domain/services/chat_management_service.dart'
    show ChatOperationResult, BatchArchiveResult;

/// Archive service interface for managing chat archives
/// Handles archiving/unarchiving, analytics, and batch operations
abstract interface class IArchiveService {
  /// Archive a chat with optional reason and enhanced archive system
  Future<ChatOperationResult> archiveChat(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  });

  /// Unarchive a previously archived chat
  Future<ChatOperationResult> unarchiveChat(
    String chatId, {
    bool useEnhancedArchive = true,
  });

  /// Check if a chat is archived
  bool isArchived(String chatId);

  /// Get count of archived chats
  int get archivedChatsCount;

  /// Archive multiple chats in batch
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  });

  /// Save archived chats to persistent storage
  Future<void> saveArchivedChats();

  /// Load archived chats from persistent storage
  Future<void> loadArchivedChats();
}
