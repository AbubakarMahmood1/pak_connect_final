// Archived message entity extending EnhancedMessage with additional archive metadata

import 'package:logging/logging.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../values/id_types.dart';

/// Archived message extending EnhancedMessage with archive-specific metadata
class ArchivedMessage extends EnhancedMessage {
  static final _logger = Logger('ArchivedMessage');

  final DateTime archivedAt;
  final DateTime originalTimestamp; // Preserved original timestamp
  final ArchiveId archiveId;
  final ArchiveMessageMetadata archiveMetadata;
  final String? originalSearchableText; // Cached for search performance
  final Map<String, dynamic>? preservedState; // Original message state

  ArchivedMessage({
    required super.id,
    required super.chatId,
    required super.content,
    required super.timestamp,
    required super.isFromMe,
    required super.status,
    super.replyToMessageId,
    super.threadId,
    super.metadata,
    super.deliveryReceipt,
    super.readReceipt,
    super.reactions = const [],
    super.isStarred = false,
    super.isForwarded = false,
    super.priority = MessagePriority.normal,
    super.editedAt,
    super.originalContent,
    super.attachments = const [],
    super.encryptionInfo,
    required this.archivedAt,
    required this.originalTimestamp,
    required this.archiveId,
    required this.archiveMetadata,
    this.originalSearchableText,
    this.preservedState,
  });

  /// Create archived message from EnhancedMessage
  factory ArchivedMessage.fromEnhancedMessage(
    EnhancedMessage message,
    DateTime archiveTime, {
    ArchiveId? customArchiveId,
    Map<String, dynamic>? additionalMetadata,
  }) {
    // Generate searchable text for indexing
    final searchableText = _generateSearchableText(message);

    // Preserve original message state
    final preservedState = {
      'originalStatus': message.status.index,
      'wasStarred': message.isStarred,
      'reactionCount': message.reactions.length,
      'attachmentCount': message.attachments.length,
      'wasEdited': message.wasEdited,
      'wasThreaded': message.isThreaded,
      'wasReply': message.isReply,
    };

    return ArchivedMessage(
      id: message.id,
      chatId: message.chatId,
      content: message.content,
      timestamp: message.timestamp,
      isFromMe: message.isFromMe,
      status: message.status,
      replyToMessageId: message.replyToMessageId,
      threadId: message.threadId,
      metadata: message.metadata,
      deliveryReceipt: message.deliveryReceipt,
      readReceipt: message.readReceipt,
      reactions: message.reactions,
      isStarred: message.isStarred,
      isForwarded: message.isForwarded,
      priority: message.priority,
      editedAt: message.editedAt,
      originalContent: message.originalContent,
      attachments: message.attachments,
      encryptionInfo: message.encryptionInfo,
      archivedAt: archiveTime,
      originalTimestamp: message.timestamp,
      archiveId:
          customArchiveId ?? _generateArchiveMessageId(message, archiveTime),
      archiveMetadata: ArchiveMessageMetadata(
        archiveVersion: '1.0',
        preservationLevel: ArchivePreservationLevel.complete,
        indexingStatus: ArchiveIndexingStatus.indexed,
        compressionApplied: false,
        originalSize: _estimateMessageSize(message),
        additionalData: additionalMetadata ?? {},
      ),
      originalSearchableText: searchableText,
      preservedState: preservedState,
    );
  }

  /// Create from base Message (for legacy compatibility)
  factory ArchivedMessage.fromMessage(
    Message message,
    DateTime archiveTime, {
    ArchiveId? customArchiveId,
  }) {
    final enhanced = EnhancedMessage.fromMessage(message);
    return ArchivedMessage.fromEnhancedMessage(
      enhanced,
      archiveTime,
      customArchiveId: customArchiveId,
    );
  }

  /// Check if message has been preserved with full fidelity
  bool get isFullyPreserved =>
      archiveMetadata.preservationLevel == ArchivePreservationLevel.complete;

  /// Check if message is searchable
  bool get isSearchable =>
      archiveMetadata.indexingStatus == ArchiveIndexingStatus.indexed;

  /// Check if message content was compressed during archiving
  bool get isCompressed => archiveMetadata.compressionApplied;

  /// Get archive age
  Duration get archiveAge => DateTime.now().difference(archivedAt);

  /// Get searchable text (cached or generated)
  String get searchableText =>
      originalSearchableText ?? _generateSearchableText(this);

