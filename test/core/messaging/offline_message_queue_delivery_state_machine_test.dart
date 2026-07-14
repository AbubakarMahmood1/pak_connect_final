import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';

void main() {
  group('OfflineMessageQueue delivery state machine', () {
    late _RecordingQueueRepository repository;
    late _ControlledRetryScheduler scheduler;
    late OfflineMessageQueue queue;

    setUp(() async {
      repository = _RecordingQueueRepository();
      scheduler = _ControlledRetryScheduler();
      queue = OfflineMessageQueue(
        queueRepository: repository,
        queuePersistenceManager: _PersistenceManager(),
        retryScheduler: scheduler,
      );
      await queue.initialize();
    });

    tearDown(() {
      queue.dispose();
    });

    test(
      'awaits async false and schedules a retry without ACK cooldown',
      () async {
        final message = _message('async-false');
        repository.messages.add(message);
        DateTime? retryPolicyLastAttempt;
        scheduler.onShouldRetry =
            ({required lastAttemptAt, required attempts}) {
              retryPolicyLastAttempt = lastAttemptAt;
              return attempts < 5;
            };
        queue.onSendMessage = (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return OfflineQueueSendDisposition.failed;
        };

        await queue.setOnline();
        await _waitFor(() => message.status == QueuedMessageStatus.retrying);

        expect(message.attempts, 1);
        expect(retryPolicyLastAttempt, isNull);
        expect(scheduler.isScheduled(message.id), isTrue);
        expect(
          repository.savedStatusesFor(message.id),
          containsAllInOrder(<QueuedMessageStatus>[
            QueuedMessageStatus.sending,
            QueuedMessageStatus.retrying,
          ]),
        );
      },
    );

    test(
      'suppresses duplicate sends while an async callback is in flight',
      () async {
        final message = _message('in-flight');
        repository.messages.add(message);
        final callbackStarted = Completer<void>();
        final sendResult = Completer<OfflineQueueSendDisposition>();
        var sendCalls = 0;
        queue.onSendMessage = (_) {
          sendCalls++;
          if (!callbackStarted.isCompleted) callbackStarted.complete();
          return sendResult.future;
        };

        await queue.setOnline();
        await callbackStarted.future;
        await queue.setOnline();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(sendCalls, 1);
        expect(message.status, QueuedMessageStatus.sending);
        expect(repository.deletedIds, isEmpty);

        sendResult.complete(OfflineQueueSendDisposition.delivered);
        await _waitFor(() => queue.getMessageById(message.id) == null);

        expect(sendCalls, 1);
        expect(repository.deletedIds, <String>[message.id]);
      },
    );

    test(
      'deferred routes do not consume attempts or schedule retries',
      () async {
        final message = _message('wrong-peer');
        repository.messages.add(message);
        var sendCalls = 0;
        queue.onSendMessage = (_) async {
          sendCalls++;
          return OfflineQueueSendDisposition.deferred;
        };

        await queue.setOnline();
        await _waitFor(() => sendCalls == 1);

        expect(message.status, QueuedMessageStatus.pending);
        expect(message.attempts, 0);
        expect(message.lastAttemptAt, isNull);
        expect(scheduler.isScheduled(message.id), isFalse);
        expect(
          repository.savedStatusesFor(message.id),
          containsAllInOrder(<QueuedMessageStatus>[
            QueuedMessageStatus.sending,
            QueuedMessageStatus.pending,
          ]),
        );

        await queue.setOnline();
        await _waitFor(() => sendCalls == 2);
        expect(message.attempts, 0);
      },
    );

    test('an ACK completed during callback cannot be resurrected', () async {
      final message = _message('fast-ack');
      repository.messages.add(message);
      queue.onSendMessage = (_) async {
        await queue.markMessageDelivered(message.id);
        return OfflineQueueSendDisposition.delivered;
      };

      await queue.setOnline();
      await _waitFor(() => queue.getMessageById(message.id) == null);

      expect(repository.deletedIds, <String>[message.id]);
      expect(
        repository.savedStatusesFor(message.id),
        isNot(contains(QueuedMessageStatus.awaitingAck)),
      );
    });

    test('relay success persists ACK wait and owns its ACK timeout', () async {
      final message = _message('relay', isRelayMessage: true);
      repository.messages.add(message);
      queue.onSendMessage = (_) async =>
          OfflineQueueSendDisposition.awaitingAck;

      await queue.setOnline();
      await _waitFor(() => message.status == QueuedMessageStatus.awaitingAck);

      expect(scheduler.isScheduled(message.id), isTrue);
      expect(
        repository.savedStatusesFor(message.id),
        contains(QueuedMessageStatus.awaitingAck),
      );

      await scheduler.fire(message.id);

      expect(message.status, QueuedMessageStatus.retrying);
      expect(message.failureReason, 'ACK timeout');
      expect(scheduler.isScheduled(message.id), isTrue);
    });

    test(
      'delivered finalization retries deletion offline without resending',
      () async {
        final message = _message('delivered-finalization');
        repository.messages.add(message);
        repository.failNextDelete(message.id);
        var sendCalls = 0;
        queue.onSendMessage = (_) async {
          sendCalls++;
          return OfflineQueueSendDisposition.delivered;
        };

        await queue.setOnline();
        await _waitFor(() => repository.deleteAttemptsFor(message.id) == 1);

        expect(message.status, QueuedMessageStatus.sending);
        expect(await queue.retryMessage(message.id), isFalse);
        queue.setOffline();

        await _waitFor(() => queue.getMessageById(message.id) == null);
        expect(sendCalls, 1);
        expect(repository.deleteAttemptsFor(message.id), 2);
        expect(repository.deletedIds, <String>[message.id]);
      },
    );

    test(
      'awaiting-ACK finalization retries storage and keeps remaining timeout',
      () async {
        final message = _message('ack-finalization', isRelayMessage: true);
        repository.messages.add(message);
        repository.failNextSave(message.id, QueuedMessageStatus.awaitingAck);
        var sendCalls = 0;
        queue.onSendMessage = (_) async {
          sendCalls++;
          return OfflineQueueSendDisposition.awaitingAck;
        };

        await queue.setOnline();
        await _waitFor(
          () =>
              repository.saveAttemptsFor(
                message.id,
                QueuedMessageStatus.awaitingAck,
              ) ==
              1,
        );

        expect(message.status, QueuedMessageStatus.sending);
        expect(await queue.retryMessage(message.id), isFalse);
        expect(scheduler.isScheduled(message.id), isFalse);

        await _waitFor(() => message.status == QueuedMessageStatus.awaitingAck);
        expect(sendCalls, 1);
        expect(
          repository.saveAttemptsFor(
            message.id,
            QueuedMessageStatus.awaitingAck,
          ),
          2,
        );
        expect(scheduler.isScheduled(message.id), isTrue);
        expect(
          scheduler.delayFor(message.id),
          lessThan(const Duration(seconds: 5)),
        );
      },
    );

    test('deferred finalization retries only the pre-attempt state', () async {
      final message = _message('deferred-finalization');
      repository.messages.add(message);
      repository.failNextSave(message.id, QueuedMessageStatus.pending);
      var sendCalls = 0;
      queue.onSendMessage = (_) async {
        sendCalls++;
        return OfflineQueueSendDisposition.deferred;
      };

      await queue.setOnline();
      await _waitFor(
        () =>
            repository.saveAttemptsFor(
              message.id,
              QueuedMessageStatus.pending,
            ) ==
            1,
      );

      expect(message.status, QueuedMessageStatus.sending);
      expect(message.attempts, 1);
      expect(await queue.retryMessage(message.id), isFalse);

      await _waitFor(() => message.status == QueuedMessageStatus.pending);
      expect(sendCalls, 1);
      expect(message.attempts, 0);
      expect(message.lastAttemptAt, isNull);
      expect(scheduler.isScheduled(message.id), isFalse);
    });

    test(
      'failed finalization retries storage then installs remaining backoff',
      () async {
        final message = _message('failed-finalization');
        repository.messages.add(message);
        repository.failNextSave(message.id, QueuedMessageStatus.retrying);
        var sendCalls = 0;
        queue.onSendMessage = (_) async {
          sendCalls++;
          return OfflineQueueSendDisposition.failed;
        };

        await queue.setOnline();
        await _waitFor(
          () =>
              repository.saveAttemptsFor(
                message.id,
                QueuedMessageStatus.retrying,
              ) ==
              1,
        );

        expect(message.status, QueuedMessageStatus.sending);
        expect(await queue.retryMessage(message.id), isFalse);
        expect(scheduler.isScheduled(message.id), isFalse);

        await _waitFor(() => message.status == QueuedMessageStatus.retrying);
        expect(sendCalls, 1);
        expect(message.attempts, 1);
        expect(scheduler.isScheduled(message.id), isTrue);
        expect(scheduler.delayFor(message.id), Duration.zero);
      },
    );

    test('terminal failure finalization publishes failure once', () async {
      final message = _message('terminal-finalization');
      repository.messages.add(message);
      repository.failNextSave(message.id, QueuedMessageStatus.failed);
      scheduler.onShouldRetry = ({required lastAttemptAt, required attempts}) =>
          false;
      var sendCalls = 0;
      var failedNotifications = 0;
      queue.onMessageFailed = (_, _) => failedNotifications++;
      queue.onSendMessage = (_) async {
        sendCalls++;
        return OfflineQueueSendDisposition.failed;
      };

      await queue.setOnline();
      await _waitFor(() => message.status == QueuedMessageStatus.failed);

      expect(sendCalls, 1);
      expect(failedNotifications, 1);
      expect(
        repository.saveAttemptsFor(message.id, QueuedMessageStatus.failed),
        2,
      );
      expect(scheduler.isScheduled(message.id), isFalse);
    });

    test('dispose drains pending storage-only finalization retries', () async {
      final message = _message('disposed-finalization');
      repository.messages.add(message);
      repository.failNextDelete(message.id);
      var sendCalls = 0;
      queue.onSendMessage = (_) async {
        sendCalls++;
        return OfflineQueueSendDisposition.delivered;
      };

      await queue.setOnline();
      await _waitFor(() => repository.deleteAttemptsFor(message.id) == 1);
      queue.dispose();
      await _waitFor(() => repository.deletedIds.contains(message.id));

      expect(sendCalls, 1);
      expect(repository.deleteAttemptsFor(message.id), 2);
      expect(repository.deletedIds, <String>[message.id]);
    });

    test(
      'dispose while callback is outstanding finalizes its known outcome',
      () async {
        final message = _message('disposed-in-flight');
        repository.messages.add(message);
        final callbackStarted = Completer<void>();
        final outcome = Completer<OfflineQueueSendDisposition>();
        var sendCalls = 0;
        queue.onSendMessage = (_) {
          sendCalls++;
          callbackStarted.complete();
          return outcome.future;
        };

        await queue.setOnline();
        await callbackStarted.future;
        expect(message.status, QueuedMessageStatus.sending);

        queue.dispose();
        outcome.complete(OfflineQueueSendDisposition.delivered);

        await _waitFor(() => repository.deletedIds.contains(message.id));
        expect(sendCalls, 1);
        expect(queue.getMessageById(message.id), isNull);
      },
    );

    test(
      'prepared attempts receipt four admissions before outcomes settle',
      () async {
        await queue.setOnline();
        final messages = List<QueuedMessage>.generate(
          4,
          (index) => _message('prepared-$index'),
        );
        repository.messages.addAll(messages);
        final outcomes =
            <String, Completer<OfflineQueuePreparedSendDisposition>>{
              for (final message in messages)
                message.id: Completer<OfflineQueuePreparedSendDisposition>(),
            };
        final startedIds = <String>[];

        final receipts = await queue
            .attemptMessages(
              messages.map((message) => message.id),
              prepareSend: (messageId) => OfflineQueuePreparedSend(() {
                startedIds.add(messageId);
                return outcomes[messageId]!.future;
              }),
            )
            .timeout(const Duration(milliseconds: 250));

        expect(receipts, messages.map((message) => message.id).toSet());
        expect(startedIds, messages.map((message) => message.id).toList());
        expect(
          messages.map((message) => message.status),
          everyElement(QueuedMessageStatus.sending),
        );
        expect(
          outcomes.values.every((outcome) => !outcome.isCompleted),
          isTrue,
        );

        outcomes[messages[0].id]!.complete(
          OfflineQueuePreparedSendDisposition.delivered,
        );
        outcomes[messages[1].id]!.complete(
          OfflineQueuePreparedSendDisposition.failed,
        );
        outcomes[messages[2].id]!.complete(
          OfflineQueuePreparedSendDisposition.awaitingAck,
        );
        outcomes[messages[3].id]!.complete(
          OfflineQueuePreparedSendDisposition.delivered,
        );

        await _waitFor(
          () =>
              queue.getMessageById(messages[0].id) == null &&
              messages[1].status == QueuedMessageStatus.retrying &&
              messages[2].status == QueuedMessageStatus.awaitingAck &&
              queue.getMessageById(messages[3].id) == null,
        );
      },
    );

    test(
      'a vanished prepared transport is restored and not receipted',
      () async {
        await queue.setOnline();
        final message = _message('prepared-vanished');
        repository.messages.add(message);

        final receipts = await queue.attemptMessages(<String>[
          message.id,
        ], prepareSend: (_) => OfflineQueuePreparedSend(() => null));

        expect(receipts, isEmpty);
        expect(message.status, QueuedMessageStatus.pending);
        expect(message.attempts, 0);
        expect(
          repository.savedStatusesFor(message.id),
          containsAllInOrder(<QueuedMessageStatus>[
            QueuedMessageStatus.sending,
            QueuedMessageStatus.pending,
          ]),
        );
      },
    );

    test(
      'a synchronously failed prepared transport is not receipted or stuck',
      () async {
        await queue.setOnline();
        final message = _message('prepared-sync-failure');
        repository.messages.add(message);

        final receipts = await queue.attemptMessages(
          <String>[message.id],
          prepareSend: (_) => OfflineQueuePreparedSend(
            () => throw StateError('sync admission exploded'),
          ),
        );

        expect(receipts, isEmpty);
        await _waitFor(() => message.status == QueuedMessageStatus.retrying);
        expect(message.attempts, 1);
        expect(message.failureReason, contains('sync admission exploded'));
        expect(
          repository.savedStatusesFor(message.id),
          containsAllInOrder(<QueuedMessageStatus>[
            QueuedMessageStatus.sending,
            QueuedMessageStatus.retrying,
          ]),
        );
      },
    );

    test(
      'attemptMessages reports only exact real transport attempts',
      () async {
        await queue.setOnline();
        final delivered = _message('receipt-delivered');
        final awaiting = _message('receipt-awaiting', isRelayMessage: true);
        final deferred = _message('receipt-deferred');
        final failed = _message('receipt-failed');
        final backoff = _message(
          'receipt-backoff',
          status: QueuedMessageStatus.retrying,
        )..nextRetryAt = DateTime.now().add(const Duration(minutes: 1));
        final notSupplied = _message('receipt-not-supplied');
        repository.messages.addAll(<QueuedMessage>[
          delivered,
          awaiting,
          deferred,
          failed,
          backoff,
          notSupplied,
        ]);
        final sentIds = <String>[];
        queue.onSendMessage = (messageId) async {
          sentIds.add(messageId);
          return switch (messageId) {
            'receipt-delivered' => OfflineQueueSendDisposition.delivered,
            'receipt-awaiting' => OfflineQueueSendDisposition.awaitingAck,
            'receipt-deferred' => OfflineQueueSendDisposition.deferred,
            'receipt-failed' => OfflineQueueSendDisposition.failed,
            _ => throw StateError('Unexpected transport attempt: $messageId'),
          };
        };

        final receipts = await queue.attemptMessages(<String>[
          delivered.id,
          awaiting.id,
          deferred.id,
          failed.id,
          backoff.id,
          'missing',
          delivered.id,
        ]);

        expect(receipts, <String>{delivered.id, awaiting.id, failed.id});
        expect(sentIds, <String>[
          delivered.id,
          awaiting.id,
          deferred.id,
          failed.id,
        ]);
        expect(deferred.status, QueuedMessageStatus.pending);
        expect(backoff.status, QueuedMessageStatus.retrying);
        expect(notSupplied.status, QueuedMessageStatus.pending);

        queue.dispose();
        expect(await queue.attemptMessages(<String>[notSupplied.id]), isEmpty);
      },
    );

    test(
      'attemptMessages does not receipt a missing transport callback',
      () async {
        await queue.setOnline();
        final message = _message('receipt-no-callback');
        repository.messages.add(message);

        final receipts = await queue.attemptMessages(<String>[message.id]);

        expect(receipts, isEmpty);
        expect(message.status, QueuedMessageStatus.retrying);
        expect(
          message.failureReason,
          contains('No queue transport callback configured'),
        );
      },
    );

    test(
      'retry timer persists pending before invoking transport again',
      () async {
        final message = _message('retry-order');
        repository.messages.add(message);
        var calls = 0;
        queue.onSendMessage = (_) async {
          calls++;
          return OfflineQueueSendDisposition.failed;
        };

        await queue.setOnline();
        await _waitFor(() => message.status == QueuedMessageStatus.retrying);
        repository.clearHistory();

        await scheduler.fire(message.id);

        expect(calls, 2);
        expect(
          repository.savedStatusesFor(message.id),
          containsAllInOrder(<QueuedMessageStatus>[
            QueuedMessageStatus.pending,
            QueuedMessageStatus.sending,
            QueuedMessageStatus.retrying,
          ]),
        );
      },
    );

    test(
      'setOnline durably recovers loaded transient states before flush',
      () async {
        final sending = _message(
          'loaded-sending',
          status: QueuedMessageStatus.sending,
        );
        final retrying = _message(
          'loaded-retrying',
          status: QueuedMessageStatus.retrying,
        )..nextRetryAt = DateTime.now().subtract(const Duration(seconds: 1));
        final futureRetry = _message(
          'future-retrying',
          status: QueuedMessageStatus.retrying,
        )..nextRetryAt = DateTime.now().add(const Duration(minutes: 1));
        final staleAck = _message(
          'loaded-ack',
          status: QueuedMessageStatus.awaitingAck,
        )..lastAttemptAt = DateTime.now().subtract(const Duration(seconds: 6));
        repository.messages.addAll(<QueuedMessage>[
          sending,
          retrying,
          staleAck,
          futureRetry,
        ]);
        queue.onSendMessage = (_) async => OfflineQueueSendDisposition.failed;

        await queue.setOnline();

        for (final message in <QueuedMessage>[sending, retrying, staleAck]) {
          expect(message.status, QueuedMessageStatus.pending);
          expect(
            repository.savedStatusesFor(message.id).first,
            QueuedMessageStatus.pending,
          );
        }
        expect(futureRetry.status, QueuedMessageStatus.retrying);
        expect(repository.savedStatusesFor(futureRetry.id), isEmpty);
        expect(scheduler.isScheduled(futureRetry.id), isTrue);
      },
    );

    test(
      'retryMessage owns reset, persistence, and delivery trigger',
      () async {
        final message =
            _message('manual-retry', status: QueuedMessageStatus.failed)
              ..attempts = 4
              ..failedAt = DateTime.now()
              ..failureReason = 'old failure';
        repository.messages.add(message);
        queue.onSendMessage = (_) async =>
            OfflineQueueSendDisposition.delivered;
        await queue.setOnline();

        // Failed messages are not part of the automatic online flush.
        expect(queue.getMessageById(message.id), same(message));
        expect(await queue.retryMessage('missing'), isFalse);
        expect(await queue.retryMessage(message.id), isTrue);

        expect(queue.getMessageById(message.id), isNull);
        expect(
          repository.savedStatusesFor(message.id),
          containsAllInOrder(<QueuedMessageStatus>[
            QueuedMessageStatus.pending,
            QueuedMessageStatus.sending,
          ]),
        );
      },
    );

    test('dispose cancels tracked stagger deliveries', () async {
      final volatileQueue = OfflineMessageQueue(
        allowVolatileStorage: true,
        retryScheduler: scheduler,
      );
      await volatileQueue.initialize();
      await volatileQueue.queueMessage(
        chatId: 'chat-first',
        content: 'first',
        recipientPublicKey: 'recipient',
        senderPublicKey: 'sender',
      );
      await volatileQueue.queueMessage(
        chatId: 'chat-second',
        content: 'second',
        recipientPublicKey: 'recipient',
        senderPublicKey: 'sender',
      );
      var sendCalls = 0;
      volatileQueue.onSendMessage = (_) async {
        sendCalls++;
        return OfflineQueueSendDisposition.delivered;
      };

      await volatileQueue.setOnline();
      volatileQueue.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(sendCalls, 0);
    });
  });
}

