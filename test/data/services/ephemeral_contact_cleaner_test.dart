import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/ephemeral_contact_cleaner.dart';

import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'ephemeral_contact_cleaner',
    );
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
    EphemeralContactCleaner.clearQueueResolver();
  });

  tearDown(EphemeralContactCleaner.clearQueueResolver);

  test(
    'keeps an ephemeral contact when the shared queue is unavailable',
    () async {
      final contacts = ContactRepository();
      await contacts.saveContact('peer-key', 'Peer');
      EphemeralContactCleaner.configureQueueResolver(() => null);

      await EphemeralContactCleaner.cleanup(
        contactId: 'peer-key',
        logger: Logger('test'),
      );

      expect(await contacts.getContact('peer-key'), isNotNull);
    },
  );

  test('keeps an ephemeral contact when queue lookup throws', () async {
    final contacts = ContactRepository();
    await contacts.saveContact('peer-key', 'Peer');
    EphemeralContactCleaner.configureQueueResolver(
      () => throw StateError('queue unavailable'),
    );

    await EphemeralContactCleaner.cleanup(
      contactId: 'peer-key',
      logger: Logger('test'),
    );

    expect(await contacts.getContact('peer-key'), isNotNull);
  });

  test(
    'deletes an orphan only after an available queue proves it is empty',
    () async {
      final contacts = ContactRepository();
      await contacts.saveContact('peer-key', 'Peer');
      final queue = InMemoryOfflineMessageQueue();
      await queue.initialize();
      EphemeralContactCleaner.configureQueueResolver(() => queue);

      await EphemeralContactCleaner.cleanup(
        contactId: 'peer-key',
        logger: Logger('test'),
      );

      expect(await contacts.getContact('peer-key'), isNull);
    },
  );

  test('keeps a contact with a pending message in the shared queue', () async {
    final contacts = ContactRepository();
    await contacts.saveContact('peer-key', 'Peer');
    final queue = InMemoryOfflineMessageQueue();
    await queue.initialize();
    await queue.queueMessage(
      chatId: 'chat-peer',
      content: 'pending',
      recipientPublicKey: 'peer-key',
      senderPublicKey: 'sender-key',
    );
    EphemeralContactCleaner.configureQueueResolver(() => queue);

    await EphemeralContactCleaner.cleanup(
      contactId: 'peer-key',
      logger: Logger('test'),
    );

    expect(await contacts.getContact('peer-key'), isNotNull);
  });
}
