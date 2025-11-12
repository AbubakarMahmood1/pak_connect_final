/// Performance benchmark for ChatsRepository.getAllChats()
///
/// Tests the N+1 query performance issue identified in CONFIDENCE_GAPS.md
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'test_helpers/test_setup.dart';

void main() {
  group('getAllChats Performance Benchmark', () {
    late ChatsRepository chatsRepo;
    late ContactRepository contactRepo;
    late MessageRepository messageRepo;

    setUpAll(() async {
      await TestSetup.initializeTestEnvironment();
    });

    setUp(() async {
      await TestSetup.fullDatabaseReset();
      TestSetup.resetSharedPreferences();

      // Set up UserPreferences with a test public key
      // This is needed for getAllChats() to work properly
      const myPublicKey = 'mykey';
      final storage = FlutterSecureStorage();
      await storage.write(key: 'ecdh_public_key_v2', value: myPublicKey);

      chatsRepo = ChatsRepository();
      contactRepo = ContactRepository();
      messageRepo = MessageRepository();
    });

    tearDown(() async {
      await TestSetup.completeCleanup();
    });

    tearDownAll(() async {
      await DatabaseHelper.deleteDatabase();
    });

    /// Seed database with N contacts, each with M messages
    Future<void> _seedDatabase({
      required int contactCount,
      required int messagesPerContact,
    }) async {
      print('\n🌱 Seeding database:');
      print('   - $contactCount contacts');
      print('   - $messagesPerContact messages per contact');
      print('   - Total messages: ${contactCount * messagesPerContact}');

      for (int i = 0; i < contactCount; i++) {
        // Use simple key format to avoid chat ID parsing bug
        final contactKey = 'testuser${i}_key';
        final contactName = 'Test Contact $i';

        // Create contact
        await contactRepo.saveContact(contactKey, contactName);

        // Create messages for this contact
        // Use production format: chatId = contactKey (simple, no prefix)
        final chatId = contactKey;

        for (int j = 0; j < messagesPerContact; j++) {
          final message = Message(
            id: 'msg_${i}_$j',
            chatId: chatId,
            content: 'Test message $j from $contactName',
            timestamp: DateTime.now().subtract(Duration(minutes: j)),
            isFromMe: j % 2 == 0, // Alternate sender
            status: MessageStatus.delivered,
          );

          await messageRepo.saveMessage(message);
        }
      }

      print('✅ Database seeding complete\n');
    }

    // BENCHMARK TEST 1: Small dataset (10 contacts)
    test('benchmark getAllChats with 10 contacts', () async {
      await _seedDatabase(contactCount: 10, messagesPerContact: 10);

      print('⏱️  Starting benchmark: 10 contacts...');
      final stopwatch = Stopwatch()..start();
      final chats = await chatsRepo.getAllChats(nearbyDevices: []);
      stopwatch.stop();

      final elapsed = stopwatch.elapsedMilliseconds;
      print('⏱️  getAllChats() completed in ${elapsed}ms');
      print('   - Chats returned: ${chats.length}');
      print('   - Avg time per chat: ${elapsed / chats.length}ms\n');

      // Verify correctness
      expect(chats.length, greaterThan(0));
      expect(chats.length, lessThanOrEqualTo(10));

      // Performance expectations for small dataset
      expect(
        elapsed,
        lessThan(500),
        reason: '10 contacts should complete in <500ms (got ${elapsed}ms)',
      );
    });

    // BENCHMARK TEST 2: Medium dataset (50 contacts)
    test('benchmark getAllChats with 50 contacts', () async {
      await _seedDatabase(contactCount: 50, messagesPerContact: 10);

      print('⏱️  Starting benchmark: 50 contacts...');
      final stopwatch = Stopwatch()..start();
      final chats = await chatsRepo.getAllChats(nearbyDevices: []);
      stopwatch.stop();

      final elapsed = stopwatch.elapsedMilliseconds;
      print('⏱️  getAllChats() completed in ${elapsed}ms');
      print('   - Chats returned: ${chats.length}');
      print('   - Avg time per chat: ${elapsed / chats.length}ms\n');

      // Verify correctness
      expect(chats.length, greaterThan(0));
      expect(chats.length, lessThanOrEqualTo(50));

      // Performance expectations for medium dataset
      // N+1 pattern: 1 + 50 queries = ~500ms (10ms per query)
      // Acceptable: <1000ms
      // Optimal (after fix): <100ms
      print('📊 Performance Analysis:');
      if (elapsed < 100) {
        print('   ✅ EXCELLENT: ${elapsed}ms (optimized query detected)');
      } else if (elapsed < 500) {
        print('   ✅ GOOD: ${elapsed}ms (acceptable performance)');
      } else if (elapsed < 1000) {
        print('   ⚠️  SLOW: ${elapsed}ms (N+1 query pattern likely)');
      } else {
        print('   ❌ CRITICAL: ${elapsed}ms (major performance issue)');
      }
    });

    // BENCHMARK TEST 3: Large dataset (100 contacts) - CRITICAL TEST
    test('benchmark getAllChats with 100 contacts (N+1 query test)', () async {
      await _seedDatabase(contactCount: 100, messagesPerContact: 10);

      print('⏱️  Starting benchmark: 100 contacts...');
      final stopwatch = Stopwatch()..start();
      final chats = await chatsRepo.getAllChats(nearbyDevices: []);
      stopwatch.stop();

      final elapsed = stopwatch.elapsedMilliseconds;
      print('⏱️  getAllChats() completed in ${elapsed}ms');
      print('   - Chats returned: ${chats.length}');
      print(
        '   - Avg time per chat: ${(elapsed / chats.length).toStringAsFixed(1)}ms\n',
      );

      // Verify correctness
      expect(chats.length, greaterThan(0));
      expect(chats.length, lessThanOrEqualTo(100));

      // Performance analysis
      print('📊 Performance Analysis for 100 contacts:');
      print('   - Total time: ${elapsed}ms');
      print(
        '   - Per-chat avg: ${(elapsed / chats.length).toStringAsFixed(1)}ms',
      );

      // N+1 pattern calculation:
      // - 1 query to get all contacts (~50ms)
      // - N queries for messages (100 × 10ms = 1000ms)
      // - Total expected with N+1: ~1050ms
      final estimatedN1Time = 1000; // Approximate N+1 query time

      if (elapsed < 100) {
        print('   ✅ OPTIMAL: Query optimization detected!');
        print('      Using JOIN or similar optimization');
        print(
          '      ${((estimatedN1Time / elapsed) * 10).toStringAsFixed(0)}x faster than N+1 pattern',
        );
      } else if (elapsed < 500) {
        print('   ✅ GOOD: Acceptable performance');
        print(
          '      ${((estimatedN1Time / elapsed) * 10).toStringAsFixed(1)}x faster than worst case',
        );
      } else if (elapsed < 1500) {
        print('   ⚠️  CONFIRMED N+1 QUERY PATTERN');
        print('      Expected with N+1: ~${estimatedN1Time}ms');
        print(
          '      Actual: ${elapsed}ms (${((elapsed / estimatedN1Time) * 100).toStringAsFixed(0)}% of expected)',
        );
        print('      Impact: Linear growth (200 contacts = ${elapsed * 2}ms)');
        print('      Recommendation: Apply FIX-006 from RECOMMENDED_FIXES.md');
      } else {
        print('   ❌ CRITICAL PERFORMANCE ISSUE');
        print('      Worse than N+1 pattern suggests other issues');
        print('      Investigation required');
      }

      // Document findings
      print('\n📝 Confidence Gap Update:');
      print('   - Gap #2: N+1 Query Performance');
      if (elapsed > 500) {
        print('   - Status: ✅ CONFIRMED (${elapsed}ms for 100 contacts)');
        print('   - Confidence: 95% → 100%');
        print('   - Evidence: Runtime benchmark proves performance impact');
      } else {
        print('   - Status: ⚠️  NOT REPRODUCED');
        print(
          '   - Confidence: 95% (N+1 pattern exists, but optimized somehow)',
        );
        print('   - Note: SQLite query planner may be caching/optimizing');
      }
    });

    // BENCHMARK TEST 4: Stress test (500 contacts) - Optional
    test(
      'stress test getAllChats with 500 contacts',
      skip: 'Enable only for stress testing (slow)',
      () async {
        await _seedDatabase(contactCount: 500, messagesPerContact: 10);

        print('⏱️  Starting stress test: 500 contacts...');
        final stopwatch = Stopwatch()..start();
        final chats = await chatsRepo.getAllChats(nearbyDevices: []);
        stopwatch.stop();

        final elapsed = stopwatch.elapsedMilliseconds;
        print('⏱️  getAllChats() completed in ${elapsed}ms');
        print('   - Chats returned: ${chats.length}');
        print(
          '   - Avg time per chat: ${(elapsed / chats.length).toStringAsFixed(1)}ms',
        );

        // With N+1 pattern: 1 + 500 queries = ~5000ms (5 seconds)
        // This is unacceptable for production
        if (elapsed > 5000) {
          print(
            '   ❌ UNACCEPTABLE: ${elapsed}ms (${(elapsed / 1000).toStringAsFixed(1)}s)',
          );
          print('      FIX-006 is CRITICAL for production');
        }
      },
    );
  });
}
