// Enhanced message entity with comprehensive state tracking and metadata

import '../../domain/entities/message.dart';
import '../../core/models/message_priority.dart';

// Re-export MessagePriority for backward compatibility
export '../../core/models/message_priority.dart' show MessagePriority;

/// Enhanced message with comprehensive state tracking and metadata
class EnhancedMessage extends Message {
  final String? replyToMessageId;
  final String? threadId;
  final Map<String, dynamic>? metadata;
  final MessageDeliveryReceipt? deliveryReceipt;
  final MessageReadReceipt? readReceipt;
  final List<MessageReaction> reactions;
  final bool isStarred;
  final bool isForwarded;
  final MessagePriority priority;
  final DateTime? editedAt;
  final String? originalContent;
  final List<MessageAttachment> attachments;
  final MessageEncryptionInfo? encryptionInfo;

  EnhancedMessage({
    required super.id,
    required super.chatId,
    required super.content,
    required super.timestamp,
    required super.isFromMe,
    required super.status,
    this.replyToMessageId,
    this.threadId,
    this.metadata,
    this.deliveryReceipt,
    this.readReceipt,
    this.reactions = const [],
    this.isStarred = false,
    this.isForwarded = false,
    this.priority = MessagePriority.normal,
    this.editedAt,
    this.originalContent,
    this.attachments = const [],
    this.encryptionInfo,
  });

  /// Create from base Message
  factory EnhancedMessage.fromMessage(Message message) {
    return EnhancedMessage(
      id: message.id,
      chatId: message.chatId,
      content: message.content,
      timestamp: message.timestamp,
      isFromMe: message.isFromMe,
      status: message.status,
    );
  }

  /// Check if message is part of a thread
  bool get isThreaded => threadId != null;

  /// Check if message is a reply
  bool get isReply => replyToMessageId != null;

  /// Check if message was edited
  bool get wasEdited => editedAt != null;

  /// Check if message has been delivered
  bool get isDelivered =>
      deliveryReceipt != null || status == MessageStatus.delivered;

  /// Check if message has been read
  bool get isRead => readReceipt != null;

  /// Get time since delivery
  Duration? get timeSinceDelivery {
    final deliveryTime = deliveryReceipt?.deliveredAt;
    return deliveryTime != null
        ? DateTime.now().difference(deliveryTime)
        : null;
  }

  /// Get time since read
  Duration? get timeSinceRead {
    final readTime = readReceipt?.readAt;
    return readTime != null ? DateTime.now().difference(readTime) : null;
  }

  /// Get formatted status text
  String get statusText {
    if (isFromMe) {
      if (isRead) return 'Read';
      if (isDelivered) return 'Delivered';
      if (status == MessageStatus.sent) return 'Sent';
      if (status == MessageStatus.sending) return 'Sending';
      if (status == MessageStatus.failed) return 'Failed';
    }
    return 'Received';
  }

  /// Get reaction summary
  Map<String, int> get reactionSummary {
    final summary = <String, int>{};
    for (final reaction in reactions) {
      summary[reaction.emoji] = (summary[reaction.emoji] ?? 0) + 1;
    }
    return summary;
  }

  /// Check if user reacted with specific emoji
  bool hasUserReaction(String userId, String emoji) {
    return reactions.any((r) => r.userId == userId && r.emoji == emoji);
  }

  /// Create copy with updated status
  @override
  EnhancedMessage copyWith({
    MessageStatus? status,
    MessageDeliveryReceipt? deliveryReceipt,
    MessageReadReceipt? readReceipt,
    List<MessageReaction>? reactions,
    bool? isStarred,
    String? editedContent,
    DateTime? editedAt,
    MessageEncryptionInfo? encryptionInfo,
  }) {
    return EnhancedMessage(
      id: id,
      chatId: chatId,
      content: editedContent ?? content,
      timestamp: timestamp,
      isFromMe: isFromMe,
      status: status ?? this.status,
      replyToMessageId: replyToMessageId,
      threadId: threadId,
      metadata: metadata,
      deliveryReceipt: deliveryReceipt ?? this.deliveryReceipt,
      readReceipt: readReceipt ?? this.readReceipt,
      reactions: reactions ?? this.reactions,
      isStarred: isStarred ?? this.isStarred,
      isForwarded: isForwarded,
      priority: priority,
      editedAt: editedAt ?? this.editedAt,
      originalContent: editedContent != null
          ? (originalContent ?? content)
          : originalContent,
      attachments: attachments,
      encryptionInfo: encryptionInfo ?? this.encryptionInfo,
    );
  }

