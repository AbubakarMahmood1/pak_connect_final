import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queue_statistics.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/presentation/widgets/relay_queue_widget.dart';

class _FakeMeshNetworkingService implements IMeshNetworkingService {
  final _statusController = StreamController<MeshNetworkStatus>.broadcast();

  String? retriedMessageId;
  String? priorityMessageId;
  MessagePriority? priorityValue;
  String? removedMessageId;
  int retryAllCalls = 0;

  bool retryMessageResult = true;
  bool setPriorityResult = true;
  bool removeMessageResult = true;
  int retryAllResult = 0;

  Object? retryMessageError;
  Object? setPriorityError;
  Object? removeMessageError;
  Object? retryAllError;

  void emitStatus(MeshNetworkStatus status) {
    _statusController.add(status);
  }

  Future<void> close() async {
    await _statusController.close();
  }

  @override
  Future<void> initialize({String? nodeId}) async {}

  @override
  void dispose() {
    unawaited(close());
  }

  @override
  Stream<MeshNetworkStatus> get meshStatus => _statusController.stream;

  @override
  Stream<RelayStatistics> get relayStats => const Stream.empty();

  @override
  Stream<QueueSyncManagerStats> get queueStats => const Stream.empty();

  @override
  Stream<String> get messageDeliveryStream => const Stream.empty();

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream => const Stream.empty();

  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async => MeshSendResult.direct('msg-1');

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = BinaryPayloadType.media,
    Map<String, dynamic>? metadata,
  }) async => 'transfer-1';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async => true;

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async =>
      <String, QueueSyncResult>{};

  @override
  Future<bool> retryMessage(String messageId) async {
    retriedMessageId = messageId;
    if (retryMessageError != null) throw retryMessageError!;
    return retryMessageResult;
  }

  @override
  Future<bool> removeMessage(String messageId) async {
    removedMessageId = messageId;
    if (removeMessageError != null) throw removeMessageError!;
    return removeMessageResult;
  }

  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async {
    priorityMessageId = messageId;
    priorityValue = priority;
    if (setPriorityError != null) throw setPriorityError!;
    return setPriorityResult;
  }

  @override
  Future<int> retryAllMessages() async {
    retryAllCalls++;
    if (retryAllError != null) throw retryAllError!;
    return retryAllResult;
  }

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) => const [];

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => const [];

  @override
  MeshNetworkStatistics getNetworkStatistics() => MeshNetworkStatistics(
    nodeId: 'node-test',
    isInitialized: true,
    relayStatistics: null,
    queueStatistics: null,
    syncStatistics: null,
    spamStatistics: null,
    spamPreventionActive: false,
    queueSyncActive: false,
  );

  @override
  void refreshMeshStatus() {}
}

Future<void> _pumpRelayQueueWidget(
  WidgetTester tester,
  _FakeMeshNetworkingService meshService,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: RelayQueueWidget(meshService: meshService),
        ),
      ),
    ),
  );
  await tester.pump();
}

MeshNetworkStatus _status({
  required List<QueuedMessage>? queueMessages,
  bool isOnline = true,
  int pending = 0,
  int sending = 0,
  int retrying = 0,
}) {
  return MeshNetworkStatus(
    isInitialized: true,
    currentNodeId: 'node-test',
    isConnected: isOnline,
    statistics: MeshNetworkStatistics(
      nodeId: 'node-test',
      isInitialized: true,
      relayStatistics: null,
      queueStatistics: QueueStatistics(
        totalQueued: pending + sending + retrying,
        totalDelivered: 0,
        totalFailed: 0,
        pendingMessages: pending,
        sendingMessages: sending,
        retryingMessages: retrying,
        failedMessages: retrying,
        isOnline: isOnline,
        averageDeliveryTime: Duration.zero,
      ),
      syncStatistics: null,
      spamStatistics: null,
      spamPreventionActive: false,
      queueSyncActive: false,
    ),
    queueMessages: queueMessages,
  );
}

QueuedMessage _queued({
  required String id,
  required String content,
  required MessagePriority priority,
  required QueuedMessageStatus status,
  bool isRelayMessage = false,
  RelayMetadata? relayMetadata,
  DateTime? nextRetryAt,
  int attempts = 0,
}) {
  return QueuedMessage(
    id: id,
    chatId: 'chat-1',
    content: content,
    recipientPublicKey: 'recipient-public-key-1234567890',
    senderPublicKey: 'sender-public-key-1234567890',
    priority: priority,
    queuedAt: DateTime.now().subtract(const Duration(minutes: 2)),
    maxRetries: 5,
    status: status,
    attempts: attempts,
    nextRetryAt: nextRetryAt,
    isRelayMessage: isRelayMessage,
    relayMetadata: relayMetadata,
  );
}

RelayMetadata _relayMetadata({int hopCount = 2}) {
  return RelayMetadata(
    ttl: 4,
    hopCount: hopCount,
    routingPath: const ['node-a', 'node-b'],
    messageHash: 'hash-123',
    priority: MessagePriority.high,
    relayTimestamp: DateTime(2026, 1, 1),
    originalSender: 'sender-public-key-1234567890',
    finalRecipient: 'recipient-public-key-1234567890',
  );
}

