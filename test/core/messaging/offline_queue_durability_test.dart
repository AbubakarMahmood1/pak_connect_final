import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/offline_queue_store.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/core/services/queue_persistence_manager.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';

void main() {
  setUp(() {
    MessageQueueRepository.clearDefaultDatabaseProvider();
    QueuePersistenceManager.clearDefaultDatabaseProvider();
  });

  test(
    'durable store fails initialization without a persistence backend',
    () async {
      final store = QueueStore(
        directMessageQueue: [],
        relayMessageQueue: [],
        deletedMessageIds: {},
      );

      await expectLater(
        store.initializePersistence(logger: Logger('test')),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('volatile store requires an explicit opt-in', () async {
    final store = QueueStore(
      directMessageQueue: [],
      relayMessageQueue: [],
      deletedMessageIds: {},
      allowVolatileStorage: true,
    );

    await store.initializePersistence(logger: Logger('test'));

    expect(store.getAllMessages(), isEmpty);
  });

  test(
    'durable initialization preserves its backend and propagates failure',
    () async {
      final repository = _FakeQueueRepository();
      final persistence = _FakePersistenceManager(failCreate: true);
      final store = QueueStore(
        directMessageQueue: [],
        relayMessageQueue: [],
        deletedMessageIds: {},
        queueRepository: repository,
        queuePersistenceManager: persistence,
      );

      await expectLater(
        store.initializePersistence(logger: Logger('test')),
        throwsA(isA<StateError>()),
      );
      expect(identical(store.repo, repository), isTrue);
    },
  );

  for (final failure in ['queue rows', 'deletion tombstones']) {
    test('durable initialization propagates failed $failure load', () async {
      final repository = _FakeQueueRepository(
        failQueueLoad: failure == 'queue rows',
        failTombstoneLoad: failure == 'deletion tombstones',
      );
      final store = QueueStore(
        directMessageQueue: [],
        relayMessageQueue: [],
        deletedMessageIds: {},
        queueRepository: repository,
        queuePersistenceManager: _FakePersistenceManager(),
      );

      await expectLater(
        store.initializePersistence(logger: Logger('test')),
        throwsA(isA<StateError>()),
      );
      expect(identical(store.repo, repository), isTrue);
    });
  }

  test('failed durable write is not published as a queued message', () async {
    final repository = _FakeQueueRepository(failSave: true);
    final queue = OfflineMessageQueue(
      queueRepository: repository,
      queuePersistenceManager: _FakePersistenceManager(),
    );
    var callbackFired = false;
    await queue.initialize(onMessageQueued: (_) => callbackFired = true);

    await expectLater(
      queue.queueMessage(
        chatId: 'chat-1',
        content: 'must survive restart',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
      ),
      throwsA(isA<MessageQueueException>()),
    );

    expect(repository.saveCalled, isTrue);
    expect(queue.getPendingMessages(), isEmpty);
    expect(queue.getStatistics().totalQueued, 0);
    expect(callbackFired, isFalse);
    queue.dispose();
  });

  test('direct messages cannot opt out of durable storage', () async {
    final repository = _FakeQueueRepository();
    final queue = OfflineMessageQueue(
      queueRepository: repository,
      queuePersistenceManager: _FakePersistenceManager(),
    );
    await queue.initialize();

    await expectLater(
      queue.queueMessage(
        chatId: 'chat-1',
        content: 'direct payload',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        persistToStorage: false,
      ),
      throwsA(isA<MessageQueueException>()),
    );

    expect(repository.saveCalled, isFalse);
    expect(queue.getPendingMessages(), isEmpty);
    queue.dispose();
  });
}

class _FakeQueueRepository extends Fake implements IMessageQueueRepository {
  _FakeQueueRepository({
    this.failSave = false,
    this.failQueueLoad = false,
    this.failTombstoneLoad = false,
  });

  final bool failSave;
  final bool failQueueLoad;
  final bool failTombstoneLoad;
  final List<QueuedMessage> messages = [];
  bool saveCalled = false;

  @override
  List<QueuedMessage> getAllMessages() => List.unmodifiable(messages);

  @override
  Future<void> loadQueueFromStorage() async {
    if (failQueueLoad) throw StateError('queue load failed');
  }

  @override
  Future<void> loadDeletedMessageIds() async {
    if (failTombstoneLoad) throw StateError('tombstone load failed');
  }

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    saveCalled = true;
    if (failSave) throw StateError('queue write failed');
  }

  @override
  void insertMessageByPriority(QueuedMessage message) {
    messages.add(message);
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) =>
      messages.where((message) => message.status == status).toList();

  @override
  List<QueuedMessage> getPendingMessages() =>
      getMessagesByStatus(QueuedMessageStatus.pending);
}

class _FakePersistenceManager extends Fake implements IQueuePersistenceManager {
  _FakePersistenceManager({this.failCreate = false});

  final bool failCreate;

  @override
  Future<bool> createQueueTablesIfNotExist() async {
    if (failCreate) throw StateError('queue initialization failed');
    return true;
  }
}
