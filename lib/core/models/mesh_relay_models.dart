import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../domain/entities/enhanced_message.dart';

/// Metadata for mesh relay operations
class RelayMetadata {
  /// Time-to-live (maximum hops) for the message
  final int ttl;
  
  /// Current hop count (incremented at each relay)
  final int hopCount;
  
  /// Path of nodes that have relayed this message (for anti-loop protection)
  final List<String> routingPath;
  
  /// Cryptographic hash of the original message for deduplication
  final String messageHash;
  
  /// Priority level affecting TTL limits
  final MessagePriority priority;
  
  /// Timestamp when relay was initiated
  final DateTime relayTimestamp;
  
  /// Original sender's public key
  final String originalSender;
  
  /// Final recipient's public key
  final String finalRecipient;
  
  /// Rate limiting: number of messages relayed by current node in last hour
  final int senderRateCount;
  
  const RelayMetadata({
    required this.ttl,
    required this.hopCount,
    required this.routingPath,
    required this.messageHash,
    required this.priority,
    required this.relayTimestamp,
    required this.originalSender,
    required this.finalRecipient,
    this.senderRateCount = 0,
  });
  
  /// Create relay metadata for a new message
  factory RelayMetadata.create({
    required String originalMessageContent,
    required MessagePriority priority,
    required String originalSender,
    required String finalRecipient,
    required String currentNodeId,
  }) {
    final ttl = _getTTLForPriority(priority);
    final messageHash = _generateMessageHash(
      originalMessageContent,
      originalSender,
      finalRecipient,
    );
    
    return RelayMetadata(
      ttl: ttl,
      hopCount: 1,
      routingPath: [currentNodeId],
      messageHash: messageHash,
      priority: priority,
      relayTimestamp: DateTime.now(),
      originalSender: originalSender,
      finalRecipient: finalRecipient,
    );
  }
  
  /// Create next hop metadata (increments hop count, adds to path)
  RelayMetadata nextHop(String currentNodeId) {
    if (hopCount >= ttl) {
      throw RelayException('Message TTL exceeded');
    }
    
    if (routingPath.contains(currentNodeId)) {
      throw RelayException('Loop detected: node $currentNodeId already in path');
    }
    
    return RelayMetadata(
      ttl: ttl,
      hopCount: hopCount + 1,
      routingPath: [...routingPath, currentNodeId],
      messageHash: messageHash,
      priority: priority,
      relayTimestamp: relayTimestamp,
      originalSender: originalSender,
      finalRecipient: finalRecipient,
      senderRateCount: senderRateCount,
    );
  }
  
  /// Check if message should be relayed (TTL and loop check)
  bool get canRelay => hopCount < ttl;
  
  /// Check if current node is in routing path (loop detection)
  bool hasNodeInPath(String nodeId) => routingPath.contains(nodeId);
  
  /// Get remaining hops
  int get remainingHops => ttl - hopCount;
  
  /// Convert to JSON for serialization
  Map<String, dynamic> toJson() => {
    'ttl': ttl,
    'hopCount': hopCount,
    'routingPath': routingPath,
    'messageHash': messageHash,
    'priority': priority.index,
    'relayTimestamp': relayTimestamp.millisecondsSinceEpoch,
    'originalSender': originalSender,
    'finalRecipient': finalRecipient,
    'senderRateCount': senderRateCount,
  };
  
  /// Create from JSON
  factory RelayMetadata.fromJson(Map<String, dynamic> json) => RelayMetadata(
    ttl: json['ttl'],
    hopCount: json['hopCount'],
    routingPath: List<String>.from(json['routingPath']),
    messageHash: json['messageHash'],
    priority: MessagePriority.values[json['priority']],
    relayTimestamp: DateTime.fromMillisecondsSinceEpoch(json['relayTimestamp']),
    originalSender: json['originalSender'],
    finalRecipient: json['finalRecipient'],
    senderRateCount: json['senderRateCount'] ?? 0,
  );
  
  /// Get TTL based on priority level
  static int _getTTLForPriority(MessagePriority priority) {
    switch (priority) {
      case MessagePriority.urgent:
        return 20;
      case MessagePriority.high:
        return 15;
      case MessagePriority.normal:
        return 10;
      case MessagePriority.low:
        return 5;
    }
  }
  
