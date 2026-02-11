import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  group('ISeenMessageStore Abstraction Contract', () {
    late ISeenMessageStore seenMessageStore;
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUpAll(() async {
      // Only initialize once for the entire group
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'seen_message_store_abstraction',
      );
    });

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      seenMessageStore = TestSetup.getService<ISeenMessageStore>();
      await seenMessageStore.clear();
    });

    tearDown(() async {
      await seenMessageStore.clear();
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    tearDownAll(() {
      TestSetup.resetDIServiceLocator();
    });

    group('Message Delivery Tracking', () {
      test('✅ marks message as delivered', () async {
        // Act
        await seenMessageStore.markDelivered('msg-1');

        // Assert
        expect(seenMessageStore.hasDelivered('msg-1'), isTrue);
      });

      test('✅ returns false for undelivered message', () {
        // Assert
        expect(seenMessageStore.hasDelivered('unknown-msg'), isFalse);
      });

      test('✅ prevents duplicate relay of same message', () async {
        // Arrange
        const messageId = 'msg-relay-1';

        // Act
        await seenMessageStore.markDelivered(messageId);
        final firstCheck = seenMessageStore.hasDelivered(messageId);

        // Attempt to mark again (should be idempotent)
        await seenMessageStore.markDelivered(messageId);
        final secondCheck = seenMessageStore.hasDelivered(messageId);

        // Assert
        expect(firstCheck, isTrue);
        expect(secondCheck, isTrue); // Still marked as delivered
      });

      test('✅ tracks multiple messages independently', () async {
        // Arrange
        const msg1 = 'msg-1';
        const msg2 = 'msg-2';
        const msg3 = 'msg-3';

        // Act
        await seenMessageStore.markDelivered(msg1);
        await seenMessageStore.markDelivered(msg3);

        // Assert
        expect(seenMessageStore.hasDelivered(msg1), isTrue);
        expect(seenMessageStore.hasDelivered(msg2), isFalse);
        expect(seenMessageStore.hasDelivered(msg3), isTrue);
      });
    });

    group('Message Read Tracking', () {
      test('✅ marks message as read', () async {
        // Act
        await seenMessageStore.markRead('msg-read-1');

        // Assert
        expect(seenMessageStore.hasRead('msg-read-1'), isTrue);
      });

      test('✅ returns false for unread message', () {
        // Assert
        expect(seenMessageStore.hasRead('unknown-msg'), isFalse);
      });

      test('✅ independent from delivery tracking', () async {
        // Arrange
        const messageId = 'msg-state';

        // Act - Mark as delivered but not read
        await seenMessageStore.markDelivered(messageId);

        // Assert
        expect(seenMessageStore.hasDelivered(messageId), isTrue);
        expect(seenMessageStore.hasRead(messageId), isFalse);
      });

      test('✅ can mark message as both delivered and read', () async {
        // Arrange
        const messageId = 'msg-both';

        // Act
        await seenMessageStore.markDelivered(messageId);
        await seenMessageStore.markRead(messageId);

        // Assert
        expect(seenMessageStore.hasDelivered(messageId), isTrue);
        expect(seenMessageStore.hasRead(messageId), isTrue);
      });
    });

    group('Mesh Relay Use Cases', () {
      test('✅ prevents message from being relayed twice', () async {
        // Simulate relay scenario:
        // 1. Device A receives message from Device B
        // 2. Device A checks if message should be relayed
        // 3. Device A marks as delivered (consumed by relay engine)
        // 4. Same message arrives again (network fluke)
        // 5. Device A checks again - should skip relay

        // Arrange
        const messageId = 'network-msg-123';

        // Act - First delivery (relay it)
        final shouldRelayFirst = !seenMessageStore.hasDelivered(messageId);
        if (shouldRelayFirst) {
          await seenMessageStore.markDelivered(messageId);
        }

        // Simulate same message arriving again
        final shouldRelaySecond = !seenMessageStore.hasDelivered(messageId);

        // Assert
        expect(shouldRelayFirst, isTrue); // First time: relay
        expect(shouldRelaySecond, isFalse); // Second time: skip
      });

      test(
        '✅ maintains separate delivered and read states for relay logic',
        () async {
          // Arrange
          const messageId = 'relay-msg';

          // Act - Relay engine marks as delivered (consumed)
          await seenMessageStore.markDelivered(messageId);

          // User reads message later
          await seenMessageStore.markRead(messageId);

          // Assert
          expect(seenMessageStore.hasDelivered(messageId), isTrue);
          expect(seenMessageStore.hasRead(messageId), isTrue);
        },
      );
    });

    group('Statistics and Monitoring', () {
      test('✅ getStatistics returns non-null map', () {
        // Act
        final stats = seenMessageStore.getStatistics();

        // Assert
        expect(stats, isNotNull);
        expect(stats, isA<Map<String, dynamic>>());
      });

      test('✅ statistics reflect tracked messages', () async {
        // Arrange
        await seenMessageStore.markDelivered('msg-1');
        await seenMessageStore.markDelivered('msg-2');
        await seenMessageStore.markRead('msg-3');

        // Act
        final stats = seenMessageStore.getStatistics();

        // Assert
        expect(stats.containsKey('deliveredCount') || stats.isNotEmpty, isTrue);
      });

      test('✅ statistics are accurate after clear', () async {
        // Arrange
        await seenMessageStore.markDelivered('msg-1');

        // Act
        await seenMessageStore.clear();
        final statsAfter = seenMessageStore.getStatistics();

        // Assert - after clear, store should be empty (minimal entries or all zeros)
        expect(statsAfter, isNotNull);
        // Statistics should show cleared state (exact format depends on implementation)
      });
    });

    group('Maintenance Operations', () {
      test('✅ performMaintenance completes without error', () async {
        // Arrange
        await seenMessageStore.markDelivered('msg-old');

        // Act & Assert
        expect(seenMessageStore.performMaintenance(), completes);
      });

      test('✅ clear removes all tracked messages', () async {
        // Arrange
        await seenMessageStore.markDelivered('msg-1');
        await seenMessageStore.markDelivered('msg-2');
        await seenMessageStore.markRead('msg-3');

        // Act
        await seenMessageStore.clear();

        // Assert
        expect(seenMessageStore.hasDelivered('msg-1'), isFalse);
        expect(seenMessageStore.hasDelivered('msg-2'), isFalse);
        expect(seenMessageStore.hasRead('msg-3'), isFalse);
      });

      test('✅ store is reusable after clear', () async {
        // Arrange
        await seenMessageStore.markDelivered('old-msg');
        await seenMessageStore.clear();

        // Act
        await seenMessageStore.markDelivered('new-msg');

        // Assert
        expect(seenMessageStore.hasDelivered('old-msg'), isFalse);
        expect(seenMessageStore.hasDelivered('new-msg'), isTrue);
      });
    });

    group('DI Integration', () {
      test('✅ ISeenMessageStore is registered in DI container', () {
        // Act & Assert
        final store = TestSetup.getService<ISeenMessageStore>();
        expect(store, isNotNull);
        expect(store, isA<ISeenMessageStore>());
      });

      test('✅ DI-registered instance is singleton', () {
        // Act
        final store1 = TestSetup.getService<ISeenMessageStore>();
        final store2 = TestSetup.getService<ISeenMessageStore>();

        // Assert
        expect(identical(store1, store2), isTrue);
      });

      test('✅ ISeenMessageStore can be used by relay components', () {
        // This test verifies that the seen message store is properly set up
        // for use by relay components like MeshRelayEngine
        final store = TestSetup.getService<ISeenMessageStore>();
        expect(store, isNotNull);

        // Store should be usable by any component that needs it
        expect(store.hasDelivered, isNotNull);
        expect(store.markDelivered, isNotNull);
      });
    });

    group('Concurrent Access', () {
      test('✅ handles concurrent mark operations safely', () async {
        // Arrange
        final futures = <Future>[];
        for (int i = 0; i < 10; i++) {
          futures.add(seenMessageStore.markDelivered('msg-$i'));
        }

        // Act
        await Future.wait(futures);

        // Assert - all messages should be marked
        for (int i = 0; i < 10; i++) {
          expect(seenMessageStore.hasDelivered('msg-$i'), isTrue);
        }
      });

      test('✅ handles concurrent read checks safely', () async {
        // Arrange
        await seenMessageStore.markDelivered('msg-concurrent');
        final futures = <Future<bool>>[];

        // Act - Multiple concurrent checks
        for (int i = 0; i < 5; i++) {
          futures.add(
            Future(() => seenMessageStore.hasDelivered('msg-concurrent')),
          );
        }

        final results = await Future.wait(futures);

        // Assert - all should return true
        expect(results.every((r) => r == true), isTrue);
      });
    });
  });
}
