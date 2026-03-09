import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/repositories/archive_data_helper.dart';
import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

ArchiveMessageMetadata _messageMetadata() {
  return const ArchiveMessageMetadata(
    archiveVersion: '1.0',
    preservationLevel: ArchivePreservationLevel.complete,
    indexingStatus: ArchiveIndexingStatus.indexed,
    compressionApplied: true,
    originalSize: 2048,
    additionalData: <String, dynamic>{'source': 'unit'},
  );
}

ArchiveMetadata _chatMetadata() {
  return const ArchiveMetadata(
    version: '1.0',
    reason: 'manual',
    originalUnreadCount: 2,
    wasOnline: true,
    hadUnsentMessages: false,
    estimatedStorageSize: 4096,
    archiveSource: 'tests',
    tags: <String>['important'],
    hasSearchIndex: true,
    additionalMetadata: <String, dynamic>{'scope': 'all'},
  );
}

ArchivedMessage _fullArchivedMessage() {
  return ArchivedMessage(
    id: const MessageId('msg-1'),
    chatId: const ChatId('chat-1'),
    content: 'hello world',
    timestamp: DateTime(2026, 1, 1, 10, 0, 0),
    isFromMe: true,
    status: MessageStatus.failed,
    replyToMessageId: const MessageId('msg-0'),
    threadId: 'thread-1',
    metadata: const <String, dynamic>{'topic': 'coverage'},
    deliveryReceipt: MessageDeliveryReceipt(
      deliveredAt: DateTime(2026, 1, 1, 10, 1, 0),
      deviceId: 'dev-a',
      networkRoute: 'a>b',
    ),
    readReceipt: MessageReadReceipt(
      readAt: DateTime(2026, 1, 1, 10, 2, 0),
      readBy: 'peer',
      deviceId: 'dev-b',
    ),
    reactions: <MessageReaction>[
      MessageReaction(
        emoji: '👍',
        userId: const UserId('peer'),
        reactedAt: DateTime(2026, 1, 1, 10, 3, 0),
      ),
    ],
    isStarred: true,
    isForwarded: true,
    priority: MessagePriority.urgent,
    editedAt: DateTime(2026, 1, 1, 10, 4, 0),
    originalContent: 'hello original',
    attachments: const <MessageAttachment>[
      MessageAttachment(
        id: 'att-1',
        type: 'image',
        name: 'photo.png',
        size: 1024,
        mimeType: 'image/png',
      ),
    ],
    encryptionInfo: MessageEncryptionInfo(
      algorithm: 'Noise',
      keyId: 'key-1',
      isEndToEndEncrypted: true,
      encryptedAt: DateTime(2026, 1, 1, 10, 5, 0),
      senderKeyFingerprint: 'sender',
      recipientKeyFingerprint: 'receiver',
    ),
    archivedAt: DateTime(2026, 1, 2, 10, 0, 0),
    originalTimestamp: DateTime(2026, 1, 1, 10, 0, 0),
    archiveId: const ArchiveId('archive-message-1'),
    archiveMetadata: _messageMetadata(),
    preservedState: const <String, dynamic>{'edited': true},
  );
}

ArchivedMessage _minimalArchivedMessage() {
  return ArchivedMessage(
    id: const MessageId('msg-2'),
    chatId: const ChatId('chat-2'),
    content: 'minimal',
    timestamp: DateTime(2026, 2, 1, 9, 0, 0),
    isFromMe: false,
    status: MessageStatus.sent,
    archivedAt: DateTime(2026, 2, 2, 9, 0, 0),
    originalTimestamp: DateTime(2026, 2, 1, 9, 0, 0),
    archiveId: const ArchiveId('archive-message-2'),
    archiveMetadata: _messageMetadata(),
  );
}

ArchivedChat _archivedChat({ArchiveCompressionInfo? compressionInfo}) {
  return ArchivedChat(
    id: const ArchiveId('archive-chat-1'),
    originalChatId: const ChatId('chat-1'),
    contactName: 'Alice',
    contactPublicKey: 'peer-public-key',
    archivedAt: DateTime(2026, 3, 1, 8, 0, 0),
    lastMessageTime: DateTime(2026, 2, 28, 18, 0, 0),
    messageCount: 12,
    metadata: _chatMetadata(),
    messages: const <ArchivedMessage>[],
    compressionInfo: compressionInfo,
    customData: const <String, dynamic>{'batch': 1},
  );
}

