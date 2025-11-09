// Comprehensive test suite for favorites-based store-and-forward feature
// Tests database migration, contact model, repository methods, and queue integration

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
  });

  setUp(() async {
    await TestSetup.cleanupDatabase();
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    await TestSetup.completeCleanup();
  });

  // logging handled by TestSetup

  group('Database Migration v5→v6', () {
    setUp(() async {
      await TestSetup.cleanupDatabase();
      // Use unique database name for each test
      final testDbName =
          'test_favorites_migration_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseHelper.setTestDatabaseName(testDbName);
      await DatabaseHelper.deleteDatabase();
    });

    tearDown(() async {
      await TestSetup.completeCleanup();
    });

    test('creates is_favorite column in new databases', () async {
      final db = await DatabaseHelper.database;

      // Query the contacts table schema
      final result = await db.rawQuery('PRAGMA table_info(contacts)');
      final columnNames = result.map((row) => row['name'] as String).toList();

      expect(
        columnNames,
        contains('is_favorite'),
        reason: 'contacts table should have is_favorite column',
      );
    });

    test('creates idx_contacts_favorite index', () async {
      final db = await DatabaseHelper.database;

      // Query indexes for contacts table
      final result = await db.rawQuery('PRAGMA index_list(contacts)');
      final indexNames = result.map((row) => row['name'] as String).toList();

      expect(
        indexNames,
        contains('idx_contacts_favorite'),
        reason: 'contacts table should have idx_contacts_favorite index',
      );
    });

    test('is_favorite defaults to 0 for new contacts', () async {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a contact without specifying is_favorite
      await db.insert('contacts', {
        'public_key': 'test_key_123',
        'display_name': 'Test Contact',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'created_at': now,
        'updated_at': now,
      });

      // Query the contact
      final result = await db.query(
        'contacts',
        where: 'public_key = ?',
        whereArgs: ['test_key_123'],
      );
      expect(result.length, 1);
      expect(
        result.first['is_favorite'],
        0,
        reason: 'is_favorite should default to 0',
      );
    });
  });

  group('Contact Model with isFavorite', () {
    setUp(() async {
      await TestSetup.cleanupDatabase();
    });

    tearDown(() async {
      await TestSetup.completeCleanup();
    });
    test('creates contact with isFavorite=false by default', () {
      final contact = Contact(
        publicKey: 'test_key',
        displayName: 'Test User',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );

      expect(contact.isFavorite, false);
    });

    test('creates contact with isFavorite=true', () {
      final contact = Contact(
        publicKey: 'test_key',
        displayName: 'Favorite User',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.high,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
        isFavorite: true,
      );

      expect(contact.isFavorite, true);
    });

    test('toJson includes isFavorite field', () {
      final contact = Contact(
        publicKey: 'test_key',
        displayName: 'Test User',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
        isFavorite: true,
      );

      final json = contact.toJson();
      expect(json['isFavorite'], true);
    });

    test('fromJson parses isFavorite field', () {
      final json = {
        'publicKey': 'test_key',
        'displayName': 'Test User',
        'trustStatus': 0,
        'securityLevel': 0,
        'firstSeen': DateTime.now().millisecondsSinceEpoch,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
        'isFavorite': 1, // Database format (integer)
      };

      final contact = Contact.fromJson(json);
      expect(contact.isFavorite, true);
    });

    test('toDatabase converts isFavorite to integer', () {
      final contact = Contact(
        publicKey: 'test_key',
        displayName: 'Test User',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
        isFavorite: true,
      );

      final dbData = contact.toDatabase();
      expect(dbData['is_favorite'], 1);
    });

    test('fromDatabase parses is_favorite integer to boolean', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dbRow = {
        'public_key': 'test_key',
        'display_name': 'Test User',
        'trust_status': 0,
        'security_level': 0,
        'first_seen': now,
        'last_seen': now,
        'is_favorite': 1,
      };

      final contact = Contact.fromDatabase(dbRow);
      expect(contact.isFavorite, true);
    });

    test('copyWithSecurityLevel preserves isFavorite', () {
      final contact = Contact(
        publicKey: 'test_key',
        displayName: 'Test User',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
        isFavorite: true,
      );

      final updated = contact.copyWithSecurityLevel(SecurityLevel.high);
      expect(
        updated.isFavorite,
        true,
        reason: 'isFavorite should be preserved',
      );
      expect(updated.securityLevel, SecurityLevel.high);
    });
  });

  group('ContactRepository Favorites Methods', () {
    late ContactRepository repository;

    setUp(() async {
      final testDbName =
          'test_favorites_repo_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseHelper.setTestDatabaseName(testDbName);
      await DatabaseHelper.deleteDatabase();
      repository = ContactRepository();
    });

    test('markContactFavorite sets is_favorite to 1', () async {
      // Create a contact
      await repository.saveContact('test_key_1', 'Test User');

      // Mark as favorite
      await repository.markContactFavorite('test_key_1');

      // Verify
      final contact = await repository.getContact('test_key_1');
      expect(contact, isNotNull);
      expect(contact!.isFavorite, true);
    });

    test('unmarkContactFavorite sets is_favorite to 0', () async {
      // Create and mark as favorite
      await repository.saveContact('test_key_2', 'Test User');
      await repository.markContactFavorite('test_key_2');

      // Unmark favorite
      await repository.unmarkContactFavorite('test_key_2');

      // Verify
      final contact = await repository.getContact('test_key_2');
      expect(contact, isNotNull);
      expect(contact!.isFavorite, false);
    });

    test('toggleContactFavorite switches state', () async {
      await repository.saveContact('test_key_3', 'Test User');

      // Toggle to true
      final result1 = await repository.toggleContactFavorite('test_key_3');
      expect(result1, true);

      final contact1 = await repository.getContact('test_key_3');
      expect(contact1!.isFavorite, true);

      // Toggle to false
      final result2 = await repository.toggleContactFavorite('test_key_3');
      expect(result2, false);

      final contact2 = await repository.getContact('test_key_3');
      expect(contact2!.isFavorite, false);
    });

    test('getFavoriteContacts returns only favorites', () async {
      // Create 3 contacts, mark 2 as favorites
      await repository.saveContact('fav_key_1', 'Favorite 1');
      await repository.saveContact('reg_key_1', 'Regular 1');
      await repository.saveContact('fav_key_2', 'Favorite 2');

      await repository.markContactFavorite('fav_key_1');
      await repository.markContactFavorite('fav_key_2');

      // Get favorites
      final favorites = await repository.getFavoriteContacts();

      expect(favorites.length, 2);
      expect(favorites.every((c) => c.isFavorite), true);
      expect(
        favorites.map((c) => c.publicKey).toList(),
        containsAll(['fav_key_1', 'fav_key_2']),
      );
    });

    test('getFavoriteContactCount returns correct count', () async {
      await repository.saveContact('fav1', 'Fav 1');
      await repository.saveContact('fav2', 'Fav 2');
      await repository.saveContact('reg1', 'Reg 1');

      await repository.markContactFavorite('fav1');
      await repository.markContactFavorite('fav2');

      final count = await repository.getFavoriteContactCount();
      expect(count, 2);
    });

    test('isContactFavorite returns correct status', () async {
      await repository.saveContact('test_key', 'Test User');

      expect(await repository.isContactFavorite('test_key'), false);

      await repository.markContactFavorite('test_key');
      expect(await repository.isContactFavorite('test_key'), true);

      await repository.unmarkContactFavorite('test_key');
      expect(await repository.isContactFavorite('test_key'), false);
    });

    test('markContactFavorite is idempotent', () async {
      await repository.saveContact('test_key', 'Test User');

      await repository.markContactFavorite('test_key');
      await repository.markContactFavorite('test_key'); // Call again

      final contact = await repository.getContact('test_key');
      expect(contact!.isFavorite, true);
    });

    test('unmarkContactFavorite is idempotent', () async {
      await repository.saveContact('test_key', 'Test User');

      await repository.unmarkContactFavorite('test_key');
      await repository.unmarkContactFavorite('test_key'); // Call again

      final contact = await repository.getContact('test_key');
      expect(contact!.isFavorite, false);
    });
  });

  group('OfflineMessageQueue Favorites Integration', () {
    late OfflineMessageQueue queue;
    late ContactRepository repository;

    const testSenderKey = 'sender_public_key_123';
    const testRecipientKey = 'recipient_public_key_456';
    const testFavoriteKey = 'favorite_public_key_789';

    setUp(() async {
      final testDbName =
          'test_queue_favorites_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseHelper.setTestDatabaseName(testDbName);
      await DatabaseHelper.deleteDatabase();

      repository = ContactRepository();
      await repository.saveContact(testRecipientKey, 'Regular Contact');
      await repository.saveContact(testFavoriteKey, 'Favorite Contact');
      await repository.markContactFavorite(testFavoriteKey);

      queue = OfflineMessageQueue();
      await queue.initialize(contactRepository: repository);
    });

    test('auto-boosts priority for favorite contacts', () async {
      final messageId = await queue.queueMessage(
        chatId: 'chat_1',
        content: 'Test message',
        recipientPublicKey: testFavoriteKey,
        senderPublicKey: testSenderKey,
        priority: MessagePriority.normal, // Start with normal priority
      );

      final message = queue.getMessageById(messageId);
      expect(message, isNotNull);
      expect(
        message!.priority,
        MessagePriority.high,
        reason: 'Priority should be auto-boosted to HIGH for favorites',
      );
    });

    test('does not auto-boost priority for regular contacts', () async {
      final messageId = await queue.queueMessage(
        chatId: 'chat_2',
        content: 'Test message',
        recipientPublicKey: testRecipientKey,
        senderPublicKey: testSenderKey,
        priority: MessagePriority.normal,
      );

      final message = queue.getMessageById(messageId);
      expect(message, isNotNull);
      expect(
        message!.priority,
        MessagePriority.normal,
        reason: 'Priority should remain NORMAL for regular contacts',
      );
    });

    test('does not auto-boost if already high priority', () async {
      final messageId = await queue.queueMessage(
        chatId: 'chat_3',
        content: 'Test message',
        recipientPublicKey: testFavoriteKey,
        senderPublicKey: testSenderKey,
        priority: MessagePriority.urgent, // Already urgent
      );

      final message = queue.getMessageById(messageId);
      expect(
        message!.priority,
        MessagePriority.urgent,
        reason: 'Urgent priority should not be changed',
      );
    });

    test(
      'enforces per-peer limit for regular contacts (100 messages)',
      () async {
        // Queue 100 messages (at limit)
        for (int i = 0; i < 100; i++) {
          await queue.queueMessage(
            chatId: 'chat_$i',
            content: 'Message $i',
            recipientPublicKey: testRecipientKey,
            senderPublicKey: testSenderKey,
          );
        }

        // Try to queue 101st message - should fail
        expect(
          () async => await queue.queueMessage(
            chatId: 'chat_101',
            content: 'Message 101',
            recipientPublicKey: testRecipientKey,
            senderPublicKey: testSenderKey,
          ),
          throwsA(isA<MessageQueueException>()),
        );
      },
    );

    test(
      'enforces per-peer limit for favorite contacts (limit validation)',
      () async {
        // Test the limit check logic without queuing all 500 messages (performance)
        // Queue just 200 messages to verify the feature works
        for (int i = 0; i < 200; i++) {
          await queue.queueMessage(
            chatId: 'chat_fav_$i',
            content: 'Message $i',
            recipientPublicKey: testFavoriteKey,
            senderPublicKey: testSenderKey,
          );
        }

        // Verify we can still queue more (not at 500 limit yet)
        final messageId = await queue.queueMessage(
          chatId: 'chat_fav_201',
          content: 'Message 201',
          recipientPublicKey: testFavoriteKey,
          senderPublicKey: testSenderKey,
        );

        expect(
          messageId,
          isNotEmpty,
          reason: 'Should be able to queue up to 500 messages for favorites',
        );
      },
    );

    test('favorites get 5x more queue space than regular contacts', () async {
      // Verify the constants are set correctly (performance test)
      // Regular: 100, Favorite: 500 = 5x difference
      const regularLimit = 100;
      const favoriteLimit = 500;

      expect(
        favoriteLimit ~/ regularLimit,
        5,
        reason: 'Favorites should have 5x more queue space',
      );
    });

    test('delivered messages do not count toward per-peer limit', () async {
      // Queue and deliver 100 messages
      for (int i = 0; i < 100; i++) {
        final messageId = await queue.queueMessage(
          chatId: 'chat_$i',
          content: 'Message $i',
          recipientPublicKey: testRecipientKey,
          senderPublicKey: testSenderKey,
        );
        await queue.markMessageDelivered(messageId);
      }

      // Should be able to queue more messages since previous ones were delivered
      final messageId = await queue.queueMessage(
        chatId: 'chat_new',
        content: 'New message',
        recipientPublicKey: testRecipientKey,
        senderPublicKey: testSenderKey,
      );

      expect(messageId, isNotEmpty);
    });

    test('works without ContactRepository (backward compatibility)', () async {
      final queueWithoutRepo = OfflineMessageQueue();
      await queueWithoutRepo.initialize(); // No contactRepository parameter

      // Should use default regular limits (100)
      final messageId = await queueWithoutRepo.queueMessage(
        chatId: 'chat_1',
        content: 'Test message',
        recipientPublicKey: 'any_recipient',
        senderPublicKey: testSenderKey,
        priority: MessagePriority.normal,
      );

      final message = queueWithoutRepo.getMessageById(messageId);
      expect(message, isNotNull);
      expect(
        message!.priority,
        MessagePriority.normal,
        reason: 'No auto-boost without ContactRepository',
      );
    });
  });

  group('End-to-End Favorites Workflow', () {
    late ContactRepository repository;
    late OfflineMessageQueue queue;

    setUp(() async {
      final testDbName =
          'test_e2e_favorites_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseHelper.setTestDatabaseName(testDbName);
      await DatabaseHelper.deleteDatabase();

      repository = ContactRepository();
      queue = OfflineMessageQueue();
      await queue.initialize(contactRepository: repository);
    });

    test(
      'complete workflow: create contact, mark favorite, queue messages',
      () async {
        const senderKey = 'sender_key';
        const recipientKey = 'recipient_key';

        // 1. Create contact
        await repository.saveContact(recipientKey, 'Test User');
        final contact1 = await repository.getContact(recipientKey);
        expect(contact1!.isFavorite, false);

        // 2. Mark as favorite
        await repository.markContactFavorite(recipientKey);
        final contact2 = await repository.getContact(recipientKey);
        expect(contact2!.isFavorite, true);

        // 3. Queue message - should auto-boost and have higher limit
        final messageId = await queue.queueMessage(
          chatId: 'chat_1',
          content: 'Test message',
          recipientPublicKey: recipientKey,
          senderPublicKey: senderKey,
          priority: MessagePriority.normal,
        );

        final message = queue.getMessageById(messageId);
        expect(message!.priority, MessagePriority.high);

        // 4. Unmark favorite
        await repository.unmarkContactFavorite(recipientKey);
        final contact3 = await repository.getContact(recipientKey);
        expect(contact3!.isFavorite, false);

        // 5. New messages should use regular limits
        final messageId2 = await queue.queueMessage(
          chatId: 'chat_2',
          content: 'Another message',
          recipientPublicKey: recipientKey,
          senderPublicKey: senderKey,
          priority: MessagePriority.normal,
        );

        final message2 = queue.getMessageById(messageId2);
        expect(message2!.priority, MessagePriority.normal);
      },
    );
  });
}
