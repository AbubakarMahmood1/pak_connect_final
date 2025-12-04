// Archived chat entity with comprehensive metadata and restoration capabilities

import 'package:logging/logging.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/entities/enhanced_message.dart';
import '../values/id_types.dart';
import 'archived_message.dart';

/// Archived chat entity containing complete chat state and metadata
class ArchivedChat {
  static final _logger = Logger('ArchivedChat');

  final ArchiveId id; // Unique archive ID
  final ChatId originalChatId;
  final String contactName;
  final String? contactPublicKey;
  final DateTime archivedAt;
  final DateTime? lastMessageTime;
  final int messageCount;
  final ArchiveMetadata metadata;
  final List<ArchivedMessage> messages;
  final ArchiveCompressionInfo? compressionInfo;
  final Map<String, dynamic>? customData;

  const ArchivedChat({
    required this.id,
    required this.originalChatId,
    required this.contactName,
    this.contactPublicKey,
    required this.archivedAt,
    this.lastMessageTime,
    required this.messageCount,
    required this.metadata,
    required this.messages,
    this.compressionInfo,
    this.customData,
  });

  /// Create archived chat from chat list item and messages
  factory ArchivedChat.fromChatAndMessages({
    required ArchiveId archiveId,
    required ChatListItem chatItem,
    required List<EnhancedMessage> messages,
    String? archiveReason,
    Map<String, dynamic>? customData,
  }) {
    final now = DateTime.now();
    final archivedMessages = messages
        .map(
          (m) => ArchivedMessage.fromEnhancedMessage(
            m,
            now,
            customArchiveId: archiveId,
          ),
        )
        .toList();

    // Calculate storage size estimate
    final estimatedSize = _calculateStorageSize(chatItem, archivedMessages);

    return ArchivedChat(
      id: archiveId,
      originalChatId: chatItem.chatId,
      contactName: chatItem.contactName,
      contactPublicKey: chatItem.contactPublicKey,
      archivedAt: now,
      lastMessageTime: chatItem.lastMessageTime,
      messageCount: messages.length,
      metadata: ArchiveMetadata(
        version: '1.0',
        reason: archiveReason ?? 'User archived',
        originalUnreadCount: chatItem.unreadCount,
        wasOnline: chatItem.isOnline,
        hadUnsentMessages: chatItem.hasUnsentMessages,
        lastSeen: chatItem.lastSeen,
        estimatedStorageSize: estimatedSize,
        archiveSource: 'ChatManagementService',
        tags: [],
      ),
      messages: archivedMessages,
      customData: customData,
    );
  }

  /// Check if archive is searchable (has indexed content)
  bool get isSearchable => metadata.hasSearchIndex;

  /// Check if archive is compressed
  bool get isCompressed => compressionInfo != null;

  /// Get archive age
  Duration get archiveAge => DateTime.now().difference(archivedAt);

  /// Get archive size estimate in bytes
  int get estimatedSize =>
      compressionInfo?.compressedSize ?? metadata.estimatedStorageSize;

  /// Get chat duration (if available)
  Duration? get chatDuration {
    if (lastMessageTime != null && messages.isNotEmpty) {
      final firstMessage = messages.reduce(
        (a, b) => a.originalTimestamp.isBefore(b.originalTimestamp) ? a : b,
      );
      return lastMessageTime!.difference(firstMessage.originalTimestamp);
    }
    return null;
  }

  /// Get restoration preview info
  ChatRestorationPreview getRestorationPreview() {
    final recentMessages = messages
        .where(
          (m) => m.originalTimestamp.isAfter(
            DateTime.now().subtract(const Duration(days: 7)),
          ),
        )
        .length;

    return ChatRestorationPreview(
      chatId: originalChatId.value,
      contactName: contactName,
      messageCount: messageCount,
      recentMessageCount: recentMessages,
      lastActivity: lastMessageTime,
      estimatedRestoreTime: _estimateRestoreTime(),
      warnings: _generateRestorationWarnings(),
    );
  }

  /// Convert to lightweight summary for lists
  ArchivedChatSummary toSummary() {
    return ArchivedChatSummary(
      id: id,
      originalChatId: originalChatId,
      contactName: contactName,
      archivedAt: archivedAt,
      messageCount: messageCount,
      lastMessageTime: lastMessageTime,
      estimatedSize: estimatedSize,
      isCompressed: isCompressed,
      tags: metadata.tags,
      isSearchable: isSearchable,
    );
  }