void main() {
  group('ArchiveDataHelper', () {
    final helper = ArchiveDataHelper();

    test('archivedMessageToMap serializes full message fields', () {
      final map = helper.archivedMessageToMap(
        _fullArchivedMessage(),
        const ArchiveId('root-archive-id'),
      );

      expect(map['id'], 'msg-1');
      expect(map['archive_id'], 'root-archive-id');
      expect(map['original_message_id'], 'msg-1');
      expect(map['chat_id'], 'chat-1');
      expect(map['content'], 'hello world');
      expect(map['is_from_me'], 1);
      expect(map['reply_to_message_id'], 'msg-0');
      expect(map['thread_id'], 'thread-1');
      expect(map['is_starred'], 1);
      expect(map['is_forwarded'], 1);
      expect(map['has_media'], 1);
      expect(map['media_type'], 'image');
      expect(map['original_content'], 'hello original');
      expect(
        jsonDecode(map['metadata_json'] as String),
        const <String, dynamic>{'topic': 'coverage'},
      );
      expect(
        jsonDecode(map['preserved_state_json'] as String),
        const <String, dynamic>{'edited': true},
      );
      expect(
        (jsonDecode(map['encryption_info_json'] as String)
            as Map<String, dynamic>)['algorithm'],
        'Noise',
      );
      expect(
        (jsonDecode(map['archive_metadata_json'] as String)
            as Map<String, dynamic>)['archiveVersion'],
        '1.0',
      );
      expect(map['created_at'], isA<int>());
    });

    test('archivedMessageToMap handles null and empty optional fields', () {
      final map = helper.archivedMessageToMap(
        _minimalArchivedMessage(),
        const ArchiveId('root-archive-id-2'),
      );

      expect(map['reply_to_message_id'], isNull);
      expect(map['thread_id'], isNull);
      expect(map['is_starred'], 0);
      expect(map['is_forwarded'], 0);
      expect(map['original_content'], isNull);
      expect(map['has_media'], 0);
      expect(map['media_type'], isNull);
      expect(map['metadata_json'], isNull);
      expect(map['delivery_receipt_json'], isNull);
      expect(map['read_receipt_json'], isNull);
      expect(map['reactions_json'], isNull);
      expect(map['attachments_json'], isNull);
      expect(map['preserved_state_json'], isNull);
      expect(
        (jsonDecode(map['encryption_info_json'] as String)
            as Map<String, dynamic>)['algorithm'],
        'SQLCipher',
      );
    });

    test(
      'archivedChatToMap includes compression and optional encrypted data',
      () {
        final chat = _archivedChat(
          compressionInfo: ArchiveCompressionInfo(
            algorithm: 'gzip',
            originalSize: 4000,
            compressedSize: 2000,
            compressionRatio: 0.5,
            compressedAt: DateTime(2026, 3, 1, 8, 1, 0),
          ),
        );

        final map = helper.archivedChatToMap(
          chat,
          const ChatId('chat-origin'),
          'cleanup',
          const <String, dynamic>{'tag': 'roi'},
        );

        expect(map['archive_id'], 'archive-chat-1');
        expect(map['original_chat_id'], 'chat-origin');
        expect(map['contact_name'], 'Alice');
        expect(map['contact_public_key'], 'peer-public-key');
        expect(map['message_count'], 12);
        expect(map['archive_reason'], 'cleanup');
        expect(
          jsonDecode(map['metadata_json'] as String),
          _chatMetadata().toJson(),
        );
        expect(
          jsonDecode(map['custom_data_json'] as String),
          const <String, dynamic>{'tag': 'roi'},
        );
        expect(
          jsonDecode(map['compression_info_json'] as String),
          chat.compressionInfo!.toJson(),
        );
        expect(map['is_compressed'], 1);
        expect(map['compression_ratio'], 0.5);
        expect(map['created_at'], isA<int>());
        expect(map['updated_at'], isA<int>());
      },
    );

    test(
      'archivedChatToMap emits null reason/custom/compression when absent',
      () {
        final map = helper.archivedChatToMap(
          _archivedChat(),
          const ChatId('chat-origin-2'),
          null,
          null,
        );

        expect(map['archive_reason'], isNull);
        expect(map['custom_data_json'], isNull);
        expect(map['compression_info_json'], isNull);
        expect(map['compression_ratio'], isNull);
        expect(map['is_compressed'], 0);
      },
    );
  });
}
