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
    final recordId = row['id'] as String;
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
    final decodedMetadata = _decodeJsonObject(
      decryptedMetadataJson,
      fieldName: 'metadata_json',
      recordId: recordId,
    );
    final decodedDeliveryReceipt = _decodeJsonObject(
      decryptedDeliveryReceiptJson,
      fieldName: 'delivery_receipt_json',
      recordId: recordId,
    );
    final decodedReadReceipt = _decodeJsonObject(
      decryptedReadReceiptJson,
      fieldName: 'read_receipt_json',
      recordId: recordId,
    );
    final decodedReactions = _decodeJsonList(
      decryptedReactionsJson,
      fieldName: 'reactions_json',
      recordId: recordId,
    );
    final decodedAttachments = _decodeJsonList(
      decryptedAttachmentsJson,
      fieldName: 'attachments_json',
      recordId: recordId,
    );
    final decodedEncryptionInfo = _decodeJsonObject(
      row['encryption_info_json'] as String?,
      fieldName: 'encryption_info_json',
      recordId: recordId,
    );
    final decodedArchiveMetadata = _decodeJsonObject(
      decryptedArchiveMetadataJson,
      fieldName: 'archive_metadata_json',
      recordId: recordId,
    );
    final decodedPreservedState = _decodeJsonObject(
      decryptedPreservedStateJson,
      fieldName: 'preserved_state_json',
      recordId: recordId,
    );

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
      metadata: decodedMetadata,
      deliveryReceipt: decodedDeliveryReceipt != null
          ? MessageDeliveryReceipt.fromJson(decodedDeliveryReceipt)
          : null,
      readReceipt: decodedReadReceipt != null
          ? MessageReadReceipt.fromJson(decodedReadReceipt)
          : null,
      reactions: decodedReactions != null
          ? decodedReactions.map((r) => MessageReaction.fromJson(r)).toList()
          : const [],
      isStarred: (row['is_starred'] as int? ?? 0) == 1,
      isForwarded: (row['is_forwarded'] as int? ?? 0) == 1,
      priority: MessagePriority.values[row['priority'] as int? ?? 1],
      editedAt: row['edited_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['edited_at'] as int)
          : null,
      originalContent: decryptedOriginalContent,
      attachments: decodedAttachments != null
          ? decodedAttachments
                .map((a) => MessageAttachment.fromJson(a))
                .toList()
          : const [],
      encryptionInfo: decodedEncryptionInfo != null
          ? MessageEncryptionInfo.fromJson(decodedEncryptionInfo)
          : null,

      // ArchivedMessage specific fields
      archivedAt: DateTime.fromMillisecondsSinceEpoch(
        row['archived_at'] as int,
      ),
      originalTimestamp: DateTime.fromMillisecondsSinceEpoch(
        row['original_timestamp'] as int,
      ),
      archiveId: ArchiveId(row['archive_id'] as String),
      archiveMetadata: decodedArchiveMetadata != null
          ? ArchiveMessageMetadata.fromJson(decodedArchiveMetadata)
          : ArchiveMessageMetadata(
              archiveVersion: '1.0',
              preservationLevel: ArchivePreservationLevel.complete,
              indexingStatus: ArchiveIndexingStatus.indexed,
              compressionApplied: false,
              originalSize: 0,
              additionalData: {},
            ),
      originalSearchableText: row['searchable_text'] as String?,
      preservedState: decodedPreservedState,
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
    final archiveId = archiveRow['archive_id'] as String;
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
    final decodedArchiveMetadata = _decodeJsonObject(
      decryptedMetadataJson,
      fieldName: 'metadata_json',
      recordId: archiveId,
    );
    final decodedCompressionInfo = _decodeJsonObject(
      compressionInfoJson,
      fieldName: 'compression_info_json',
      recordId: archiveId,
    );
    final decodedCustomData = _decodeJsonObject(
      decryptedCustomDataJson,
      fieldName: 'custom_data_json',
      recordId: archiveId,
    );

    return ArchivedChat(
      id: ArchiveId(archiveId),
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
      metadata: decodedArchiveMetadata != null
          ? ArchiveMetadata.fromJson(decodedArchiveMetadata)
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
      compressionInfo: decodedCompressionInfo != null
          ? ArchiveCompressionInfo.fromJson(decodedCompressionInfo)
          : null,
      customData: decodedCustomData,
    );
  }

  Map<String, dynamic>? _decodeJsonObject(
    String? value, {
    required String fieldName,
    required String recordId,
  }) {
    final decoded = _decodeJson(
      value,
      fieldName: fieldName,
      recordId: recordId,
    );
    if (decoded == null) {
      return null;
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    ArchiveRepository._logger.warning(
      'Skipping archive field $fieldName for $recordId: expected JSON object but found ${decoded.runtimeType}',
    );
    return null;
  }

  List<dynamic>? _decodeJsonList(
    String? value, {
    required String fieldName,
    required String recordId,
  }) {
    final decoded = _decodeJson(
      value,
      fieldName: fieldName,
      recordId: recordId,
    );
    if (decoded == null) {
      return null;
    }
    if (decoded is List<dynamic>) {
      return decoded;
    }
    if (decoded is List) {
      return List<dynamic>.from(decoded);
    }
    ArchiveRepository._logger.warning(
      'Skipping archive field $fieldName for $recordId: expected JSON list but found ${decoded.runtimeType}',
    );
    return null;
  }

  dynamic _decodeJson(
    String? value, {
    required String fieldName,
    required String recordId,
  }) {
    if (value == null || value.isEmpty) {
      return null;
    }
    if (ArchiveCrypto.isUnsupportedLegacyCiphertext(value)) {
      ArchiveRepository._logger.warning(
        'Skipping unsupported legacy archive field $fieldName for $recordId',
      );
      return null;
    }
    try {
      return jsonDecode(value);
    } catch (e, stackTrace) {
      ArchiveRepository._logger.warning(
        'Skipping malformed archive field $fieldName for $recordId: $e',
        e,
        stackTrace,
      );
      return null;
    }
  }
}
