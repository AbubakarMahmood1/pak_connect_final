import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/relay_send_pipeline.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';
import 'package:pak_connect/core/models/message_priority.dart';
import 'package:pak_connect/core/security/spam_prevention_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('RelaySendPipeline persistence policy', () {
    late _RecordingQueue queue;
    late RelaySendPipeline pipeline;
    late _StubSpamPreventionManager spam;

    setUp(() {
      queue = _RecordingQueue();
      spam = _StubSpamPreventionManager();
      pipeline = RelaySendPipeline(
        logger: Logger('RelaySendPipelineTest'),
        messageQueue: queue,
        spamPrevention: spam,
      );
    });

    test('origin relays persist while intermediates are transient', () async {
      final originMeta = RelayMetadata.create(
        originalMessageContent: 'hello',
        priority: MessagePriority.normal,
        originalSender: 'origin',
        finalRecipient: 'final',
        currentNodeId: 'origin',
      );
      final originMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-1',
        originalContent: 'hello',
        metadata: originMeta,
        relayNodeId: 'origin',
      );

      await pipeline.relayToNextHop(
        relayMessage: originMessage,
        nextHopNodeId: 'peer-a',
      );

      expect(queue.records, hasLength(1));
      final originRecord = queue.records.first;
      expect(originRecord.persistToStorage, isTrue);
      expect(originRecord.isRelay, isTrue);
      expect(originRecord.recipient, 'peer-a');
      expect(originRecord.originalMessageId, 'msg-1');

      queue.records.clear();

      final intermediateMeta = originMeta.nextHop('peer-a');
      final intermediateMessage = MeshRelayMessage.createRelay(
        originalMessageId: 'msg-1',
        originalContent: 'hello',
        metadata: intermediateMeta,
        relayNodeId: 'peer-a',
      );

      await pipeline.relayToNextHop(
        relayMessage: intermediateMessage,
        nextHopNodeId: 'peer-b',
      );

      expect(queue.records, hasLength(1));
      final intermediateRecord = queue.records.first;
      expect(intermediateRecord.persistToStorage, isFalse);
      expect(intermediateRecord.isRelay, isTrue);
      expect(intermediateRecord.recipient, 'peer-b');
      expect(intermediateRecord.originalMessageId, 'msg-1');
    });
  });
}

class _RecordingQueue extends OfflineMessageQueue {
  final List<_QueueRecord> records = [];

  @override
  Future<MessageId> queueMessageWithIds({
    required ChatId chatId,
    required String content,
    required ChatId recipientId,
    required ChatId senderId,
    MessagePriority priority = MessagePriority.normal,
    MessageId? replyToMessageId,
    List<String> attachments = const [],
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  }) async {
    final id = MessageId('rec_${records.length}');
    records.add(
      _QueueRecord(
        id: id,
        chatId: chatId.value,
        recipient: recipientId.value,
        sender: senderId.value,
        priority: priority,
        isRelay: isRelayMessage,
        relayMetadata: relayMetadata,
        originalMessageId: originalMessageId,
        relayNodeId: relayNodeId,
        messageHash: messageHash,
        persistToStorage: persistToStorage,
      ),
    );
    return id;
  }
}

class _QueueRecord {
  final MessageId id;
  final String chatId;
  final String recipient;
  final String sender;
  final MessagePriority priority;
  final bool isRelay;
  final RelayMetadata? relayMetadata;
  final String? originalMessageId;
  final String? relayNodeId;
  final String? messageHash;
  final bool persistToStorage;

  _QueueRecord({
    required this.id,
    required this.chatId,
    required this.recipient,
    required this.sender,
    required this.priority,
    required this.isRelay,
    required this.relayMetadata,
    required this.originalMessageId,
    required this.relayNodeId,
    required this.messageHash,
    required this.persistToStorage,
  });
}

class _StubSpamPreventionManager extends SpamPreventionManager {
  @override
  Future<void> initialize() async {}

  @override
  SpamPreventionStatistics getStatistics() => const SpamPreventionStatistics(
    totalAllowed: 0,
    totalBlocked: 0,
    blockRate: 0,
    averageSpamScore: 0,
    activeTrustScores: 0,
    processedHashes: 0,
  );

  @override
  Future<SpamCheckResult> checkIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    required String currentNodeId,
  }) async => const SpamCheckResult(
    allowed: true,
    spamScore: 0,
    reason: 'stub-allowed',
    checks: [],
  );

  @override
  Future<SpamCheckResult> checkOutgoingRelay({
    required String senderNodeId,
    required int messageSize,
  }) async => const SpamCheckResult(
    allowed: true,
    spamScore: 0,
    reason: 'stub-allowed',
    checks: [],
  );

  @override
  Future<void> recordRelayOperation({
    required String fromNodeId,
    required String toNodeId,
    required String messageHash,
    required int messageSize,
  }) async {}

  @override
  void clearStatistics() {}

  @override
  void dispose() {}
}