QueuedMessage _message(
  String id, {
  bool isRelayMessage = false,
  QueuedMessageStatus status = QueuedMessageStatus.pending,
}) {
  return QueuedMessage(
    id: id,
    chatId: 'chat-$id',
    content: 'content-$id',
    recipientPublicKey: 'recipient-$id',
    senderPublicKey: 'sender',
    priority: MessagePriority.normal,
    queuedAt: DateTime.now(),
    maxRetries: 5,
    status: status,
    isRelayMessage: isRelayMessage,
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _RecordingQueueRepository extends Fake
    implements IMessageQueueRepository {
  final List<QueuedMessage> messages = <QueuedMessage>[];
  final List<({String id, QueuedMessageStatus status})> saveHistory =
      <({String id, QueuedMessageStatus status})>[];
  final List<String> deletedIds = <String>[];
  final List<String> deleteAttempts = <String>[];
  final Map<({String id, QueuedMessageStatus status}), int>
  _saveFailuresRemaining = <({String id, QueuedMessageStatus status}), int>{};
  final Map<String, int> _deleteFailuresRemaining = <String, int>{};

  List<QueuedMessageStatus> savedStatusesFor(String id) => saveHistory
      .where((entry) => entry.id == id)
      .map((entry) => entry.status)
      .toList(growable: false);

  void clearHistory() => saveHistory.clear();

  void failNextSave(String id, QueuedMessageStatus status, {int times = 1}) {
    _saveFailuresRemaining[(id: id, status: status)] = times;
  }

  void failNextDelete(String id, {int times = 1}) {
    _deleteFailuresRemaining[id] = times;
  }

  int saveAttemptsFor(String id, QueuedMessageStatus status) => saveHistory
      .where((entry) => entry.id == id && entry.status == status)
      .length;

  int deleteAttemptsFor(String id) =>
      deleteAttempts.where((attemptedId) => attemptedId == id).length;

  @override
  Future<void> loadQueueFromStorage() async {}

  @override
  Future<void> loadDeletedMessageIds() async {}

  @override
  Set<String> getDeletedMessageIdsSnapshot() => const <String>{};

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    saveHistory.add((id: message.id, status: message.status));
    final key = (id: message.id, status: message.status);
    final failuresRemaining = _saveFailuresRemaining[key] ?? 0;
    if (failuresRemaining > 0) {
      _saveFailuresRemaining[key] = failuresRemaining - 1;
      throw StateError('Injected save failure for ${message.id}');
    }
  }

  @override
  Future<void> deleteMessageFromStorage(String messageId) async {
    deleteAttempts.add(messageId);
    final failuresRemaining = _deleteFailuresRemaining[messageId] ?? 0;
    if (failuresRemaining > 0) {
      _deleteFailuresRemaining[messageId] = failuresRemaining - 1;
      throw StateError('Injected delete failure for $messageId');
    }
    deletedIds.add(messageId);
  }

  @override
  List<QueuedMessage> getAllMessages() => <QueuedMessage>[...messages];

  @override
  void insertMessageByPriority(QueuedMessage message) => messages.add(message);

  @override
  void removeMessageFromQueue(String messageId) {
    messages.removeWhere((message) => message.id == messageId);
  }
}

class _PersistenceManager extends Fake implements IQueuePersistenceManager {
  @override
  Future<bool> createQueueTablesIfNotExist() async => true;
}

class _ControlledRetryScheduler extends Fake implements IRetryScheduler {
  final Map<String, FutureOr<void> Function()> _callbacks =
      <String, FutureOr<void> Function()>{};
  final Map<String, Duration> _delays = <String, Duration>{};
  bool Function({required DateTime? lastAttemptAt, required int attempts})?
  onShouldRetry;

  Future<void> fire(String messageId) async {
    final callback = _callbacks.remove(messageId);
    _delays.remove(messageId);
    expect(callback, isNotNull, reason: 'No timer registered for $messageId');
    await callback!();
  }

  @override
  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  ) {
    _callbacks[messageId] = callback;
    _delays[messageId] = delay;
  }

  @override
  void cancelRetryTimer(String messageId) {
    _callbacks.remove(messageId);
    _delays.remove(messageId);
  }

  @override
  void cancelAllRetryTimers() {
    _callbacks.clear();
    _delays.clear();
  }

  @override
  bool isScheduled(String messageId) => _callbacks.containsKey(messageId);

  Duration? delayFor(String messageId) => _delays[messageId];

  @override
  List<String> getScheduledMessageIds() => _callbacks.keys.toList();

  @override
  Duration calculateBackoffDelay(int attempt) =>
      const Duration(milliseconds: 10);

  @override
  bool shouldRetry(
    String messageId,
    DateTime? lastAttemptAt,
    int attempts,
    int maxRetries,
    DateTime? expiresAt,
  ) {
    return onShouldRetry?.call(
          lastAttemptAt: lastAttemptAt,
          attempts: attempts,
        ) ??
        attempts < maxRetries;
  }

  @override
  int getMaxRetriesForPriority(MessagePriority priority, int baseMaxRetries) =>
      baseMaxRetries;

  @override
  DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority) =>
      queuedAt.add(const Duration(hours: 1));

  @override
  bool isMessageExpired(QueuedMessage message) => false;
}
