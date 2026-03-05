import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

EnhancedMessage _buildEnhancedMessage({
  String id = 'msg-1',
  String chatId = 'chat-1',
  String content = 'Hello Archive',
  DateTime? timestamp,
  List<MessageAttachment>? attachments,
  List<MessageReaction>? reactions,
  MessageEncryptionInfo? encryptionInfo,
  String? threadId = 'thread-1',
}) {
  final attachmentList =
      attachments ??
      const [
        MessageAttachment(
          id: 'a1',
          type: 'image',
          name: 'photo.png',
          size: 2048,
        ),
      ];
  final reactionList =
      reactions ??
      [
        MessageReaction(
          emoji: 'fire',
          userId: const UserId('user-1'),
          reactedAt: DateTime(2026, 3, 1, 10, 1),
        ),
      ];
  final encryption =
      encryptionInfo ??
      MessageEncryptionInfo(
        algorithm: 'xchacha20',
        keyId: 'key-1',
        isEndToEndEncrypted: true,
        encryptedAt: DateTime(2026, 3, 1, 10, 0),
      );

  return EnhancedMessage(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: content,
    timestamp: timestamp ?? DateTime(2026, 3, 1, 10, 0),
    isFromMe: true,
    status: MessageStatus.delivered,
    replyToMessageId: const MessageId('reply-1'),
    threadId: threadId,
    metadata: const {'lang': 'en'},
    deliveryReceipt: MessageDeliveryReceipt(
      deliveredAt: DateTime(2026, 3, 1, 10, 0, 30),
      deviceId: 'device-1',
    ),
    readReceipt: MessageReadReceipt(
      readAt: DateTime(2026, 3, 1, 10, 1),
      readBy: 'user-1',
    ),
    reactions: reactionList,
    isStarred: true,
    isForwarded: true,
    priority: MessagePriority.high,
    editedAt: DateTime(2026, 3, 1, 10, 2),
    originalContent: 'Original content',
    attachments: attachmentList,
    encryptionInfo: encryption,
  );
}

ArchivedMessage _buildArchivedMessage({
  EnhancedMessage? source,
  DateTime? archivedAt,
  ArchiveMessageMetadata? metadata,
  String? searchableText,
}) {
  final message = source ?? _buildEnhancedMessage();
  final archived = ArchivedMessage.fromEnhancedMessage(
    message,
    archivedAt ?? DateTime(2026, 3, 2, 8, 0),
  );

  if (metadata == null && searchableText == null) {
    return archived;
  }

  return archived.copyWithArchiveUpdate(
    archiveMetadata: metadata,
    originalSearchableText: searchableText,
  );
}

