import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_provider.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../test_helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database database;
  late List<QueuedMessage> directMessages;
  late List<QueuedMessage> relayMessages;
  late Set<MessageId> deletedIds;
  late MessageQueueRepository repository;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'message_queue_repository_atomic_mutation',
    );
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
    database = await DatabaseHelper.database;
    directMessages = <QueuedMessage>[];
    relayMessages = <QueuedMessage>[];
    deletedIds = <MessageId>{};
    repository = MessageQueueRepository(
      directMessageQueue: directMessages,
      relayMessageQueue: relayMessages,
      deletedMessageIds: deletedIds,
      databaseProvider: DatabaseProvider(),
    );
  });

  tearDownAll(() async {
    await DatabaseHelper.close();
    await DatabaseHelper.deleteDatabase();
  });

  Future<void> seedQueue(QueuedMessage message) async {
    await database.insert(
      'offline_message_queue',
      repository.queuedMessageToDb(message),
    );
  }

  Future<List<Map<String, Object?>>> queueRows() {
    return database.query('offline_message_queue', orderBy: 'message_id ASC');
  }

  Future<List<Map<String, Object?>>> tombstoneRows() {
    return database.query('deleted_message_ids', orderBy: 'message_id ASC');
  }

  test(
    'queue snapshot freezes mutable messages before the first await',
    () async {
      final message = _message('snapshot');
      final gatedProvider = _GatedDatabaseProvider(database);
      final gatedRepository = MessageQueueRepository(
        databaseProvider: gatedProvider,
      );

      final save = gatedRepository.saveQueueSnapshotToStorage([message]);
      await gatedProvider.requested;

      message.priority = MessagePriority.urgent;
      message.status = QueuedMessageStatus.failed;
      message.attempts = 4;
      gatedProvider.release();
      await save;

      final row = (await queueRows()).single;
      expect(row['priority'], MessagePriority.normal.index);
      expect(row['status'], QueuedMessageStatus.pending.index);
      expect(row['attempts'], 0);
    },
  );

  test(
    'queue snapshot replacement rolls back when a later insert fails',
    () async {
      await seedQueue(_message('original'));
      await database.execute('''
      CREATE TRIGGER fail_queue_snapshot
      BEFORE INSERT ON offline_message_queue
      WHEN NEW.message_id = 'replacement-b'
      BEGIN
        SELECT RAISE(ABORT, 'injected queue snapshot failure');
      END
    ''');

      await expectLater(
        repository.saveQueueSnapshotToStorage([
          _message('replacement-a'),
          _message('replacement-b'),
        ]),
        throwsA(anything),
      );

      expect((await queueRows()).map((row) => row['message_id']), ['original']);
    },
  );

  test(
    'bulk tombstone commit updates both tables then publishes shared memory',
    () async {
      final first = _message('message-a');
      final second = _message('message-b');
      directMessages.addAll([first, second]);
      await seedQueue(first);
      await seedQueue(second);
      await database.insert('deleted_message_ids', {
        'message_id': first.id,
        'deleted_at': 123,
        'reason': 'original reason',
      });

      await repository.markMessagesDeleted([first.id, second.id, first.id]);

      expect(await queueRows(), isEmpty);
      final tombstones = await tombstoneRows();
      expect(tombstones.map((row) => row['message_id']), [first.id, second.id]);
      expect(tombstones.first['deleted_at'], 123);
      expect(tombstones.first['reason'], 'original reason');
      expect(directMessages, isEmpty);
      expect(deletedIds, {MessageId(first.id), MessageId(second.id)});
    },
  );

  test(
    'bulk tombstone failure rolls back disk and does not publish memory',
    () async {
      final first = _message('message-a');
      final second = _message('message-b');
      directMessages.addAll([first, second]);
      await seedQueue(first);
      await seedQueue(second);
      await database.execute('''
      CREATE TRIGGER fail_bulk_tombstone
      BEFORE DELETE ON offline_message_queue
      WHEN OLD.message_id = 'message-b'
      BEGIN
        SELECT RAISE(ABORT, 'injected tombstone failure');
      END
    ''');

      await expectLater(
        repository.markMessagesDeleted([first.id, second.id]),
        throwsA(anything),
      );

      expect((await queueRows()).map((row) => row['message_id']), [
        first.id,
        second.id,
      ]);
      expect(await tombstoneRows(), isEmpty);
      expect(directMessages.map((message) => message.id), [
        first.id,
        second.id,
      ]);
      expect(deletedIds, isEmpty);
    },
  );

  test('deleted-ID snapshot retains existing timestamp and reason', () async {
    await database.insert('deleted_message_ids', {
      'message_id': 'retained',
      'deleted_at': 100,
      'reason': 'keep me',
    });
    await database.insert('deleted_message_ids', {
      'message_id': 'removed',
      'deleted_at': 50,
      'reason': 'drop me',
    });

    await repository.saveDeletedIdsSnapshotToStorage([
      'retained',
      'new-tombstone',
    ]);

    final rows = await tombstoneRows();
    expect(rows.map((row) => row['message_id']), ['new-tombstone', 'retained']);
    final retained = rows.singleWhere((row) => row['message_id'] == 'retained');
    expect(retained['deleted_at'], 100);
    expect(retained['reason'], 'keep me');
    expect(deletedIds, isEmpty, reason: 'snapshot persistence is disk-only');
  });

  test(
    'prune retains newest durable IDs and publishes the exact set',
    () async {
      for (final entry in const {
        'oldest': 100,
        'middle': 200,
        'newest': 300,
      }.entries) {
        await database.insert('deleted_message_ids', {
          'message_id': entry.key,
          'deleted_at': entry.value,
        });
        deletedIds.add(MessageId(entry.key));
      }
      deletedIds.add(const MessageId('memory-only'));

      final retained = await repository.pruneDeletedMessageIds(2);

      expect(retained, {'middle', 'newest'});
      expect(deletedIds, {
        const MessageId('middle'),
        const MessageId('newest'),
      });
      expect((await tombstoneRows()).map((row) => row['message_id']).toSet(), {
        'middle',
        'newest',
      });
    },
  );
}

QueuedMessage _message(String id) => QueuedMessage(
  id: id,
  chatId: 'chat-1',
  content: 'content-$id',
  recipientPublicKey: 'recipient-key',
  senderPublicKey: 'sender-key',
  priority: MessagePriority.normal,
  queuedAt: DateTime.utc(2026, 7, 13),
  maxRetries: 5,
);

class _GatedDatabaseProvider implements IDatabaseProvider {
  _GatedDatabaseProvider(this._database);

  final Database _database;
  final Completer<void> _requested = Completer<void>();
  final Completer<void> _release = Completer<void>();

  Future<void> get requested => _requested.future;

  void release() => _release.complete();

  @override
  Future<Database> get database async {
    _requested.complete();
    await _release.future;
    return _database;
  }

  @override
  Future<Map<String, dynamic>> getDatabaseSize() async => const {};
}
