import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

void main() {
  test(
    'malformed later queue row does not publish a partial loaded prefix',
    () async {
      final existing = _message('existing');
      final directMessages = <QueuedMessage>[existing];
      late MessageQueueRepository repository;
      final database = _QueryDatabase((table) {
        if (table == 'deleted_message_ids') return const [];
        final valid = repository.queuedMessageToDb(_message('valid'));
        final malformed = Map<String, Object?>.from(valid)
          ..['message_id'] = 'malformed'
          ..['queue_id'] = 'malformed'
          ..['priority'] = 999;
        return [valid, malformed];
      });
      repository = MessageQueueRepository(
        directMessageQueue: directMessages,
        databaseProvider: _DatabaseProvider(database),
      );

      await expectLater(repository.loadQueueFromStorage(), throwsA(anything));

      expect(directMessages, hasLength(1));
      expect(directMessages.single.id, 'existing');
    },
  );

  test(
    'malformed later tombstone does not publish a partial loaded set',
    () async {
      final deletedIds = <MessageId>{const MessageId('existing')};
      final database = _QueryDatabase((table) {
        if (table == 'deleted_message_ids') {
          return <Map<String, Object?>>[
            {'message_id': 'valid'},
            {'message_id': 42},
          ];
        }
        return const [];
      });
      final repository = MessageQueueRepository(
        deletedMessageIds: deletedIds,
        databaseProvider: _DatabaseProvider(database),
      );

      await expectLater(repository.loadDeletedMessageIds(), throwsA(anything));

      expect(deletedIds, {const MessageId('existing')});
    },
  );
}

QueuedMessage _message(String id) => QueuedMessage(
  id: id,
  chatId: 'chat-1',
  content: 'content',
  recipientPublicKey: 'recipient-key',
  senderPublicKey: 'sender-key',
  priority: MessagePriority.normal,
  queuedAt: DateTime.utc(2026, 7, 13),
  maxRetries: 5,
);

class _QueryDatabase extends Fake implements Database {
  _QueryDatabase(this.rowsForTable);

  final List<Map<String, Object?>> Function(String table) rowsForTable;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #query) {
      final table = invocation.positionalArguments.first as String;
      return Future<List<Map<String, Object?>>>.value(rowsForTable(table));
    }
    return super.noSuchMethod(invocation);
  }
}

class _DatabaseProvider implements IDatabaseProvider {
  _DatabaseProvider(this._database);

  final Database _database;

  @override
  Future<Database> get database async => _database;

  @override
  Future<Map<String, dynamic>> getDatabaseSize() async => const {};
}
