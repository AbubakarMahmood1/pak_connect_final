import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/services/message_cost_policy.dart';
import 'package:pak_connect/domain/services/proof_of_work_service.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';

void main() {
  late SpamPreventionManager spamManager;
  late MessageCostPolicy costPolicy;

  MeshRelayMessage createMessage(
    String id,
    String fromNodeId, {
    int? powNonce,
    int? powDifficulty,
    int? timestampMs,
  }) {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return MeshRelayMessage(
      originalMessageId: id,
      originalContent: 'test content for $id',
      relayMetadata: RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: [fromNodeId],
        messageHash: 'hash_$id',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.fromMillisecondsSinceEpoch(ts),
        originalSender: fromNodeId,
        finalRecipient: 'recipient-node',
        powNonce: powNonce,
        powDifficulty: powDifficulty,
      ),
      relayNodeId: 'relay-node',
      relayedAt: DateTime.now(),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    spamManager = SpamPreventionManager();
    costPolicy = MessageCostPolicy();
    costPolicy.setFreeThresholdsForTest(unknown: 5, known: 10, friend: 20);
    spamManager.setCostPolicy(costPolicy);
    await spamManager.initialize();
  });

  tearDown(() {
    costPolicy.dispose();
    spamManager.dispose();
  });

  group('SpamPreventionManager - Proof of Work', () {
    test('allows message without PoW when under free tier', () async {
      final msg = createMessage('msg-1', 'sender-a');
      final result = await spamManager.checkIncomingRelay(
        relayMessage: msg,
        fromNodeId: 'sender-a',
        currentNodeId: 'my-node',
      );
      expect(result.allowed, isTrue,
          reason: 'Free tier message should be allowed without PoW');
    });

    test('allows message with valid PoW when above free tier', () async {
      // Push sender above free threshold (5 for unknown trust 0.35)
      spamManager.setTrustScoreForTest('heavy-sender', 0.35);
      for (int i = 0; i < 10; i++) {
        costPolicy.recordMessage('heavy-sender');
      }

      // Compute valid PoW
      const ts = 1700000000000;
      final challenge = ProofOfWorkService.buildChallenge('hash_pow-msg', ts);
      final powResult = ProofOfWorkService.compute(
        challenge: challenge,
        difficulty: 8,
      );

      final msg = createMessage(
        'pow-msg',
        'heavy-sender',
        powNonce: powResult!.nonce,
        powDifficulty: 8,
        timestampMs: ts,
      );

      final result = await spamManager.checkIncomingRelay(
        relayMessage: msg,
        fromNodeId: 'heavy-sender',
        currentNodeId: 'my-node',
      );
      expect(result.allowed, isTrue,
          reason: 'Message with valid PoW should be allowed');
    });

    test('checks PoW validity in spam check results', () async {
      final msg = createMessage('msg-pow', 'node-x');
      final result = await spamManager.checkIncomingRelay(
        relayMessage: msg,
        fromNodeId: 'node-x',
        currentNodeId: 'my-node',
      );
      // Should include proofOfWork check
      final powCheck = result.checks.where(
        (c) => c.type == SpamCheckType.proofOfWork,
      );
      expect(powCheck, isNotEmpty,
          reason: 'PoW check should be present in results');
      expect(powCheck.first.passed, isTrue,
          reason: 'PoW check should pass for free-tier message');
    });

    test('rejects message with invalid PoW nonce', () async {
      // Set network floor high to require PoW
      costPolicy.addNetworkTimestampsForTest(1500);

      final msg = createMessage(
        'invalid-pow',
        'bad-actor',
        powNonce: 42, // invalid nonce
        powDifficulty: 4, // claims difficulty 4 but nonce is wrong
      );

      final result = await spamManager.checkIncomingRelay(
        relayMessage: msg,
        fromNodeId: 'bad-actor',
        currentNodeId: 'my-node',
      );

      final powCheck = result.checks.firstWhere(
        (c) => c.type == SpamCheckType.proofOfWork,
      );
      expect(powCheck.passed, isFalse,
          reason: 'Invalid PoW nonce should fail');
    });

    test('rejects message below network difficulty floor', () async {
      // Set network floor to 8 (requires 200+ hourly messages)
      costPolicy.addNetworkTimestampsForTest(300);

      // Message claims difficulty 0 (no PoW)
      final msg = createMessage('low-pow', 'lazy-node');

      final result = await spamManager.checkIncomingRelay(
        relayMessage: msg,
        fromNodeId: 'lazy-node',
        currentNodeId: 'my-node',
      );

      final powCheck = result.checks.firstWhere(
        (c) => c.type == SpamCheckType.proofOfWork,
      );
      expect(powCheck.passed, isFalse,
          reason: 'Message below network floor should fail PoW check');
    });

    test('backward compatibility: no cost policy = PoW not enforced', () async {
      // Create manager WITHOUT cost policy
      final plainManager = SpamPreventionManager();
      await plainManager.initialize();

      final msg = createMessage('legacy-msg', 'old-client');
      final result = await plainManager.checkIncomingRelay(
        relayMessage: msg,
        fromNodeId: 'old-client',
        currentNodeId: 'my-node',
      );

      final powCheck = result.checks.firstWhere(
        (c) => c.type == SpamCheckType.proofOfWork,
      );
      expect(powCheck.passed, isTrue,
          reason: 'Without cost policy, PoW should pass');
      expect(powCheck.message, contains('not enforced'));

      plainManager.dispose();
    });
  });

  group('RelayMetadata - PoW wire format', () {
    test('serializes PoW fields to JSON', () {
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['node-a'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        originalSender: 'sender',
        finalRecipient: 'recipient',
        powNonce: 12345,
        powDifficulty: 8,
      );

      final json = meta.toJson();
      expect(json['powNonce'], equals(12345));
      expect(json['powDifficulty'], equals(8));
    });

    test('deserializes PoW fields from JSON', () {
      final json = {
        'ttl': 5,
        'hopCount': 1,
        'routingPath': ['node-a'],
        'messageHash': 'hash123',
        'priority': MessagePriority.normal.index,
        'relayTimestamp': 1700000000000,
        'originalSender': 'sender',
        'finalRecipient': 'recipient',
        'powNonce': 12345,
        'powDifficulty': 8,
      };

      final meta = RelayMetadata.fromJson(json);
      expect(meta.powNonce, equals(12345));
      expect(meta.powDifficulty, equals(8));
    });

    test('handles missing PoW fields (backward compat)', () {
      final json = {
        'ttl': 5,
        'hopCount': 1,
        'routingPath': ['node-a'],
        'messageHash': 'hash123',
        'priority': MessagePriority.normal.index,
        'relayTimestamp': 1700000000000,
        'originalSender': 'sender',
        'finalRecipient': 'recipient',
      };

      final meta = RelayMetadata.fromJson(json);
      expect(meta.powNonce, isNull);
      expect(meta.powDifficulty, isNull);
    });

    test('nextHop preserves PoW fields', () {
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['node-a'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: 'sender',
        finalRecipient: 'recipient',
        powNonce: 42,
        powDifficulty: 12,
      );

      final next = meta.nextHop('node-b');
      expect(next.powNonce, equals(42));
      expect(next.powDifficulty, equals(12));
    });

    test('omits PoW from JSON when null/zero', () {
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['node-a'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: 'sender',
        finalRecipient: 'recipient',
      );

      final json = meta.toJson();
      expect(json.containsKey('powNonce'), isFalse);
      expect(json.containsKey('powDifficulty'), isFalse);
    });
  });

  group('End-to-End PoW Pipeline', () {
    test('compute → serialize → deserialize → verify', () {
      const messageHash = 'e2e-hash-test';
      const timestamp = 1700000000000;
      const difficulty = 8;

      // 1. Compute PoW (sender side)
      final challenge =
          ProofOfWorkService.buildChallenge(messageHash, timestamp);
      final powResult = ProofOfWorkService.compute(
        challenge: challenge,
        difficulty: difficulty,
      );
      expect(powResult, isNotNull);

      // 2. Create metadata with PoW (wire format)
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['sender'],
        messageHash: messageHash,
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
        originalSender: 'sender',
        finalRecipient: 'recipient',
        powNonce: powResult!.nonce,
        powDifficulty: difficulty,
      );

      // 3. Serialize → deserialize (network transit)
      final json = meta.toJson();
      final received = RelayMetadata.fromJson(json);

      // 4. Verify PoW (relay side)
      final receivedChallenge = ProofOfWorkService.buildChallenge(
        received.messageHash,
        received.relayTimestamp.millisecondsSinceEpoch,
      );
      final valid = ProofOfWorkService.verify(
        challenge: receivedChallenge,
        nonce: received.powNonce,
        difficulty: received.powDifficulty ?? 0,
      );
      expect(valid, isTrue);
    });
  });
}