void main() {
  group('RelayQueueWidget', () {
    testWidgets('shows loading state before mesh status arrives', (
      tester,
    ) async {
      final meshService = _FakeMeshNetworkingService();
      addTearDown(meshService.close);

      await _pumpRelayQueueWidget(tester, meshService);

      expect(find.text('Loading relay queue...'), findsOneWidget);
      expect(find.text('Initializing mesh network...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders unavailable and empty queue states', (tester) async {
      final meshService = _FakeMeshNetworkingService();
      addTearDown(meshService.close);
      await _pumpRelayQueueWidget(tester, meshService);

      meshService.emitStatus(_status(queueMessages: null, isOnline: false));
      await tester.pump();
      expect(find.text('Queue information unavailable'), findsOneWidget);
      expect(find.text('🔌 Offline'), findsOneWidget);

      meshService.emitStatus(_status(queueMessages: const []));
      await tester.pump();
      expect(find.text('No messages in relay queue'), findsOneWidget);
      expect(find.text('🌐 Online'), findsOneWidget);
    });

    testWidgets('renders queued messages and queue-level actions', (
      tester,
    ) async {
      final meshService = _FakeMeshNetworkingService()..retryAllResult = 2;
      addTearDown(meshService.close);
      await _pumpRelayQueueWidget(tester, meshService);

      final retryingRelay = _queued(
        id: 'msg-retrying-12345678901234567',
        content: 'Relay payload content',
        priority: MessagePriority.high,
        status: QueuedMessageStatus.retrying,
        attempts: 1,
        isRelayMessage: true,
        relayMetadata: _relayMetadata(),
        nextRetryAt: DateTime.now().add(const Duration(seconds: 10)),
      );
      final directPending = _queued(
        id: 'msg-pending-12345678901234567',
        content: 'Direct payload content',
        priority: MessagePriority.normal,
        status: QueuedMessageStatus.pending,
      );

      meshService.emitStatus(
        _status(
          queueMessages: [retryingRelay, directPending],
          pending: 1,
          retrying: 1,
        ),
      );
      await tester.pump();

      expect(find.text('📤 Relay Queue'), findsOneWidget);
      expect(
        find.text('1 pending • 1 retrying • Ready to deliver'),
        findsOneWidget,
      );
      expect(find.textContaining('Retrying message delivery'), findsOneWidget);
      expect(
        find.textContaining('Direct: "Direct payload content"'),
        findsOneWidget,
      );
      expect(find.byType(PopupMenuButton<String>), findsNWidgets(2));
      expect(find.text('Retry All'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);

      await tester.tap(find.text('Retry All'));
      await tester.pumpAndSettle();
      expect(meshService.retryAllCalls, 1);
      expect(find.textContaining('Retrying 2 failed messages'), findsOneWidget);
    });

    testWidgets('clear action shows snackbar message', (tester) async {
      final meshService = _FakeMeshNetworkingService();
      addTearDown(meshService.close);
      await _pumpRelayQueueWidget(tester, meshService);

      final pending = _queued(
        id: 'msg-clear-12345678901234567',
        content: 'Clear payload content',
        priority: MessagePriority.normal,
        status: QueuedMessageStatus.pending,
      );

      meshService.emitStatus(_status(queueMessages: [pending], pending: 1));
      await tester.pump();

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Failed messages cleared'), findsOneWidget);
    });

    testWidgets('renders sending message state without popup action', (
      tester,
    ) async {
      final meshService = _FakeMeshNetworkingService();
      addTearDown(meshService.close);
      await _pumpRelayQueueWidget(tester, meshService);

      final sending = _queued(
        id: 'msg-sending-12345678901234567',
        content: 'Sending payload content',
        priority: MessagePriority.low,
        status: QueuedMessageStatus.sending,
      );

      meshService.emitStatus(_status(queueMessages: [sending], sending: 1));
      await tester.pump();

      expect(find.text('Sending message...'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    });

    testWidgets('invokes retry, priority, and remove item actions', (
      tester,
    ) async {
      final meshService = _FakeMeshNetworkingService();
      addTearDown(meshService.close);
      await _pumpRelayQueueWidget(tester, meshService);

      final message = _queued(
        id: 'msg-action-12345678901234567',
        content: 'Action payload content',
        priority: MessagePriority.normal,
        status: QueuedMessageStatus.pending,
      );

      meshService.emitStatus(_status(queueMessages: [message], pending: 1));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry Now'));
      await tester.pumpAndSettle();
      expect(meshService.retriedMessageId, message.id);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set High Priority'));
      await tester.pumpAndSettle();
      expect(meshService.priorityMessageId, message.id);
      expect(meshService.priorityValue, MessagePriority.high);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(meshService.removedMessageId, message.id);
    });

    testWidgets('shows error snackbar when retry action throws', (
      tester,
    ) async {
      final meshService = _FakeMeshNetworkingService()
        ..retryMessageError = StateError('forced retry failure');
      addTearDown(meshService.close);
      await _pumpRelayQueueWidget(tester, meshService);

      final message = _queued(
        id: 'msg-error-12345678901234567',
        content: 'Error payload content',
        priority: MessagePriority.normal,
        status: QueuedMessageStatus.pending,
      );

      meshService.emitStatus(_status(queueMessages: [message], pending: 1));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry Now'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Error retrying message'), findsOneWidget);
    });
  });
}
