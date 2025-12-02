import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/queue_sync_manager.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Result of sending a mesh message.
class MeshSendResult {
  final MeshSendType type;
  final String? messageId;
  final String? nextHop;
  final String? error;

  const MeshSendResult._(this.type, this.messageId, this.nextHop, this.error);

  factory MeshSendResult.direct(String messageId) =>
      MeshSendResult._(MeshSendType.direct, messageId, null, null);

  factory MeshSendResult.relay(String messageId, String nextHop) =>
      MeshSendResult._(MeshSendType.relay, messageId, nextHop, null);

  factory MeshSendResult.error(String error) =>
      MeshSendResult._(MeshSendType.error, null, null, error);

  MessageId? get messageIdValue =>
      messageId != null ? MessageId(messageId!) : null;

  bool get isSuccess => type != MeshSendType.error;
  bool get isDirect => type == MeshSendType.direct;
  bool get isRelay => type == MeshSendType.relay;
}

enum MeshSendType { direct, relay, error }

/// Current status of the mesh network.
class MeshNetworkStatus {
  final bool isInitialized;
  final String? currentNodeId;
  final bool isConnected;
  final MeshNetworkStatistics statistics;
  final List<QueuedMessage>? queueMessages;

  const MeshNetworkStatus({
    required this.isInitialized,
    this.currentNodeId,
    required this.isConnected,
    required this.statistics,
    this.queueMessages,
  });
}

/// Comprehensive network statistics.
class MeshNetworkStatistics {
  final String nodeId;
  final bool isInitialized;
  final RelayStatistics? relayStatistics;
  final QueueStatistics? queueStatistics;
  final QueueSyncManagerStats? syncStatistics;
  final SpamPreventionStatistics? spamStatistics;
  final bool spamPreventionActive;
  final bool queueSyncActive;

  const MeshNetworkStatistics({
    required this.nodeId,
    required this.isInitialized,
    this.relayStatistics,
    this.queueStatistics,
    this.syncStatistics,
    this.spamStatistics,
    required this.spamPreventionActive,
    required this.queueSyncActive,
  });
}
