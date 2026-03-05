import 'package:flutter_test/flutter_test.dart';

import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('ArchivedChat', () {
    test('fromChatAndMessages builds archive with expected metadata', () {
      final now = DateTime.now();
      final chatItem = ChatListItem(
        chatId: ChatId('chat_1'),
        contactName: 'Alice',
        contactPublicKey: 'pk_alice',
        lastMessage: 'latest',
        lastMessageTime: now,
        unreadCount: 3,
        isOnline: true,
        hasUnsentMessages: true,
        lastSeen: now.subtract(const Duration(minutes: 5)),
      );
      final messages = [
        _enhanced(
          'm1',
          'chat_1',
          'hello',
          now.subtract(const Duration(days: 2)),
        ),
        _enhanced(
          'm2',
          'chat_1',
          'world',
          now.subtract(const Duration(hours: 1)),
        ),
      ];

      final archive = ArchivedChat.fromChatAndMessages(
        archiveId: const ArchiveId('arch_1'),
        chatItem: chatItem,
        messages: messages,
      );

      expect(archive.id, const ArchiveId('arch_1'));
      expect(archive.originalChatId, ChatId('chat_1'));
      expect(archive.contactName, 'Alice');
      expect(archive.contactPublicKey, 'pk_alice');
      expect(archive.messageCount, 2);
      expect(archive.metadata.reason, 'User archived');
      expect(archive.metadata.originalUnreadCount, 3);
      expect(archive.metadata.wasOnline, isTrue);
      expect(archive.metadata.hadUnsentMessages, isTrue);
      expect(archive.metadata.archiveSource, 'ChatManagementService');
      expect(archive.messages, hasLength(2));
      expect(archive.isSearchable, isFalse);
      expect(archive.isCompressed, isFalse);
      expect(archive.estimatedSize, archive.metadata.estimatedStorageSize);
      expect(archive.chatDuration, isNotNull);
      expect(archive.chatDuration!.inHours, greaterThanOrEqualTo(47));
    });

    test('chatDuration returns null when lastMessageTime is absent', () {
      final archive = ArchivedChat(
        id: const ArchiveId('arch_null'),
        originalChatId: ChatId('chat_null'),
        contactName: 'Null',
        archivedAt: DateTime.now().subtract(const Duration(days: 1)),
        lastMessageTime: null,
        messageCount: 1,
        metadata: const ArchiveMetadata(
          version: '1.0',
          reason: 'null-check',
          originalUnreadCount: 0,
          wasOnline: false,
          hadUnsentMessages: false,
          estimatedStorageSize: 128,
          archiveSource: 'test',
          tags: [],
        ),
        messages: [_enhancedArchivedMessage('m1', 'chat_null')],
      );

      expect(archive.chatDuration, isNull);
    });
    test(
      'getRestorationPreview includes warnings and restore estimate branches',
      () {
        final oldArchive = _archive(
          archivedAt: DateTime.now().subtract(const Duration(days: 45)),
          messageCount: 1500,
          metadata: const ArchiveMetadata(
            version: '1.0',
            reason: 'bulk',
            originalUnreadCount: 0,
            wasOnline: false,
            hadUnsentMessages: true,
            estimatedStorageSize: 2 * 1024 * 1024,
            archiveSource: 'test',
            tags: ['bulk'],
            hasSearchIndex: true,
          ),
          compressionInfo: ArchiveCompressionInfo(
            algorithm: 'gzip',
            originalSize: 3 * 1024 * 1024,
            compressedSize: 2 * 1024 * 1024,
            compressionRatio: 0.66,
            compressedAt: DateTime.now(),
          ),
          messages: [
            _enhancedArchivedMessage(
              'recent',
              'chat_warn',
              timestamp: DateTime.now().subtract(const Duration(days: 1)),
            ),
            _enhancedArchivedMessage(
              'old',
              'chat_warn',
              timestamp: DateTime.now().subtract(const Duration(days: 10)),
            ),
          ],
        );

        final preview = oldArchive.getRestorationPreview();

        expect(preview.chatId, oldArchive.originalChatId.value);
        expect(preview.messageCount, 1500);
        expect(preview.recentMessageCount, 1);
        expect(preview.hasWarnings, isTrue);
        expect(preview.isRecentlyActive, isTrue);
        expect(
          preview.estimatedRestoreTime,
          const Duration(milliseconds: 3800),
        );
        expect(
          preview.warnings.any((w) => w.contains('over 30 days old')),
          isTrue,
        );
        expect(
          preview.warnings.any(
            (w) => w.contains('restoration may take longer'),
          ),
          isTrue,
        );
        expect(
          preview.warnings.any((w) => w.contains('sufficient storage space')),
          isTrue,
        );
        expect(
          preview.warnings.any((w) => w.contains('unsent messages')),
          isTrue,
        );
      },
    );

    test('toSummary maps current archive state', () {
      final archive = _archive(
        metadata: const ArchiveMetadata(
          version: '1.0',
          reason: 'summary',
          originalUnreadCount: 0,
          wasOnline: false,
          hadUnsentMessages: false,
          estimatedStorageSize: 900,
          archiveSource: 'test',
          tags: ['one', 'two'],
          hasSearchIndex: true,
        ),
      );

      final summary = archive.toSummary();

      expect(summary.id, archive.id);
      expect(summary.originalChatId, archive.originalChatId);
      expect(summary.contactName, archive.contactName);
      expect(summary.messageCount, archive.messageCount);
      expect(summary.estimatedSize, archive.estimatedSize);
      expect(summary.isCompressed, isFalse);
      expect(summary.tags, ['one', 'two']);
      expect(summary.isSearchable, isTrue);
    });

    test(
      'copyWith overrides fields and recalculates messageCount from messages',
      () {
        final original = _archive(
          messageCount: 5,
          messages: [_enhancedArchivedMessage('m1', 'chat_copy')],
        );
        final newMessages = [
          _enhancedArchivedMessage('m2', 'chat_copy'),
          _enhancedArchivedMessage('m3', 'chat_copy'),
        ];
        final newCompression = ArchiveCompressionInfo(
          algorithm: 'zstd',
          originalSize: 4096,
          compressedSize: 2048,
          compressionRatio: 0.5,
          compressedAt: DateTime.now(),
        );

        final updated = original.copyWith(
          metadata: const ArchiveMetadata(
            version: '2.0',
            reason: 'updated',
            originalUnreadCount: 1,
            wasOnline: true,
            hadUnsentMessages: false,
            estimatedStorageSize: 999,
            archiveSource: 'copyWith',
            tags: ['updated'],
            hasSearchIndex: false,
          ),
          messages: newMessages,
          compressionInfo: newCompression,
          customData: const {'k': 'v'},
        );

        expect(updated.metadata.version, '2.0');
        expect(updated.messages, hasLength(2));
        expect(updated.messageCount, 2);
        expect(updated.compressionInfo, isNotNull);
        expect(updated.customData, {'k': 'v'});
      },
    );

    test('toJson/fromJson round-trips with optional fields', () {
      final archivedAt = DateTime.now().subtract(const Duration(days: 2));
      final original = _archive(
        archivedAt: archivedAt,
        lastMessageTime: DateTime.now().subtract(const Duration(hours: 1)),
        metadata: ArchiveMetadata(
          version: '1.1',
          reason: 'json',
          originalUnreadCount: 4,
          wasOnline: true,
          hadUnsentMessages: true,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 30)),
          estimatedStorageSize: 1234,
          archiveSource: 'unit',
          tags: const ['a', 'b'],
          hasSearchIndex: true,
          additionalMetadata: const {'origin': 'test'},
        ),
        compressionInfo: ArchiveCompressionInfo(
          algorithm: 'gzip',
          originalSize: 3000,
          compressedSize: 2000,
          compressionRatio: 0.66,
          compressedAt: DateTime.now(),
          compressionMetadata: const {'level': 6},
        ),
        customData: const {'flag': true},
      );

      final roundTrip = ArchivedChat.fromJson(original.toJson());

      expect(roundTrip.id, original.id);
      expect(roundTrip.originalChatId, original.originalChatId);
      expect(roundTrip.contactName, original.contactName);
      expect(roundTrip.contactPublicKey, original.contactPublicKey);
      expect(
        roundTrip.archivedAt.millisecondsSinceEpoch,
        archivedAt.millisecondsSinceEpoch,
      );
      expect(roundTrip.messageCount, original.messageCount);
      expect(roundTrip.metadata.hasSearchIndex, isTrue);
      expect(roundTrip.metadata.additionalMetadata?['origin'], 'test');
      expect(roundTrip.compressionInfo?.algorithm, 'gzip');
      expect(roundTrip.customData?['flag'], isTrue);
      expect(roundTrip.messages, isNotEmpty);
    });

    test('fromJson rethrows on invalid payload', () {
      expect(
        () => ArchivedChat.fromJson(const {
          'id': 'arch_bad',
          'originalChatId': 'chat_bad',
          'contactName': 'Bad',
          'archivedAt': 1,
          'messageCount': 1,
          'metadata': {'version': '1.0'},
          'messages': 'not-a-list',
        }),
        throwsA(isA<Object>()),
      );
    });
  });

  group('ArchiveMetadata', () {
    test('toJson/fromJson supports optional and default fields', () {
      final metadata = ArchiveMetadata(
        version: '1.0',
        reason: 'meta',
        originalUnreadCount: 2,
        wasOnline: true,
        hadUnsentMessages: false,
        lastSeen: DateTime.now().subtract(const Duration(minutes: 10)),
        estimatedStorageSize: 42,
        archiveSource: 'test',
        tags: const ['x'],
        hasSearchIndex: true,
        additionalMetadata: const {'v': 1},
      );
      final restored = ArchiveMetadata.fromJson(metadata.toJson());

      expect(restored.version, '1.0');
      expect(restored.reason, 'meta');
      expect(restored.hasSearchIndex, isTrue);
      expect(restored.additionalMetadata?['v'], 1);
    });

    test('fromJson falls back hasSearchIndex to false when absent', () {
      final restored = ArchiveMetadata.fromJson({
        'version': '1.0',
        'reason': 'meta',
        'originalUnreadCount': 0,
        'wasOnline': false,
        'hadUnsentMessages': false,
        'estimatedStorageSize': 0,
        'archiveSource': 'test',
        'tags': const <String>[],
      });

      expect(restored.hasSearchIndex, isFalse);
      expect(restored.additionalMetadata, isNull);
    });
  });

  group('ArchiveCompressionInfo', () {
    test('toJson/fromJson round-trips compression metadata', () {
      final info = ArchiveCompressionInfo(
        algorithm: 'brotli',
        originalSize: 1200,
        compressedSize: 300,
        compressionRatio: 0.25,
        compressedAt: DateTime.now(),
        compressionMetadata: const {'window': 16},
      );
      final restored = ArchiveCompressionInfo.fromJson(info.toJson());

      expect(restored.algorithm, 'brotli');
      expect(restored.originalSize, 1200);
      expect(restored.compressedSize, 300);
      expect(restored.compressionRatio, 0.25);
      expect(restored.compressionMetadata?['window'], 16);
    });
  });

  group('ArchivedChatSummary', () {
    test('formattedSize covers byte, KB, and MB formatting', () {
      final now = DateTime.now();
      final bytes = ArchivedChatSummary(
        id: const ArchiveId('a1'),
        originalChatId: ChatId('c1'),
        contactName: 'A',
        archivedAt: now,
        messageCount: 1,
        estimatedSize: 999,
        isCompressed: false,
        tags: const [],
        isSearchable: false,
      );
      final kb = ArchivedChatSummary(
        id: const ArchiveId('a2'),
        originalChatId: ChatId('c2'),
        contactName: 'B',
        archivedAt: now,
        messageCount: 1,
        estimatedSize: 25 * 1024,
        isCompressed: false,
        tags: const [],
        isSearchable: false,
      );
      final mb = ArchivedChatSummary(
        id: const ArchiveId('a3'),
        originalChatId: ChatId('c3'),
        contactName: 'C',
        archivedAt: now,
        messageCount: 1,
        estimatedSize: 3 * 1024 * 1024,
        isCompressed: true,
        tags: const [],
        isSearchable: true,
      );

      expect(bytes.formattedSize, '999B');
      expect(kb.formattedSize, '25.0KB');
      expect(mb.formattedSize, '3.0MB');
    });

    test('ageDescription covers today/day/week/month/year ranges', () {
      final now = DateTime.now();
      ArchivedChatSummary summaryWithAge(Duration age) => ArchivedChatSummary(
        id: const ArchiveId('a_age'),
        originalChatId: ChatId('c_age'),
        contactName: 'A',
        archivedAt: now.subtract(age),
        messageCount: 1,
        estimatedSize: 1,
        isCompressed: false,
        tags: const [],
        isSearchable: false,
      );

      expect(summaryWithAge(const Duration(hours: 6)).ageDescription, 'Today');
      expect(summaryWithAge(const Duration(days: 3)).ageDescription, '3d ago');
      expect(summaryWithAge(const Duration(days: 14)).ageDescription, '2w ago');
      expect(
        summaryWithAge(const Duration(days: 95)).ageDescription,
        '3mo ago',
      );
      expect(
        summaryWithAge(const Duration(days: 800)).ageDescription,
        '2y ago',
      );
    });
  });

  group('ChatRestorationPreview', () {
    test('flags and formattedRestoreTime branches are computed', () {
      final ms = ChatRestorationPreview(
        chatId: 'c1',
        contactName: 'A',
        messageCount: 1,
        recentMessageCount: 0,
        estimatedRestoreTime: const Duration(milliseconds: 750),
        warnings: const [],
      );
      final secs = ChatRestorationPreview(
        chatId: 'c2',
        contactName: 'B',
        messageCount: 1,
        recentMessageCount: 1,
        estimatedRestoreTime: const Duration(seconds: 9),
        warnings: const ['w'],
      );
      final mins = ChatRestorationPreview(
        chatId: 'c3',
        contactName: 'C',
        messageCount: 1,
        recentMessageCount: 2,
        estimatedRestoreTime: const Duration(seconds: 65),
        warnings: const [],
      );

      expect(ms.formattedRestoreTime, '750ms');
      expect(ms.hasWarnings, isFalse);
      expect(ms.isRecentlyActive, isFalse);

      expect(secs.formattedRestoreTime, '9s');
      expect(secs.hasWarnings, isTrue);
      expect(secs.isRecentlyActive, isTrue);

      expect(mins.formattedRestoreTime, '1m 5s');
      expect(mins.isRecentlyActive, isTrue);
    });
  });
}

