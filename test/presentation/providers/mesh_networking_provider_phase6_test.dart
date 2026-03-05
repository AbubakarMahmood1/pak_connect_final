import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';

class _FakeMeshNetworkingService implements IMeshNetworkingService {
  final StreamController<MeshNetworkStatus> statusController =
      StreamController<MeshNetworkStatus>.broadcast();
  final StreamController<RelayStatistics> relayController =
      StreamController<RelayStatistics>.broadcast();
  final StreamController<QueueSyncManagerStats> queueController =
      StreamController<QueueSyncManagerStats>.broadcast();
  final StreamController<String> deliveryController =
      StreamController<String>.broadcast();
  final StreamController<ReceivedBinaryEvent> binaryController =
      StreamController<ReceivedBinaryEvent>.broadcast();

  MeshSendResult nextSendResult = MeshSendResult.direct('msg-1');
  bool throwOnSend = false;
  bool throwOnSync = false;
  Map<String, QueueSyncResult> syncResult = <String, QueueSyncResult>{};
  List<PendingBinaryTransfer> pendingTransfers = <PendingBinaryTransfer>[];

  MeshNetworkStatistics stats = MeshNetworkStatistics(
    nodeId: 'node-a',
    isInitialized: true,
    relayStatistics: const RelayStatistics(
      totalRelayed: 12,
      totalDropped: 1,
      totalDeliveredToSelf: 4,
      totalBlocked: 1,
      totalProbabilisticSkip: 0,
      spamScore: 0.1,
      relayEfficiency: 0.9,
      activeRelayMessages: 2,
      networkSize: 3,
      currentRelayProbability: 0.8,
    ),
    queueStatistics: const QueueStatistics(
      totalQueued: 20,
      totalDelivered: 18,
      totalFailed: 2,
      pendingMessages: 1,
      sendingMessages: 0,
      retryingMessages: 0,
      failedMessages: 0,
      isOnline: true,
      averageDeliveryTime: Duration(milliseconds: 500),
    ),
    syncStatistics: const QueueSyncManagerStats(
      totalSyncRequests: 4,
      successfulSyncs: 3,
      failedSyncs: 1,
      messagesTransferred: 10,
      activeSyncs: 0,
      successRate: 0.75,
      recentSyncCount: 2,
    ),
    spamStatistics: null,
    spamPreventionActive: true,
    queueSyncActive: true,
  );

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream =>
      binaryController.stream;

  @override
  Future<void> initialize({String? nodeId}) async {}

  @override
  Stream<String> get messageDeliveryStream => deliveryController.stream;

  @override
  Stream<MeshNetworkStatus> get meshStatus => statusController.stream;

  @override
  Stream<QueueSyncManagerStats> get queueStats => queueController.stream;

  @override
  Stream<RelayStatistics> get relayStats => relayController.stream;

  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (throwOnSend) {
      throw StateError('send failure');
    }
    return nextSendResult;
  }

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
    if (throwOnSync) {
      throw StateError('sync failure');
    }
    return syncResult;
  }

  @override
  Future<bool> removeMessage(String messageId) async => true;

  @override
  Future<int> retryAllMessages() async => 0;

  @override
  Future<bool> retryMessage(String messageId) async => true;

  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async =>
      true;

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
  }) async {
    return 'transfer-1';
  }

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async {
    return true;
  }

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => pendingTransfers;

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) =>
      const <QueuedMessage>[];

  @override
  MeshNetworkStatistics getNetworkStatistics() => stats;

  @override
  void refreshMeshStatus() {}

  @override
  void dispose() {
    statusController.close();
    relayController.close();
    queueController.close();
    deliveryController.close();
    binaryController.close();
  }
}

MeshNetworkStatus _status({
  required bool initialized,
  required bool connected,
}) {
  return MeshNetworkStatus(
    isInitialized: initialized,
    currentNodeId: initialized ? 'node-a' : null,
    isConnected: connected,
    statistics: MeshNetworkStatistics(
      nodeId: 'node-a',
      isInitialized: initialized,
      relayStatistics: null,
      queueStatistics: null,
      syncStatistics: null,
      spamStatistics: null,
      spamPreventionActive: initialized,
      queueSyncActive: initialized,
    ),
    queueMessages: const <QueuedMessage>[],
  );
}

