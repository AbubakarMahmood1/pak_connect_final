import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';

void main() {
  group('OfflineMessageQueue durable mutations', () {
    late _MutationRepository repository;
    late _RetryScheduler scheduler;
    late OfflineMessageQueue queue;

    setUp(() async {
      repository = _MutationRepository();
      scheduler = _RetryScheduler();
      queue = OfflineMessageQueue(
        queueRepository: repository,
        queuePersistenceManager: _PersistenceManager(),
        retryScheduler: scheduler,
      );
      await queue.initialize();
    });

    tearDown(() => queue.dispose());

    test(
      'delivered delete failure preserves live state and observers',
      () async {
        final message = _message(
          'delivered-failure',
          status: QueuedMessageStatus.awaitingAck,
        );
        repository.messages.add(message);
        repository.failDelete = true;
        var deliveredCallbacks = 0;
        queue.onMessageDelivered = (_) => deliveredCallbacks++;

        await expectLater(
          queue.markMessageDelivered(message.id),
          throwsA(isA<StateError>()),
        );

        expect(queue.getMessageById(message.id), same(message));
        expect(message.status, QueuedMessageStatus.awaitingAck);
        expect(message.deliveredAt, isNull);
        expect(deliveredCallbacks, 0);
        expect(queue.getStatistics().totalDelivered, 0);
      },
    );

    test('remove failure preserves message and retry timer', () async {
      final message = _message(
        'remove-failure',
        status: QueuedMessageStatus.retrying,
      );
      repository.messages.add(message);
      scheduler.registerRetryTimer(message.id, Duration.zero, () {});
      repository.failDelete = true;

      await expectLater(
        queue.removeMessage(message.id),
        throwsA(isA<StateError>()),
      );

      expect(queue.getMessageById(message.id), same(message));
      expect(scheduler.isScheduled(message.id), isTrue);
    });

    test(
      'priority save failure preserves priority and repository order',
      () async {
        final first = _message('first', priority: MessagePriority.normal);
        final second = _message('second', priority: MessagePriority.low);
        repository.messages.addAll([first, second]);
        repository.failSave = true;

        expect(
          await queue.changePriority(first.id, MessagePriority.urgent),
          isFalse,
        );

        expect(first.priority, MessagePriority.normal);
        expect(repository.messages.map((message) => message.id), [
          first.id,
          second.id,
        ]);
      },
    );

    test('retry reset failure preserves every failed-state field', () async {
      final failedAt = DateTime.utc(2026, 7, 13, 1);
      final lastAttemptAt = DateTime.utc(2026, 7, 13);
      final message =
          _message('retry-failure', status: QueuedMessageStatus.failed)
            ..attempts = 4
            ..lastAttemptAt = lastAttemptAt
            ..failedAt = failedAt
            ..failureReason = 'old failure';
      repository.messages.add(message);
      repository.failSave = true;

      await expectLater(
        queue.retryMessage(message.id),
        throwsA(isA<StateError>()),
      );

      expect(message.status, QueuedMessageStatus.failed);
      expect(message.attempts, 4);
      expect(message.lastAttemptAt, lastAttemptAt);
      expect(message.failedAt, failedAt);
      expect(message.failureReason, 'old failure');
    });

    test(
      'clear failure preserves injected repository rows and timers',
      () async {
        final first = _message('clear-a');
        final second = _message('clear-b');
        repository.messages.addAll([first, second]);
        scheduler.registerRetryTimer(first.id, Duration.zero, () {});
        repository.failQueueSnapshot = true;

        await expectLater(queue.clearQueue(), throwsA(isA<StateError>()));

        expect(repository.messages, [first, second]);
        expect(scheduler.isScheduled(first.id), isTrue);
      },
    );

    test('successful clear removes injected repository rows', () async {
      repository.messages.addAll([_message('clear-a'), _message('clear-b')]);

      await queue.clearQueue();

      expect(repository.messages, isEmpty);
      expect(queue.getStatistics().pendingMessages, 0);
    });

    test('loaded repository tombstones are visible to queue sync', () async {
      queue.dispose();
      repository = _MutationRepository(deletedIds: {'deleted-before-start'});
      queue = OfflineMessageQueue(
        queueRepository: repository,
        queuePersistenceManager: _PersistenceManager(),
        retryScheduler: scheduler,
      );

      await queue.initialize();

      expect(queue.isMessageDeleted('deleted-before-start'), isTrue);
    });

    test(
      'admission detaches caller-owned attachments and relay path',
      () async {
        final attachments = <String>['attachment-a'];
        final routingPath = <String>['node-a'];
        final relayMetadata = RelayMetadata(
          ttl: 4,
          hopCount: 1,
          routingPath: routingPath,
          messageHash: 'hash-a',
          priority: MessagePriority.normal,
          relayTimestamp: DateTime.utc(2026, 7, 13),
          originalSender: 'sender',
          finalRecipient: 'recipient',
        );

        final messageId = await queue.queueMessage(
          chatId: 'chat-alias',
          content: 'payload',
          recipientPublicKey: 'recipient',
          senderPublicKey: 'sender',
          attachments: attachments,
          isRelayMessage: true,
          relayMetadata: relayMetadata,
          originalMessageId: 'original-alias',
        );
        attachments.add('attachment-b');
        routingPath.add('node-b');

        final admitted = queue.getMessageById(messageId)!;
        expect(admitted.attachments, <String>['attachment-a']);
        expect(admitted.relayMetadata!.routingPath, <String>['node-a']);
        expect(admitted.attachments, isNot(same(attachments)));
        expect(admitted.relayMetadata, isNot(same(relayMetadata)));
      },
    );

    test(
      'concurrent admissions cannot overrun the regular-peer limit',
      () async {
        repository.messages.addAll(<QueuedMessage>[
          for (var index = 0; index < 99; index++)
            _message('existing-$index', recipientPublicKey: 'same-peer'),
        ]);
        repository.saveGate = Completer<void>();

        final firstAdmission = queue.queueMessage(
          chatId: 'chat-first',
          content: 'first',
          recipientPublicKey: 'same-peer',
          senderPublicKey: 'sender',
        );
        await repository.saveStarted.future;
        final secondAdmission = queue.queueMessage(
          chatId: 'chat-second',
          content: 'second',
          recipientPublicKey: 'same-peer',
          senderPublicKey: 'sender',
        );

        repository.saveGate!.complete();
        await firstAdmission;
        await expectLater(
          secondAdmission,
          throwsA(isA<MessageQueueException>()),
        );

        expect(
          repository.messages.where(
            (message) => message.recipientPublicKey == 'same-peer',
          ),
          hasLength(100),
        );
      },
    );

    test('dispose during admission rolls back the durable row', () async {
      repository.saveGate = Completer<void>();
      var queuedNotifications = 0;
      queue.onMessageQueued = (_) => queuedNotifications++;

      final admission = queue.queueMessage(
        chatId: 'chat-dispose',
        content: 'dispose race',
        recipientPublicKey: 'recipient-dispose',
        senderPublicKey: 'sender',
      );
      await repository.saveStarted.future;
      queue.dispose();
      repository.saveGate!.complete();

      await expectLater(admission, throwsA(isA<MessageQueueException>()));
      expect(repository.savedToStorage, hasLength(1));
      expect(repository.deletedFromStorage, repository.savedToStorage);
      expect(repository.messages, isEmpty);
      expect(queuedNotifications, 0);
    });

    test('throwing observers cannot undo a committed delivery', () async {
      final message = _message(
        'observer-failure',
        status: QueuedMessageStatus.awaitingAck,
      );
      repository.messages.add(message);
      queue.onMessageDelivered = (_) => throw StateError('observer failed');
      queue.onStatsUpdated = (_) => throw StateError('stats failed');

      await queue.markMessageDelivered(message.id);

      expect(queue.getMessageById(message.id), isNull);
      expect(repository.deletedFromStorage, contains(message.id));
      expect(queue.getStatistics().totalDelivered, 1);
    });

    test('terminal failure is counted once', () async {
      final message = _message(
        'terminal-failure',
        status: QueuedMessageStatus.sending,
        maxRetries: 2,
      )..attempts = 2;
      repository.messages.add(message);
      var failedCallbacks = 0;
      queue.onMessageFailed = (_, _) => failedCallbacks++;

      await queue.markMessageFailed(message.id, 'final failure');
      await queue.markMessageFailed(message.id, 'duplicate failure');

      expect(message.status, QueuedMessageStatus.failed);
      expect(queue.getStatistics().totalFailed, 1);
      expect(failedCallbacks, 1);
    });
  });
}