  /// Create copy with updated data
  ArchivedChat copyWith({
    ArchiveMetadata? metadata,
    List<ArchivedMessage>? messages,
    ArchiveCompressionInfo? compressionInfo,
    Map<String, dynamic>? customData,
  }) {
    return ArchivedChat(
      id: id,
      originalChatId: originalChatId,
      contactName: contactName,
      contactPublicKey: contactPublicKey,
      archivedAt: archivedAt,
      lastMessageTime: lastMessageTime,
      messageCount: messages?.length ?? messageCount,
      metadata: metadata ?? this.metadata,
      messages: messages ?? this.messages,
      compressionInfo: compressionInfo ?? this.compressionInfo,
      customData: customData ?? this.customData,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id.value,
      'originalChatId': originalChatId.value,
      'contactName': contactName,
      'contactPublicKey': contactPublicKey,
      'archivedAt': archivedAt.millisecondsSinceEpoch,
      'lastMessageTime': lastMessageTime?.millisecondsSinceEpoch,
      'messageCount': messageCount,
      'metadata': metadata.toJson(),
      'messages': messages.map((m) => m.toJson()).toList(),
      'compressionInfo': compressionInfo?.toJson(),
      'customData': customData,
    };
  }

  /// Create from JSON
  factory ArchivedChat.fromJson(Map<String, dynamic> json) {
    try {
      return ArchivedChat(
        id: ArchiveId(json['id']),
        originalChatId: ChatId(json['originalChatId']),
        contactName: json['contactName'],
        contactPublicKey: json['contactPublicKey'],
        archivedAt: DateTime.fromMillisecondsSinceEpoch(json['archivedAt']),
        lastMessageTime: json['lastMessageTime'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['lastMessageTime'])
            : null,
        messageCount: json['messageCount'],
        metadata: ArchiveMetadata.fromJson(json['metadata']),
        messages: (json['messages'] as List<dynamic>)
            .map((m) => ArchivedMessage.fromJson(m))
            .toList(),
        compressionInfo: json['compressionInfo'] != null
            ? ArchiveCompressionInfo.fromJson(json['compressionInfo'])
            : null,
        customData: json['customData'] != null
            ? Map<String, dynamic>.from(json['customData'])
            : null,
      );
    } catch (e) {
      _logger.severe('Failed to deserialize ArchivedChat: $e');
      rethrow;
    }
  }

  // Private helper methods

  static int _calculateStorageSize(
    ChatListItem chat,
    List<ArchivedMessage> messages,
  ) {
    // Rough estimate in bytes
    int size = chat.contactName.length * 2; // UTF-16 encoding estimate
    size += messages.fold(0, (sum, msg) => sum + msg.content.length * 2);
    size += messages.length * 200; // Metadata overhead per message
    return size;
  }

  Duration _estimateRestoreTime() {
    // Base time + message processing time
    final baseTime = const Duration(milliseconds: 500);
    final messageTime = Duration(milliseconds: messageCount * 2);
    final compressionTime = isCompressed
        ? const Duration(milliseconds: 300)
        : Duration.zero;

    return baseTime + messageTime + compressionTime;
  }

  List<String> _generateRestorationWarnings() {
    final warnings = <String>[];

    if (archiveAge > const Duration(days: 30)) {
      warnings.add(
        'Archive is over 30 days old - contact may no longer be available',
      );
    }

    if (messageCount > 1000) {
      warnings.add(
        'Large archive ($messageCount messages) - restoration may take longer',
      );
    }

    if (isCompressed && estimatedSize > 1024 * 1024) {
      // 1MB
      warnings.add(
        'Large compressed archive - ensure sufficient storage space',
      );
    }

    if (metadata.hadUnsentMessages) {
      warnings.add(
        'Archive contained unsent messages - these may not be restored properly',
      );
    }

    return warnings;
  }
}

/// Archive metadata container
class ArchiveMetadata {
  final String version;
  final String reason;
  final int originalUnreadCount;
  final bool wasOnline;
  final bool hadUnsentMessages;
  final DateTime? lastSeen;
  final int estimatedStorageSize;
  final String archiveSource;
  final List<String> tags;
  final bool hasSearchIndex;
  final Map<String, dynamic>? additionalMetadata;

