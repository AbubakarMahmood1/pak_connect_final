/// Queued message entity with delivery tracking
///
/// Extracted from offline_message_queue.dart for better separation of concerns.
/// This is a domain entity used across core, data, and presentation layers.

import '../../core/models/message_priority.dart';
import '../../core/models/mesh_relay_models.dart';
import 'queue_enums.dart';

// Explicitly use MessagePriority from message_priority.dart to avoid conflicts
// with MessagePriority from enhanced_message.dart
export '../../core/models/message_priority.dart' show MessagePriority;

/// Queued message with delivery tracking
class QueuedMessage {
  final String id;
  final String chatId;
  final String content;
  final String recipientPublicKey;
  final String senderPublicKey;
  MessagePriority priority; // Mutable to allow priority changes
  final DateTime queuedAt;
  final String? replyToMessageId;
  final List<String> attachments;
  final int maxRetries;

  // Delivery tracking
  QueuedMessageStatus status;
  int attempts;
  DateTime? lastAttemptAt;
  DateTime? nextRetryAt;
  DateTime? deliveredAt;
  DateTime? failedAt;
  String? failureReason;

  /// Expiry timestamp - messages expire if not delivered by this time
  /// TTL is priority-based: urgent=24h, high=12h, normal=6h, low=3h
  final DateTime? expiresAt;

  // Mesh relay fields (optional for backward compatibility)
  /// Indicates if this is a relay message
  final bool isRelayMessage;

  /// Relay metadata for mesh routing (only present for relay messages)
  final RelayMetadata? relayMetadata;

  /// Original message ID (for relay messages, different from relay wrapper ID)
  final String? originalMessageId;

  /// Node that created this relay (current relay node's public key)
  final String? relayNodeId;

  /// Message hash for deduplication across the mesh
  final String? messageHash;

  /// Rate limiting: sender's message count in current time window
  final int senderRateCount;

  QueuedMessage({
    required this.id,
    required this.chatId,
    required this.content,
    required this.recipientPublicKey,
    required this.senderPublicKey,
    required this.priority,
    required this.queuedAt,
    required this.maxRetries,
    this.replyToMessageId,
    this.attachments = const [],
    this.status = QueuedMessageStatus.pending,
    this.attempts = 0,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.deliveredAt,
    this.failedAt,
    this.failureReason,
    this.expiresAt,
    // Relay-specific fields
    this.isRelayMessage = false,
    this.relayMetadata,
    this.originalMessageId,
    this.relayNodeId,
    this.messageHash,
    this.senderRateCount = 0,
  });

  /// Create a relay message from a MeshRelayMessage
  factory QueuedMessage.fromRelayMessage({
    required MeshRelayMessage relayMessage,
    required String chatId,
    required int maxRetries,
    QueuedMessageStatus status = QueuedMessageStatus.pending,
  }) {
    final queuedAt = relayMessage.relayedAt;
    final priority = relayMessage.relayMetadata.priority;

    // Calculate expiry time based on priority
    Duration ttl;
    switch (priority) {
      case MessagePriority.urgent:
        ttl = Duration(hours: 24);
        break;
      case MessagePriority.high:
        ttl = Duration(hours: 12);
        break;
      case MessagePriority.normal:
        ttl = Duration(hours: 6);
        break;
      case MessagePriority.low:
        ttl = Duration(hours: 3);
        break;
    }

    return QueuedMessage(
      id: '${relayMessage.originalMessageId}_relay_${DateTime.now().millisecondsSinceEpoch}',
      chatId: chatId,
      content: relayMessage.originalContent,
      recipientPublicKey: relayMessage.relayMetadata.finalRecipient,
      senderPublicKey: relayMessage.relayMetadata.originalSender,
      priority: priority,
      queuedAt: queuedAt,
      maxRetries: maxRetries,
      status: status,
      expiresAt: queuedAt.add(ttl),
      // Relay-specific fields
      isRelayMessage: true,
      relayMetadata: relayMessage.relayMetadata,
      originalMessageId: relayMessage.originalMessageId,
      relayNodeId: relayMessage.relayNodeId,
      messageHash: relayMessage.relayMetadata.messageHash,
      senderRateCount: relayMessage.relayMetadata.senderRateCount,
    );
  }