QueuedMessage _message(
  String id, {
  QueuedMessageStatus status = QueuedMessageStatus.pending,
  MessagePriority priority = MessagePriority.normal,
  int maxRetries = 5,
  String? recipientPublicKey,
}) => QueuedMessage(
  id: id,
  chatId: 'chat-$id',
  content: 'content-$id',
  recipientPublicKey: recipientPublicKey ?? 'recipient-$id',
  senderPublicKey: 'sender',
  priority: priority,
  queuedAt: DateTime.utc(2026, 7, 13),
  maxRetries: maxRetries,
  status: status,
);

class _MutationRepository extends Fake implements IMessageQueueRepository {
  _MutationRepository({Set<String>? deletedIds})
    : deletedIds = deletedIds ?? <String>{};

  final List<QueuedMessage> messages = <QueuedMessage>[];
  final Set<String> deletedIds;
  final List<String> deletedFromStorage = <String>[];
  final List<String> savedToStorage = <String>[];
  final Completer<void> saveStarted = Completer<void>();
  Completer<void>? saveGate;
  bool failSave = false;
  bool failDelete = false;
  bool failQueueSnapshot = false;

  @override
  Future<void> loadQueueFromStorage() async {}

  @override
  Future<void> loadDeletedMessageIds() async {}

  @override
  Set<String> getDeletedMessageIdsSnapshot() => Set<String>.of(deletedIds);

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    if (failSave) throw StateError('message save failed');
    if (!saveStarted.isCompleted) saveStarted.complete();
    final gate = saveGate;
    if (gate != null) await gate.future;
    savedToStorage.add(message.id);
  }

  @override
  Future<void> deleteMessageFromStorage(String messageId) async {
    if (failDelete) throw StateError('message delete failed');
    deletedFromStorage.add(messageId);
  }

  @override
  Future<void> deleteMessagesFromStorage(Iterable<String> messageIds) async {
    if (failDelete) throw StateError('message delete failed');
    deletedFromStorage.addAll(messageIds);
  }

  @override
  Future<void> saveQueueSnapshotToStorage(
    Iterable<QueuedMessage> messages,
  ) async {
    if (failQueueSnapshot) throw StateError('queue snapshot failed');
  }

  @override
  List<QueuedMessage> getAllMessages() => List<QueuedMessage>.of(messages);

  @override
  void insertMessageByPriority(QueuedMessage message) {
    messages.add(message);
    messages.sort((left, right) {
      final priority = right.priority.index.compareTo(left.priority.index);
      return priority != 0 ? priority : left.queuedAt.compareTo(right.queuedAt);
    });
  }

  @override
  void removeMessageFromQueue(String messageId) {
    messages.removeWhere((message) => message.id == messageId);
  }

  @override
  Future<void> markMessagesDeleted(Iterable<String> messageIds) async {
    final ids = messageIds.toSet();
    deletedIds.addAll(ids);
    messages.removeWhere((message) => ids.contains(message.id));
  }
}

