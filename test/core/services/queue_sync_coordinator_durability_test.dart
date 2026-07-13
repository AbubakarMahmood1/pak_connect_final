import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/queue_sync_coordinator.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';

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
    );

    await expectLater(
      coordinator.addSyncedMessage(message),
      throwsA(isA<StateError>()),
    );
    expect(repository.messages, isEmpty);
  });
}

class _FailingQueueRepository extends Fake implements IMessageQueueRepository {
  final List<QueuedMessage> messages = [];

  @override
  List<QueuedMessage> getAllMessages() => List.unmodifiable(messages);

  @override
  void insertMessageByPriority(QueuedMessage message) {
    messages.add(message);
  }

  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    throw StateError('sync persistence failed');
  }
}
