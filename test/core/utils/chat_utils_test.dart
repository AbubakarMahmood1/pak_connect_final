/// Unit tests for ChatUtils.extractContactKey()
///
/// Critical parsing utility used by:
/// - ChatsRepository.getAllChats()
/// - MessageRepository._ensureChatExists()
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/utils/chat_utils.dart';

void main() {
  group('ChatUtils.extractContactKey', () {
    group('Production Format (Simple)', () {
      test('returns chatId as-is for simple production format', () {
        expect(ChatUtils.extractContactKey('alice', 'mykey'), equals('alice'));
      });

      test('handles contact key with underscores', () {
        expect(
          ChatUtils.extractContactKey('testuser0_key', 'mykey'),
          equals('testuser0_key'),
        );
      });

      test('handles contact key with multiple underscores', () {
        expect(
          ChatUtils.extractContactKey('test_user_0_key', 'mykey'),
          equals('test_user_0_key'),
        );
      });

      test('handles long base64-like keys', () {
        final longKey =
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/==';
        expect(ChatUtils.extractContactKey(longKey, 'mykey'), equals(longKey));
      });
    });

    group('Test Format (Legacy: persistent_chat_)', () {
      test('extracts contact key from test format with simple keys', () {
        expect(
          ChatUtils.extractContactKey('persistent_chat_alice_mykey', 'mykey'),
          equals('alice'),
        );
      });

      test('extracts OTHER key when first key matches myPublicKey', () {
        expect(
          ChatUtils.extractContactKey('persistent_chat_mykey_alice', 'mykey'),
          equals('alice'),
        );
      });

      test('extracts contact key with underscores correctly', () {
        // This is the bug we fixed!
        expect(
          ChatUtils.extractContactKey(
            'persistent_chat_testuser0_key_mykey',
            'mykey',
          ),
          equals('testuser0_key'),
        );
      });

      test('extracts contact key with MULTIPLE underscores correctly', () {
        expect(
          ChatUtils.extractContactKey(
            'persistent_chat_test_user_0_key_mykey',
            'mykey',
          ),
          equals('test_user_0_key'),
        );
      });

      test('handles myPublicKey with underscores', () {
        expect(
          ChatUtils.extractContactKey(
            'persistent_chat_alice_my_test_key',
            'my_test_key',
          ),
          equals('alice'),
        );
      });

      test('handles BOTH keys with underscores', () {
        expect(
          ChatUtils.extractContactKey(
            'persistent_chat_test_user_0_key_my_test_key',
            'my_test_key',
          ),
          equals('test_user_0_key'),
        );
      });

      test(
        'returns first key when myPublicKey is empty (backwards compat)',
        () {
          // This is for MessageRepository which doesn't have myPublicKey
          expect(
            ChatUtils.extractContactKey('persistent_chat_alice_bob', ''),
            equals('alice'),
          );
        },
      );

      test('returns first key when neither matches myPublicKey', () {
        expect(
          ChatUtils.extractContactKey('persistent_chat_alice_bob', 'charlie'),
          equals('alice'),
        );
      });
    });

    group('Temp Format (Ephemeral Connections)', () {
      test('returns null for temp chats', () {
        expect(ChatUtils.extractContactKey('temp_abc123', 'mykey'), isNull);
      });

      test('returns null for temp chats with device ID', () {
        expect(
          ChatUtils.extractContactKey('temp_device123456789', 'mykey'),
          isNull,
        );
      });

      test('returns null for temp chats with underscores', () {
        expect(
          ChatUtils.extractContactKey('temp_device_abc_123', 'mykey'),
          isNull,
        );
      });
    });

    group('Edge Cases', () {
      test('handles empty chatId', () {
        expect(ChatUtils.extractContactKey('', 'mykey'), equals(''));
      });

      test('handles chatId with only prefix (no underscore)', () {
        expect(
          ChatUtils.extractContactKey('persistent_chat_alice', 'mykey'),
          equals('alice'),
        );
      });

      test('handles chatId with prefix but empty key', () {
        expect(
          ChatUtils.extractContactKey('persistent_chat_', 'mykey'),
          isNull,
        );
      });

      test('handles chatId with only one key after prefix', () {
        expect(
          ChatUtils.extractContactKey('persistent_chat_alice_', 'mykey'),
          equals('alice'),
        );
      });

      test('handles whitespace in keys', () {
        expect(
          ChatUtils.extractContactKey('alice bob', 'mykey'),
          equals('alice bob'),
        );
      });

      test('handles special characters in keys', () {
        expect(
          ChatUtils.extractContactKey('alice@example.com', 'mykey'),
          equals('alice@example.com'),
        );
      });

      test('handles unicode characters in keys', () {
        expect(
          ChatUtils.extractContactKey('用户_alice', 'mykey'),
          equals('用户_alice'),
        );
      });
    });

    group('Real-World Scenarios', () {
      test(
        'scenario: ChatsRepository.getAllChats() with production format',
        () {
          // Production uses simple format: chatId = contactPublicKey
          const contactKey = 'user123_public_key';
          const myKey = 'my_device_key';

          expect(
            ChatUtils.extractContactKey(contactKey, myKey),
            equals(contactKey),
          );
        },
      );

      test('scenario: Test with persistent_chat_ format and compound keys', () {
        // This was the failing case in the benchmark test
        const chatId = 'persistent_chat_testuser0_key_mykey';
        const myKey = 'mykey';

        expect(
          ChatUtils.extractContactKey(chatId, myKey),
          equals('testuser0_key'),
        );
      });

      test('scenario: MessageRepository without myPublicKey', () {
        // MessageRepository passes empty string for myPublicKey
        const chatId = 'persistent_chat_alice_bob';

        expect(ChatUtils.extractContactKey(chatId, ''), equals('alice'));
      });

      test('scenario: Temp chat from mesh discovery', () {
        // Ephemeral connections start with temp_
        const tempChatId = 'temp_nearby_device_12345';

        expect(ChatUtils.extractContactKey(tempChatId, 'mykey'), isNull);
      });
    });

    group('Performance', () {
      test('handles large batch of extractions efficiently', () {
        final stopwatch = Stopwatch()..start();

        // Extract 10,000 keys
        for (int i = 0; i < 10000; i++) {
          ChatUtils.extractContactKey(
            'persistent_chat_user${i}_key_mykey',
            'mykey',
          );
        }

        stopwatch.stop();

        // Should complete in <100ms (10µs per extraction)
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      });

      test('handles long keys efficiently', () {
        // Generate 1KB key
        final longKey = 'a' * 1024;
        final chatId = 'persistent_chat_${longKey}_mykey';

        final stopwatch = Stopwatch()..start();
        ChatUtils.extractContactKey(chatId, 'mykey');
        stopwatch.stop();

        // Should complete in <1ms
        expect(stopwatch.elapsedMilliseconds, lessThan(1));
      });
    });

    group('Regression Tests (Bug Fixes)', () {
      test('REGRESSION: Bug fix - extract full key with underscores', () {
        // Before fix: extracted "key" instead of "testuser0_key"
        // After fix: extracts "testuser0_key" correctly
        expect(
          ChatUtils.extractContactKey(
            'persistent_chat_testuser0_key_mykey',
            'mykey',
          ),
          equals('testuser0_key'),
          reason: 'Should extract full contact key, not just last segment',
        );
      });

      test('REGRESSION: Bug fix - handle keys with 3+ underscores', () {
        // Before fix: would split incorrectly with multiple underscores
        // After fix: uses lastIndexOf to split into exactly 2 parts
        expect(
          ChatUtils.extractContactKey(
            'persistent_chat_test_user_0_key_my_test_key',
            'my_test_key',
          ),
          equals('test_user_0_key'),
          reason: 'Should handle multiple underscores in both keys',
        );
      });

      test('REGRESSION: Backwards compatibility with single-word keys', () {
        // Existing tests use simple keys like 'alice', 'bob', 'charlie'
        // These should continue to work
        expect(
          ChatUtils.extractContactKey('persistent_chat_alice_mykey', 'mykey'),
          equals('alice'),
        );
      });
    });
  });
}
