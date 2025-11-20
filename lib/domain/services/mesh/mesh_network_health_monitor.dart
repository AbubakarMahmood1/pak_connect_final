import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats;
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart'
    show RelayStatistics;
import 'package:pak_connect/domain/models/mesh_network_models.dart';

/// Manages mesh network status streams and late-subscriber delivery.
class MeshNetworkHealthMonitor {
  final Logger _logger;
  final StreamController<MeshNetworkStatus> _meshStatusController =
      StreamController<MeshNetworkStatus>.broadcast();
  final StreamController<RelayStatistics> _relayStatsController =
      StreamController<RelayStatistics>.broadcast();
  final StreamController<QueueSyncManagerStats> _queueStatsController =
      StreamController<QueueSyncManagerStats>.broadcast();
  final StreamController<String> _messageDeliveryController =
      StreamController<String>.broadcast();

  MeshNetworkStatus? _lastMeshStatus;

  MeshNetworkHealthMonitor({Logger? logger})
    : _logger = logger ?? Logger('MeshNetworkHealthMonitor');

  Stream<MeshNetworkStatus> get meshStatus => Stream.multi((controller) {
    if (_lastMeshStatus != null) {
      controller.add(_lastMeshStatus!);
    }

    final subscription = _meshStatusController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );

    controller.onCancel = subscription.cancel;
  });

  Stream<RelayStatistics> get relayStats => _relayStatsController.stream;
  Stream<QueueSyncManagerStats> get queueStats => _queueStatsController.stream;
  Stream<String> get messageDeliveryStream => _messageDeliveryController.stream;

  void broadcastInitialStatus() {
    _emitStatus(
      MeshNetworkStatus(
        isInitialized: false,
        currentNodeId: null,
        isConnected: false,
        queueMessages: const [],
        statistics: MeshNetworkStatistics(
          nodeId: 'initializing',
          isInitialized: false,
          relayStatistics: null,
          queueStatistics: const QueueStatistics(
            totalQueued: 0,
            totalDelivered: 0,
            totalFailed: 0,
            pendingMessages: 0,
            sendingMessages: 0,
            retryingMessages: 0,
            failedMessages: 0,
            isOnline: false,
            averageDeliveryTime: Duration.zero,
          ),
          syncStatistics: null,
          spamStatistics: null,
          spamPreventionActive: false,
          queueSyncActive: false,
        ),
      ),
    );
  }

  void broadcastFallbackStatus({String? currentNodeId}) {
    _emitStatus(
      MeshNetworkStatus(
        isInitialized: false,
        currentNodeId: currentNodeId,
        isConnected: false,
        queueMessages: const [],
        statistics: MeshNetworkStatistics(
          nodeId: currentNodeId ?? 'unknown',
          isInitialized: false,
          relayStatistics: null,
          queueStatistics: const QueueStatistics(
            totalQueued: 0,
            totalDelivered: 0,
            totalFailed: 0,
            pendingMessages: 0,
            sendingMessages: 0,
            retryingMessages: 0,
            failedMessages: 0,
            isOnline: false,
            averageDeliveryTime: Duration.zero,
          ),
          syncStatistics: null,
          spamStatistics: null,
          spamPreventionActive: false,
          queueSyncActive: false,
        ),
      ),
    );
  }

  void broadcastInProgressStatus({
    required bool isConnected,
    required String? currentNodeId,
    required MeshNetworkStatistics statistics,
    List<QueuedMessage> queueMessages = const [],
  }) {
    _emitStatus(
      MeshNetworkStatus(
        isInitialized: false,
        currentNodeId: currentNodeId,
        isConnected: isConnected,
        queueMessages: queueMessages,
        statistics: statistics,
      ),
    );
  }

  void broadcastMeshStatus({
    required bool isInitialized,
    required String? currentNodeId,
    required bool isConnected,
    required List<QueuedMessage> queueMessages,
    required MeshNetworkStatistics statistics,
  }) {
    _emitStatus(
      MeshNetworkStatus(
        isInitialized: isInitialized,
        currentNodeId: currentNodeId,
        isConnected: isConnected,
        queueMessages: queueMessages,
        statistics: statistics,
      ),
    );
  }

  void schedulePostFrameStatusUpdate({
    required bool Function() isInitialized,
    required String? Function() nodeIdProvider,
    required List<QueuedMessage> Function() queueSnapshotProvider,
    required MeshNetworkStatistics Function() statisticsProvider,
    required bool Function() isConnectedProvider,
  }) {
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isInitialized() && !_meshStatusController.isClosed) {
          _logger.fine('🔄 Post-frame mesh status refresh scheduled');
          broadcastInProgressStatus(
            isConnected: isConnectedProvider(),
            currentNodeId: nodeIdProvider(),
            statistics: statisticsProvider(),
            queueMessages: queueSnapshotProvider(),
          );
        }
      });
    } catch (e) {
      _logger.warning('Failed to schedule post-frame status update: $e');
    }
  }

  void emitRelayStats(RelayStatistics stats) {
    _relayStatsController.add(stats);
  }

  void emitQueueStats(QueueSyncManagerStats stats) {
    _queueStatsController.add(stats);
  }

  void notifyMessageDelivered(String messageId) {
    _messageDeliveryController.add(messageId);
  }

  void dispose() {
    _meshStatusController.close();
    _relayStatsController.close();
    _queueStatsController.close();
    _messageDeliveryController.close();
  }

  void _emitStatus(MeshNetworkStatus status) {
    _lastMeshStatus = status;
    if (!_meshStatusController.isClosed) {
      _meshStatusController.add(status);
    }
  }
}