EnhancedMessage _enhanced(
  String id,
  String chatId,
  String content,
  DateTime timestamp,
) {
  return EnhancedMessage.fromMessage(
    Message(
      id: MessageId(id),
      chatId: ChatId(chatId),
      content: content,
      timestamp: timestamp,
      isFromMe: true,
      status: MessageStatus.delivered,
    ),
  );
}

ArchivedMessage _enhancedArchivedMessage(
  String id,
  String chatId, {
  DateTime? timestamp,
}) {
  final source = _enhanced(
    id,
    chatId,
    'content_$id',
    timestamp ?? DateTime.now().subtract(const Duration(hours: 2)),
  );
  return ArchivedMessage.fromEnhancedMessage(
    source,
    DateTime.now(),
    customArchiveId: const ArchiveId('arch_helper'),
  );
}

ArchivedChat _archive({
  DateTime? archivedAt,
  DateTime? lastMessageTime,
  int messageCount = 2,
  ArchiveMetadata? metadata,
  List<ArchivedMessage>? messages,
  ArchiveCompressionInfo? compressionInfo,
  Map<String, dynamic>? customData,
}) {
  final archivedMessages =
      messages ??
      [
        _enhancedArchivedMessage(
          'm1',
          'chat_helper',
          timestamp: DateTime.now().subtract(const Duration(days: 2)),
        ),
        _enhancedArchivedMessage(
          'm2',
          'chat_helper',
          timestamp: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      ];

  return ArchivedChat(
    id: const ArchiveId('arch_helper'),
    originalChatId: ChatId('chat_helper'),
    contactName: 'Helper',
    contactPublicKey: 'pk_helper',
    archivedAt: archivedAt ?? DateTime.now().subtract(const Duration(days: 5)),
    lastMessageTime:
        lastMessageTime ?? DateTime.now().subtract(const Duration(hours: 1)),
    messageCount: messageCount,
    metadata:
        metadata ??
        const ArchiveMetadata(
          version: '1.0',
          reason: 'helper',
          originalUnreadCount: 0,
          wasOnline: false,
          hadUnsentMessages: false,
          estimatedStorageSize: 2048,
          archiveSource: 'test',
          tags: [],
        ),
    messages: archivedMessages,
    compressionInfo: compressionInfo,
    customData: customData,
  );
}
