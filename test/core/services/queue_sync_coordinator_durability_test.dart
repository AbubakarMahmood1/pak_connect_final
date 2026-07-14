import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/queue_sync_coordinator.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  test('failed synced-message write is not published in memory', () async {
    final repository = _FailingQueueRepository();
    final coordinator = QueueSyncCoordinator(repository: repository);
    final message = QueuedMessage(
      id: 'sync-message-1',
      chatId: 'chat-1',
      content: 'sync payload',
      recipientPublicKey: 'recipient-key',
      senderPublicKey: 'sender-key',
      priority: MessagePriority.normal,
      queuedAt: DateTime.utc(2026, 7, 13),
      maxRetries: 5,
      status: QueuedMessageStatus.failed,
      attempts: 3,
      failedAt: DateTime.utc(2026, 7, 13, 1),
      failureReason: 'remote state',
    );

    await expectLater(
      coordinator.addSyncedMessage(message),
      throwsA(isA<StateError>()),
    );
    expect(repository.messages, isEmpty);
    expect(message.status, QueuedMessageStatus.failed);
    expect(message.attempts, 3);
    expect(message.failureReason, 'remote state');
  });

  test('synced admission detaches caller-owned relay metadata', () async {
    final repository = _FailingQueueRepository(failSave: false);
    final coordinator = QueueSyncCoordinator(repository: repository);
    final attachments = <String>['attachment-a'];
    final routingPath = <String>['node-a'];
    final metadata = RelayMetadata(
      ttl: 4,
      hopCount: 1,
      routingPath: routingPath,
      messageHash: 'relay-hash',
      priority: MessagePriority.normal,
      relayTimestamp: DateTime.utc(2026, 7, 13),
      originalSender: 'sender',
      finalRecipient: 'recipient',
    );
    final message = QueuedMessage(
      id: 'sync-relay-alias',
      chatId: 'chat-relay',
      content: 'relay payload',
      recipientPublicKey: 'recipient',
      senderPublicKey: 'sender',
      priority: MessagePriority.normal,
      queuedAt: DateTime.utc(2026, 7, 13),
      maxRetries: 5,
      attachments: attachments,
      isRelayMessage: true,
      relayMetadata: metadata,
      originalMessageId: 'original-relay',
    );

    expect(await coordinator.addSyncedMessage(message), isTrue);
    attachments.add('attachment-b');
    routingPath.add('node-b');

    final admitted = repository.messages.single;
    expect(admitted.attachments, <String>['attachment-a']);
    expect(admitted.relayMetadata!.routingPath, <String>['node-a']);
    expect(admitted.attachments, isNot(same(attachments)));
    expect(admitted.relayMetadata, isNot(same(metadata)));
  });

  test('failed tombstone transaction publishes no deleted ID', () async {
    final deletedIds = <MessageId>{};
    final repository = _FailingQueueRepository(failMarkDeleted: true);
    final coordinator = QueueSyncCoordinator(
      repository: repository,
      deletedMessageIds: deletedIds,
    );

    await expectLater(
      coordinator.markMessageDeleted('message-1'),
      throwsA(isA<StateError>()),
    );

    expect(deletedIds, isEmpty);
    expect(coordinator.isMessageDeleted('message-1'), isFalse);
  });

  test('failed tombstone pruning preserves the exact original set', () async {
    final deletedIds = <MessageId>{
      for (var index = 0; index < 1001; index++) MessageId('message-$index'),
    };
    final original = Set<MessageId>.of(deletedIds);
    final repository = _FailingQueueRepository(failPrune: true);
    final coordinator = QueueSyncCoordinator(
      repository: repository,
      deletedMessageIds: deletedIds,
    );

    await expectLater(
      coordinator.cleanupOldDeletedIds(),
      throwsA(isA<StateError>()),
    );

    expect(deletedIds, original);
  });

  test('failed durable reset preserves tombstones and sync state', () async {
    final deletedIds = <MessageId>{const MessageId('message-1')};
    final repository = _FailingQueueRepository(failTombstoneSnapshot: true);
    final coordinator = QueueSyncCoordinator(
      repository: repository,
      deletedMessageIds: deletedIds,
    );
    final hashBefore = coordinator.calculateQueueHash();

    await expectLater(coordinator.resetSyncState(), throwsA(isA<StateError>()));

    expect(deletedIds, {const MessageId('message-1')});
    expect(coordinator.calculateQueueHash(), hashBefore);
  });

  test(
    'durable tombstone conflict is learned without publishing a row',
    () async {
      final repository = _FailingQueueRepository(
        failSave: false,
        atomicResult: const QueueStateTransitionResult(
          applied: false,
          current: null,
        ),
      );
      final coordinator = QueueSyncCoordinator(repository: repository);
      final message = _message('durably-deleted');

      expect(await coordinator.addSyncedMessage(message), isFalse);
      expect(repository.messages, isEmpty);
      expect(coordinator.isMessageDeleted(message.id), isTrue);
    },
  );

  test('newer durable attempt is reconciled instead of overwritten', () async {
    final current = _message('newer-attempt')
      ..status = QueuedMessageStatus.sending
      ..attempts = 2
      ..lastAttemptAt = DateTime.utc(2026, 7, 13, 14);
    final repository = _FailingQueueRepository(
      failSave: false,
      atomicResult: QueueStateTransitionResult(
        applied: false,
        current: current,
      ),
    );
    final coordinator = QueueSyncCoordinator(repository: repository);

    expect(
      await coordinator.addSyncedMessage(_message('newer-attempt')),
      isFalse,
    );
    expect(repository.messages, hasLength(1));
    expect(repository.messages.single.status, QueuedMessageStatus.sending);
    expect(repository.messages.single.attempts, 2);
  });
}

