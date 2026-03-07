import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_queue_store.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/core/services/queue_persistence_manager.dart';

void main() {
  final logger = Logger('QueueStorePhase13Test');

  late QueueStore store;

  QueuedMessage _msg({
    String id = 'msg-1',
    MessagePriority priority = MessagePriority.normal,
    QueuedMessageStatus status = QueuedMessageStatus.pending,
    bool isRelay = false,
    DateTime? queuedAt,
  }) {
    return QueuedMessage(
      id: id,
      chatId: 'chat-1',
      content: 'hello',
      recipientPublicKey: 'recipient-key',
      senderPublicKey: 'sender-key',
      priority: priority,
      queuedAt: queuedAt ?? DateTime.now(),
      maxRetries: 3,
      status: status,
      isRelayMessage: isRelay,
    );
  }

  setUp(() {
    // Clear static defaults so hasDatabaseProvider evaluates all three
    // conditions (covering line 40: QueuePersistenceManager.hasDefaultDatabaseProvider)
    MessageQueueRepository.clearDefaultDatabaseProvider();
    QueuePersistenceManager.clearDefaultDatabaseProvider();

    store = QueueStore(
      directMessageQueue: [],
      relayMessageQueue: [],
      deletedMessageIds: {},
    );
  });

  // ── hasDatabaseProvider (line 40) ─────────────────────────────────────

  group('hasDatabaseProvider', () {
    test('returns false when no provider configured', () {
      expect(store.hasDatabaseProvider, isFalse);
    });
  });

  // ── persistenceManager getter – noop path (line 61) ───────────────────
  // Accessing persistenceManager BEFORE initializePersistence, with no DB
  // provider, triggers the _NoopQueuePersistenceManager() fallback (line 61).

  group('persistenceManager noop creation', () {
    test('creates noop persistence manager without db provider', () {
      final pm = store.persistenceManager;
      expect(pm, isNotNull);
    });
  });

  // ── initializePersistence fallback (lines 67-68, 138-139) ─────────────

  group('initializePersistence in-memory fallback', () {
    test('falls back to in-memory when no db provider', () async {
      await store.initializePersistence(logger: logger);
      expect(store.getAllMessages(), isEmpty);
      expect(store.directQueueSize, 0);
      expect(store.relayQueueSize, 0);
    });
  });

  // ── _InMemoryQueueRepository methods ──────────────────────────────────

  group('InMemoryQueueRepository (via QueueStore.repo)', () {
    setUp(() async {
      await store.initializePersistence(logger: logger);
    });

    // -- insertMessageByPriority (lines 203-216) --

    test('inserts direct message by priority', () {
      store.insertMessageByPriority(
        _msg(id: 'u', priority: MessagePriority.urgent),
      );
      store.insertMessageByPriority(
        _msg(id: 'l', priority: MessagePriority.low),
      );
      store.insertMessageByPriority(
        _msg(id: 'h', priority: MessagePriority.high),
      );

      final all = store.getAllMessages();
      expect(all.length, 3);
    });

    test('inserts relay message into relay queue', () {
      store.insertMessageByPriority(
        _msg(id: 'r1', isRelay: true, priority: MessagePriority.normal),
      );
      expect(store.relayQueueSize, 1);
      expect(store.directQueueSize, 0);
    });

    test('insertIndex falls through loop when all higher priority', () {
      // urgent first, then low → low appended via insertIndex = index + 1
      store.insertMessageByPriority(
        _msg(id: 'u', priority: MessagePriority.urgent),
      );
      store.insertMessageByPriority(
        _msg(id: 'l', priority: MessagePriority.low),
      );
      expect(store.getAllMessages().last.id, 'l');
    });

    // -- getAllMessages (lines 199-201) --

    test('getAllMessages returns combined direct + relay', () {
      store.insertMessageByPriority(_msg(id: 'd1'));
      store.insertMessageByPriority(_msg(id: 'r1', isRelay: true));
      expect(store.getAllMessages().length, 2);
    });

    // -- getMessageById (lines 164-171) --

    test('getMessageById returns matching message', () {
      store.insertMessageByPriority(_msg(id: 'find-me'));
      final found = store.repo.getMessageById('find-me');
      expect(found, isNotNull);
      expect(found!.id, 'find-me');
    });

    test('getMessageById returns null for missing id', () {
      expect(store.repo.getMessageById('ghost'), isNull);
    });

    // -- getMessagesByStatus (lines 174-178) --

    test('getMessagesByStatus filters correctly', () {
      store.insertMessageByPriority(
        _msg(id: 'p1', status: QueuedMessageStatus.pending),
      );
      store.insertMessageByPriority(
        _msg(id: 's1', status: QueuedMessageStatus.sending),
      );

      final pending =
          store.repo.getMessagesByStatus(QueuedMessageStatus.pending);
      expect(pending.length, 1);
      expect(pending.first.id, 'p1');
    });

    // -- getPendingMessages (lines 181-183) --

    test('getPendingMessages returns only pending', () {
      store.insertMessageByPriority(
        _msg(id: 'p', status: QueuedMessageStatus.pending),
      );
      store.insertMessageByPriority(
        _msg(id: 'f', status: QueuedMessageStatus.failed),
      );
      expect(store.repo.getPendingMessages().length, 1);
    });

    // -- removeMessage (lines 186-188) --

    test('removeMessage removes by id', () async {
      store.insertMessageByPriority(_msg(id: 'rm'));
      await store.repo.removeMessage('rm');
      expect(store.repo.getMessageById('rm'), isNull);
    });

    // -- getOldestPendingMessage (lines 191-195) --

    test('getOldestPendingMessage returns oldest', () {
      final earlier = DateTime(2024, 1, 1);
      final later = DateTime(2024, 6, 1);
      store.insertMessageByPriority(_msg(id: 'old', queuedAt: earlier));
      store.insertMessageByPriority(_msg(id: 'new', queuedAt: later));

      final oldest = store.repo.getOldestPendingMessage();
      expect(oldest, isNotNull);
      expect(oldest!.id, 'old');
    });

    test('getOldestPendingMessage returns null when empty', () {
      expect(store.repo.getOldestPendingMessage(), isNull);
    });

    test('getOldestPendingMessage returns null when no pending', () {
      store.insertMessageByPriority(
        _msg(id: 'done', status: QueuedMessageStatus.delivered),
      );
      expect(store.repo.getOldestPendingMessage(), isNull);
    });

    // -- removeMessageFromQueue (lines 219-223) --

    test('removeMessageFromQueue removes from direct queue', () {
      store.insertMessageByPriority(_msg(id: 'x'));
      store.removeMessageFromQueue('x');
      expect(store.getAllMessages(), isEmpty);
    });

    test('removeMessageFromQueue removes from relay queue', () {
      store.insertMessageByPriority(_msg(id: 'rx', isRelay: true));
      store.removeMessageFromQueue('rx');
      expect(store.getAllMessages(), isEmpty);
    });

    // -- isMessageDeleted (lines 226-228) --

    test('isMessageDeleted returns false for unknown id', () {
      expect(store.repo.isMessageDeleted('unknown'), isFalse);
    });

    // -- markMessageDeleted (lines 231-234) --

    test('markMessageDeleted marks and removes message', () async {
      store.insertMessageByPriority(_msg(id: 'del'));
      await store.repo.markMessageDeleted('del');

      expect(store.repo.isMessageDeleted('del'), isTrue);
      expect(store.repo.getMessageById('del'), isNull);
    });

    // -- queuedMessageToDb returns empty map (lines 237-238) --

    test('queuedMessageToDb returns empty map (in-memory)', () {
      final result = store.repo.queuedMessageToDb(_msg());
      expect(result, isEmpty);
    });

    // -- queuedMessageFromDb throws (lines 240-242) --

    test('queuedMessageFromDb throws UnimplementedError', () {
      expect(
        () => store.repo.queuedMessageFromDb({}),
        throwsA(isA<UnimplementedError>()),
      );
    });

    // -- no-op storage methods (lines 146-161) --

    test('loadQueueFromStorage completes', () async {
      await store.loadQueueFromStorage();
    });

    test('saveMessageToStorage completes', () async {
      await store.saveMessageToStorage(_msg());
    });

    test('deleteMessageFromStorage completes', () async {
      await store.deleteMessageFromStorage('any-id');
    });

    test('saveQueueToStorage completes', () async {
      await store.saveQueueToStorage();
    });

    test('loadDeletedMessageIds completes', () async {
      await store.loadDeletedMessageIds();
    });

    test('saveDeletedMessageIds completes', () async {
      await store.repo.saveDeletedMessageIds();
    });

    // -- clearInMemoryQueues --

    test('clearInMemoryQueues empties both queues', () {
      store.insertMessageByPriority(_msg(id: 'd'));
      store.insertMessageByPriority(_msg(id: 'r', isRelay: true));
      store.clearInMemoryQueues();
      expect(store.getAllMessages(), isEmpty);
    });
  });

  // ── _NoopQueuePersistenceManager methods (lines 249-280) ──────────────

  group('NoopQueuePersistenceManager (via QueueStore.persistenceManager)', () {
    setUp(() async {
      await store.initializePersistence(logger: logger);
    });

    test('createQueueTablesIfNotExist returns true', () async {
      final result =
          await store.persistenceManager.createQueueTablesIfNotExist();
      expect(result, isTrue);
    });

    test('migrateQueueSchema completes', () async {
      await store.persistenceManager.migrateQueueSchema(
        oldVersion: 1,
        newVersion: 2,
      );
    });

    test('getQueueTableStats returns zeroed map', () async {
      final stats = await store.persistenceManager.getQueueTableStats();
      expect(stats['tableCount'], 0);
      expect(stats['rowCount'], 0);
    });

    test('vacuumQueueTables completes', () async {
      await store.persistenceManager.vacuumQueueTables();
    });

    test('backupQueueData returns null', () async {
      expect(await store.persistenceManager.backupQueueData(), isNull);
    });

    test('restoreQueueData returns true', () async {
      final result =
          await store.persistenceManager.restoreQueueData('/fake/path');
      expect(result, isTrue);
    });

    test('getQueueTableHealth returns ok map', () async {
      final health = await store.persistenceManager.getQueueTableHealth();
      expect(health['ok'], isTrue);
      expect(health['rowCount'], 0);
    });

    test('ensureQueueConsistency returns 0', () async {
      expect(await store.persistenceManager.ensureQueueConsistency(), 0);
    });
  });
}
