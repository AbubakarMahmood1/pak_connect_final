import 'dart:convert';
import '../../domain/entities/archived_message.dart';
import '../../domain/entities/archived_chat.dart';

/// Helper for archive data transformations, compression, and serialization
class ArchiveDataHelper {
  const ArchiveDataHelper();

  Map<String, dynamic> archivedMessageToMap(
    ArchivedMessage message,
    String archiveId,
  ) {
    return {
      'id': message.id,
      'archive_id': archiveId,
      'original_message_id': message.id, // preserve original id
      'chat_id': message.chatId,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'is_from_me': message.isFromMe ? 1 : 0,
      'status': message.status.index,
      'reply_to_message_id': message.replyToMessageId,
      'thread_id': message.threadId,
      'is_starred': message.isStarred ? 1 : 0,
      'is_forwarded': message.isForwarded ? 1 : 0,
      'priority': message.priority.index,
      'edited_at': message.editedAt?.millisecondsSinceEpoch,
      'original_content': message.originalContent,
      'has_media': message.attachments.isNotEmpty ? 1 : 0,
      'media_type': message.attachments.isNotEmpty
          ? message.attachments.first.type.toString().split('.').last
          : null,
      'archived_at': message.archivedAt.millisecondsSinceEpoch,
      'original_timestamp': message.originalTimestamp.millisecondsSinceEpoch,
      'metadata_json': message.metadata != null && message.metadata!.isNotEmpty
          ? jsonEncode(message.metadata)
          : null,
      'delivery_receipt_json': message.deliveryReceipt != null
          ? jsonEncode(message.deliveryReceipt!.toJson())
          : null,
      'read_receipt_json': message.readReceipt != null
          ? jsonEncode(message.readReceipt!.toJson())
          : null,
      'reactions_json': message.reactions.isNotEmpty
          ? jsonEncode(message.reactions.map((r) => r.toJson()).toList())
          : null,
      'attachments_json': message.attachments.isNotEmpty
          ? jsonEncode(message.attachments.map((a) => a.toJson()).toList())
          : null,
      'encryption_info_json': message.encryptionInfo != null
          ? jsonEncode(message.encryptionInfo!.toJson())
          : null,
      'archive_metadata_json': jsonEncode(message.archiveMetadata.toJson()),
      'preserved_state_json':
          message.preservedState != null && message.preservedState!.isNotEmpty
          ? jsonEncode(message.preservedState)
          : null,
      'searchable_text': message.searchableText,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> archivedChatToMap(
    ArchivedChat archive,
    String originalChatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
  ) {
    return {
      'archive_id': archive.id,
      'original_chat_id': originalChatId,
      'contact_name': archive.contactName,
      'contact_public_key': archive.contactPublicKey,
      'archived_at': archive.archivedAt.millisecondsSinceEpoch,
      'last_message_time': archive.lastMessageTime?.millisecondsSinceEpoch,
      'message_count': archive.messageCount,
      'archive_reason': archiveReason,
      'estimated_size': archive.estimatedSize,
      'is_compressed': archive.isCompressed ? 1 : 0,
      'compression_ratio': archive.compressionInfo?.compressionRatio,
      'metadata_json': jsonEncode(archive.metadata),
      'compression_info_json': archive.compressionInfo != null
          ? jsonEncode(archive.compressionInfo!.toJson())
          : null,
      'custom_data_json': customData != null ? jsonEncode(customData) : null,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  // Compression helper intentionally omitted: repository keeps compression logic
}
