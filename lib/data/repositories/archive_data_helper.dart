import 'dart:convert';
import '../../domain/entities/archived_message.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/values/id_types.dart';
import '../../core/security/archive_crypto.dart';

/// Helper for archive data transformations, compression, and serialization
class ArchiveDataHelper {
  const ArchiveDataHelper();

  Map<String, dynamic> archivedMessageToMap(
    ArchivedMessage message,
    ArchiveId archiveId,
  ) {
    final encryptedContent = ArchiveCrypto.encryptField(message.content);
    final encryptedOriginalContent = message.originalContent != null
        ? ArchiveCrypto.encryptField(message.originalContent!)
        : null;
    final encryptionInfo = ArchiveCrypto.resolveEncryptionInfo(
      message.encryptionInfo,
    );

    return {
      'id': message.id.value,
      'archive_id': archiveId.value,
      'original_message_id': message.id.value, // preserve original id
      'chat_id': message.chatId.value,
      'content': encryptedContent,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'is_from_me': message.isFromMe ? 1 : 0,
      'status': message.status.index,
      'reply_to_message_id': message.replyToMessageId?.value,
      'thread_id': message.threadId,
      'is_starred': message.isStarred ? 1 : 0,
      'is_forwarded': message.isForwarded ? 1 : 0,
      'priority': message.priority.index,
      'edited_at': message.editedAt?.millisecondsSinceEpoch,
      'original_content': encryptedOriginalContent,
      'has_media': message.attachments.isNotEmpty ? 1 : 0,
      'media_type': message.attachments.isNotEmpty
          ? message.attachments.first.type.toString().split('.').last
          : null,
      'archived_at': message.archivedAt.millisecondsSinceEpoch,
      'original_timestamp': message.originalTimestamp.millisecondsSinceEpoch,
      'metadata_json': message.metadata != null && message.metadata!.isNotEmpty
          ? ArchiveCrypto.encryptField(jsonEncode(message.metadata))
          : null,
      'delivery_receipt_json': message.deliveryReceipt != null
          ? ArchiveCrypto.encryptField(
              jsonEncode(message.deliveryReceipt!.toJson()),
            )
          : null,
      'read_receipt_json': message.readReceipt != null
          ? ArchiveCrypto.encryptField(
              jsonEncode(message.readReceipt!.toJson()),
            )
          : null,
      'reactions_json': message.reactions.isNotEmpty
          ? ArchiveCrypto.encryptField(
              jsonEncode(message.reactions.map((r) => r.toJson()).toList()),
            )
          : null,
      'attachments_json': message.attachments.isNotEmpty
          ? ArchiveCrypto.encryptField(
              jsonEncode(message.attachments.map((a) => a.toJson()).toList()),
            )
          : null,
      'encryption_info_json': jsonEncode(encryptionInfo.toJson()),
      'archive_metadata_json': ArchiveCrypto.encryptField(
        jsonEncode(message.archiveMetadata.toJson()),
      ),
      'preserved_state_json':
          message.preservedState != null && message.preservedState!.isNotEmpty
          ? ArchiveCrypto.encryptField(jsonEncode(message.preservedState))
          : null,
      'searchable_text': message.searchableText,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> archivedChatToMap(
    ArchivedChat archive,
    ChatId originalChatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
  ) {
    final encryptedMetadata = ArchiveCrypto.encryptField(
      jsonEncode(archive.metadata),
    );
    final encryptedCustomData = customData != null
        ? ArchiveCrypto.encryptField(jsonEncode(customData))
        : null;
    final encryptedReason = archiveReason != null
        ? ArchiveCrypto.encryptField(archiveReason)
        : null;

    return {
      'archive_id': archive.id.value,
      'original_chat_id': originalChatId.value,
      'contact_name': archive.contactName,
      'contact_public_key': archive.contactPublicKey,
      'archived_at': archive.archivedAt.millisecondsSinceEpoch,
      'last_message_time': archive.lastMessageTime?.millisecondsSinceEpoch,
      'message_count': archive.messageCount,
      'archive_reason': encryptedReason,
      'estimated_size': archive.estimatedSize,
      'is_compressed': archive.isCompressed ? 1 : 0,
      'compression_ratio': archive.compressionInfo?.compressionRatio,
      'metadata_json': encryptedMetadata,
      'compression_info_json': archive.compressionInfo != null
          ? jsonEncode(archive.compressionInfo!.toJson())
          : null,
      'custom_data_json': encryptedCustomData,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  // Compression helper intentionally omitted: repository keeps compression logic
}