  const ArchiveMetadata({
    required this.version,
    required this.reason,
    required this.originalUnreadCount,
    required this.wasOnline,
    required this.hadUnsentMessages,
    this.lastSeen,
    required this.estimatedStorageSize,
    required this.archiveSource,
    required this.tags,
    this.hasSearchIndex = false,
    this.additionalMetadata,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'reason': reason,
    'originalUnreadCount': originalUnreadCount,
    'wasOnline': wasOnline,
    'hadUnsentMessages': hadUnsentMessages,
    'lastSeen': lastSeen?.millisecondsSinceEpoch,
    'estimatedStorageSize': estimatedStorageSize,
    'archiveSource': archiveSource,
    'tags': tags,
    'hasSearchIndex': hasSearchIndex,
    'additionalMetadata': additionalMetadata,
  };

  factory ArchiveMetadata.fromJson(Map<String, dynamic> json) =>
      ArchiveMetadata(
        version: json['version'],
        reason: json['reason'],
        originalUnreadCount: json['originalUnreadCount'],
        wasOnline: json['wasOnline'],
        hadUnsentMessages: json['hadUnsentMessages'],
        lastSeen: json['lastSeen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['lastSeen'])
            : null,
        estimatedStorageSize: json['estimatedStorageSize'],
        archiveSource: json['archiveSource'],
        tags: List<String>.from(json['tags']),
        hasSearchIndex: json['hasSearchIndex'] ?? false,
        additionalMetadata: json['additionalMetadata'] != null
            ? Map<String, dynamic>.from(json['additionalMetadata'])
            : null,
      );
}

/// Compression information for archived data
class ArchiveCompressionInfo {
  final String algorithm;
  final int originalSize;
  final int compressedSize;
  final double compressionRatio;
  final DateTime compressedAt;
  final Map<String, dynamic>? compressionMetadata;

  const ArchiveCompressionInfo({
    required this.algorithm,
    required this.originalSize,
    required this.compressedSize,
    required this.compressionRatio,
    required this.compressedAt,
    this.compressionMetadata,
  });

  Map<String, dynamic> toJson() => {
    'algorithm': algorithm,
    'originalSize': originalSize,
    'compressedSize': compressedSize,
    'compressionRatio': compressionRatio,
    'compressedAt': compressedAt.millisecondsSinceEpoch,
    'compressionMetadata': compressionMetadata,
  };

  factory ArchiveCompressionInfo.fromJson(Map<String, dynamic> json) =>
      ArchiveCompressionInfo(
        algorithm: json['algorithm'],
        originalSize: json['originalSize'],
        compressedSize: json['compressedSize'],
        compressionRatio: json['compressionRatio'],
        compressedAt: DateTime.fromMillisecondsSinceEpoch(json['compressedAt']),
        compressionMetadata: json['compressionMetadata'] != null
            ? Map<String, dynamic>.from(json['compressionMetadata'])
            : null,
      );
}

/// Lightweight summary for archived chat lists
class ArchivedChatSummary {
  final ArchiveId id;
  final ChatId originalChatId;
  final String contactName;
  final DateTime archivedAt;
  final int messageCount;
  final DateTime? lastMessageTime;
  final int estimatedSize;
  final bool isCompressed;
  final List<String> tags;
  final bool isSearchable;

  const ArchivedChatSummary({
    required this.id,
    required this.originalChatId,
    required this.contactName,
    required this.archivedAt,
    required this.messageCount,
    this.lastMessageTime,
    required this.estimatedSize,
    required this.isCompressed,
    required this.tags,
    required this.isSearchable,
  });

  /// Get formatted size string
  String get formattedSize {
    if (estimatedSize < 1024) return '${estimatedSize}B';
    if (estimatedSize < 1024 * 1024) {
      return '${(estimatedSize / 1024).toStringAsFixed(1)}KB';
    }
    return '${(estimatedSize / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  /// Get archive age string
  String get ageDescription {
    final age = DateTime.now().difference(archivedAt);
    if (age.inDays < 1) return 'Today';
    if (age.inDays < 7) return '${age.inDays}d ago';
    if (age.inDays < 30) return '${(age.inDays / 7).round()}w ago';
    if (age.inDays < 365) return '${(age.inDays / 30).round()}mo ago';
    return '${(age.inDays / 365).round()}y ago';
  }
}

/// Chat restoration preview information
class ChatRestorationPreview {
  final String chatId;
  final String contactName;
  final int messageCount;
  final int recentMessageCount;
  final DateTime? lastActivity;
  final Duration estimatedRestoreTime;
  final List<String> warnings;

  const ChatRestorationPreview({
    required this.chatId,
    required this.contactName,
    required this.messageCount,
    required this.recentMessageCount,
    this.lastActivity,
    required this.estimatedRestoreTime,
    required this.warnings,
  });

  bool get hasWarnings => warnings.isNotEmpty;
  bool get isRecentlyActive => recentMessageCount > 0;

  String get formattedRestoreTime {
    if (estimatedRestoreTime.inSeconds < 1) {
      return '${estimatedRestoreTime.inMilliseconds}ms';
    } else if (estimatedRestoreTime.inMinutes < 1) {
      return '${estimatedRestoreTime.inSeconds}s';
    } else {
      return '${estimatedRestoreTime.inMinutes}m ${estimatedRestoreTime.inSeconds % 60}s';
    }
  }
}
