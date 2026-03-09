import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/entities/preference_keys.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';

MeshRelayMessage _msg(String id, String fromNodeId) {
  return MeshRelayMessage(
    originalMessageId: id,
    originalContent: 'test content for $id',
    relayMetadata: RelayMetadata(
      ttl: 5,
      hopCount: 1,
      routingPath: [fromNodeId],
      messageHash: 'hash_$id',
      priority: MessagePriority.normal,
      relayTimestamp: DateTime.now(),
      originalSender: fromNodeId,
      finalRecipient: 'recipient-node',
    ),
    relayNodeId: 'relay-node',
    relayedAt: DateTime.now(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpamPreventionManager manager;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    manager = SpamPreventionManager();
  });

  tearDown(() {
    manager.dispose();
  });

  group('User-configurable rate limits', () {
    test('loads default limits when no preferences set', () async {
      await manager.initialize();
      final limits = manager.currentRateLimits;
      expect(limits['unknown'], PreferenceDefaults.rateLimitUnknownPerHour);
      expect(limits['known'], PreferenceDefaults.rateLimitKnownPerHour);
      expect(limits['friend'], PreferenceDefaults.rateLimitFriendPerHour);
    });

    test('loads user-configured limits from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.rateLimitUnknownPerHour: 3,
        PreferenceKeys.rateLimitKnownPerHour: 50,
        PreferenceKeys.rateLimitFriendPerHour: 200,
      });
      await manager.initialize();
      final limits = manager.currentRateLimits;
      expect(limits['unknown'], 3);
      expect(limits['known'], 50);
      expect(limits['friend'], 200);
    });

    test('reloadUserRateLimits picks up changed values', () async {
      await manager.initialize();
      expect(manager.currentRateLimits['unknown'],
          PreferenceDefaults.rateLimitUnknownPerHour);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(PreferenceKeys.rateLimitUnknownPerHour, 15);

      await manager.reloadUserRateLimits();
      expect(manager.currentRateLimits['unknown'], 15);
    });

    test('stranger blocked earlier than friend', () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.rateLimitUnknownPerHour: 2,
        PreferenceKeys.rateLimitKnownPerHour: 10,
        PreferenceKeys.rateLimitFriendPerHour: 50,
      });
      await manager.initialize();

      const strangerId = 'stranger-node-001';
      const friendId = 'friend-node-001';
      const currentNode = 'my-node';

      // Set trust just above the trust-check minimum (>0.3)
      // but still in unknown tier (<0.4)
      manager.setTrustScoreForTest(strangerId, 0.35);
      manager.setTrustScoreForTest(friendId, 0.8);

      // Pre-fill 2 relay records for stranger (simulates 2 prior messages)
      manager.incrementRelayCountForTest(strangerId);
      manager.incrementRelayCountForTest(strangerId);

      // Next message from stranger → blocked (limit=2, count=2)
      final strangerBlocked = await manager.checkIncomingRelay(
        relayMessage: _msg('msg-stranger-blocked', strangerId),
        fromNodeId: strangerId,
        currentNodeId: currentNode,
      );
      expect(strangerBlocked.allowed, isFalse,
          reason: 'Stranger should be rate-limited at 2/hr');

      // Pre-fill 2 relay records for friend (same count, higher limit)
      manager.incrementRelayCountForTest(friendId);
      manager.incrementRelayCountForTest(friendId);

      // Friend with same count → still allowed (limit=50)
      final friendAllowed = await manager.checkIncomingRelay(
        relayMessage: _msg('msg-friend-ok', friendId),
        fromNodeId: friendId,
        currentNodeId: currentNode,
      );
      expect(friendAllowed.allowed, isTrue,
          reason: 'Friend should still be allowed');
    });

    test('known-tier contact gets intermediate limit', () async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.rateLimitUnknownPerHour: 2,
        PreferenceKeys.rateLimitKnownPerHour: 4,
        PreferenceKeys.rateLimitFriendPerHour: 50,
      });
      await manager.initialize();

      const knownId = 'known-node-001';
      const currentNode = 'my-node';

      // Default trust 0.5 → known tier (0.4-0.7)
      // Pre-fill exactly 4 relay records
      for (var i = 0; i < 4; i++) {
        manager.incrementRelayCountForTest(knownId);
      }

      // 5th message → blocked at known tier limit
      final blocked = await manager.checkIncomingRelay(
        relayMessage: _msg('msg-known-blocked', knownId),
        fromNodeId: knownId,
        currentNodeId: currentNode,
      );
      expect(blocked.allowed, isFalse,
          reason: 'Known contact should be rate-limited at 4/hr');
    });
  });
}
