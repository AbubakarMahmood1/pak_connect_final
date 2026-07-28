import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

void main() {
  test('queue persistence operations propagate database failures', () async {
    final repository = MessageQueueRepository(
      databaseProvider: _ThrowingDatabaseProvider(),
    );
    final message = QueuedMessage(
      id: 'message-1',
      chatId: 'chat-1',
      content: 'content',
      recipientPublicKey: 'recipient-key',
      senderPublicKey: 'sender-key',
      priority: MessagePriority.normal,
      queuedAt: DateTime.utc(2026, 7, 13),
      maxRetries: 5,
    );

    await expectLater(
      repository.loadQueueFromStorage(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.saveMessageToStorage(message),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.deleteMessageFromStorage(message.id),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.saveQueueToStorage(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.loadDeletedMessageIds(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.saveDeletedMessageIds(),
      throwsA(isA<StateError>()),
    );
  });
}

class _ThrowingDatabaseProvider implements IDatabaseProvider {
  @override
  Future<Database> get database =>
      Future<Database>.error(StateError('database unavailable'));

  @override
  Future<Map<String, dynamic>> getDatabaseSize() async =>
      throw StateError('database unavailable');
}
