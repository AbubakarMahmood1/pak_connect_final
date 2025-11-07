import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialize sqflite_ffi for testing
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SeenMessageStore', () {
    late SeenMessageStore store;

    setUp(() async {
      // Use a unique test database for each test
      final testDbName =
          'test_seen_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseHelper.setTestDatabaseName(testDbName);

      // Delete any existing test database
      await DatabaseHelper.deleteDatabase();

      store = SeenMessageStore.instance;
      await store.initialize();
    });

    tearDown(() async {
      await store.clear();
      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
    });

    test('initializes correctly', () async {
      final stats = store.getStatistics();
      expect(stats['initialized'], true);
      expect(stats['deliveredCount'], 0);
      expect(stats['readCount'], 0);
    });

    test('marks message as delivered', () async {
      await store.markDelivered('msg_123');

      expect(store.hasDelivered('msg_123'), true);
      expect(store.hasRead('msg_123'), false);

      final stats = store.getStatistics();
      expect(stats['deliveredCount'], 1);
      expect(stats['readCount'], 0);
    });

    test('marks message as read', () async {
      await store.markRead('msg_123');

      expect(store.hasDelivered('msg_123'), false);
      expect(store.hasRead('msg_123'), true);

      final stats = store.getStatistics();
      expect(stats['deliveredCount'], 0);
      expect(stats['readCount'], 1);
    });

    test('tracks both delivered and read separately', () async {
      await store.markDelivered('msg_delivered');
      await store.markRead('msg_read');

      expect(store.hasDelivered('msg_delivered'), true);
      expect(store.hasRead('msg_delivered'), false);

      expect(store.hasDelivered('msg_read'), false);
      expect(store.hasRead('msg_read'), true);

      final stats = store.getStatistics();
      expect(stats['deliveredCount'], 1);
      expect(stats['readCount'], 1);
    });

    test('persists across restarts', () async {
      // Mark messages
      await store.markDelivered('msg_delivered');
      await store.markRead('msg_read');

      // Simulate restart by creating new instance
      await DatabaseHelper.close();
      final newStore = SeenMessageStore.instance;
      await newStore.initialize();

      // Verify persistence
      expect(newStore.hasDelivered('msg_delivered'), true);
      expect(newStore.hasRead('msg_read'), true);
    });

    test('enforces LRU limit for delivered messages', () async {
      // Add more than maxIdsPerType
      for (int i = 0; i < SeenMessageStore.maxIdsPerType + 100; i++) {
        await store.markDelivered('msg_$i');
      }

      final stats = store.getStatistics();
      expect(stats['deliveredCount'], SeenMessageStore.maxIdsPerType);

      // Oldest messages should be evicted
      expect(store.hasDelivered('msg_0'), false);
      expect(store.hasDelivered('msg_50'), false);

      // Newest messages should be retained
      final lastIndex = SeenMessageStore.maxIdsPerType + 99;
      expect(store.hasDelivered('msg_$lastIndex'), true);
    });

    test('enforces LRU limit for read messages', () async {
      // Add more than maxIdsPerType
      for (int i = 0; i < SeenMessageStore.maxIdsPerType + 100; i++) {
        await store.markRead('msg_$i');
      }

      final stats = store.getStatistics();
      expect(stats['readCount'], SeenMessageStore.maxIdsPerType);

      // Oldest messages should be evicted
      expect(store.hasRead('msg_0'), false);

      // Newest messages should be retained
      final lastIndex = SeenMessageStore.maxIdsPerType + 99;
      expect(store.hasRead('msg_$lastIndex'), true);
    });

    test('moves existing message to end when re-marked (LRU)', () async {
      // Add messages
      await store.markDelivered('msg_1');
      await store.markDelivered('msg_2');
      await store.markDelivered('msg_3');

      // Re-mark msg_1 (should move to end)
      await store.markDelivered('msg_1');

      // Add many more messages to trigger eviction
      for (int i = 4; i < SeenMessageStore.maxIdsPerType; i++) {
        await store.markDelivered('msg_$i');
      }

      // msg_1 should still be present (moved to end)
      expect(store.hasDelivered('msg_1'), true);
    });

    test('clears all messages', () async {
      await store.markDelivered('msg_1');
      await store.markDelivered('msg_2');
      await store.markRead('msg_3');
      await store.markRead('msg_4');

      var stats = store.getStatistics();
      expect(stats['totalTracked'], 4);

      await store.clear();

      stats = store.getStatistics();
      expect(stats['totalTracked'], 0);
      expect(store.hasDelivered('msg_1'), false);
      expect(store.hasRead('msg_3'), false);
    });

    test('performs maintenance correctly', () async {
      // Add excess messages
      for (int i = 0; i < SeenMessageStore.maxIdsPerType + 500; i++) {
        await store.markDelivered('delivered_$i');
        await store.markRead('read_$i');
      }

      // Run maintenance
      await store.performMaintenance();

      // Should trim to maxIdsPerType
      final stats = store.getStatistics();
      expect(
        stats['deliveredCount'],
        lessThanOrEqualTo(SeenMessageStore.maxIdsPerType),
      );
      expect(
        stats['readCount'],
        lessThanOrEqualTo(SeenMessageStore.maxIdsPerType),
      );
    });

    test('handles duplicate markings gracefully', () async {
      // Mark same message multiple times
      await store.markDelivered('msg_1');
      await store.markDelivered('msg_1');
      await store.markDelivered('msg_1');

      final stats = store.getStatistics();
      expect(stats['deliveredCount'], 1); // Should only count once
      expect(store.hasDelivered('msg_1'), true);
    });

    test('handles empty message IDs', () async {
      await store.markDelivered('');
      expect(store.hasDelivered(''), true);

      final stats = store.getStatistics();
      expect(stats['deliveredCount'], 1);
    });
  });
}