  /// Convert to JSON for storage
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'replyToMessageId': replyToMessageId,
    'threadId': threadId,
    'metadata': metadata,
    'deliveryReceipt': deliveryReceipt?.toJson(),
    'readReceipt': readReceipt?.toJson(),
    'reactions': reactions.map((r) => r.toJson()).toList(),
    'isStarred': isStarred,
    'isForwarded': isForwarded,
    'priority': priority.index,
    'editedAt': editedAt?.millisecondsSinceEpoch,
    'originalContent': originalContent,
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'encryptionInfo': encryptionInfo?.toJson(),
  };

  /// Create from JSON
  factory EnhancedMessage.fromJson(Map<String, dynamic> json) =>
      EnhancedMessage(
        id: json['id'],
        chatId: json['chatId'],
        content: json['content'],
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
        isFromMe: json['isFromMe'],
        status: MessageStatus.values[json['status']],
        replyToMessageId: json['replyToMessageId'],
        threadId: json['threadId'],
        metadata: json['metadata'],
        deliveryReceipt: json['deliveryReceipt'] != null
            ? MessageDeliveryReceipt.fromJson(json['deliveryReceipt'])
            : null,
        readReceipt: json['readReceipt'] != null
            ? MessageReadReceipt.fromJson(json['readReceipt'])
            : null,
        reactions:
            (json['reactions'] as List<dynamic>?)
                ?.map((r) => MessageReaction.fromJson(r))
                .toList() ??
            [],
        isStarred: json['isStarred'] ?? false,
        isForwarded: json['isForwarded'] ?? false,
        priority: MessagePriority.values[json['priority'] ?? 0],
        editedAt: json['editedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['editedAt'])
            : null,
        originalContent: json['originalContent'],
        attachments:
            (json['attachments'] as List<dynamic>?)
                ?.map((a) => MessageAttachment.fromJson(a))
                .toList() ??
            [],
        encryptionInfo: json['encryptionInfo'] != null
            ? MessageEncryptionInfo.fromJson(json['encryptionInfo'])
            : null,
      );
}

/// Message delivery receipt
class MessageDeliveryReceipt {
  final DateTime deliveredAt;
  final String? deviceId;
  final String? networkRoute;

  const MessageDeliveryReceipt({
    required this.deliveredAt,
    this.deviceId,
    this.networkRoute,
  });

  Map<String, dynamic> toJson() => {
    'deliveredAt': deliveredAt.millisecondsSinceEpoch,
    'deviceId': deviceId,
    'networkRoute': networkRoute,
  };

  factory MessageDeliveryReceipt.fromJson(Map<String, dynamic> json) =>
      MessageDeliveryReceipt(
        deliveredAt: DateTime.fromMillisecondsSinceEpoch(json['deliveredAt']),
        deviceId: json['deviceId'],
        networkRoute: json['networkRoute'],
      );
}

/// Message read receipt
class MessageReadReceipt {
  final DateTime readAt;
  final String? readBy;
  final String? deviceId;

  const MessageReadReceipt({required this.readAt, this.readBy, this.deviceId});

  Map<String, dynamic> toJson() => {
    'readAt': readAt.millisecondsSinceEpoch,
    'readBy': readBy,
    'deviceId': deviceId,
  };

  factory MessageReadReceipt.fromJson(Map<String, dynamic> json) =>
      MessageReadReceipt(
        readAt: DateTime.fromMillisecondsSinceEpoch(json['readAt']),
        readBy: json['readBy'],
        deviceId: json['deviceId'],
      );
}

/// Message reaction
class MessageReaction {
  final String emoji;
  final String userId;
  final DateTime reactedAt;

  const MessageReaction({
    required this.emoji,
    required this.userId,
    required this.reactedAt,
  });

  Map<String, dynamic> toJson() => {
    'emoji': emoji,
    'userId': userId,
    'reactedAt': reactedAt.millisecondsSinceEpoch,
  };

  factory MessageReaction.fromJson(Map<String, dynamic> json) =>
      MessageReaction(
        emoji: json['emoji'],
        userId: json['userId'],
        reactedAt: DateTime.fromMillisecondsSinceEpoch(json['reactedAt']),
      );
}

/// Message attachment
class MessageAttachment {
  final String id;
  final String type; // 'image', 'file', 'audio', etc.
  final String name;
  final int size;
  final String? mimeType;
  final String? localPath;
  final String? url;
  final Map<String, dynamic>? metadata;

  const MessageAttachment({
    required this.id,
    required this.type,
    required this.name,
    required this.size,
    this.mimeType,
    this.localPath,
    this.url,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'name': name,
    'size': size,
    'mimeType': mimeType,
    'localPath': localPath,
    'url': url,
    'metadata': metadata,
  };

  factory MessageAttachment.fromJson(Map<String, dynamic> json) =>
      MessageAttachment(
        id: json['id'],
        type: json['type'],
        name: json['name'],
        size: json['size'],
        mimeType: json['mimeType'],
        localPath: json['localPath'],
        url: json['url'],
        metadata: json['metadata'],
      );
}

/// Message encryption information
class MessageEncryptionInfo {
  final String algorithm;
  final String keyId;
  final bool isEndToEndEncrypted;
  final DateTime encryptedAt;
  final String? senderKeyFingerprint;
  final String? recipientKeyFingerprint;

  const MessageEncryptionInfo({
    required this.algorithm,
    required this.keyId,
    required this.isEndToEndEncrypted,
    required this.encryptedAt,
    this.senderKeyFingerprint,
    this.recipientKeyFingerprint,
  });

  Map<String, dynamic> toJson() => {
    'algorithm': algorithm,
    'keyId': keyId,
    'isEndToEndEncrypted': isEndToEndEncrypted,
    'encryptedAt': encryptedAt.millisecondsSinceEpoch,
    'senderKeyFingerprint': senderKeyFingerprint,
    'recipientKeyFingerprint': recipientKeyFingerprint,
  };

  factory MessageEncryptionInfo.fromJson(Map<String, dynamic> json) =>
      MessageEncryptionInfo(
        algorithm: json['algorithm'],
        keyId: json['keyId'],
        isEndToEndEncrypted: json['isEndToEndEncrypted'],
        encryptedAt: DateTime.fromMillisecondsSinceEpoch(json['encryptedAt']),
        senderKeyFingerprint: json['senderKeyFingerprint'],
        recipientKeyFingerprint: json['recipientKeyFingerprint'],
      );
}
