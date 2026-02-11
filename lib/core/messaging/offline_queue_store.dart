import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_queue_persistence_manager.dart';
import 'package:pak_connect/domain/values/id_types.dart';

import '../services/message_queue_repository.dart';
import '../services/queue_persistence_manager.dart';

class QueueStore {
  QueueStore({
    required List<QueuedMessage> directMessageQueue,
    required List<QueuedMessage> relayMessageQueue,
    required Set<MessageId> deletedMessageIds,
    IMessageQueueRepository? queueRepository,
    IQueuePersistenceManager? queuePersistenceManager,
  }) : _directMessageQueue = directMessageQueue,
       _relayMessageQueue = relayMessageQueue,
       _deletedMessageIds = deletedMessageIds,
       _queueRepository = queueRepository,
       _queuePersistenceManager = queuePersistenceManager;

  final List<QueuedMessage> _directMessageQueue;
  final List<QueuedMessage> _relayMessageQueue;
  final Set<MessageId> _deletedMessageIds;

  IMessageQueueRepository? _queueRepository;
  IQueuePersistenceManager? _queuePersistenceManager;
  IDatabaseProvider? _databaseProvider;

  void setDatabaseProvider(IDatabaseProvider? databaseProvider) {
    _databaseProvider = databaseProvider;
  }

  bool get hasDatabaseProvider {
    return _databaseProvider != null ||
        GetIt.instance.isRegistered<IDatabaseProvider>();
  }

  int get directQueueSize => _directMessageQueue.length;
  int get relayQueueSize => _relayMessageQueue.length;

  IMessageQueueRepository get repo {
    _queueRepository ??= MessageQueueRepository(
      directMessageQueue: _directMessageQueue,
      relayMessageQueue: _relayMessageQueue,
      deletedMessageIds: _deletedMessageIds,
      databaseProvider: _databaseProvider,
    );
    return _queueRepository!;
  }

  IQueuePersistenceManager get persistenceManager {
    if (_queuePersistenceManager != null) return _queuePersistenceManager!;

    _queuePersistenceManager = hasDatabaseProvider
        ? QueuePersistenceManager(databaseProvider: _databaseProvider)
        : _NoopQueuePersistenceManager();
    return _queuePersistenceManager!;
  }

  Future<void> initializePersistence({required Logger logger}) async {
    if (!hasDatabaseProvider) {
      _useInMemoryFallback();
      logger.warning(
        '⚠️ No database provider found; using in-memory queue for this run',
      );
      return;
    }

    try {
      await persistenceManager.createQueueTablesIfNotExist();
      await loadQueueFromStorage();
      await loadDeletedMessageIds();
    } catch (e) {
      logger.warning(
        '⚠️ Persistence unavailable, falling back to in-memory queue: $e',
      );
      _useInMemoryFallback();
    }
  }

  void _useInMemoryFallback() {
    _queuePersistenceManager = _NoopQueuePersistenceManager();
    _queueRepository = _InMemoryQueueRepository(
      directMessageQueue: _directMessageQueue,
      relayMessageQueue: _relayMessageQueue,
      deletedMessageIds: _deletedMessageIds,
    );
  }

  List<QueuedMessage> getAllMessages() {
    return repo.getAllMessages();
  }

  void insertMessageByPriority(QueuedMessage message) {
    repo.insertMessageByPriority(message);
  }

  void removeMessageFromQueue(String messageId) {
    repo.removeMessageFromQueue(messageId);
  }

  Future<void> loadQueueFromStorage() async {
    await repo.loadQueueFromStorage();
  }

  Future<void> saveMessageToStorage(QueuedMessage message) async {
    await repo.saveMessageToStorage(message);
  }

  Future<void> deleteMessageFromStorage(String messageId) async {
    await repo.deleteMessageFromStorage(messageId);
  }

  Future<void> saveQueueToStorage() async {
    await repo.saveQueueToStorage();
  }

