import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

import '../../test_helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ArchiveRepository repository;
  var sequence = 0;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'archive_atomic_restore',
    );
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
    repository = ArchiveRepository();
    await repository.initialize();
    sequence++;
  });

  tearDownAll(() async {
    await DatabaseHelper.close();
    await DatabaseHelper.deleteDatabase();
  });

  Future<ArchiveId> seedArchive({
    required String originalChatId,
    required int actualMessageCount,
    int? storedMessageCount,
    List<String>? messageIds,
    String? contactPublicKey,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime(2026, 7, 13, 10, sequence).millisecondsSinceEpoch;
    final archiveId = ArchiveId('archive-$originalChatId-$sequence');
    await db.insert('archived_chats', {
      'archive_id': archiveId.value,
      'original_chat_id': originalChatId,
      'contact_name': 'Atomic Restore',
      'contact_public_key': contactPublicKey,
      'archived_at': now,
      'last_message_time': now,
      'message_count': storedMessageCount ?? actualMessageCount,
      'archive_reason': 'test',
      'estimated_size': actualMessageCount * 100,
      'is_compressed': 0,
      'metadata_json':
          '{"version":"1.0","reason":"test",'
          '"originalUnreadCount":1,"wasOnline":false,'
          '"hadUnsentMessages":false,"estimatedStorageSize":100,'
          '"archiveSource":"test","tags":[],"hasSearchIndex":true}',
      'created_at': now,
      'updated_at': now,
    });

    for (var index = 0; index < actualMessageCount; index++) {
      final messageId = messageIds?[index] ?? 'restore-$sequence-$index';
      await db.insert('archived_messages', {
        'id': 'archived-$messageId',
        'archive_id': archiveId.value,
        'original_message_id': messageId,
        'chat_id': originalChatId,
        'content': 'restored content $index',
        'timestamp': now + index,
        'is_from_me': index.isEven ? 1 : 0,
        'status': MessageStatus.delivered.index,
        'is_starred': index == 0 ? 1 : 0,
        'is_forwarded': 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': now,
        'original_timestamp': now + index,
        'searchable_text': 'restored content $index',
        'created_at': now,
      });
    }
    return archiveId;
  }

  Future<void> seedLiveChat(
    String chatId, {
    String messageId = 'old-live',
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime(2026, 7, 13, 9, sequence).millisecondsSinceEpoch;
    await db.insert('chats', {
      'chat_id': chatId,
      'contact_name': 'Existing Chat',
      'last_message': 'existing content',
      'last_message_time': now,
      'unread_count': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('messages', {
      'id': messageId,
      'chat_id': chatId,
      'content': 'existing content',
      'timestamp': now,
      'is_from_me': 1,
      'status': MessageStatus.delivered.index,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> archiveCount(ArchiveId archiveId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM archived_chats WHERE archive_id = ?',
      [archiveId.value],
    );
    return rows.single['count'] as int;
  }

  Future<List<Map<String, Object?>>> liveMessages(String chatId) async {
    final db = await DatabaseHelper.database;
    return db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<int> archivedMessageCount(ArchiveId archiveId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM archived_messages WHERE archive_id = ?',
      [archiveId.value],
    );
    return rows.single['count'] as int;
  }

  test('existing target fails closed unless overwrite is explicit', () async {
    final archiveId = await seedArchive(
      originalChatId: 'conflict-target',
      actualMessageCount: 2,
    );
    await seedLiveChat('conflict-target');

    final result = await repository.restoreChat(archiveId);

    expect(result.success, isFalse);
    expect(result.message, contains('already exists'));
    expect(await archiveCount(archiveId), 1);
    expect(await liveMessages('conflict-target'), hasLength(1));
    expect((await liveMessages('conflict-target')).single['id'], 'old-live');
  });

  test('explicit overwrite atomically replaces the selected target', () async {
    final archiveId = await seedArchive(
      originalChatId: 'overwrite-target',
      actualMessageCount: 2,
    );
    await seedLiveChat('overwrite-target');

    final result = await repository.restoreChat(
      archiveId,
      overwriteExisting: true,
    );

    expect(result.success, isTrue);
    expect(await archiveCount(archiveId), 0);
    final restored = await liveMessages('overwrite-target');
    expect(restored, hasLength(2));
    expect(restored.map((row) => row['id']), isNot(contains('old-live')));
    expect(restored.map((row) => row['id']).toSet(), {
      'restore-$sequence-0',
      'restore-$sequence-1',
    });
    expect(await archivedMessageCount(archiveId), 0);
  });

  test('failed overwrite rolls the original target back intact', () async {
    final archiveId = await seedArchive(
      originalChatId: 'overwrite-rollback',
      actualMessageCount: 2,
    );
    await seedLiveChat('overwrite-rollback');
    final db = await DatabaseHelper.database;
    await db.execute('''
      CREATE TRIGGER fail_overwrite_restore
      BEFORE INSERT ON messages
      WHEN NEW.id = 'restore-$sequence-1'
      BEGIN
        SELECT RAISE(ABORT, 'injected overwrite failure');
      END
    ''');

    final result = await repository.restoreChat(
      archiveId,
      overwriteExisting: true,
    );

    expect(result.success, isFalse);
    expect(await archiveCount(archiveId), 1);
    final originalMessages = await liveMessages('overwrite-rollback');
    expect(originalMessages, hasLength(1));
    expect(originalMessages.single['id'], 'old-live');
  });

  test('insert failure rolls back live rows and retains the archive', () async {
    final archiveId = await seedArchive(
      originalChatId: 'rollback-target',
      actualMessageCount: 2,
    );
    final db = await DatabaseHelper.database;
    await db.execute('''
      CREATE TRIGGER fail_atomic_restore
      BEFORE INSERT ON messages
      WHEN NEW.id = 'restore-$sequence-1'
      BEGIN
        SELECT RAISE(ABORT, 'injected restore failure');
      END
    ''');

    final result = await repository.restoreChat(archiveId);

    expect(result.success, isFalse);
    expect(await archiveCount(archiveId), 1);
    expect(await liveMessages('rollback-target'), isEmpty);
    final chats = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: ['rollback-target'],
    );
    expect(chats, isEmpty);
  });

  test(
    'message ID collision in another chat aborts without mutation',
    () async {
      await seedLiveChat('unrelated-chat', messageId: 'shared-message');
      final archiveId = await seedArchive(
        originalChatId: 'collision-target',
        actualMessageCount: 1,
        messageIds: const ['shared-message'],
      );

      final result = await repository.restoreChat(archiveId);

      expect(result.success, isFalse);
      expect(await archiveCount(archiveId), 1);
      expect(await liveMessages('collision-target'), isEmpty);
      expect(await liveMessages('unrelated-chat'), hasLength(1));
    },
  );

  test('custom target rewrites every restored chat ID', () async {
    final archiveId = await seedArchive(
      originalChatId: 'original-target',
      actualMessageCount: 3,
    );

    final result = await repository.restoreChat(
      archiveId,
      targetChatId: const ChatId('custom-target'),
    );

    expect(result.success, isTrue);
    expect(await liveMessages('original-target'), isEmpty);
    final restored = await liveMessages('custom-target');
    expect(restored, hasLength(3));
    expect(restored.map((row) => row['chat_id']).toSet(), {'custom-target'});
  });

  test('message-count mismatch preserves the archive', () async {
    final archiveId = await seedArchive(
      originalChatId: 'count-mismatch',
      actualMessageCount: 2,
      storedMessageCount: 3,
    );

    final result = await repository.restoreChat(archiveId);

    expect(result.success, isFalse);
    expect(result.message, contains('message count'));
    expect(await archiveCount(archiveId), 1);
    expect(await liveMessages('count-mismatch'), isEmpty);
  });

  test('malformed archived JSON fails closed without live mutation', () async {
    final archiveId = await seedArchive(
      originalChatId: 'malformed-json',
      actualMessageCount: 1,
    );
    final db = await DatabaseHelper.database;
    await db.update(
      'archived_messages',
      {'metadata_json': 'not-json'},
      where: 'archive_id = ?',
      whereArgs: [archiveId.value],
    );

    final result = await repository.restoreChat(archiveId);

    expect(result.success, isFalse);
    expect(await archiveCount(archiveId), 1);
    expect(await liveMessages('malformed-json'), isEmpty);
  });

  test('contact linkage is retained only for an existing contact', () async {
    final db = await DatabaseHelper.database;
    final now = DateTime(2026, 7, 13, 8, sequence).millisecondsSinceEpoch;
    await db.insert('contacts', {
      'public_key': 'known-contact',
      'display_name': 'Known Contact',
      'trust_status': 0,
      'security_level': 0,
      'first_seen': now,
      'last_seen': now,
      'created_at': now,
      'updated_at': now,
    });
    final linkedArchive = await seedArchive(
      originalChatId: 'linked-target',
      actualMessageCount: 1,
      messageIds: const ['linked-message'],
      contactPublicKey: 'known-contact',
    );
    final unlinkedArchive = await seedArchive(
      originalChatId: 'unlinked-target',
      actualMessageCount: 1,
      messageIds: const ['unlinked-message'],
      contactPublicKey: 'missing-contact',
    );

    expect((await repository.restoreChat(linkedArchive)).success, isTrue);
    expect((await repository.restoreChat(unlinkedArchive)).success, isTrue);

    final linked = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: ['linked-target'],
    );
    final unlinked = await db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: ['unlinked-target'],
    );
    expect(linked.single['contact_public_key'], 'known-contact');
    expect(unlinked.single['contact_public_key'], isNull);
  });
}