QueuedMessage _message(String id) => QueuedMessage(
  id: id,
  chatId: 'chat-$id',
  content: 'content-$id',
  recipientPublicKey: 'recipient',
  senderPublicKey: 'sender',
  priority: MessagePriority.normal,
  queuedAt: DateTime.utc(2026, 7, 13),
  maxRetries: 5,
);

class _FailingQueueRepository extends Fake
    implements IMessageQueueRepository, IConditionalMessageQueueRepository {
  _FailingQueueRepository({
    this.failSave = true,
    this.failMarkDeleted = false,
    this.failPrune = false,
    this.failTombstoneSnapshot = false,
    this.atomicResult,
  });

  final bool failSave;
  final bool failMarkDeleted;
  final bool failPrune;
  final bool failTombstoneSnapshot;
  final QueueStateTransitionResult? atomicResult;
  final List<QueuedMessage> messages = [];

  @override
  Future<QueueStateTransitionResult> insertMessageIfAbsentAndNotDeleted(
    QueuedMessage message,
  ) async {
    if (failSave) throw StateError('sync persistence failed');
    return atomicResult ??
        QueueStateTransitionResult(applied: true, current: message);
  }

  @override
  List<QueuedMessage> getAllMessages() => List.unmodifiable(messages);

  @override
  QueuedMessage? getMessageById(String messageId) {
    for (final message in messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  @override
  void insertMessageByPriority(QueuedMessage message) {
    messages.add(message);
  }

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    if (failSave) throw StateError('sync persistence failed');
  }

  @override
  Future<void> markMessagesDeleted(Iterable<String> messageIds) async {
    if (failMarkDeleted) throw StateError('tombstone transaction failed');
  }

  @override
  Future<Set<String>> pruneDeletedMessageIds(int maxRetained) async {
    if (failPrune) throw StateError('tombstone prune failed');
    return const <String>{};
  }

  @override
  Future<void> saveDeletedIdsSnapshotToStorage(
    Iterable<String> messageIds,
  ) async {
    if (failTombstoneSnapshot) {
      throw StateError('tombstone snapshot failed');
    }
  }
}
