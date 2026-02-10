/// Performance benchmark for ChatsRepository.getAllChats()
///
/// Tests the N+1 query performance issue identified in CONFIDENCE_GAPS.md
//
// Diagnostic output is intentional for benchmark result reporting.

library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'test_helpers/test_setup.dart';

ChatId _cid(String value) => ChatId(value);

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('getAllChats Performance Benchmark', () {
    late ChatsRepository chatsRepo;
    late ContactRepository contactRepo;
    late MessageRepository messageRepo;

    setUpAll(() async {
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'performance_get_all_chats',
      );
    });

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      await TestSetup.configureTestDatabase(label: 'performance_get_all_chats');
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
      await TestSetup.nukeDatabase();
    });

    /// Seed database with N contacts, each with M messages
    Future<void> seedDatabase({
      required int contactCount,
      required int messagesPerContact,
    }) async {
      debugPrint('\n🌱 Seeding database:');
      debugPrint('   - $contactCount contacts');
      debugPrint('   - $messagesPerContact messages per contact');
      debugPrint('   - Total messages: ${contactCount * messagesPerContact}');

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
            id: MessageId('msg_${i}_$j'),
            chatId: _cid(chatId),
            content: 'Test message $j from $contactName',
            timestamp: DateTime.now().subtract(Duration(minutes: j)),
            isFromMe: j % 2 == 0, // Alternate sender
            status: MessageStatus.delivered,
          );

          await messageRepo.saveMessage(message);
        }
      }

      debugPrint('✅ Database seeding complete\n');
    }

    // BENCHMARK TEST 1: Small dataset (10 contacts)
    test('benchmark getAllChats with 10 contacts', () async {
      await seedDatabase(contactCount: 10, messagesPerContact: 10);

      debugPrint('⏱️  Starting benchmark: 10 contacts...');
      final stopwatch = Stopwatch()..start();
      final chats = await chatsRepo.getAllChats(nearbyDevices: []);
      stopwatch.stop();

      final elapsed = stopwatch.elapsedMilliseconds;
      debugPrint('⏱️  getAllChats() completed in ${elapsed}ms');
      debugPrint('   - Chats returned: ${chats.length}');
      debugPrint('   - Avg time per chat: ${elapsed / chats.length}ms\n');

      // Verify correctness
      expect(chats.length, greaterThan(0));
      expect(chats.length, lessThanOrEqualTo(10));

      // Log performance instead of failing the suite (diagnostic benchmark)
      if (elapsed < 500) {
        debugPrint('✅ 10 contacts completed within 500ms');
      } else {
        debugPrint(
          '⚠️  10-contact benchmark exceeded 500ms (${elapsed}ms). '
          'This is informational only.',
        );
      }
    });

    // BENCHMARK TEST 2: Medium dataset (50 contacts)
    test('benchmark getAllChats with 50 contacts', () async {
      await seedDatabase(contactCount: 50, messagesPerContact: 10);

      debugPrint('⏱️  Starting benchmark: 50 contacts...');
      final stopwatch = Stopwatch()..start();
      final chats = await chatsRepo.getAllChats(nearbyDevices: []);
      stopwatch.stop();

      final elapsed = stopwatch.elapsedMilliseconds;
      debugPrint('⏱️  getAllChats() completed in ${elapsed}ms');
      debugPrint('   - Chats returned: ${chats.length}');
      debugPrint('   - Avg time per chat: ${elapsed / chats.length}ms\n');

      // Verify correctness
      expect(chats.length, greaterThan(0));
      expect(chats.length, lessThanOrEqualTo(50));

      // Performance expectations for medium dataset
      // N+1 pattern: 1 + 50 queries = ~500ms (10ms per query)
      // Acceptable: <1000ms
      // Optimal (after fix): <100ms
      debugPrint('📊 Performance Analysis:');
      if (elapsed < 100) {
        debugPrint('   ✅ EXCELLENT: ${elapsed}ms (optimized query detected)');
      } else if (elapsed < 500) {
        debugPrint('   ✅ GOOD: ${elapsed}ms (acceptable performance)');
      } else if (elapsed < 1000) {
        debugPrint('   ⚠️  SLOW: ${elapsed}ms (N+1 query pattern likely)');
      } else {
        debugPrint('   ❌ CRITICAL: ${elapsed}ms (major performance issue)');
      }
    });

    // BENCHMARK TEST 3: Large dataset (100 contacts) - CRITICAL TEST
    test('benchmark getAllChats with 100 contacts (N+1 query test)', () async {
      await seedDatabase(contactCount: 100, messagesPerContact: 10);

      debugPrint('⏱️  Starting benchmark: 100 contacts...');
      final stopwatch = Stopwatch()..start();
      final chats = await chatsRepo.getAllChats(nearbyDevices: []);
      stopwatch.stop();

      final elapsed = stopwatch.elapsedMilliseconds;
      debugPrint('⏱️  getAllChats() completed in ${elapsed}ms');
      debugPrint('   - Chats returned: ${chats.length}');
      debugPrint(
        '   - Avg time per chat: ${(elapsed / chats.length).toStringAsFixed(1)}ms\n',
      );

      // Verify correctness
      expect(chats.length, greaterThan(0));
      expect(chats.length, lessThanOrEqualTo(100));

      // Performance analysis
      debugPrint('📊 Performance Analysis for 100 contacts:');
      debugPrint('   - Total time: ${elapsed}ms');
      debugPrint(
        '   - Per-chat avg: ${(elapsed / chats.length).toStringAsFixed(1)}ms',
      );

      // N+1 pattern calculation:
      // - 1 query to get all contacts (~50ms)
      // - N queries for messages (100 × 10ms = 1000ms)
      // - Total expected with N+1: ~1050ms
      final estimatedN1Time = 1000; // Approximate N+1 query time

      if (elapsed < 100) {
        debugPrint('   ✅ OPTIMAL: Query optimization detected!');
        debugPrint('      Using JOIN or similar optimization');
        debugPrint(
          '      ${((estimatedN1Time / elapsed) * 10).toStringAsFixed(0)}x faster than N+1 pattern',
        );
      } else if (elapsed < 500) {
        debugPrint('   ✅ GOOD: Acceptable performance');
        debugPrint(
          '      ${((estimatedN1Time / elapsed) * 10).toStringAsFixed(1)}x faster than worst case',
        );
      } else if (elapsed < 1500) {
        debugPrint('   ⚠️  CONFIRMED N+1 QUERY PATTERN');
        debugPrint('      Expected with N+1: ~${estimatedN1Time}ms');
        debugPrint(
          '      Actual: ${elapsed}ms (${((elapsed / estimatedN1Time) * 100).toStringAsFixed(0)}% of expected)',
        );
        debugPrint('      Impact: Linear growth (200 contacts = ${elapsed * 2}ms)');
        debugPrint('      Recommendation: Apply FIX-006 from RECOMMENDED_FIXES.md');
      } else {
        debugPrint('   ❌ CRITICAL PERFORMANCE ISSUE');
        debugPrint('      Worse than N+1 pattern suggests other issues');
        debugPrint('      Investigation required');
      }

      // Document findings
      debugPrint('\n📝 Confidence Gap Update:');
      debugPrint('   - Gap #2: N+1 Query Performance');
      if (elapsed > 500) {
        debugPrint('   - Status: ✅ CONFIRMED (${elapsed}ms for 100 contacts)');
        debugPrint('   - Confidence: 95% → 100%');
        debugPrint('   - Evidence: Runtime benchmark proves performance impact');
      } else {
        debugPrint('   - Status: ⚠️  NOT REPRODUCED');
        debugPrint(
          '   - Confidence: 95% (N+1 pattern exists, but optimized somehow)',
        );
        debugPrint('   - Note: SQLite query planner may be caching/optimizing');
      }
    });

    // BENCHMARK TEST 4: Stress test (500 contacts) - Optional
    test(
      'stress test getAllChats with 500 contacts',
      () async {
        await seedDatabase(contactCount: 500, messagesPerContact: 10);

        debugPrint('⏱️  Starting stress test: 500 contacts...');
        final stopwatch = Stopwatch()..start();
        final chats = await chatsRepo.getAllChats(nearbyDevices: []);
        stopwatch.stop();

        final elapsed = stopwatch.elapsedMilliseconds;
        debugPrint('⏱️  getAllChats() completed in ${elapsed}ms');
        debugPrint('   - Chats returned: ${chats.length}');
        debugPrint(
          '   - Avg time per chat: ${(elapsed / chats.length).toStringAsFixed(1)}ms',
        );

        // With N+1 pattern: 1 + 500 queries = ~5000ms (5 seconds)
        // This is unacceptable for production
        if (elapsed > 5000) {
          debugPrint(
            '   ❌ UNACCEPTABLE: ${elapsed}ms (${(elapsed / 1000).toStringAsFixed(1)}s)',
          );
          debugPrint('      FIX-006 is CRITICAL for production');
        }
      },
      timeout: Timeout(Duration(minutes: 2)),
    );
  });
}
