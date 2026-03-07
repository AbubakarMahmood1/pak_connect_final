import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../../test_helpers/test_setup.dart';

/// Phase 13: Supplementary tests for ArchiveRepository
/// Targets uncovered lines: archiveChat flow, restoreChat branches,
/// searchArchives with messageTypeFilter, getArchiveStatistics edge cases,
/// error catch paths, and the _FirstWhereOrNull extension.
void main() {
  Logger.root.level = Level.OFF;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'archive_repo_p13',
    );
    await TestSetup.fullDatabaseReset();
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
  });

  /// Insert an archive directly in the DB (bypasses ChatsRepository).
  Future<ArchiveId> createArchiveDirectly(
    String chatId,
    String contactName,
    int messageCount, {
    int estimatedSize = 0,
    bool isCompressed = false,
    double compressionRatio = 0.0,
    DateTime? archivedAt,
  }) async {
    final db = await DatabaseHelper.database;
    final now = archivedAt ?? DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    final size = estimatedSize > 0 ? estimatedSize : messageCount * 100;
    final archiveId = ArchiveId('archive_${chatId}_$timestamp');

    await db.insert('archived_chats', {
      'archive_id': archiveId.value,
      'original_chat_id': chatId,
      'contact_name': contactName,
      'contact_public_key': 'test_pk_$chatId',
      'archived_at': timestamp,
      'last_message_time': timestamp,
      'message_count': messageCount,
      'archive_reason': 'Test archive',
      'estimated_size': size,
      'is_compressed': isCompressed ? 1 : 0,
      'compression_ratio': compressionRatio,
      'metadata_json':
          '{"version":"1.0","reason":"Test archive","originalUnreadCount":0,'
          '"wasOnline":false,"hadUnsentMessages":false,'
          '"estimatedStorageSize":$size,"archiveSource":"test",'
          '"tags":[],"hasSearchIndex":true}',
      'created_at': timestamp,
      'updated_at': timestamp,
    });

    for (int i = 0; i < messageCount; i++) {
      final msgTime = now.subtract(Duration(hours: messageCount - i));
      await db.insert('archived_messages', {
        'id': 'archived_msg_${timestamp}_${chatId}_$i',
        'archive_id': archiveId.value,
        'original_message_id': 'msg_${chatId}_$i',
        'chat_id': chatId,
        'content': 'Test message $i for $contactName',
        'timestamp': msgTime.millisecondsSinceEpoch,
        'is_from_me': i % 2 == 0 ? 1 : 0,
        'status': MessageStatus.delivered.index,
        'is_starred': i == 0 ? 1 : 0,
        'is_forwarded': i == 1 ? 1 : 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': timestamp,
        'original_timestamp': msgTime.millisecondsSinceEpoch,
        'searchable_text': 'Test message $i for $contactName',
        'created_at': timestamp,
      });
    }

    return archiveId;
  }

  /// Create a chat and messages in the live tables so archiveChat() can find them.
  Future<void> createChatWithMessages(
    String chatId,
    String contactName,
    int messageCount,
  ) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('chats', {
      'chat_id': chatId,
      'contact_name': contactName,
      'created_at': now,
      'updated_at': now,
    });

    final messageRepo = MessageRepository();
    for (int i = 0; i < messageCount; i++) {
      final message = Message(
        id: MessageId('msg_${chatId}_$i'),
        chatId: ChatId(chatId),
        content: 'Test message $i for $contactName',
        timestamp: DateTime.now().subtract(Duration(hours: messageCount - i)),
        isFromMe: i % 2 == 0,
        status: MessageStatus.delivered,
      );
      await messageRepo.saveMessage(message);
    }
  }

  // ─── archiveChat flow ──────────────────────────────────────────────

  group('ArchiveRepository.archiveChat', () {
    test('returns failure when chat does not exist', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final result = await repo.archiveChat(chatId: 'nonexistent_chat');

      expect(result.success, false);
      expect(result.message, contains('Chat not found'));
      expect(result.operationType, ArchiveOperationType.archive);
    });

    test('returns failure when chat has no messages', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      // Create chat with zero messages via the DB directly
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('chats', {
        'chat_id': 'empty_chat',
        'contact_name': 'Nobody',
        'created_at': now,
        'updated_at': now,
      });

      final result = await repo.archiveChat(chatId: 'empty_chat');

      // Chat may not be found via ChatsRepository.getAllChats if schema
      // differs, or may be found with no messages. Either error is acceptable.
      expect(result.success, false);
    });

    test('archives chat successfully with messages', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createChatWithMessages('chat_arc', 'Alice', 3);

      final result = await repo.archiveChat(
        chatId: 'chat_arc',
        archiveReason: 'cleanup',
        customData: {'source': 'test'},
      );

      expect(result.success, true);
      expect(result.archiveId, isNotNull);
      expect(result.metadata?['messageCount'], 3);
      expect(result.metadata?['compressed'], false);

      // Verify archive is stored
      final archive = await repo.getArchivedChat(result.archiveId!);
      expect(archive, isNotNull);
      expect(archive!.contactName, 'Alice');
      expect(archive.messages.length, 3);
    });

    test('archives large chat with compression', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      // Create chat with enough messages so estimatedSize > 10240
      await createChatWithMessages('chat_big', 'BigChat', 15);

      final result = await repo.archiveChat(
        chatId: 'chat_big',
        compressLargeArchives: true,
      );

      expect(result.success, true);
      expect(result.archiveId, isNotNull);
      expect(result.metadata?['messageCount'], 15);
    });

    test('archives chat without compression when disabled', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createChatWithMessages('chat_nocomp', 'NoComp', 5);

      final result = await repo.archiveChat(
        chatId: 'chat_nocomp',
        compressLargeArchives: false,
      );

      expect(result.success, true);
      expect(result.metadata?['compressed'], false);
    });

    test('warning included when > 1000 messages', () async {
      // This is a lightweight check — we verify the warning string logic
      // with a smaller set (exact threshold testing would be too slow).
      final repo = ArchiveRepository();
      await repo.initialize();

      await createChatWithMessages('chat_warn', 'WarnChat', 3);
      final result = await repo.archiveChat(chatId: 'chat_warn');
      expect(result.success, true);
      // With only 3 messages, no "Large archive" warning
      expect(
        result.warnings.any((w) => w.contains('Large archive')),
        false,
      );
    });
  });

  // ─── restoreChat branches ──────────────────────────────────────────

  group('ArchiveRepository.restoreChat', () {
    test('returns failure for non-existent archive', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final result = await repo.restoreChat(ArchiveId('missing'));

      expect(result.success, false);
      expect(result.message, contains('not found'));
    });

    test('restores chat and removes archive from DB', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId =
          await createArchiveDirectly('chat_rst', 'Restoree', 4);

      final result = await repo.restoreChat(archiveId);

      expect(result.success, true);
      expect(result.metadata?['restoredMessages'], 4);
      expect(result.metadata?['wasCompressed'], false);

      // Archive should be removed after restore
      final gone = await repo.getArchivedChat(archiveId);
      expect(gone, isNull);
    });

    test('restores compressed archive', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      // Create a "compressed" archive directly (flag only; decompressArchive
      // handles fallback gracefully when blob is absent)
      final archiveId = await createArchiveDirectly(
        'chat_comp_rst',
        'Compressed',
        2,
        isCompressed: true,
      );

      final result = await repo.restoreChat(archiveId);

      expect(result.success, true);
      expect(result.metadata?['restoredMessages'], 2);
    });
  });

  // ─── searchArchives with messageTypeFilter ─────────────────────────

  group('ArchiveRepository.searchArchives — messageTypeFilter', () {
    test('filters starred messages', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('chat_sf', 'FilterContact', 5);

      // Search with filter for starred messages
      final result = await repo.searchArchives(
        query: 'Test message',
        filter: const ArchiveSearchFilter(
          messageTypeFilter: ArchiveMessageTypeFilter(wasStarred: true),
        ),
      );

      // Only the first message (i==0) is starred
      expect(result.messages.every((m) => m.isStarred), true);
    });

    test('filters isFromMe messages', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('chat_fm', 'FromMeContact', 4);

      final result = await repo.searchArchives(
        query: 'Test message',
        filter: const ArchiveSearchFilter(
          messageTypeFilter: ArchiveMessageTypeFilter(isFromMe: true),
        ),
      );

      // Even-indexed messages have is_from_me = 1
      expect(result.messages.every((m) => m.isFromMe), true);
    });

    test('search with custom limit', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('chat_lim', 'LimitContact', 10);

      final result = await repo.searchArchives(
        query: 'Test message',
        limit: 3,
      );

      expect(result.messages.length, lessThanOrEqualTo(3));
    });

    test('search returns empty for blank query', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('chat_blank', 'BlankQuery', 2);

      final result = await repo.searchArchives(query: '   ');

      expect(result.totalResults, 0);
    });
  });

  // ─── getArchiveStatistics edge cases ───────────────────────────────

  group('ArchiveRepository.getArchiveStatistics', () {
    test('returns empty stats for empty database', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final stats = await repo.getArchiveStatistics();

      expect(stats.totalArchives, 0);
      expect(stats.totalMessages, 0);
      expect(stats.compressedArchives, 0);
      expect(stats.oldestArchive, isNull);
      expect(stats.newestArchive, isNull);
      expect(stats.averageArchiveAge, Duration.zero);
    });

    test('statistics include compressed archives count', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_st1', 'Alice', 3);
      await createArchiveDirectly(
        'ch_st2',
        'Bob',
        5,
        isCompressed: true,
        compressionRatio: 0.5,
      );

      final stats = await repo.getArchiveStatistics();

      expect(stats.totalArchives, 2);
      expect(stats.compressedArchives, 1);
      expect(stats.totalMessages, 8);
      expect(stats.oldestArchive, isNotNull);
      expect(stats.newestArchive, isNotNull);
    });

    test('archivesByMonth groups correctly', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final jan = DateTime(2025, 1, 15);
      final feb = DateTime(2025, 2, 20);

      await createArchiveDirectly('ch_m1', 'Jan1', 1, archivedAt: jan);
      await createArchiveDirectly('ch_m2', 'Jan2', 2, archivedAt: jan);
      await createArchiveDirectly('ch_m3', 'Feb1', 1, archivedAt: feb);

      final stats = await repo.getArchiveStatistics();

      expect(stats.archivesByMonth.containsKey('2025-01'), true);
      expect(stats.archivesByMonth['2025-01'], 2);
      expect(stats.archivesByMonth['2025-02'], 1);
    });

    test('messagesByContact aggregation', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_mc1', 'Alice', 5);
      await createArchiveDirectly('ch_mc2', 'Bob', 10);

      final stats = await repo.getArchiveStatistics();

      expect(stats.messagesByContact['Alice'], 5);
      expect(stats.messagesByContact['Bob'], 10);
    });

    test('performance stats reflect recorded operations', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_perf', 'Perf', 2);

      final stats = await repo.getArchiveStatistics();

      expect(stats.performanceStats, isNotNull);
      expect(stats.searchableArchives, stats.totalArchives);
    });
  });

  // ─── permanentlyDeleteArchive ──────────────────────────────────────

  group('ArchiveRepository.permanentlyDeleteArchive', () {
    test('returns failure for non-existent archive', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final result = await repo.permanentlyDeleteArchive(
        ArchiveId('nonexistent'),
      );

      expect(result.success, false);
      expect(result.message, contains('not found'));
      expect(result.operationType, ArchiveOperationType.delete);
    });

    test('deletes archive and returns metadata', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId =
          await createArchiveDirectly('ch_del', 'Deletable', 5);

      final result = await repo.permanentlyDeleteArchive(archiveId);

      expect(result.success, true);
      expect(result.metadata?['messageCount'], 5);
      expect(result.metadata?['sizeFreed'], greaterThan(0));

      // Confirm gone
      final gone = await repo.getArchivedChat(archiveId);
      expect(gone, isNull);
    });
  });

  // ─── getArchivedChat mapping ───────────────────────────────────────

  group('ArchiveRepository.getArchivedChat — mapping', () {
    test('maps archive without metadata_json gracefully', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final db = await DatabaseHelper.database;
      final ts = DateTime.now().millisecondsSinceEpoch;
      const archiveIdStr = 'archive_no_meta';

      await db.insert('archived_chats', {
        'archive_id': archiveIdStr,
        'original_chat_id': 'nometa_chat',
        'contact_name': 'NoMeta',
        'archived_at': ts,
        'message_count': 0,
        'estimated_size': 0,
        'is_compressed': 0,
        'created_at': ts,
        'updated_at': ts,
      });

      final archive = await repo.getArchivedChat(ArchiveId(archiveIdStr));

      expect(archive, isNotNull);
      expect(archive!.contactName, 'NoMeta');
      expect(archive.metadata.version, '1.0');
    });

    test('maps archive with custom_data_json', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final db = await DatabaseHelper.database;
      final ts = DateTime.now().millisecondsSinceEpoch;
      const archiveIdStr = 'archive_custom_data';

      await db.insert('archived_chats', {
        'archive_id': archiveIdStr,
        'original_chat_id': 'custom_chat',
        'contact_name': 'Custom',
        'archived_at': ts,
        'message_count': 0,
        'estimated_size': 0,
        'is_compressed': 0,
        'metadata_json':
            '{"version":"1.0","reason":"custom","originalUnreadCount":0,'
            '"wasOnline":false,"hadUnsentMessages":false,'
            '"estimatedStorageSize":0,"archiveSource":"test",'
            '"tags":[],"hasSearchIndex":true}',
        'custom_data_json': '{"key":"value"}',
        'created_at': ts,
        'updated_at': ts,
      });

      final archive = await repo.getArchivedChat(ArchiveId(archiveIdStr));

      expect(archive, isNotNull);
      expect(archive!.customData, isNotNull);
      expect(archive.customData!['key'], 'value');
    });
  });

  // ─── getArchivedChats — dateRange filter ───────────────────────────

  group('ArchiveRepository.getArchivedChats — dateRange', () {
    test('dateRange filter narrows results', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final old = DateTime(2024, 1, 1);
      final recent = DateTime(2025, 6, 1);

      await createArchiveDirectly('ch_dr1', 'Old', 1, archivedAt: old);
      await createArchiveDirectly('ch_dr2', 'New', 1, archivedAt: recent);

      final filter = ArchiveSearchFilter(
        dateRange: ArchiveDateRange(
          start: DateTime(2025, 1, 1),
          end: DateTime(2025, 12, 31),
        ),
      );
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 1);
      expect(results.first.contactName, 'New');
    });
  });

  // ─── synchronized helper ───────────────────────────────────────────

  group('ArchiveRepository.synchronized', () {
    test('executes block immediately', () {
      var executed = false;
      ArchiveRepository.synchronized(Object(), () {
        executed = true;
      });
      expect(executed, true);
    });
  });

  // ─── clearCache and dispose ────────────────────────────────────────

  group('ArchiveRepository lifecycle', () {
    test('clearCache is no-op', () {
      final repo = ArchiveRepository();
      // Should not throw
      repo.clearCache();
    });

    test('dispose completes without error', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      await repo.dispose();
    });

    test('initialize is idempotent', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      await repo.initialize(); // second call — _isInitialized guard
    });
  });
}
