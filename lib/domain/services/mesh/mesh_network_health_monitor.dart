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
  final Set<void Function(MeshNetworkStatus)> _meshStatusListeners = {};
  final Set<void Function(RelayStatistics)> _relayStatsListeners = {};
  final Set<void Function(QueueSyncManagerStats)> _queueStatsListeners = {};
  final Set<void Function(String)> _messageDeliveryListeners = {};

  MeshNetworkStatus? _lastMeshStatus;

  MeshNetworkHealthMonitor({Logger? logger})
    : _logger = logger ?? Logger('MeshNetworkHealthMonitor');

  Stream<MeshNetworkStatus> get meshStatus => Stream.multi((controller) {
    if (_lastMeshStatus != null) {
      controller.add(_lastMeshStatus!);
    }

    void listener(MeshNetworkStatus status) {
      controller.add(status);
    }

    _meshStatusListeners.add(listener);
    controller.onCancel = () {
      _meshStatusListeners.remove(listener);
    };
  });

  Stream<RelayStatistics> get relayStats => Stream.multi((controller) {
    void listener(RelayStatistics stats) {
      controller.add(stats);
    }

    _relayStatsListeners.add(listener);
    controller.onCancel = () {
      _relayStatsListeners.remove(listener);
    };
  });
  Stream<QueueSyncManagerStats> get queueStats => Stream.multi((controller) {
    void listener(QueueSyncManagerStats stats) {
      controller.add(stats);
    }

    _queueStatsListeners.add(listener);
    controller.onCancel = () {
      _queueStatsListeners.remove(listener);
    };
  });
  Stream<String> get messageDeliveryStream => Stream.multi((controller) {
    void listener(String messageId) {
      controller.add(messageId);
    }

    _messageDeliveryListeners.add(listener);
    controller.onCancel = () {
      _messageDeliveryListeners.remove(listener);
    };
  });

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
        if (!isInitialized() && _meshStatusListeners.isNotEmpty) {
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
    for (final listener in List.of(_relayStatsListeners)) {
      try {
        listener(stats);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying relay stats listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  void emitQueueStats(QueueSyncManagerStats stats) {
    for (final listener in List.of(_queueStatsListeners)) {
      try {
        listener(stats);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying queue stats listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  void notifyMessageDelivered(String messageId) {
    for (final listener in List.of(_messageDeliveryListeners)) {
      try {
        listener(messageId);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying message delivery listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  void dispose() {
    _meshStatusListeners.clear();
    _relayStatsListeners.clear();
    _queueStatsListeners.clear();
    _messageDeliveryListeners.clear();
  }

  void _emitStatus(MeshNetworkStatus status) {
    _lastMeshStatus = status;
    for (final listener in List.of(_meshStatusListeners)) {
      try {
        listener(status);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying mesh status listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }
}
