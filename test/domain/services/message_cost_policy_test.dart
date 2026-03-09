import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/services/message_cost_policy.dart';
import 'package:pak_connect/domain/entities/preference_keys.dart';

void main() {
  late MessageCostPolicy policy;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    policy = MessageCostPolicy();
  });

  tearDown(() {
    policy.dispose();
  });

  group('MessageCostPolicy', () {
    group('getRequiredDifficulty', () {
      test('returns 0 for sender within free tier (unknown)', () {
        // Default free threshold for unknown: 50
        final difficulty = policy.getRequiredDifficulty('sender-a', 0.3);
        expect(difficulty, equals(0));
      });

      test('returns 0 for sender within free tier (known)', () {
        // Default free threshold for known: 100
        for (int i = 0; i < 99; i++) {
          policy.recordMessage('known-sender');
        }
        final difficulty =
            policy.getRequiredDifficulty('known-sender', 0.5);
        expect(difficulty, equals(0));
      });

      test('returns 0 for sender within free tier (friend)', () {
        // Default free threshold for friend: 200
        for (int i = 0; i < 199; i++) {
          policy.recordMessage('friend-sender');
        }
        final difficulty =
            policy.getRequiredDifficulty('friend-sender', 0.8);
        expect(difficulty, equals(0));
      });

      test('returns tier 1 difficulty after exceeding free threshold', () {
        policy.setFreeThresholdsForTest(unknown: 5);
        for (int i = 0; i < 6; i++) {
          policy.recordMessage('spammer');
        }
        final difficulty = policy.getRequiredDifficulty('spammer', 0.1);
        expect(difficulty, equals(8)); // Tier 1: difficulty 8
      });

      test('returns tier 2 difficulty after 150+ over free', () {
        policy.setFreeThresholdsForTest(unknown: 5);
        for (int i = 0; i < 160; i++) {
          policy.recordMessage('heavy-spammer');
        }
        final difficulty =
            policy.getRequiredDifficulty('heavy-spammer', 0.1);
        expect(difficulty, equals(12)); // Tier 2: difficulty 12
      });

      test('returns tier 3 difficulty after 400+ over free', () {
        policy.setFreeThresholdsForTest(unknown: 5);
        for (int i = 0; i < 410; i++) {
          policy.recordMessage('mega-spammer');
        }
        final difficulty =
            policy.getRequiredDifficulty('mega-spammer', 0.1);
        expect(difficulty, equals(16)); // Tier 3: difficulty 16
      });

      test('returns tier 4 difficulty after 900+ over free', () {
        policy.setFreeThresholdsForTest(unknown: 5);
        for (int i = 0; i < 910; i++) {
          policy.recordMessage('ultra-spammer');
        }
        final difficulty =
            policy.getRequiredDifficulty('ultra-spammer', 0.1);
        expect(difficulty, equals(20)); // Tier 4: difficulty 20
      });

      test('trust tier affects free threshold', () {
        policy.setFreeThresholdsForTest(unknown: 10, known: 50, friend: 100);
        // Send 30 messages
        for (int i = 0; i < 30; i++) {
          policy.recordMessage('mixed-sender');
        }

        // Unknown: 30 > 10 → should have difficulty
        final unknownDiff =
            policy.getRequiredDifficulty('mixed-sender', 0.1);
        expect(unknownDiff, greaterThan(0));

        // Known: 30 < 50 → still free
        final knownDiff =
            policy.getRequiredDifficulty('mixed-sender', 0.5);
        expect(knownDiff, equals(0));

        // Friend: 30 < 100 → still free
        final friendDiff =
            policy.getRequiredDifficulty('mixed-sender', 0.8);
        expect(friendDiff, equals(0));
      });
    });

    group('getNetworkFloor', () {
      test('returns 0 for low traffic', () {
        expect(policy.getNetworkFloor(100), equals(0));
        expect(policy.getNetworkFloor(199), equals(0));
      });

      test('returns 4 for moderate traffic (200+)', () {
        expect(policy.getNetworkFloor(200), equals(4));
        expect(policy.getNetworkFloor(499), equals(4));
      });

      test('returns 8 for high traffic (500+)', () {
        expect(policy.getNetworkFloor(500), equals(8));
        expect(policy.getNetworkFloor(999), equals(8));
      });

      test('returns 12 for extreme traffic (1000+)', () {
        expect(policy.getNetworkFloor(1000), equals(12));
        expect(policy.getNetworkFloor(5000), equals(12));
      });
    });

    group('getEffectiveDifficulty', () {
      test('takes maximum of sender difficulty and network floor', () {
        policy.setFreeThresholdsForTest(unknown: 5);
        // 10 messages from sender → difficulty 8 (tier 1)
        for (int i = 0; i < 10; i++) {
          policy.recordMessage('sender-x');
        }

        // Network floor = 0 → sender difficulty wins
        final d1 = policy.getEffectiveDifficulty(
          'sender-x',
          0.1,
          networkHourlyVolume: 50,
        );
        expect(d1, equals(8));

        // Network floor = 12 → floor wins
        final d2 = policy.getEffectiveDifficulty(
          'sender-x',
          0.1,
          networkHourlyVolume: 1500,
        );
        expect(d2, equals(12));
      });
    });

    group('getDailyCount', () {
      test('returns 0 for unknown sender', () {
        expect(policy.getDailyCount('unknown'), equals(0));
      });

      test('tracks recorded messages', () {
        policy.recordMessage('node-a');
        policy.recordMessage('node-a');
        policy.recordMessage('node-a');
        expect(policy.getDailyCount('node-a'), equals(3));
      });

      test('tracks different senders independently', () {
        policy.recordMessage('node-a');
        policy.recordMessage('node-b');
        policy.recordMessage('node-b');
        expect(policy.getDailyCount('node-a'), equals(1));
        expect(policy.getDailyCount('node-b'), equals(2));
      });
    });

    group('getNetworkHourlyVolume', () {
      test('tracks total network messages', () {
        policy.recordMessage('a');
        policy.recordMessage('b');
        policy.recordMessage('c');
        expect(policy.getNetworkHourlyVolume(), equals(3));
      });

      test('network volume includes all senders', () {
        policy.addNetworkTimestampsForTest(100);
        expect(policy.getNetworkHourlyVolume(), equals(100));
      });
    });

    group('user preferences', () {
      test('loads custom free thresholds from preferences', () async {
        SharedPreferences.setMockInitialValues({
          PreferenceKeys.powFreeThresholdUnknown: 25,
          PreferenceKeys.powFreeThresholdKnown: 75,
          PreferenceKeys.powFreeThresholdFriend: 150,
        });

        final customPolicy = MessageCostPolicy();
        await customPolicy.initialize();

        expect(customPolicy.currentFreeThresholds, {
          'unknown': 25,
          'known': 75,
          'friend': 150,
        });

        customPolicy.dispose();
      });

      test('uses defaults when no preferences set', () async {
        SharedPreferences.setMockInitialValues({});

        final defaultPolicy = MessageCostPolicy();
        await defaultPolicy.initialize();

        expect(defaultPolicy.currentFreeThresholds, {
          'unknown': PreferenceDefaults.powFreeThresholdUnknown,
          'known': PreferenceDefaults.powFreeThresholdKnown,
          'friend': PreferenceDefaults.powFreeThresholdFriend,
        });

        defaultPolicy.dispose();
      });
    });

    group('resetForTests', () {
      test('clears all tracking data', () {
        policy.recordMessage('a');
        policy.recordMessage('b');
        expect(policy.getDailyCount('a'), equals(1));

        policy.resetForTests();
        expect(policy.getDailyCount('a'), equals(0));
        expect(policy.getNetworkHourlyVolume(), equals(0));
      });
    });
  });
}