  /// Get restoration compatibility info
  MessageRestorationInfo getRestorationInfo() {
    final warnings = <String>[];
    final canRestore = _canRestore(warnings);

    return MessageRestorationInfo(
      messageId: id,
      canRestore: canRestore,
      warnings: warnings,
      originalTimestamp: originalTimestamp,
      archiveAge: archiveAge,
      preservationLevel: archiveMetadata.preservationLevel,
      requiresPostProcessing: _requiresPostProcessing(),
    );
  }

  /// Create a restored EnhancedMessage
  EnhancedMessage toRestoredMessage({ChatId? newChatId}) {
    return EnhancedMessage(
      id: id,
      chatId: newChatId ?? chatId,
      content: content,
      timestamp: originalTimestamp, // Use original timestamp for restoration
      isFromMe: isFromMe,
      status: status,
      replyToMessageId: replyToMessageId,
      threadId: threadId,
      metadata: metadata,
      deliveryReceipt: deliveryReceipt,
      readReceipt: readReceipt,
      reactions: reactions,
      isStarred: isStarred,
      isForwarded: isForwarded,
      priority: priority,
      editedAt: editedAt,
      originalContent: originalContent,
      attachments: attachments,
      encryptionInfo: encryptionInfo,
    );
  }

  /// Create copy with updated archive metadata
  ArchivedMessage copyWithArchiveUpdate({
    ArchiveMessageMetadata? archiveMetadata,
    String? originalSearchableText,
    Map<String, dynamic>? preservedState,
  }) {
    return ArchivedMessage(
      id: id,
      chatId: chatId,
      content: content,
      timestamp: timestamp,
      isFromMe: isFromMe,
      status: status,
      replyToMessageId: replyToMessageId,
      threadId: threadId,
      metadata: metadata,
      deliveryReceipt: deliveryReceipt,
      readReceipt: readReceipt,
      reactions: reactions,
      isStarred: isStarred,
      isForwarded: isForwarded,
      priority: priority,
      editedAt: editedAt,
      originalContent: originalContent,
      attachments: attachments,
      encryptionInfo: encryptionInfo,
      archivedAt: archivedAt,
      originalTimestamp: originalTimestamp,
      archiveId: archiveId,
      archiveMetadata: archiveMetadata ?? this.archiveMetadata,
      originalSearchableText:
          originalSearchableText ?? this.originalSearchableText,
      preservedState: preservedState ?? this.preservedState,
    );
  }

  /// Convert to JSON for storage
  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json.addAll({
      'archivedAt': archivedAt.millisecondsSinceEpoch,
      'originalTimestamp': originalTimestamp.millisecondsSinceEpoch,
      'archiveId': archiveId.value,
      'archiveMetadata': archiveMetadata.toJson(),
      'originalSearchableText': originalSearchableText,
      'preservedState': preservedState,
    });
    return json;
  }

  /// Create from JSON
  factory ArchivedMessage.fromJson(Map<String, dynamic> json) {
    try {
      final enhancedMessage = EnhancedMessage.fromJson(json);

      return ArchivedMessage(
        id: enhancedMessage.id,
        chatId: enhancedMessage.chatId,
        content: enhancedMessage.content,
        timestamp: enhancedMessage.timestamp,
        isFromMe: enhancedMessage.isFromMe,
        status: enhancedMessage.status,
        replyToMessageId: enhancedMessage.replyToMessageId,
        threadId: enhancedMessage.threadId,
        metadata: enhancedMessage.metadata,
        deliveryReceipt: enhancedMessage.deliveryReceipt,
        readReceipt: enhancedMessage.readReceipt,
        reactions: enhancedMessage.reactions,
        isStarred: enhancedMessage.isStarred,
        isForwarded: enhancedMessage.isForwarded,
        priority: enhancedMessage.priority,
        editedAt: enhancedMessage.editedAt,
        originalContent: enhancedMessage.originalContent,
        attachments: enhancedMessage.attachments,
        encryptionInfo: enhancedMessage.encryptionInfo,
        archivedAt: DateTime.fromMillisecondsSinceEpoch(json['archivedAt']),
        originalTimestamp: DateTime.fromMillisecondsSinceEpoch(
          json['originalTimestamp'],
        ),
        archiveId: ArchiveId(json['archiveId'] as String),
        archiveMetadata: ArchiveMessageMetadata.fromJson(
          json['archiveMetadata'],
        ),
        originalSearchableText: json['originalSearchableText'],
        preservedState: json['preservedState'] != null
            ? Map<String, dynamic>.from(json['preservedState'])
            : null,
      );
    } catch (e) {
      _logger.severe('Failed to deserialize ArchivedMessage: $e');
      rethrow;
    }
  }

  // Private helper methods

  static String _generateSearchableText(EnhancedMessage message) {
    final buffer = StringBuffer();
    buffer.write(message.content);

    // Include attachment names for search
    for (final attachment in message.attachments) {
      buffer.write(' ${attachment.name}');
    }

    // Include reaction context
    if (message.reactions.isNotEmpty) {
      buffer.write(' ${message.reactions.map((r) => r.emoji).join(' ')}');
    }

    return buffer.toString().toLowerCase().trim();
  }

  static ArchiveId _generateArchiveMessageId(
    EnhancedMessage message,
    DateTime archiveTime,
  ) {
    final hash = '${message.id.value}_${archiveTime.millisecondsSinceEpoch}'
        .hashCode
        .abs();
    return ArchiveId('archived_msg_$hash');
  }

  static int _estimateMessageSize(EnhancedMessage message) {
    int size = message.content.length * 2; // UTF-16 estimate
    size += message.attachments.fold(
      0,
      (sum, att) => sum + att.name.length * 2,
    );
    size += message.reactions.length * 50; // Emoji + metadata
    size += 200; // Base metadata overhead
    return size;
  }

  bool _canRestore(List<String> warnings) {
    bool canRestore = true;

    if (archiveMetadata.preservationLevel == ArchivePreservationLevel.minimal) {
      warnings.add(
        'Message was archived with minimal preservation - some data may be lost',
      );
    }

    if (archiveAge > const Duration(days: 365)) {
      warnings.add(
        'Message is over 1 year old - compatibility issues may occur',
      );
    }

    if (attachments.isNotEmpty &&
        archiveMetadata.preservationLevel !=
            ArchivePreservationLevel.complete) {
      warnings.add('Message attachments may not be fully restored');
      canRestore = false;
    }

    if (encryptionInfo != null && archiveAge > const Duration(days: 90)) {
      warnings.add('Encrypted message keys may have expired');
    }

    return canRestore;
  }

  bool _requiresPostProcessing() {
    return attachments.isNotEmpty ||
        encryptionInfo != null ||
        reactions.isNotEmpty ||
        threadId != null;
  }
}

