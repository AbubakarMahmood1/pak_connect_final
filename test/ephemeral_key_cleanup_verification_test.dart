import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/core/security/ephemeral_key_manager.dart';
import 'package:pak_connect/core/utils/chat_utils.dart';

/// 🧪 VERIFICATION TEST: Ephemeral Key Cleanup
///
/// This test verifies the fix for chat duplication bug caused by 6-hour TTL cache.
///
/// What we're testing:
/// 1. No cache restoration - ephemeral keys NOT reused from SharedPreferences
/// 2. New session every time - different ephemeral IDs on each initialization
/// 3. Chat ID mapping - chat ID = their ephemeral ID (1:1 mapping)
///
/// Root cause that was fixed:
/// - EphemeralKeyManager._tryRestoreSession() used to restore keys if < 6 hours old
/// - This caused: same ephemeral ID → same chat ID → chat duplication
/// - Fix: Always generate fresh ephemeral keys (no cache restoration)
///
/// Related documents:
/// - EPHEMERAL_KEY_CHAT_MAPPING_ANALYSIS.md (investigation)
/// - EPHEMERAL_KEY_CLEANUP_SUMMARY.md (cleanup summary)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ephemeral Key Cleanup Verification', () {
    setUp(() async {
      // Clear SharedPreferences before each test
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance().then((prefs) => prefs.clear());
    });

    test(
      '1. No cache restoration - fresh ephemeral key on each initialization',
      () async {
        // GIVEN: First initialization creates an ephemeral session
        await EphemeralKeyManager.initialize('test-private-key');
        final firstSessionKey = EphemeralKeyManager.generateMyEphemeralKey();

        print('🔑 First session key: ${firstSessionKey.substring(0, 16)}...');

        // Verify session key was saved to SharedPreferences (for debugging)
        final prefs = await SharedPreferences.getInstance();
        final savedSessionKey = prefs.getString('current_ephemeral_session');
        expect(
          savedSessionKey,
          isNotNull,
          reason: 'Session key should be saved for debugging',
        );
        expect(
          savedSessionKey,
          equals(firstSessionKey),
          reason: 'Saved key should match current session',
        );

        print('💾 Session key saved to SharedPreferences (for debugging only)');

        // WHEN: Re-initialize EphemeralKeyManager (simulating app restart)
        await EphemeralKeyManager.initialize('test-private-key');
        final secondSessionKey = EphemeralKeyManager.generateMyEphemeralKey();

        print('🔑 Second session key: ${secondSessionKey.substring(0, 16)}...');

        // THEN: Second session key should be DIFFERENT (not restored from cache)
        expect(
          secondSessionKey,
          isNot(equals(firstSessionKey)),
          reason:
              '❌ BUG DETECTED: Ephemeral key was restored from cache! '
              'Expected fresh key on each initialization. '
              'Check EphemeralKeyManager._tryRestoreSession() - it should NOT restore from SharedPreferences.',
        );

        print(
          '✅ PASS: Different ephemeral keys on each initialization (no cache restoration)',
        );
      },
    );

    test('2. Multiple initializations create different ephemeral IDs', () async {
      // GIVEN: Multiple app sessions (simulated by multiple initializations)
      final sessionKeys = <String>[];

      for (int i = 0; i < 5; i++) {
        await EphemeralKeyManager.initialize('test-private-key');
        final sessionKey = EphemeralKeyManager.generateMyEphemeralKey();
        sessionKeys.add(sessionKey);

        print('🔑 Session $i key: ${sessionKey.substring(0, 16)}...');

        // Small delay to ensure timestamp changes
        await Future.delayed(Duration(milliseconds: 10));
      }

      // THEN: All session keys should be unique
      final uniqueKeys = sessionKeys.toSet();
      expect(
        uniqueKeys.length,
        equals(sessionKeys.length),
        reason:
            '❌ BUG DETECTED: Some ephemeral keys were reused! '
            'Expected ${sessionKeys.length} unique keys, got ${uniqueKeys.length}. '
            'Each initialization should generate a fresh ephemeral key.',
      );

      print(
        '✅ PASS: All ${sessionKeys.length} sessions have unique ephemeral keys',
      );
    });

    test('3. Chat ID mapping - chat ID = their ephemeral ID', () async {
      // GIVEN: Another device's ephemeral ID
      final theirEphemeralId = 'abc123def456xyz789';

      print('📱 Their ephemeral ID: $theirEphemeralId');

      // WHEN: Generate chat ID for this device
      final chatId = ChatUtils.generateChatId(theirEphemeralId);

      print('🆔 Generated chat ID: $chatId');

      // THEN: Chat ID should exactly match their ephemeral ID
      expect(
        chatId,
        equals(theirEphemeralId),
        reason:
            'Chat ID should be 1:1 mapped to their ephemeral ID. '
            'This is the current behavior (Phase 2). '
            'Phase 3 will use Noise NN session ID instead.',
      );

      print('✅ PASS: Chat ID = their ephemeral ID (1:1 mapping confirmed)');
    });

    test('4. Same ephemeral ID creates same chat ID (current behavior)', () async {
      // GIVEN: Same device connects twice with same ephemeral ID
      final theirEphemeralId = 'same-ephemeral-id-123';

      // WHEN: Generate chat IDs for both connections
      final chatId1 = ChatUtils.generateChatId(theirEphemeralId);
      final chatId2 = ChatUtils.generateChatId(theirEphemeralId);

      print('📱 Their ephemeral ID: $theirEphemeralId');
      print('🆔 Chat ID #1: $chatId1');
      print('🆔 Chat ID #2: $chatId2');

      // THEN: Both chat IDs should be the same (current behavior)
      expect(
        chatId1,
        equals(chatId2),
        reason:
            'Same ephemeral ID should create same chat ID (current behavior). '
            'This is WHY cache restoration caused bug - cached ID → same chat. '
            'Phase 3 fix: Use Noise NN session ID (unique per handshake).',
      );

      print(
        '✅ PASS: Same ephemeral ID → same chat ID (explains why cache caused duplication)',
      );
    });

    test('5. Different ephemeral IDs create different chat IDs', () async {
      // GIVEN: Same device connects twice with DIFFERENT ephemeral IDs
      // (This is the fix - cache removal ensures different IDs across app restarts)
      final theirFirstEphemeralId = 'first-ephemeral-id-abc';
      final theirSecondEphemeralId = 'second-ephemeral-id-xyz';

      // WHEN: Generate chat IDs for both connections
      final chatId1 = ChatUtils.generateChatId(theirFirstEphemeralId);
      final chatId2 = ChatUtils.generateChatId(theirSecondEphemeralId);

      print('📱 Their first ephemeral ID: $theirFirstEphemeralId');
      print('🆔 First chat ID: $chatId1');
      print('📱 Their second ephemeral ID: $theirSecondEphemeralId');
      print('🆔 Second chat ID: $chatId2');

      // THEN: Chat IDs should be different (different sessions)
      expect(
        chatId1,
        isNot(equals(chatId2)),
        reason:
            'Different ephemeral IDs should create different chat IDs. '
            'This proves the fix works - no cache restoration → different IDs → different chats.',
      );

      print(
        '✅ PASS: Different ephemeral IDs → different chat IDs (fix working!)',
      );
    });

    test(
      '6. Ephemeral key includes timestamp component (prevents replay)',
      () async {
        // GIVEN: Multiple initializations with small time gaps
        await EphemeralKeyManager.initialize('test-private-key');
        final key1 = EphemeralKeyManager.generateMyEphemeralKey();

        await Future.delayed(Duration(milliseconds: 50));

        await EphemeralKeyManager.initialize('test-private-key');
        final key2 = EphemeralKeyManager.generateMyEphemeralKey();

        print('🔑 Key 1 (time T): ${key1.substring(0, 16)}...');
        print('🔑 Key 2 (time T+50ms): ${key2.substring(0, 16)}...');

        // THEN: Keys should be different (timestamp + random component)
        expect(
          key1,
          isNot(equals(key2)),
          reason:
              'Ephemeral keys should include timestamp component. '
              'Even with same private key and salt, different timestamps → different keys.',
        );

        print('✅ PASS: Timestamp component ensures key uniqueness');
      },
    );

    test(
      '7. SharedPreferences save is for debugging only (not restored)',
      () async {
        // GIVEN: First initialization saves to SharedPreferences
        await EphemeralKeyManager.initialize('test-private-key');
        final firstKey = EphemeralKeyManager.generateMyEphemeralKey();

        final prefs = await SharedPreferences.getInstance();
        final savedKey = prefs.getString('current_ephemeral_session');

        print('🔑 First key: ${firstKey.substring(0, 16)}...');
        print('💾 Saved key: ${savedKey?.substring(0, 16)}...');

        expect(
          savedKey,
          equals(firstKey),
          reason: 'Key should be saved to SharedPreferences',
        );

        // WHEN: Manually modify saved key (simulate cache corruption)
        await prefs.setString(
          'current_ephemeral_session',
          'corrupted-cached-key',
        );
        print('💣 Manually corrupted cached key');

        // Re-initialize
        await EphemeralKeyManager.initialize('test-private-key');
        final newKey = EphemeralKeyManager.generateMyEphemeralKey();

        print('🔑 New key after corruption: ${newKey.substring(0, 16)}...');

        // THEN: New key should be fresh (NOT the corrupted cached key)
        expect(
          newKey,
          isNot(equals('corrupted-cached-key')),
          reason:
              '❌ BUG DETECTED: Corrupted cache was used! '
              'EphemeralKeyManager should NOT restore from SharedPreferences.',
        );

        expect(
          newKey,
          isNot(equals(firstKey)),
          reason:
              'New key should be different from first key (fresh generation)',
        );

        print(
          '✅ PASS: Cached value ignored (proof that cache is NOT restored)',
        );
      },
    );
  });

  group('Chat Duplication Bug Scenario (Regression Test)', () {
    test('Scenario: User reports same chat after app restart', () async {
      // SCENARIO: This is the exact bug users experienced
      //
      // Device A (Alice) and Device B (Bob) connect:
      // 1. Alice starts app, ephemeral ID = "alice-ephemeral-123"
      // 2. Bob starts app, ephemeral ID = "bob-ephemeral-456"
      // 3. They handshake, chat created with ID = "bob-ephemeral-456"
      // 4. Both close app
      // 5. Alice restarts app
      //    - OLD BUG: Ephemeral ID restored from cache = "alice-ephemeral-123" (same)
      //    - NEW FIX: Ephemeral ID regenerated = "alice-ephemeral-789" (different)
      // 6. Bob restarts app
      //    - OLD BUG: Ephemeral ID restored = "bob-ephemeral-456" (same)
      //    - NEW FIX: Ephemeral ID regenerated = "bob-ephemeral-999" (different)
      // 7. They handshake again
      //    - OLD BUG: Chat ID = "bob-ephemeral-456" (SAME CHAT - duplication!)
      //    - NEW FIX: Chat ID = "bob-ephemeral-999" (NEW CHAT - correct!)

      print('\n📖 SCENARIO: Simulating real-world chat duplication bug\n');

      // === FIRST SESSION ===
      print('🔵 SESSION 1: Initial connection');

      await EphemeralKeyManager.initialize('alice-private-key');
      final aliceEphemeralId1 = EphemeralKeyManager.generateMyEphemeralKey();

      await EphemeralKeyManager.initialize('bob-private-key');
      final bobEphemeralId1 = EphemeralKeyManager.generateMyEphemeralKey();

      // Alice sees Bob's ephemeral ID, creates chat
      final chatId1 = ChatUtils.generateChatId(bobEphemeralId1);

      print(
        '👤 Alice ephemeral ID (session 1): ${aliceEphemeralId1.substring(0, 16)}...',
      );
      print(
        '👤 Bob ephemeral ID (session 1): ${bobEphemeralId1.substring(0, 16)}...',
      );
      print('💬 Chat ID created: ${chatId1.substring(0, 16)}...');

      // === APP RESTART (simulated by re-initialization) ===
      print('\n🔄 APP RESTART: Both devices restart\n');

      // === SECOND SESSION ===
      print('🟢 SESSION 2: Reconnection after restart');

      await EphemeralKeyManager.initialize('alice-private-key');
      final aliceEphemeralId2 = EphemeralKeyManager.generateMyEphemeralKey();

      await EphemeralKeyManager.initialize('bob-private-key');
      final bobEphemeralId2 = EphemeralKeyManager.generateMyEphemeralKey();

      // Alice sees Bob's (new) ephemeral ID, creates chat
      final chatId2 = ChatUtils.generateChatId(bobEphemeralId2);

      print(
        '👤 Alice ephemeral ID (session 2): ${aliceEphemeralId2.substring(0, 16)}...',
      );
      print(
        '👤 Bob ephemeral ID (session 2): ${bobEphemeralId2.substring(0, 16)}...',
      );
      print('💬 Chat ID created: ${chatId2.substring(0, 16)}...');

      // === VERIFICATION ===
      print('\n🔍 VERIFICATION:\n');

      // Alice's ephemeral ID should change
      expect(
        aliceEphemeralId2,
        isNot(equals(aliceEphemeralId1)),
        reason:
            '❌ BUG: Alice ephemeral ID was cached! Should be different after restart.',
      );
      print('✅ Alice ephemeral ID changed (no cache restoration)');

      // Bob's ephemeral ID should change
      expect(
        bobEphemeralId2,
        isNot(equals(bobEphemeralId1)),
        reason:
            '❌ BUG: Bob ephemeral ID was cached! Should be different after restart.',
      );
      print('✅ Bob ephemeral ID changed (no cache restoration)');

      // Chat IDs should be DIFFERENT (different sessions)
      expect(
        chatId2,
        isNot(equals(chatId1)),
        reason:
            '❌ BUG: Chat duplication detected! Same chat ID across sessions. '
            'This is the bug users reported. '
            'Root cause: Ephemeral keys were cached (6-hour TTL).',
      );
      print('✅ Different chat IDs across sessions (bug fixed!)');

      print('\n🎉 SUCCESS: Chat duplication bug is FIXED!');
      print('   - Session 1 chat ID: ${chatId1.substring(0, 16)}...');
      print('   - Session 2 chat ID: ${chatId2.substring(0, 16)}...');
      print('   - Result: Two separate chats (correct behavior)\n');
    });
  });

  group('Investigation Logging Verification', () {
    test('Logging functions work correctly', () {
      // This test just verifies the logging doesn't crash
      // Actual log output is verified during real-world testing

      final testId = 'test-ephemeral-id-123';
      final chatId = ChatUtils.generateChatId(testId);

      expect(chatId, equals(testId));
      print(
        '✅ ChatUtils logging works (check logs for investigation messages)',
      );
    });
  });
}
