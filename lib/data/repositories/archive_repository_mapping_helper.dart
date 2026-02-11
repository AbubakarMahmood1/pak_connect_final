part of 'archive_repository.dart';

class _ArchiveRepositoryMappingHelper {
  _ArchiveRepositoryMappingHelper(this._owner);

  final ArchiveRepository _owner;

  Future<ArchivedChat> compressArchive(ArchivedChat archive) async {
    try {
      ArchiveRepository._logger.info(
        'Compressing archive ${archive.id} (${archive.messageCount} messages)',
      );

      // Serialize messages to JSON
      final messagesJson = jsonEncode(
        archive.messages.map((m) => m.toJson()).toList(),
      );
      final originalData = Uint8List.fromList(utf8.encode(messagesJson));
      final originalSize = originalData.length;

      // Compress using our compression module
      final compressionResult = CompressionUtil.compress(
        originalData,
        config: CompressionConfig.aggressive, // Use aggressive for archives
      );

      if (compressionResult == null) {
        // Compression not beneficial or failed - store uncompressed
        ArchiveRepository._logger.info(
          'Compression not beneficial for archive ${archive.id}, storing uncompressed',
        );
        return archive;
      }

      // Store compressed data as base64 in customData
      final compressedBase64 = base64Encode(compressionResult.compressed);
      final customData = Map<String, dynamic>.from(archive.customData ?? {});
      customData['_compressed_messages_blob'] = compressedBase64;
      customData['_compression_original_size'] = originalSize;

      final compressionInfo = ArchiveCompressionInfo(
        algorithm: compressionResult.stats.algorithm,
        originalSize: originalSize,
        compressedSize: compressionResult.stats.compressedSize,
        compressionRatio: compressionResult.stats.compressionRatio,
        compressedAt: DateTime.now(),
        compressionMetadata: {
          'savingsPercent': compressionResult.stats.savingsPercent,
          'compressionTimeMs': compressionResult.stats.compressionTimeMs,
        },
      );

      ArchiveRepository._logger.info(
        'Archive ${archive.id} compressed: $originalSize → ${compressionResult.stats.compressedSize} bytes '
        '(${compressionResult.stats.savingsPercent.toStringAsFixed(1)}% savings)',
      );

      return archive.copyWith(
        compressionInfo: compressionInfo,
        customData: customData,
      );
    } catch (e, stackTrace) {
      ArchiveRepository._logger.warning(
        'Compression failed for archive ${archive.id}, storing uncompressed: $e',
        e,
        stackTrace,
      );
      return archive;
    }
  }

  Future<ArchivedChat> decompressArchive(ArchivedChat archive) async {
    try {
      // Check if archive is actually compressed
      if (!archive.isCompressed || archive.customData == null) {
        ArchiveRepository._logger.fine(
          'Archive ${archive.id} is not compressed, returning as-is',
        );
        return archive;
      }

      final customData = archive.customData!;
      final compressedBase64 =
          customData['_compressed_messages_blob'] as String?;
      final originalSize = customData['_compression_original_size'] as int?;

      if (compressedBase64 == null) {
        ArchiveRepository._logger.warning(
          'Archive ${archive.id} marked as compressed but no compressed data found',
        );
        return archive;
      }

      ArchiveRepository._logger.info('Decompressing archive ${archive.id}');

      // Decode base64 and decompress
      final compressedData = base64Decode(compressedBase64);
      final decompressed = CompressionUtil.decompress(
        Uint8List.fromList(compressedData),
        originalSize: originalSize,
        config: CompressionConfig.aggressive,
      );

      if (decompressed == null) {
        ArchiveRepository._logger.severe(
          'Failed to decompress archive ${archive.id}, using stored messages',
        );
        return archive;
      }

      // Deserialize messages from decompressed JSON
      final messagesJson = utf8.decode(decompressed);
      final messagesList = jsonDecode(messagesJson) as List<dynamic>;
      final messages = messagesList
          .map((m) => ArchivedMessage.fromJson(m as Map<String, dynamic>))
          .toList();

      ArchiveRepository._logger.info(
        'Archive ${archive.id} decompressed: ${messages.length} messages restored',
      );

      // Return archive with decompressed messages
      // Remove compression info since we're working with uncompressed data now
      return archive.copyWith(messages: messages);
    } catch (e, stackTrace) {
      ArchiveRepository._logger.severe(
        'Decompression failed for archive ${archive.id}, using stored messages: $e',
        e,
        stackTrace,
      );
      return archive; // Fall back to stored messages
    }
  }