  Future<void> loadDeletedMessageIds() async {
    await repo.loadDeletedMessageIds();
  }

  void clearInMemoryQueues() {
    _directMessageQueue.clear();
    _relayMessageQueue.clear();
  }
}

class _InMemoryQueueRepository implements IMessageQueueRepository {
  _InMemoryQueueRepository({
    List<QueuedMessage>? directMessageQueue,
    List<QueuedMessage>? relayMessageQueue,
    Set<MessageId>? deletedMessageIds,
  }) : directMessageQueue = directMessageQueue ?? [],
       relayMessageQueue = relayMessageQueue ?? [],
       deletedMessageIds = deletedMessageIds ?? {};

  final List<QueuedMessage> directMessageQueue;
  final List<QueuedMessage> relayMessageQueue;
  final Set<MessageId> deletedMessageIds;

  @override
  Future<void> loadQueueFromStorage() async {}

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {}

  @override
  Future<void> deleteMessageFromStorage(String messageId) async {}

  @override
  Future<void> saveQueueToStorage() async {}

  @override
  Future<void> loadDeletedMessageIds() async {}

  @override
  Future<void> saveDeletedMessageIds() async {}

  @override
  QueuedMessage? getMessageById(String messageId) {
    for (final message in getAllMessages()) {
      if (message.id == messageId) {
        return message;
      }
    }
    return null;
  }

  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return getAllMessages()
        .where((message) => message.status == status)
        .toList();
  }

  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  @override
  Future<void> removeMessage(String messageId) async {
    removeMessageFromQueue(messageId);
  }

  @override
  QueuedMessage? getOldestPendingMessage() {
    final pending = getPendingMessages();
    pending.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return pending.isEmpty ? null : pending.first;
  }

  @override
  List<QueuedMessage> getAllMessages() {
    return [...directMessageQueue, ...relayMessageQueue];
  }

  @override
  void insertMessageByPriority(QueuedMessage message) {
    final targetQueue = message.isRelayMessage
        ? relayMessageQueue
        : directMessageQueue;
    int insertIndex = 0;
    for (int index = 0; index < targetQueue.length; index++) {
      if (targetQueue[index].priority.index <= message.priority.index) {
        insertIndex = index;
        break;
      }
      insertIndex = index + 1;
    }
    targetQueue.insert(insertIndex, message);
  }

  @override
  void removeMessageFromQueue(String messageId) {
    final id = MessageId(messageId);
    directMessageQueue.removeWhere((message) => MessageId(message.id) == id);
    relayMessageQueue.removeWhere((message) => MessageId(message.id) == id);
  }

  @override
  bool isMessageDeleted(String messageId) {
    return deletedMessageIds.contains(MessageId(messageId));
  }

  @override
  Future<void> markMessageDeleted(String messageId) async {
    deletedMessageIds.add(MessageId(messageId));
    removeMessageFromQueue(messageId);
  }

  @override
  Map<String, dynamic> queuedMessageToDb(QueuedMessage message) => {};

  @override
  QueuedMessage queuedMessageFromDb(Map<String, dynamic> row) {
    throw UnimplementedError(
      'In-memory repository does not deserialize DB rows',
    );
  }
}

class _NoopQueuePersistenceManager implements IQueuePersistenceManager {
  @override
  Future<bool> createQueueTablesIfNotExist() async => true;

  @override
  Future<void> migrateQueueSchema({
    required int oldVersion,
    required int newVersion,
  }) async {}

  @override
  Future<Map<String, dynamic>> getQueueTableStats() async => {
    'tableCount': 0,
    'rowCount': 0,
  };

  @override
  Future<void> vacuumQueueTables() async {}

  @override
  Future<String?> backupQueueData() async => null;

  @override
  Future<bool> restoreQueueData(String backupPath) async => true;

  @override
  Future<Map<String, dynamic>> getQueueTableHealth() async => {
    'ok': true,
    'rowCount': 0,
  };

  @override
  Future<int> ensureQueueConsistency() async => 0;
}
