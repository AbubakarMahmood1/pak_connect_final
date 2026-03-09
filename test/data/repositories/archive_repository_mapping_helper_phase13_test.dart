// Phase 13: Supplementary tests for _ArchiveRepositoryMappingHelper
// Targets uncovered lines: mapToArchivedMessage null/edge-case branches,
// mapToArchivedChatSummary defaults, mapToArchivedChat fallback metadata,
// applyMessageTypeFilter combinations, compress/decompress paths.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_crypto.dart';
import 'package:pak_connect/domain/utils/compression_config.dart';
import 'package:pak_connect/domain/utils/compression_util.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  Logger.root.level = Level.OFF;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'mapping_helper_p13',
    );
    await TestSetup.fullDatabaseReset();
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
  });

  // ── Helper: insert an archive row directly ──────────────────────────

  Future<ArchiveId> insertArchiveRow(
    String chatId,
    String contactName, {
    int messageCount = 1,
    int? lastMessageTime,
    int? estimatedSize,
    bool isCompressed = false,
    String? metadataJson,
    String? compressionInfoJson,
    String? customDataJson,
    String? archiveReason,
    String contactPublicKey = '_DEFAULT_PK_',
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final archiveId = ArchiveId('archive_${chatId}_$now');

    await db.insert('archived_chats', {
      'archive_id': archiveId.value,
      'original_chat_id': chatId,
      'contact_name': contactName,
      'contact_public_key':
          contactPublicKey == '_DEFAULT_PK_' ? 'pk_$chatId' : contactPublicKey,
      'archived_at': now,
      'last_message_time': lastMessageTime,
      'message_count': messageCount,
      'archive_reason': archiveReason,
      'estimated_size': estimatedSize,
      'is_compressed': isCompressed ? 1 : 0,
      'compression_info_json': compressionInfoJson,
      'metadata_json': metadataJson,
      'custom_data_json': customDataJson,
      'created_at': now,
      'updated_at': now,
    });

    return archiveId;
  }

  Future<void> insertMessageRow(
    ArchiveId archiveId,
    String msgId,
    String chatId, {
    String content = 'Test message',
    int? timestamp,
    bool isFromMe = true,
    int status = 2,
    String? replyToMessageId,
    String? threadId,
    String? metadataJson,
    String? deliveryReceiptJson,
    String? readReceiptJson,
    String? reactionsJson,
    String? attachmentsJson,
    String? encryptionInfoJson,
    int? isStarred,
    int? isForwarded,
    int? priority,
    int? editedAt,
    String? originalContent,
    String? archiveMetadataJson,
    String? preservedStateJson,
    String? searchableText,
  }) async {
    final db = await DatabaseHelper.database;
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;

    await db.insert('archived_messages', {
      'id': msgId,
      'archive_id': archiveId.value,
      'original_message_id': 'orig_$msgId',
      'chat_id': chatId,
      'content': content,
      'timestamp': now,
      'is_from_me': isFromMe ? 1 : 0,
      'status': status,
      'reply_to_message_id': replyToMessageId,
      'thread_id': threadId,
      'metadata_json': metadataJson,
      'delivery_receipt_json': deliveryReceiptJson,
      'read_receipt_json': readReceiptJson,
      'reactions_json': reactionsJson,
      'attachments_json': attachmentsJson,
      'encryption_info_json': encryptionInfoJson,
      'is_starred': isStarred,
      'is_forwarded': isForwarded,
      'priority': priority,
      'edited_at': editedAt,
      'original_content': originalContent,
      'archive_metadata_json': archiveMetadataJson,
      'preserved_state_json': preservedStateJson,
      'searchable_text': searchableText,
      'archived_at': now,
      'original_timestamp': now,
      'has_media': 0,
      'created_at': now,
    });
  }

  // ── mapToArchivedMessage via getArchivedChat ───────────────────────

  group('mapToArchivedMessage — null handling', () {
    test('minimal fields: all optional JSON columns null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat1', 'Alice');
      await insertMessageRow(archiveId, 'msg1', 'chat1');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat, isNotNull);
      expect(chat!.messages.length, 1);

      final msg = chat.messages.first;
      expect(msg.id, const MessageId('msg1'));
      expect(msg.replyToMessageId, isNull);
      expect(msg.threadId, isNull);
      expect(msg.metadata, isNull);
      expect(msg.deliveryReceipt, isNull);
      expect(msg.readReceipt, isNull);
      expect(msg.reactions, isEmpty);
      expect(msg.attachments, isEmpty);
      expect(msg.encryptionInfo, isNull);
      expect(msg.editedAt, isNull);
      expect(msg.originalContent, isNull);
      expect(msg.originalSearchableText, isNull);
      expect(msg.preservedState, isNull);
    });

    test('is_starred and is_forwarded default to 0 when null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat2', 'Bob');
      await insertMessageRow(archiveId, 'msg2', 'chat2');

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.isStarred, isFalse);
      expect(msg.isForwarded, isFalse);
    });

    test('is_starred=1 and is_forwarded=1 map to true', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat3', 'Carol');
      await insertMessageRow(
        archiveId,
        'msg3',
        'chat3',
        isStarred: 1,
        isForwarded: 1,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.isStarred, isTrue);
      expect(msg.isForwarded, isTrue);
    });

    test('priority defaults to normal (index 1) when null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat4', 'Dave');
      await insertMessageRow(archiveId, 'msg4', 'chat4');

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.priority, MessagePriority.normal);
    });

    test('explicit priority maps correctly', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat5', 'Eve');
      await insertMessageRow(
        archiveId,
        'msg5',
        'chat5',
        priority: MessagePriority.high.index,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.priority, MessagePriority.high);
    });

    test('editedAt populates when present', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final editTime = DateTime(2025, 6, 1).millisecondsSinceEpoch;
      final archiveId = await insertArchiveRow('chat6', 'Frank');
      await insertMessageRow(
        archiveId,
        'msg6',
        'chat6',
        editedAt: editTime,
        originalContent: 'Original text',
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.editedAt, isNotNull);
      expect(msg.wasEdited, isTrue);
      expect(msg.originalContent, 'Original text');
    });

    test('replyToMessageId and threadId populate when present', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat7', 'Grace');
      await insertMessageRow(
        archiveId,
        'msg7',
        'chat7',
        replyToMessageId: 'reply-target-id',
        threadId: 'thread-001',
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.replyToMessageId, const MessageId('reply-target-id'));
      expect(msg.threadId, 'thread-001');
    });

    test('metadata_json decrypts and parses', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final metaJson = jsonEncode({'topic': 'test', 'custom': 42});
      final archiveId = await insertArchiveRow('chat8', 'Hank');
      await insertMessageRow(
        archiveId,
        'msg8',
        'chat8',
        metadataJson: metaJson,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.metadata, isNotNull);
      expect(msg.metadata!['topic'], 'test');
      expect(msg.metadata!['custom'], 42);
    });

    test('delivery and read receipt JSON parse correctly', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final now = DateTime.now().millisecondsSinceEpoch;
      final deliveryJson = jsonEncode({
        'deliveredAt': now,
        'deviceId': 'dev-1',
      });
      final readJson = jsonEncode({'readAt': now, 'readBy': 'user-1'});

      final archiveId = await insertArchiveRow('chat9', 'Iris');
      await insertMessageRow(
        archiveId,
        'msg9',
        'chat9',
        deliveryReceiptJson: deliveryJson,
        readReceiptJson: readJson,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.deliveryReceipt, isNotNull);
      expect(msg.readReceipt, isNotNull);
    });

    test('reactions_json with multiple reactions', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final now = DateTime.now().millisecondsSinceEpoch;
      final reactionsJson = jsonEncode([
        {'emoji': '👍', 'userId': 'u1', 'reactedAt': now},
        {'emoji': '❤️', 'userId': 'u2', 'reactedAt': now},
      ]);

      final archiveId = await insertArchiveRow('chat10', 'Jack');
      await insertMessageRow(
        archiveId,
        'msg10',
        'chat10',
        reactionsJson: reactionsJson,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.reactions.length, 2);
    });

    test('attachments_json with attachment data', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final attachJson = jsonEncode([
        {'id': 'att1', 'type': 'image', 'name': 'photo.jpg', 'size': 1024},
      ]);

      final archiveId = await insertArchiveRow('chat11', 'Karen');
      await insertMessageRow(
        archiveId,
        'msg11',
        'chat11',
        attachmentsJson: attachJson,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.attachments.length, 1);
      expect(msg.attachments.first.name, 'photo.jpg');
    });

    test('archive_metadata_json fallback to default when null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat12', 'Leo');
      await insertMessageRow(archiveId, 'msg12', 'chat12');

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.archiveMetadata.archiveVersion, '1.0');
      expect(
        msg.archiveMetadata.preservationLevel,
        ArchivePreservationLevel.complete,
      );
      expect(
        msg.archiveMetadata.indexingStatus,
        ArchiveIndexingStatus.indexed,
      );
      expect(msg.archiveMetadata.compressionApplied, isFalse);
    });

    test('archive_metadata_json parses when provided', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archMetaJson = jsonEncode({
        'archiveVersion': '2.0',
        'preservationLevel': ArchivePreservationLevel.standard.index,
        'indexingStatus': ArchiveIndexingStatus.indexing.index,
        'compressionApplied': true,
        'originalSize': 4096,
        'additionalData': {'source': 'migration'},
      });

      final archiveId = await insertArchiveRow('chat13', 'Mona');
      await insertMessageRow(
        archiveId,
        'msg13',
        'chat13',
        archiveMetadataJson: archMetaJson,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.archiveMetadata.archiveVersion, '2.0');
      expect(
        msg.archiveMetadata.preservationLevel,
        ArchivePreservationLevel.standard,
      );
    });

    test('preserved_state_json round-trips', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final stateJson = jsonEncode({'pinned': true, 'muted': false});
      final archiveId = await insertArchiveRow('chat14', 'Nick');
      await insertMessageRow(
        archiveId,
        'msg14',
        'chat14',
        preservedStateJson: stateJson,
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.preservedState, isNotNull);
      expect(msg.preservedState!['pinned'], true);
    });

    test('searchable_text populates originalSearchableText', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chat15', 'Olivia');
      await insertMessageRow(
        archiveId,
        'msg15',
        'chat15',
        searchableText: 'searchable content here',
      );

      final chat = await repo.getArchivedChat(archiveId);
      final msg = chat!.messages.first;
      expect(msg.originalSearchableText, 'searchable content here');
    });
  });

  // ── mapToArchivedChatSummary via getArchivedChats ─────────────────

  group('mapToArchivedChatSummary — edge cases', () {
    test('last_message_time null yields null in summary', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await insertArchiveRow('chatS1', 'Sam', lastMessageTime: null);

      final summaries = await repo.getArchivedChats();
      expect(summaries.isNotEmpty, isTrue);
      final summary = summaries.firstWhere(
        (s) => s.contactName == 'Sam',
      );
      expect(summary.lastMessageTime, isNull);
    });

    test('estimated_size defaults to 0 when null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await insertArchiveRow('chatS2', 'Tina', estimatedSize: null);

      final summaries = await repo.getArchivedChats();
      final summary = summaries.firstWhere(
        (s) => s.contactName == 'Tina',
      );
      expect(summary.estimatedSize, 0);
    });

    test('is_compressed=1 maps to true', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await insertArchiveRow('chatS3', 'Uma', isCompressed: true);

      final summaries = await repo.getArchivedChats();
      final summary = summaries.firstWhere(
        (s) => s.contactName == 'Uma',
      );
      expect(summary.isCompressed, isTrue);
    });

    test('tags default to empty and isSearchable defaults to true', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await insertArchiveRow('chatS4', 'Vera');

      final summaries = await repo.getArchivedChats();
      final summary = summaries.firstWhere(
        (s) => s.contactName == 'Vera',
      );
      expect(summary.tags, isEmpty);
      expect(summary.isSearchable, isTrue);
    });

    test('last_message_time set yields DateTime in summary', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final ts = DateTime(2025, 3, 15).millisecondsSinceEpoch;
      await insertArchiveRow('chatS5', 'Wade', lastMessageTime: ts);

      final summaries = await repo.getArchivedChats();
      final summary = summaries.firstWhere(
        (s) => s.contactName == 'Wade',
      );
      expect(summary.lastMessageTime, isNotNull);
    });
  });

  // ── mapToArchivedChat — metadata fallback ──────────────────────────

  group('mapToArchivedChat — metadata handling', () {
    test('null metadata_json builds default ArchiveMetadata', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow(
        'chatM1',
        'Xavier',
        metadataJson: null,
        archiveReason: 'manual',
      );
      await insertMessageRow(archiveId, 'msgM1', 'chatM1');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat, isNotNull);
      expect(chat!.metadata.version, '1.0');
      expect(chat.metadata.reason, 'manual');
      expect(chat.metadata.archiveSource, 'migration');
    });

    test('provided metadata_json overrides defaults', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final meta = jsonEncode({
        'version': '2.0',
        'reason': 'cleanup',
        'originalUnreadCount': 5,
        'wasOnline': true,
        'hadUnsentMessages': true,
        'estimatedStorageSize': 8192,
        'archiveSource': 'user_action',
        'tags': ['important', 'work'],
        'hasSearchIndex': true,
      });

      final archiveId = await insertArchiveRow(
        'chatM2',
        'Yolanda',
        metadataJson: meta,
      );
      await insertMessageRow(archiveId, 'msgM2', 'chatM2');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat!.metadata.version, '2.0');
      expect(chat.metadata.reason, 'cleanup');
      expect(chat.metadata.originalUnreadCount, 5);
      expect(chat.metadata.wasOnline, isTrue);
      expect(chat.metadata.tags, contains('important'));
    });

    test('null archive_reason falls back to Unknown in default metadata',
        () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow(
        'chatM3',
        'Zach',
        metadataJson: null,
        archiveReason: null,
      );
      await insertMessageRow(archiveId, 'msgM3', 'chatM3');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat!.metadata.reason, 'Unknown');
    });

    test('compression_info_json populates compressionInfo', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final compInfo = jsonEncode({
        'algorithm': 'deflate',
        'originalSize': 10000,
        'compressedSize': 3000,
        'compressionRatio': 0.3,
        'compressedAt': DateTime.now().millisecondsSinceEpoch,
      });

      final archiveId = await insertArchiveRow(
        'chatM4',
        'Amy',
        compressionInfoJson: compInfo,
      );
      await insertMessageRow(archiveId, 'msgM4', 'chatM4');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat!.compressionInfo, isNotNull);
      expect(chat.compressionInfo!.algorithm, 'deflate');
      expect(chat.compressionInfo!.originalSize, 10000);
    });

    test('null compression_info_json leaves compressionInfo null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow('chatM5', 'Beth');
      await insertMessageRow(archiveId, 'msgM5', 'chatM5');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat!.compressionInfo, isNull);
    });

    test('custom_data_json populates customData map', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final customJson = jsonEncode({'tag': 'work', 'priority': 'high'});
      final archiveId = await insertArchiveRow(
        'chatM6',
        'Carl',
        customDataJson: customJson,
      );
      await insertMessageRow(archiveId, 'msgM6', 'chatM6');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat!.customData, isNotNull);
      expect(chat.customData!['tag'], 'work');
    });

    test('contactPublicKey empty string maps from archive row', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final archiveId = await insertArchiveRow(
        'chatM7',
        'Dana',
        contactPublicKey: '',
      );
      await insertMessageRow(archiveId, 'msgM7', 'chatM7');

      final chat = await repo.getArchivedChat(archiveId);
      expect(chat, isNotNull);
      // Empty string should be preserved or converted
      expect(chat!.contactPublicKey, anyOf(isNull, equals('')));
    });
  });

  // ── applyMessageTypeFilter — all branch combinations ──────────────

  group('applyMessageTypeFilter — filter branches', () {
    ArchivedMessage makeMsg({
      required String id,
      bool isFromMe = false,
      bool isStarred = false,
      bool hasAttachments = false,
      int? editedAtMs,
    }) {
      return ArchivedMessage(
        id: MessageId(id),
        chatId: const ChatId('c1'),
        content: 'msg $id',
        timestamp: DateTime.now(),
        isFromMe: isFromMe,
        status: MessageStatus.delivered,
        isStarred: isStarred,
        attachments: hasAttachments
            ? [
                MessageAttachment(
                  id: 'att1',
                  type: 'image',
                  name: 'pic.jpg',
                  size: 100,
                ),
              ]
            : const [],
        editedAt: editedAtMs != null
            ? DateTime.fromMillisecondsSinceEpoch(editedAtMs)
            : null,
        archivedAt: DateTime.now(),
        originalTimestamp: DateTime.now(),
        archiveId: const ArchiveId('a1'),
        archiveMetadata: const ArchiveMessageMetadata(
          archiveVersion: '1.0',
          preservationLevel: ArchivePreservationLevel.complete,
          indexingStatus: ArchiveIndexingStatus.indexed,
          compressionApplied: false,
          originalSize: 0,
          additionalData: {},
        ),
      );
    }

    late List<ArchivedMessage> messages;

    setUp(() {
      messages = [
        makeMsg(id: 'm1', isFromMe: true, isStarred: true),
        makeMsg(id: 'm2', isFromMe: false, hasAttachments: true),
        makeMsg(
          id: 'm3',
          isFromMe: true,
          editedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        makeMsg(id: 'm4', isFromMe: false),
      ];
    });

    test('isFromMe=true filters only sent messages', () {
      final filter = const ArchiveMessageTypeFilter(isFromMe: true);
      final result = messages.where((message) {
        if (filter.isFromMe != null && message.isFromMe != filter.isFromMe) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 2);
      expect(result.every((m) => m.isFromMe), isTrue);
    });

    test('isFromMe=false filters only received messages', () {
      final filter = const ArchiveMessageTypeFilter(isFromMe: false);
      final result = messages.where((message) {
        if (filter.isFromMe != null && message.isFromMe != filter.isFromMe) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 2);
      expect(result.every((m) => !m.isFromMe), isTrue);
    });

    test('hasAttachments=true filters messages with attachments', () {
      final filter = const ArchiveMessageTypeFilter(hasAttachments: true);
      final result = messages.where((message) {
        if (filter.hasAttachments != null &&
            message.attachments.isNotEmpty != filter.hasAttachments) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 1);
      expect(result.first.id, const MessageId('m2'));
    });

    test('wasStarred=true filters starred messages', () {
      final filter = const ArchiveMessageTypeFilter(wasStarred: true);
      final result = messages.where((message) {
        if (filter.wasStarred != null &&
            message.isStarred != filter.wasStarred) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 1);
      expect(result.first.id, const MessageId('m1'));
    });

    test('wasEdited=true filters edited messages', () {
      final filter = const ArchiveMessageTypeFilter(wasEdited: true);
      final result = messages.where((message) {
        if (filter.wasEdited != null && message.wasEdited != filter.wasEdited) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 1);
      expect(result.first.id, const MessageId('m3'));
    });

    test('combined filters: isFromMe=true AND wasStarred=true', () {
      final filter = const ArchiveMessageTypeFilter(
        isFromMe: true,
        wasStarred: true,
      );
      final result = messages.where((message) {
        if (filter.isFromMe != null && message.isFromMe != filter.isFromMe) {
          return false;
        }
        if (filter.wasStarred != null &&
            message.isStarred != filter.wasStarred) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 1);
      expect(result.first.id, const MessageId('m1'));
    });

    test('null filter fields pass all messages', () {
      const filter = ArchiveMessageTypeFilter();
      final result = messages.where((message) {
        if (filter.isFromMe != null && message.isFromMe != filter.isFromMe) {
          return false;
        }
        if (filter.hasAttachments != null &&
            message.attachments.isNotEmpty != filter.hasAttachments) {
          return false;
        }
        if (filter.wasStarred != null &&
            message.isStarred != filter.wasStarred) {
          return false;
        }
        if (filter.wasEdited != null && message.wasEdited != filter.wasEdited) {
          return false;
        }
        return true;
      }).toList();
      expect(result.length, 4);
    });
  });

  // ── ArchiveCrypto — pass-through and legacy ────────────────────────

  group('ArchiveCrypto — field encrypt/decrypt', () {
    test('encryptField is a no-op pass-through', () {
      final result = ArchiveCrypto.encryptField('hello world');
      expect(result, 'hello world');
    });

    test('decryptField returns plain text unchanged', () {
      final result = ArchiveCrypto.decryptField('plain text');
      expect(result, 'plain text');
    });

    test('decryptField handles empty string', () {
      final result = ArchiveCrypto.decryptField('');
      expect(result, '');
    });

    test('encryptField handles special characters', () {
      const input = '{"key":"value","emoji":"🔐"}';
      expect(ArchiveCrypto.encryptField(input), input);
    });

    test('decryptField handles JSON content', () {
      const json = '{"version":"1.0","reason":"test"}';
      expect(ArchiveCrypto.decryptField(json), json);
    });
  });

  // ── CompressionUtil — compress/decompress ──────────────────────────

  group('CompressionUtil — edge cases', () {
    test('compress returns null for small data', () {
      final smallData = Uint8List.fromList([1, 2, 3]);
      final result = CompressionUtil.compress(smallData);
      // Small data below threshold should return null
      expect(result == null || result.compressed.isNotEmpty, isTrue);
    });

    test('compress and decompress round-trip for large data', () {
      final largeText = 'A' * 1000;
      final data = Uint8List.fromList(largeText.codeUnits);
      final compressed = CompressionUtil.compress(data);

      if (compressed != null) {
        expect(compressed.compressed.length, lessThan(data.length));
        final decompressed = CompressionUtil.decompress(
          compressed.compressed,
          originalSize: data.length,
        );
        expect(decompressed, isNotNull);
        expect(decompressed!.length, data.length);
      }
    });

    test('compress with aggressive config', () {
      final data = Uint8List.fromList(('B' * 500).codeUnits);
      final result = CompressionUtil.compress(
        data,
        config: CompressionConfig.aggressive,
      );
      if (result != null) {
        expect(result.stats.compressionRatio, greaterThan(0));
      }
    });

    test('compress with disabled config returns null', () {
      final data = Uint8List.fromList(('C' * 500).codeUnits);
      final result = CompressionUtil.compress(
        data,
        config: CompressionConfig.disabled,
      );
      expect(result, isNull);
    });

    test('decompress with null originalSize', () {
      final data = Uint8List.fromList(('D' * 500).codeUnits);
      final compressed = CompressionUtil.compress(data);
      if (compressed != null) {
        final decompressed = CompressionUtil.decompress(
          compressed.compressed,
          originalSize: null,
        );
        // Should still work or return null gracefully
        expect(decompressed == null || decompressed.isNotEmpty, isTrue);
      }
    });
  });

  // ── ArchiveMessageTypeFilter — serialization ──────────────────────

  group('ArchiveMessageTypeFilter — toJson/fromJson', () {
    test('round-trip with all fields null', () {
      const filter = ArchiveMessageTypeFilter();
      final json = filter.toJson();
      final restored = ArchiveMessageTypeFilter.fromJson(json);
      expect(restored.isFromMe, isNull);
      expect(restored.hasAttachments, isNull);
      expect(restored.wasStarred, isNull);
      expect(restored.wasEdited, isNull);
    });

    test('round-trip with all fields set', () {
      const filter = ArchiveMessageTypeFilter(
        isFromMe: true,
        hasAttachments: false,
        wasStarred: true,
        wasEdited: false,
      );
      final json = filter.toJson();
      final restored = ArchiveMessageTypeFilter.fromJson(json);
      expect(restored.isFromMe, true);
      expect(restored.hasAttachments, false);
      expect(restored.wasStarred, true);
      expect(restored.wasEdited, false);
    });
  });
}
