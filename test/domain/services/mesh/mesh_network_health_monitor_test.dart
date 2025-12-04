import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart'
    show RelayStatistics;
import 'package:pak_connect/core/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats;
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';

void main() {
  group('MeshNetworkHealthMonitor', () {
    late MeshNetworkHealthMonitor monitor;
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUp(() {
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      monitor = MeshNetworkHealthMonitor();
    });

    void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

    tearDown(() {
      final severe = logRecords.where((l) => l.level >= Level.SEVERE);
      final unexpected = severe.where(
        (l) => !allowedSevere.any(
          (p) => p is String
              ? l.message.contains(p)
              : (p as RegExp).hasMatch(l.message),
        ),
      );
      expect(
        unexpected,
        isEmpty,
        reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
      );
      for (final pattern in allowedSevere) {
        final found = severe.any(
          (l) => pattern is String
              ? l.message.contains(pattern)
              : (pattern as RegExp).hasMatch(l.message),
        );
        expect(
          found,
          isTrue,
          reason: 'Missing expected SEVERE matching "$pattern"',
        );
      }
    });

    test('broadcastInitialStatus emits default snapshot', () async {
      monitor.broadcastInitialStatus();

      final status = await monitor.meshStatus.first;
      expect(status.isInitialized, isFalse);
      expect(status.queueMessages, isEmpty);
    });

    test('meshStatus replays last value to late subscribers', () async {
      final stats = MeshNetworkStatistics(
        nodeId: 'node-1',
        isInitialized: true,
        relayStatistics: const RelayStatistics(
          totalRelayed: 0,
          totalDropped: 0,
          totalDeliveredToSelf: 0,
          totalBlocked: 0,
          totalProbabilisticSkip: 0,
          spamScore: 0,
          relayEfficiency: 0,
          activeRelayMessages: 0,
          networkSize: 0,
          currentRelayProbability: 0,
        ),
        queueStatistics: const QueueStatistics(
          totalQueued: 1,
          totalDelivered: 0,
          totalFailed: 0,
          pendingMessages: 1,
          sendingMessages: 0,
          retryingMessages: 0,
          failedMessages: 0,
          isOnline: true,
          averageDeliveryTime: Duration.zero,
        ),
        syncStatistics: null,
        spamStatistics: null,
        spamPreventionActive: false,
        queueSyncActive: false,
      );
      final queueMessages = [
        QueuedMessage(
          id: 'queued-1',
          chatId: 'chat-A',
          content: 'payload',
          recipientPublicKey: 'recipient',
          senderPublicKey: 'sender',
          priority: MessagePriority.normal,
          queuedAt: DateTime.now(),
          maxRetries: 3,
        ),
      ];

      monitor.broadcastMeshStatus(
        isInitialized: true,
        currentNodeId: 'node-1',
        isConnected: true,
        queueMessages: queueMessages,
        statistics: stats,
      );

      final lateValues = <MeshNetworkStatus>[];
      final subscription = monitor.meshStatus.listen(lateValues.add);
      await Future<void>.delayed(Duration.zero);

      expect(lateValues, isNotEmpty);
      expect(lateValues.first.queueMessages?.single.id, 'queued-1');
      expect(lateValues.first.statistics.nodeId, 'node-1');
      await subscription.cancel();
    });

    test('emits relay and queue stats through dedicated streams', () async {
      const relayStats = RelayStatistics(
        totalRelayed: 1,
        totalDropped: 0,
        totalDeliveredToSelf: 0,
        totalBlocked: 0,
        totalProbabilisticSkip: 0,
        spamScore: 0.1,
        relayEfficiency: 0.9,
        activeRelayMessages: 0,
        networkSize: 1,
        currentRelayProbability: 0.5,
      );
      const queueStats = QueueSyncManagerStats(
        totalSyncRequests: 2,
        successfulSyncs: 2,
        failedSyncs: 0,
        messagesTransferred: 4,
        activeSyncs: 1,
        successRate: 1.0,
        recentSyncCount: 1,
      );

      final relayFuture = monitor.relayStats.first;
      final queueFuture = monitor.queueStats.first;

      monitor.emitRelayStats(relayStats);
      monitor.emitQueueStats(queueStats);

      expect(await relayFuture, relayStats);
      expect(await queueFuture, queueStats);
    });
  });
}