void main() {
  group('mesh_networking_provider phase 6.3', () {
    test(
      'MeshNetworkingController handles send + sync success and failures',
      () async {
        final fake = _FakeMeshNetworkingService();
        final container = ProviderContainer(
          overrides: [meshNetworkingServiceProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        final controller = container.read(meshNetworkingControllerProvider);

        final sent = await controller.sendMeshMessage(
          content: 'hello',
          recipientPublicKey: 'peer-key',
        );
        expect(sent.isDirect, isTrue);
        expect(sent.messageId, 'msg-1');

        fake.throwOnSend = true;
        final failedSend = await controller.sendMeshMessage(
          content: 'hello',
          recipientPublicKey: 'peer-key',
        );
        expect(failedSend.type, MeshSendType.error);
        expect(failedSend.error, contains('Send failed'));

        fake.throwOnSync = true;
        final syncFailure = await controller.syncQueuesWithPeers();
        expect(syncFailure.containsKey('error'), isTrue);
        expect(syncFailure['error']!.error, contains('Sync failed'));
      },
    );

    test('MeshNetworkingController computes network health issues', () {
      final fake = _FakeMeshNetworkingService()
        ..stats = MeshNetworkStatistics(
          nodeId: 'node-z',
          isInitialized: false,
          relayStatistics: const RelayStatistics(
            totalRelayed: 1,
            totalDropped: 4,
            totalDeliveredToSelf: 0,
            totalBlocked: 5,
            totalProbabilisticSkip: 0,
            spamScore: 0.8,
            relayEfficiency: 0.1,
            activeRelayMessages: 2,
            networkSize: 2,
            currentRelayProbability: 0.3,
          ),
          queueStatistics: const QueueStatistics(
            totalQueued: 30,
            totalDelivered: 10,
            totalFailed: 20,
            pendingMessages: 12,
            sendingMessages: 2,
            retryingMessages: 2,
            failedMessages: 14,
            isOnline: false,
            averageDeliveryTime: Duration(seconds: 2),
          ),
          syncStatistics: null,
          spamStatistics: null,
          spamPreventionActive: false,
          queueSyncActive: false,
        );

      final health = MeshNetworkingController(fake).getNetworkHealth();

      expect(health.isHealthy, isFalse);
      expect(health.issues, contains('Mesh networking not initialized'));
      expect(health.issues, contains('Spam prevention not active'));
      expect(health.issues, contains('Queue synchronization not active'));
      expect(health.issues, contains('High message drop rate'));
      expect(health.issues, contains('Many failed messages in queue'));
    });

    test('MeshNetworkingUIState exposes derived metrics', () {
      final uiState = MeshNetworkingUIState(
        networkStatus: AsyncValue.data(
          _status(initialized: true, connected: true),
        ),
        relayStats: const AsyncValue.data(
          RelayStatistics(
            totalRelayed: 7,
            totalDropped: 2,
            totalDeliveredToSelf: 1,
            totalBlocked: 1,
            totalProbabilisticSkip: 0,
            spamScore: 0.2,
            relayEfficiency: 0.75,
            activeRelayMessages: 1,
            networkSize: 3,
            currentRelayProbability: 0.7,
          ),
        ),
        queueStats: const AsyncValue.loading(),
      );

      expect(uiState.isReady, isTrue);
      expect(uiState.isConnected, isTrue);
      expect(uiState.currentNodeId, 'node-a');
      expect(uiState.relayEfficiencyPercent, 75.0);
      expect(uiState.totalRelayed, 7);
      expect(uiState.totalBlocked, 1);
      expect(uiState.pendingMessages, 0);
    });

    test('BinaryPayloadInbox stores and clears payloads', () {
      final inbox = BinaryPayloadInbox();
      final event = ReceivedBinaryEvent(
        fragmentId: 'f1',
        originalType: 0x90,
        filePath: '/tmp/file.bin',
        size: 128,
        transferId: 'tx-1',
        ttl: 3,
      );

      inbox.addPayload(event);
      expect(inbox.state['tx-1'], same(event));

      inbox.clearPayload('tx-1');
      expect(inbox.state.containsKey('tx-1'), isFalse);
    });

    test(
      'provider bridge ingests binary stream and pending transfers',
      () async {
        final fake = _FakeMeshNetworkingService()
          ..pendingTransfers = <PendingBinaryTransfer>[
            PendingBinaryTransfer(
              transferId: 'tx-2',
              recipientId: 'peer',
              originalType: 0x90,
            ),
          ];
        final container = ProviderContainer(
          overrides: [meshNetworkingServiceProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        container.read(binaryPayloadInboxProvider);
        final event = ReceivedBinaryEvent(
          fragmentId: 'f2',
          originalType: 0x90,
          filePath: '/tmp/payload.bin',
          size: 256,
          transferId: 'tx-2',
          ttl: 2,
        );
        fake.binaryController.add(event);
        await Future<void>.delayed(const Duration(milliseconds: 1));

        final inbox = container.read(binaryPayloadInboxProvider);
        expect(inbox['tx-2'], isNotNull);

        final pending = container.read(pendingBinaryTransfersProvider);
        expect(pending.length, 1);
        expect(pending.first.transferId, 'tx-2');
      },
    );
  });
}
