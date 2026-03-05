import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('MessageSecurity', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await MessageSecurity.clearProcessedMessages();
    });

    test(
      'generateSecureMessageId uses v2 format and increments nonce',
      () async {
        final id1 = await MessageSecurity.generateSecureMessageId(
          senderPublicKey: 'sender-A',
          content: 'hello',
          recipientPublicKey: 'recipient-A',
        );
        final id2 = await MessageSecurity.generateSecureMessageId(
          senderPublicKey: 'sender-A',
          content: 'hello again',
          recipientPublicKey: 'recipient-A',
        );

        final parts1 = id1.split('.');
        final parts2 = id2.split('.');

        expect(parts1, hasLength(3));
        expect(parts2, hasLength(3));
        expect(parts1[0], '2');
        expect(parts2[0], '2');
        expect(int.parse(parts2[1]), int.parse(parts1[1]) + 1);
        expect(parts1[2].length, 32);
        expect(parts2[2].length, 32);
      },
    );

    test('validate rejects invalid format and malformed components', () async {
      final invalidFormat = await MessageSecurity.validateMessage(
        messageId: 'not-a-valid-id',
        senderPublicKey: 'sender-B',
        content: 'payload',
      );
      expect(invalidFormat.isValid, isFalse);
      expect(invalidFormat.isError, isTrue);
      expect(invalidFormat.errorMessage, contains('Invalid message ID format'));

      final malformed = await MessageSecurity.validateMessage(
        messageId: '2.notInt.hashvalue',
        senderPublicKey: 'sender-B',
        content: 'payload',
      );
      expect(malformed.isValid, isFalse);
      expect(malformed.isError, isTrue);
      expect(
        malformed.errorMessage,
        contains('Malformed message ID components'),
      );
    });

    test(
      'validate reports replay from persisted entries when retries are disabled',
      () async {
        const replayId = '2.5.abcdefabcdefabcdefabcdefabcdefab';
        SharedPreferences.setMockInitialValues(<String, Object>{
          'processed_message_ids_v2': <String>[
            '$replayId|${DateTime.now().millisecondsSinceEpoch}',
          ],
        });

        final result = await MessageSecurity.validateMessage(
          messageId: replayId,
          senderPublicKey: 'sender-C',
          content: 'payload',
          allowRetry: false,
        );

        expect(result.isValid, isFalse);
        expect(result.isReplay, isTrue);
        expect(result.errorMessage, contains('already processed'));
      },
    );

    test(
      'allowRetry bypasses replay block but still enforces integrity',
      () async {
        const replayId = '2.5.abcdefabcdefabcdefabcdefabcdefab';
        SharedPreferences.setMockInitialValues(<String, Object>{
          'processed_message_ids_v2': <String>[
            '$replayId|${DateTime.now().millisecondsSinceEpoch}',
          ],
        });

        final result = await MessageSecurity.validateMessage(
          messageId: replayId,
          senderPublicKey: 'sender-D',
          content: 'payload',
          allowRetry: true,
        );

        expect(result.isValid, isFalse);
        expect(result.isReplay, isFalse);
        expect(result.errorMessage, contains('integrity check failed'));
      },
    );

    test(
      'validate rejects very old nonces relative to stored sender counter',
      () async {
        const sender = 'sender-E';
        final nonceKey =
            'nonce_counter_${sha256.convert(utf8.encode(sender)).toString().substring(0, 16)}';

        SharedPreferences.setMockInitialValues(<String, Object>{
          nonceKey: 5000,
        });

        final result = await MessageSecurity.validateMessage(
          messageId: '2.1.abcdefabcdefabcdefabcdefabcdefab',
          senderPublicKey: sender,
          content: 'payload',
        );

        expect(result.isValid, isFalse);
        expect(result.isError, isTrue);
        expect(result.errorMessage, contains('Nonce too old'));
      },
    );

    test('clearProcessedMessages and getStats expose replay metrics', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'processed_message_ids_v2': <String>[
          '2.1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|1700000000000',
          '2.2.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|1700000001000',
        ],
      });

      final before = await MessageSecurity.getStats();
      expect(before.processedMessagesCount, 2);
      expect(before.toString(), contains('processed: 2'));

      await MessageSecurity.clearProcessedMessages();
      final after = await MessageSecurity.getStats();
      expect(after.processedMessagesCount, 0);
      expect(after.cacheSize, 0);
    });

    test('result helper factories expose semantic flags', () {
      final valid = MessageValidationResult.valid();
      final replay = MessageValidationResult.replay('duplicate');
      final invalid = MessageValidationResult.invalid('broken');

      expect(valid.isValid, isTrue);
      expect(valid.isReplay, isFalse);
      expect(valid.isError, isFalse);

      expect(replay.isValid, isFalse);
      expect(replay.isReplay, isTrue);
      expect(replay.isError, isFalse);

      expect(invalid.isValid, isFalse);
      expect(invalid.isReplay, isFalse);
      expect(invalid.isError, isTrue);
    });
  });
}