/// Archive-specific metadata for messages
class ArchiveMessageMetadata {
  final String archiveVersion;
  final ArchivePreservationLevel preservationLevel;
  final ArchiveIndexingStatus indexingStatus;
  final bool compressionApplied;
  final int originalSize;
  final Map<String, dynamic> additionalData;

  const ArchiveMessageMetadata({
    required this.archiveVersion,
    required this.preservationLevel,
    required this.indexingStatus,
    required this.compressionApplied,
    required this.originalSize,
    required this.additionalData,
  });

  Map<String, dynamic> toJson() => {
    'archiveVersion': archiveVersion,
    'preservationLevel': preservationLevel.index,
    'indexingStatus': indexingStatus.index,
    'compressionApplied': compressionApplied,
    'originalSize': originalSize,
    'additionalData': additionalData,
  };

  factory ArchiveMessageMetadata.fromJson(Map<String, dynamic> json) =>
      ArchiveMessageMetadata(
        archiveVersion: json['archiveVersion'],
        preservationLevel:
            ArchivePreservationLevel.values[json['preservationLevel']],
        indexingStatus: ArchiveIndexingStatus.values[json['indexingStatus']],
        compressionApplied: json['compressionApplied'],
        originalSize: json['originalSize'],
        additionalData: Map<String, dynamic>.from(json['additionalData']),
      );
}

/// Message restoration information
class MessageRestorationInfo {
  final MessageId messageId;
  final bool canRestore;
  final List<String> warnings;
  final DateTime originalTimestamp;
  final Duration archiveAge;
  final ArchivePreservationLevel preservationLevel;
  final bool requiresPostProcessing;

  const MessageRestorationInfo({
    required this.messageId,
    required this.canRestore,
    required this.warnings,
    required this.originalTimestamp,
    required this.archiveAge,
    required this.preservationLevel,
    required this.requiresPostProcessing,
  });

  bool get hasWarnings => warnings.isNotEmpty;

  String get riskLevel {
    if (!canRestore) return 'High';
    if (warnings.length > 2) return 'Medium';
    if (warnings.isNotEmpty) return 'Low';
    return 'None';
  }
}

/// Archive preservation levels
enum ArchivePreservationLevel {
  minimal, // Content only
  standard, // Content + basic metadata
  complete, // Full message state with all metadata
}

/// Archive indexing status
enum ArchiveIndexingStatus {
  notIndexed, // Not available for search
  indexing, // Currently being indexed
  indexed, // Fully searchable
  indexError, // Indexing failed
}