  /// Generate cryptographic hash for message deduplication
  static String _generateMessageHash(
    String content,
    String sender,
    String recipient,
  ) {
    final combinedData = '$content:$sender:$recipient';
    final bytes = utf8.encode(combinedData);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}

/// Complete mesh relay message structure
class MeshRelayMessage {
  /// Original message ID
  final String originalMessageId;
  
  /// Original message content
  final String originalContent;
  
  /// Relay metadata
  final RelayMetadata relayMetadata;
  
  /// Current relay node's public key
  final String relayNodeId;
  
  /// Timestamp when this relay was created
  final DateTime relayedAt;
  
  /// Optional: Encrypted payload if message requires encryption
  final String? encryptedPayload;
  
  /// Signature of the relay operation
  final String? relaySignature;
  
  const MeshRelayMessage({
    required this.originalMessageId,
    required this.originalContent,
    required this.relayMetadata,
    required this.relayNodeId,
    required this.relayedAt,
    this.encryptedPayload,
    this.relaySignature,
  });
  
  /// Create relay message for forwarding
  factory MeshRelayMessage.createRelay({
    required String originalMessageId,
    required String originalContent,
    required RelayMetadata metadata,
    required String relayNodeId,
    String? encryptedPayload,
  }) {
    return MeshRelayMessage(
      originalMessageId: originalMessageId,
      originalContent: originalContent,
      relayMetadata: metadata,
      relayNodeId: relayNodeId,
      relayedAt: DateTime.now(),
      encryptedPayload: encryptedPayload,
    );
  }
  
  /// Create next hop relay message
  MeshRelayMessage nextHop(String nextRelayNodeId) {
    final nextMetadata = relayMetadata.nextHop(nextRelayNodeId);
    
    return MeshRelayMessage(
      originalMessageId: originalMessageId,
      originalContent: originalContent,
      relayMetadata: nextMetadata,
      relayNodeId: nextRelayNodeId,
      relayedAt: DateTime.now(),
      encryptedPayload: encryptedPayload,
    );
  }
  
  /// Check if message can be relayed further
  bool get canRelay => relayMetadata.canRelay;
  
  /// Get message size for bandwidth management
  int get messageSize => utf8.encode(originalContent).length;
  
  /// Convert to JSON
  Map<String, dynamic> toJson() => {
    'originalMessageId': originalMessageId,
    'originalContent': originalContent,
    'relayMetadata': relayMetadata.toJson(),
    'relayNodeId': relayNodeId,
    'relayedAt': relayedAt.millisecondsSinceEpoch,
    if (encryptedPayload != null) 'encryptedPayload': encryptedPayload,
    if (relaySignature != null) 'relaySignature': relaySignature,
  };
  
  /// Create from JSON
  factory MeshRelayMessage.fromJson(Map<String, dynamic> json) => MeshRelayMessage(
    originalMessageId: json['originalMessageId'],
    originalContent: json['originalContent'],
    relayMetadata: RelayMetadata.fromJson(json['relayMetadata']),
    relayNodeId: json['relayNodeId'],
    relayedAt: DateTime.fromMillisecondsSinceEpoch(json['relayedAt']),
    encryptedPayload: json['encryptedPayload'],
    relaySignature: json['relaySignature'],
  );
}

/// Queue synchronization message for mesh coordination
class QueueSyncMessage {
  /// Hash of the current message queue state
  final String queueHash;
  
  /// List of message IDs in the queue
  final List<String> messageIds;
  
  /// Timestamp of synchronization
  final DateTime syncTimestamp;
  
  /// Node ID requesting/responding to sync
  final String nodeId;
  
  /// Type of sync operation
  final QueueSyncType syncType;
  
  /// Optional: Specific message hashes for verification
  final Map<String, String>? messageHashes;
  
  /// Queue statistics for optimization
  final QueueSyncStats? queueStats;
  
  const QueueSyncMessage({
    required this.queueHash,
    required this.messageIds,
    required this.syncTimestamp,
    required this.nodeId,
    required this.syncType,
    this.messageHashes,
    this.queueStats,
  });
  