class _PersistenceManager extends Fake implements IQueuePersistenceManager {
  @override
  Future<bool> createQueueTablesIfNotExist() async => true;
}

class _RetryScheduler extends Fake implements IRetryScheduler {
  final Map<String, FutureOr<void> Function()> callbacks =
      <String, FutureOr<void> Function()>{};

  @override
  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  ) => callbacks[messageId] = callback;

  @override
  void cancelRetryTimer(String messageId) => callbacks.remove(messageId);

  @override
  void cancelAllRetryTimers() => callbacks.clear();

  @override
  bool isScheduled(String messageId) => callbacks.containsKey(messageId);

  @override
  List<String> getScheduledMessageIds() => callbacks.keys.toList();

  @override
  bool shouldRetry(
    String messageId,
    DateTime? lastAttemptAt,
    int attempts,
    int maxRetries,
    DateTime? expiresAt,
  ) => attempts < maxRetries;

  @override
  Duration calculateBackoffDelay(int attempt) => Duration.zero;

  @override
  int getMaxRetriesForPriority(MessagePriority priority, int baseMaxRetries) =>
      baseMaxRetries;

  @override
  DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority) =>
      queuedAt.add(const Duration(hours: 1));

  @override
  bool isMessageExpired(QueuedMessage message) => false;
}
