import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/utils/mesh_debug_logger.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('MeshDebugLogger', () {
    late StreamSubscription<LogRecord> subscription;
    late List<LogRecord> records;
    late Level previousRootLevel;

    setUp(() {
      records = <LogRecord>[];
      previousRootLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      subscription = Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'MeshDebugLogger') {
          records.add(record);
        }
      });
    });

    tearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousRootLevel;
    });

    test(
      'logs relay, queue, connection, and utility events without throwing',
      () {
        const messageId = 'msg-1234567890abcdefghij';
        const sender = 'sender-abcdefgh';
        const recipient = 'recipient-abcdefgh';
        const nextHop = 'next-hop-abcdefgh';
        const chatId = 'chat-1234567890abcdefghij';

        MeshDebugLogger.relayStart(messageId, sender, recipient);
        MeshDebugLogger.relayStartId(
          const MessageId('msg-id-typed'),
          sender,
          recipient,
        );
        MeshDebugLogger.relaySuccess(messageId, nextHop, routeScore: '0.92');
        MeshDebugLogger.relaySuccessId(
          const MessageId('msg-success-typed'),
          nextHop,
          routeScore: '0.75',
        );
        MeshDebugLogger.relayDelivered(messageId, sender, recipient);
        MeshDebugLogger.relayDeliveredId(
          const MessageId('msg-delivered-typed'),
          sender,
          recipient,
        );
        MeshDebugLogger.relayBlocked(
          messageId,
          'TTL exceeded',
          spamScore: 0.42,
        );
        MeshDebugLogger.relayBlockedId(
          const MessageId('msg-blocked-typed'),
          'Rate limit',
          spamScore: 0.1,
        );
        MeshDebugLogger.relayDropped(messageId, 'No next hop');
        MeshDebugLogger.relayDroppedId(
          const MessageId('msg-dropped-typed'),
          'Policy denied',
        );

        MeshDebugLogger.messageQueued(messageId, recipient, 'high');
        MeshDebugLogger.messageQueuedId(
          const MessageId('msg-queued-typed'),
          recipient,
          'normal',
        );
        MeshDebugLogger.messageDequeued(messageId, recipient);
        MeshDebugLogger.messageDequeuedId(
          const MessageId('msg-dequeued-typed'),
          recipient,
        );
        MeshDebugLogger.deliveryAttempt(messageId, 2, 5);
        MeshDebugLogger.deliveryAttemptId(
          const MessageId('msg-attempt-typed'),
          1,
          3,
        );
        MeshDebugLogger.deliverySuccess(messageId, recipient);
        MeshDebugLogger.deliverySuccessId(
          const MessageId('msg-success-typed-2'),
          recipient,
        );
        MeshDebugLogger.deliveryFailed(messageId, 'Timeout', 3, 5);
        MeshDebugLogger.deliveryFailedId(
          const MessageId('msg-failed-typed'),
          'Disconnected',
          1,
          4,
        );

        MeshDebugLogger.deviceConnected(recipient, queuedMessages: 4);
        MeshDebugLogger.deviceConnected(recipient);
        MeshDebugLogger.deviceDisconnected(recipient);
        MeshDebugLogger.queueDeliveryTriggered(recipient, 6);
        MeshDebugLogger.queueDeliveryTriggeredId(
          const ChatId('chat-id-typed'),
          2,
        );
        MeshDebugLogger.queueDeliveryComplete(recipient, 6, 5, 1);
        MeshDebugLogger.queueDeliveryCompleteId(
          const ChatId('chat-id-typed-2'),
          2,
          2,
          0,
        );

        MeshDebugLogger.chatMessageSaved(messageId, chatId, sender);
        MeshDebugLogger.chatMessageSavedId(
          const MessageId('msg-chat-saved-typed'),
          chatId,
          sender,
        );
        MeshDebugLogger.chatIdGenerated(chatId, sender, recipient);

        MeshDebugLogger.error(
          'sendMessage',
          'socket closed',
          messageId: messageId,
        );
        MeshDebugLogger.errorId(
          'syncQueue',
          'decode failure',
          messageId: const MessageId('msg-error-typed'),
        );
        MeshDebugLogger.warning(
          'relayPath',
          'path stale',
          messageId: messageId,
        );
        MeshDebugLogger.warningId(
          'queueHealth',
          'high retry count',
          messageId: const MessageId('msg-warning-typed'),
        );

        MeshDebugLogger.separator('Queue Processing');
        MeshDebugLogger.subsection('Dispatch');
        MeshDebugLogger.info('peer', 'online');
        MeshDebugLogger.timing(
          'deliveryLoop',
          const Duration(milliseconds: 123),
          messageId: messageId,
        );

        expect(records, isNotEmpty);
        expect(
          records.any((record) => record.message.contains('RELAY START')),
          isTrue,
        );
        expect(
          records.any((record) => record.message.contains('DELIVERY FAILED')),
          isTrue,
        );
        expect(
          records.any(
            (record) => record.message.contains('QUEUE DELIVERY COMPLETE'),
          ),
          isTrue,
        );
        expect(
          records.any(
            (record) => record.message.contains('ERROR in sendMessage'),
          ),
          isTrue,
        );
        expect(
          records.any(
            (record) => record.message.contains('TIMING deliveryLoop'),
          ),
          isTrue,
        );
        expect(MeshDebugLogger.isDebugEnabled, isA<bool>());
      },
    );
  });
}