  /// Create queue sync request
  factory QueueSyncMessage.createRequest({
    required List<String> messageIds,
    required String nodeId,
    Map<String, String>? messageHashes,
  }) {
    final queueHash = _generateQueueHash(messageIds);
    
    return QueueSyncMessage(
      queueHash: queueHash,
      messageIds: messageIds,
      syncTimestamp: DateTime.now(),
      nodeId: nodeId,
      syncType: QueueSyncType.request,
      messageHashes: messageHashes,
    );
  }
  
  /// Create queue sync response
  factory QueueSyncMessage.createResponse({
    required List<String> messageIds,
    required String nodeId,
    required QueueSyncStats stats,
    Map<String, String>? messageHashes,
  }) {
    final queueHash = _generateQueueHash(messageIds);
    
    return QueueSyncMessage(
      queueHash: queueHash,
      messageIds: messageIds,
      syncTimestamp: DateTime.now(),
      nodeId: nodeId,
      syncType: QueueSyncType.response,
      messageHashes: messageHashes,
      queueStats: stats,
    );
  }
  
  /// Check if queues are synchronized
  bool isQueueSynchronized(String otherQueueHash) => queueHash == otherQueueHash;
  
  /// Get missing message IDs compared to another queue
  List<String> getMissingMessages(List<String> otherMessageIds) {
    return otherMessageIds.where((id) => !messageIds.contains(id)).toList();
  }
  
  /// Convert to JSON
  Map<String, dynamic> toJson() => {
    'queueHash': queueHash,
    'messageIds': messageIds,
    'syncTimestamp': syncTimestamp.millisecondsSinceEpoch,
    'nodeId': nodeId,
    'syncType': syncType.index,
    if (messageHashes != null) 'messageHashes': messageHashes,
    if (queueStats != null) 'queueStats': queueStats!.toJson(),
  };
  
  /// Create from JSON
  factory QueueSyncMessage.fromJson(Map<String, dynamic> json) => QueueSyncMessage(
    queueHash: json['queueHash'],
    messageIds: List<String>.from(json['messageIds']),
    syncTimestamp: DateTime.fromMillisecondsSinceEpoch(json['syncTimestamp']),
    nodeId: json['nodeId'],
    syncType: QueueSyncType.values[json['syncType']],
    messageHashes: json['messageHashes'] != null 
      ? Map<String, String>.from(json['messageHashes']) 
      : null,
    queueStats: json['queueStats'] != null 
      ? QueueSyncStats.fromJson(json['queueStats']) 
      : null,
  );
  
  /// Generate hash for message queue state
  static String _generateQueueHash(List<String> messageIds) {
    final sortedIds = [...messageIds]..sort();
    final combinedIds = sortedIds.join(':');
    final bytes = utf8.encode(combinedIds);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}

/// Queue synchronization operation type
enum QueueSyncType {
  request,
  response,
  update,
}

/// Queue synchronization statistics
class QueueSyncStats {
  final int totalMessages;
  final int pendingMessages;
  final int failedMessages;
  final DateTime lastSyncTime;
  final double successRate;
  
  const QueueSyncStats({
    required this.totalMessages,
    required this.pendingMessages,
    required this.failedMessages,
    required this.lastSyncTime,
    required this.successRate,
  });
  
  Map<String, dynamic> toJson() => {
    'totalMessages': totalMessages,
    'pendingMessages': pendingMessages,
    'failedMessages': failedMessages,
    'lastSyncTime': lastSyncTime.millisecondsSinceEpoch,
    'successRate': successRate,
  };
  
  factory QueueSyncStats.fromJson(Map<String, dynamic> json) => QueueSyncStats(
    totalMessages: json['totalMessages'],
    pendingMessages: json['pendingMessages'],
    failedMessages: json['failedMessages'],
    lastSyncTime: DateTime.fromMillisecondsSinceEpoch(json['lastSyncTime']),
    successRate: json['successRate'].toDouble(),
  );
}

/// Exception for relay operations
class RelayException implements Exception {
  final String message;
  const RelayException(this.message);
  
  @override
  String toString() => 'RelayException: $message';
}