  /// Check if message can be relayed further
  bool get canRelay =>
      isRelayMessage && relayMetadata != null && relayMetadata!.canRelay;

  /// Get relay hop count
  int get relayHopCount => relayMetadata?.hopCount ?? 0;

  /// Check if this message has exceeded TTL
  bool get hasExceededTTL =>
      relayMetadata != null && relayMetadata!.hopCount >= relayMetadata!.ttl;

  /// Create next hop relay message
  QueuedMessage createNextHopRelay(String nextRelayNodeId) {
    if (!canRelay || relayMetadata == null) {
      throw RelayException('Cannot create next hop: message cannot be relayed');
    }

    final nextMetadata = relayMetadata!.nextHop(nextRelayNodeId);

    return QueuedMessage(
      id: '${originalMessageId}_relay_${DateTime.now().millisecondsSinceEpoch}',
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      queuedAt: DateTime.now(),
      maxRetries: maxRetries,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      // Relay-specific fields
      isRelayMessage: true,
      relayMetadata: nextMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: nextRelayNodeId,
      messageHash: messageHash,
      senderRateCount: senderRateCount,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'id': id,
    'chatId': chatId,
    'content': content,
    'recipientPublicKey': recipientPublicKey,
    'senderPublicKey': senderPublicKey,
    'priority': priority.index,
    'queuedAt': queuedAt.millisecondsSinceEpoch,
    'maxRetries': maxRetries,
    'replyToMessageId': replyToMessageId,
    'attachments': attachments,
    'status': status.index,
    'attempts': attempts,
    'lastAttemptAt': lastAttemptAt?.millisecondsSinceEpoch,
    'nextRetryAt': nextRetryAt?.millisecondsSinceEpoch,
    'deliveredAt': deliveredAt?.millisecondsSinceEpoch,
    'failedAt': failedAt?.millisecondsSinceEpoch,
    'failureReason': failureReason,
    // Relay-specific fields (for backward compatibility, only include if present)
    'isRelayMessage': isRelayMessage,
    if (relayMetadata != null) 'relayMetadata': relayMetadata!.toJson(),
    if (originalMessageId != null) 'originalMessageId': originalMessageId,
    if (relayNodeId != null) 'relayNodeId': relayNodeId,
    if (messageHash != null) 'messageHash': messageHash,
    'senderRateCount': senderRateCount,
  };

  /// Create from JSON
  factory QueuedMessage.fromJson(Map<String, dynamic> json) => QueuedMessage(
    id: json['id'],
    chatId: json['chatId'],
    content: json['content'],
    recipientPublicKey: json['recipientPublicKey'],
    senderPublicKey: json['senderPublicKey'],
    priority: MessagePriority.values[json['priority']],
    queuedAt: DateTime.fromMillisecondsSinceEpoch(json['queuedAt']),
    maxRetries: json['maxRetries'],
    replyToMessageId: json['replyToMessageId'],
    attachments: List<String>.from(json['attachments'] ?? []),
    status: QueuedMessageStatus.values[json['status']],
    attempts: json['attempts'] ?? 0,
    lastAttemptAt: json['lastAttemptAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastAttemptAt'])
        : null,
    nextRetryAt: json['nextRetryAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['nextRetryAt'])
        : null,
    deliveredAt: json['deliveredAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['deliveredAt'])
        : null,
    failedAt: json['failedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['failedAt'])
        : null,
    failureReason: json['failureReason'],
    // Relay-specific fields (backward compatible - default to false/null if not present)
    isRelayMessage: json['isRelayMessage'] ?? false,
    relayMetadata: json['relayMetadata'] != null
        ? RelayMetadata.fromJson(json['relayMetadata'])
        : null,
    originalMessageId: json['originalMessageId'],
    relayNodeId: json['relayNodeId'],
    messageHash: json['messageHash'],
    senderRateCount: json['senderRateCount'] ?? 0,
  );
}