void main() {
  group('ArchivedMessage', () {
    test('fromEnhancedMessage preserves data and indexing context', () {
      final source = _buildEnhancedMessage(content: 'Hello PHOTO world');
      final archived = ArchivedMessage.fromEnhancedMessage(
        source,
        DateTime(2026, 3, 2, 8, 0),
        additionalMetadata: const {'batch': 'b1'},
      );

      expect(archived.id, source.id);
      expect(archived.originalTimestamp, source.timestamp);
      expect(
        archived.archiveMetadata.preservationLevel,
        ArchivePreservationLevel.complete,
      );
      expect(
        archived.archiveMetadata.indexingStatus,
        ArchiveIndexingStatus.indexed,
      );
      expect(archived.archiveMetadata.additionalData['batch'], 'b1');
      expect(archived.searchableText, contains('hello photo world'));
      expect(archived.searchableText, contains('photo.png'));
      expect(archived.searchableText, contains('fire'));
      expect(archived.archiveId.value, startsWith('archived_msg_'));
      expect(archived.isFullyPreserved, isTrue);
      expect(archived.isSearchable, isTrue);
      expect(archived.isCompressed, isFalse);
      expect(archived.preservedState?['wasEdited'], isTrue);
      expect(archived.preservedState?['attachmentCount'], 1);
    });

    test('fromMessage supports custom archive id', () {
      final message = Message(
        id: const MessageId('m-legacy'),
        chatId: const ChatId('chat-legacy'),
        content: 'Legacy message',
        timestamp: DateTime(2026, 2, 1, 7, 0),
        isFromMe: false,
        status: MessageStatus.sent,
      );

      final archived = ArchivedMessage.fromMessage(
        message,
        DateTime(2026, 2, 2, 7, 0),
        customArchiveId: const ArchiveId('archive-custom-1'),
      );

      expect(archived.archiveId, const ArchiveId('archive-custom-1'));
      expect(archived.originalTimestamp, message.timestamp);
      expect(archived.content, 'Legacy message');
    });

    test(
      'toRestoredMessage uses original timestamp and optional chat override',
      () {
        final archived = _buildArchivedMessage();

        final restoredDefault = archived.toRestoredMessage();
        final restoredMoved = archived.toRestoredMessage(
          newChatId: const ChatId('chat-restored'),
        );

        expect(restoredDefault.timestamp, archived.originalTimestamp);
        expect(restoredDefault.chatId, archived.chatId);
        expect(restoredMoved.chatId, const ChatId('chat-restored'));
        expect(restoredMoved.content, archived.content);
      },
    );

    test('copyWithArchiveUpdate overrides requested archive fields', () {
      final archived = _buildArchivedMessage();
      const updatedMetadata = ArchiveMessageMetadata(
        archiveVersion: '1.1',
        preservationLevel: ArchivePreservationLevel.standard,
        indexingStatus: ArchiveIndexingStatus.indexing,
        compressionApplied: true,
        originalSize: 999,
        additionalData: {'reason': 'reindex'},
      );

      final updated = archived.copyWithArchiveUpdate(
        archiveMetadata: updatedMetadata,
        originalSearchableText: 'cached-searchable-text',
        preservedState: const {'state': 'overridden'},
      );

      expect(updated.archiveMetadata.archiveVersion, '1.1');
      expect(updated.archiveMetadata.compressionApplied, isTrue);
      expect(updated.searchableText, 'cached-searchable-text');
      expect(updated.preservedState?['state'], 'overridden');
      expect(updated.id, archived.id);
    });

    test('toJson/fromJson roundtrip retains archive fields', () {
      final archived = _buildArchivedMessage(searchableText: 'cached text');

      final json = archived.toJson();
      final restored = ArchivedMessage.fromJson(json);

      expect(restored.archiveId, archived.archiveId);
      expect(restored.archivedAt, archived.archivedAt);
      expect(restored.originalTimestamp, archived.originalTimestamp);
      expect(restored.originalSearchableText, 'cached text');
      expect(
        restored.archiveMetadata.archiveVersion,
        archived.archiveMetadata.archiveVersion,
      );
      expect(restored.content, archived.content);
    });

    test('fromJson throws on malformed payload', () {
      expect(
        () => ArchivedMessage.fromJson(const {'id': 'broken'}),
        throwsA(isA<Object>()),
      );
    });

    test(
      'restoration info flags high risk for minimal old encrypted attachments',
      () {
        final source = _buildEnhancedMessage();
        final archived = _buildArchivedMessage(
          source: source,
          archivedAt: DateTime.now().subtract(const Duration(days: 420)),
          metadata: const ArchiveMessageMetadata(
            archiveVersion: '1.0',
            preservationLevel: ArchivePreservationLevel.minimal,
            indexingStatus: ArchiveIndexingStatus.indexed,
            compressionApplied: false,
            originalSize: 512,
            additionalData: {},
          ),
        );

        final info = archived.getRestorationInfo();

        expect(info.canRestore, isFalse);
        expect(info.hasWarnings, isTrue);
        expect(
          info.warnings,
          contains(
            'Message was archived with minimal preservation - some data may be lost',
          ),
        );
        expect(
          info.warnings,
          contains('Message attachments may not be fully restored'),
        );
        expect(
          info.warnings,
          contains('Encrypted message keys may have expired'),
        );
        expect(info.riskLevel, 'High');
        expect(info.requiresPostProcessing, isTrue);
      },
    );

    test('restoration info returns none risk for clean recent message', () {
      final source = EnhancedMessage(
        id: const MessageId('clean-msg'),
        chatId: const ChatId('clean-chat'),
        content: 'clean',
        timestamp: DateTime(2026, 3, 1, 10, 0),
        isFromMe: true,
        status: MessageStatus.sent,
      );
      final archived = _buildArchivedMessage(
        source: source,
        archivedAt: DateTime.now().subtract(const Duration(days: 2)),
        metadata: const ArchiveMessageMetadata(
          archiveVersion: '1.0',
          preservationLevel: ArchivePreservationLevel.complete,
          indexingStatus: ArchiveIndexingStatus.indexed,
          compressionApplied: false,
          originalSize: 128,
          additionalData: {},
        ),
      );

      final info = archived.getRestorationInfo();

      expect(info.canRestore, isTrue);
      expect(info.warnings, isEmpty);
      expect(info.riskLevel, 'None');
      expect(info.requiresPostProcessing, isFalse);
    });

    test('archive metadata serialization roundtrip works', () {
      const metadata = ArchiveMessageMetadata(
        archiveVersion: '2.0',
        preservationLevel: ArchivePreservationLevel.standard,
        indexingStatus: ArchiveIndexingStatus.indexError,
        compressionApplied: true,
        originalSize: 2048,
        additionalData: {'attempt': 3},
      );

      final json = metadata.toJson();
      final restored = ArchiveMessageMetadata.fromJson(json);

      expect(restored.archiveVersion, '2.0');
      expect(restored.preservationLevel, ArchivePreservationLevel.standard);
      expect(restored.indexingStatus, ArchiveIndexingStatus.indexError);
      expect(restored.compressionApplied, isTrue);
      expect(restored.additionalData['attempt'], 3);
    });

    test('message restoration risk level maps low and medium states', () {
      final low = MessageRestorationInfo(
        messageId: const MessageId('m-low'),
        canRestore: true,
        warnings: const ['single warning'],
        originalTimestamp: DateTime(2026, 3, 1),
        archiveAge: const Duration(days: 5),
        preservationLevel: ArchivePreservationLevel.complete,
        requiresPostProcessing: false,
      );
      final medium = MessageRestorationInfo(
        messageId: const MessageId('m-medium'),
        canRestore: true,
        warnings: const ['w1', 'w2', 'w3'],
        originalTimestamp: DateTime(2026, 3, 1),
        archiveAge: const Duration(days: 5),
        preservationLevel: ArchivePreservationLevel.standard,
        requiresPostProcessing: true,
      );

      expect(low.riskLevel, 'Low');
      expect(medium.riskLevel, 'Medium');
    });
  });
}