  void recordOperationTime(String operation, Duration time) {
    _owner._storageUtils.recordOperationTime(operation, time);
  }

  List<ArchivedMessage> applyMessageTypeFilter(
    List<ArchivedMessage> messages,
    ArchiveMessageTypeFilter filter,
  ) {
    return messages.where((message) {
      if (filter.isFromMe != null && message.isFromMe != filter.isFromMe) {
        return false;
      }
      if (filter.hasAttachments != null &&
          message.attachments.isNotEmpty != filter.hasAttachments) {
        return false;
      }
      if (filter.wasStarred != null && message.isStarred != filter.wasStarred) {
        return false;
      }
      if (filter.wasEdited != null && message.wasEdited != filter.wasEdited) {
        return false;
      }
      return true;
    }).toList();
  }

  ArchivedMessage mapToArchivedMessage(Map<String, dynamic> row) {
    final decryptedContent = ArchiveCrypto.decryptField(
      row['content'] as String,
    );
    final decryptedOriginalContent = row['original_content'] != null
        ? ArchiveCrypto.decryptField(row['original_content'] as String)
        : null;
    final metadataJson = row['metadata_json'] as String?;
    final decryptedMetadataJson = metadataJson != null
        ? ArchiveCrypto.decryptField(metadataJson)
        : null;
    final deliveryReceiptJson = row['delivery_receipt_json'] as String?;
    final decryptedDeliveryReceiptJson = deliveryReceiptJson != null
        ? ArchiveCrypto.decryptField(deliveryReceiptJson)
        : null;
    final readReceiptJson = row['read_receipt_json'] as String?;
    final decryptedReadReceiptJson = readReceiptJson != null
        ? ArchiveCrypto.decryptField(readReceiptJson)
        : null;
    final reactionsJson = row['reactions_json'] as String?;
    final decryptedReactionsJson = reactionsJson != null
        ? ArchiveCrypto.decryptField(reactionsJson)
        : null;
    final attachmentsJson = row['attachments_json'] as String?;
    final decryptedAttachmentsJson = attachmentsJson != null
        ? ArchiveCrypto.decryptField(attachmentsJson)
        : null;
    final archiveMetadataJson = row['archive_metadata_json'] as String?;
    final decryptedArchiveMetadataJson = archiveMetadataJson != null
        ? ArchiveCrypto.decryptField(archiveMetadataJson)
        : null;
    final preservedStateJson = row['preserved_state_json'] as String?;
    final decryptedPreservedStateJson = preservedStateJson != null
        ? ArchiveCrypto.decryptField(preservedStateJson)
        : null;

    return ArchivedMessage(
      // Message base fields
      id: MessageId(row['id'] as String),
      chatId: ChatId(row['chat_id'] as String),
      content: decryptedContent,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      isFromMe: (row['is_from_me'] as int) == 1,
      status: MessageStatus.values[row['status'] as int],

      // EnhancedMessage fields
      replyToMessageId: row['reply_to_message_id'] != null
          ? MessageId(row['reply_to_message_id'] as String)
          : null,
      threadId: row['thread_id'] as String?,
      metadata: decryptedMetadataJson != null
          ? Map<String, dynamic>.from(jsonDecode(decryptedMetadataJson))
          : null,
      deliveryReceipt: decryptedDeliveryReceiptJson != null
          ? MessageDeliveryReceipt.fromJson(
              jsonDecode(decryptedDeliveryReceiptJson),
            )
          : null,
      readReceipt: decryptedReadReceiptJson != null
          ? MessageReadReceipt.fromJson(jsonDecode(decryptedReadReceiptJson))
          : null,
      reactions: decryptedReactionsJson != null
          ? (jsonDecode(decryptedReactionsJson) as List)
                .map((r) => MessageReaction.fromJson(r))
                .toList()
          : const [],
      isStarred: (row['is_starred'] as int? ?? 0) == 1,
      isForwarded: (row['is_forwarded'] as int? ?? 0) == 1,
      priority: MessagePriority.values[row['priority'] as int? ?? 1],
      editedAt: row['edited_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['edited_at'] as int)
          : null,
      originalContent: decryptedOriginalContent,
      attachments: decryptedAttachmentsJson != null
          ? (jsonDecode(decryptedAttachmentsJson) as List)
                .map((a) => MessageAttachment.fromJson(a))
                .toList()
          : const [],
      encryptionInfo: row['encryption_info_json'] != null
          ? MessageEncryptionInfo.fromJson(
              jsonDecode(row['encryption_info_json'] as String),
            )
          : null,

      // ArchivedMessage specific fields
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        row['archived_at'] as int,
      ),
      originalTimestamp: DateTime.fromMillisecondsSinceEpoch(
        row['original_timestamp'] as int,
      ),
      archiveId: ArchiveId(row['archive_id'] as String),
      archiveMetadata: decryptedArchiveMetadataJson != null
          ? ArchiveMessageMetadata.fromJson(
              jsonDecode(decryptedArchiveMetadataJson),
            )
          : ArchiveMessageMetadata(
              archiveVersion: '1.0',
              preservationLevel: ArchivePreservationLevel.complete,
              indexingStatus: ArchiveIndexingStatus.indexed,
              compressionApplied: false,
              originalSize: 0,
              additionalData: {},
            ),
      originalSearchableText: row['searchable_text'] as String?,
      preservedState: decryptedPreservedStateJson != null
          ? Map<String, dynamic>.from(jsonDecode(decryptedPreservedStateJson))
          : null,
    );
  }

  ArchivedChatSummary mapToArchivedChatSummary(Map<String, dynamic> row) {
    return ArchivedChatSummary(
      id: ArchiveId(row['archive_id'] as String),
      originalChatId: ChatId(row['original_chat_id'] as String),
      contactName: row['contact_name'] as String,
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        row['archived_at'] as int,
      ),
      lastMessageTime: row['last_message_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['last_message_time'] as int)
          : null,
      messageCount: row['message_count'] as int,
      estimatedSize: row['estimated_size'] as int? ?? 0,
      isCompressed: (row['is_compressed'] as int? ?? 0) == 1,
      tags: [], // Tags can be extracted from metadata_json if needed
      isSearchable: true, // All archives searchable with FTS5
    );
  }

  ArchivedChat mapToArchivedChat(
    Map<String, dynamic> archiveRow,
    List<ArchivedMessage> messages,
  ) {
    final compressionInfoJson = archiveRow['compression_info_json'] as String?;
    final metadataJson = archiveRow['metadata_json'] as String?;
    final decryptedMetadataJson = metadataJson != null
        ? ArchiveCrypto.decryptField(metadataJson)
        : null;
    final archiveReasonRaw = archiveRow['archive_reason'] as String?;
    final decryptedReason = archiveReasonRaw != null
        ? ArchiveCrypto.decryptField(archiveReasonRaw)
        : null;
    final customDataJson = archiveRow['custom_data_json'] as String?;
    final decryptedCustomDataJson = customDataJson != null
        ? ArchiveCrypto.decryptField(customDataJson)
        : null;

    return ArchivedChat(
      id: ArchiveId(archiveRow['archive_id'] as String),
      originalChatId: ChatId(archiveRow['original_chat_id'] as String),
      contactName: archiveRow['contact_name'] as String,
      contactPublicKey: archiveRow['contact_public_key'] as String?,
      messages: messages,
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        archiveRow['archived_at'] as int,
      ),
      lastMessageTime: archiveRow['last_message_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              archiveRow['last_message_time'] as int,
            )
          : null,
      messageCount: archiveRow['message_count'] as int,
      metadata: decryptedMetadataJson != null
          ? ArchiveMetadata.fromJson(jsonDecode(decryptedMetadataJson))
          : ArchiveMetadata(
              version: '1.0',
              reason: decryptedReason ?? archiveReasonRaw ?? 'Unknown',
              originalUnreadCount: 0,
              wasOnline: false,
              hadUnsentMessages: false,
              estimatedStorageSize: archiveRow['estimated_size'] as int? ?? 0,
              archiveSource: 'migration',
              tags: [],
              hasSearchIndex: true,
            ),
      compressionInfo: compressionInfoJson != null
          ? ArchiveCompressionInfo.fromJson(jsonDecode(compressionInfoJson))
          : null,
      customData: decryptedCustomDataJson != null
          ? Map<String, dynamic>.from(jsonDecode(decryptedCustomDataJson))
          : null,
    );
  }
}
