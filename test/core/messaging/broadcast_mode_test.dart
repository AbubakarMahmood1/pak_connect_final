import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/relay_decision_engine.dart';
import 'package:pak_connect/core/security/stealth_address.dart';
import 'package:pak_connect/domain/constants/special_recipients.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/routing/network_topology_analyzer.dart';

void main() {
  group('Phase 6: Broadcast mode for small networks', () {
    late RelayDecisionEngine engine;

    test('isSmallNetworkBroadcast true when ≤30 peers', () {
      engine = RelayDecisionEngine(
        logger: Logger('test'),
        seenMessageStore: _FakeSeenStore(),
        currentNodeId: 'me',
        topologyAnalyzer: _FakeTopology(10),
      );
      expect(engine.isSmallNetworkBroadcast, isTrue);
    });

    test('isSmallNetworkBroadcast true at exactly 30 peers', () {
      engine = RelayDecisionEngine(
        logger: Logger('test'),
        seenMessageStore: _FakeSeenStore(),
        currentNodeId: 'me',
        topologyAnalyzer: _FakeTopology(30),
      );
      expect(engine.isSmallNetworkBroadcast, isTrue);
    });

    test('isSmallNetworkBroadcast false when >30 peers', () {
      engine = RelayDecisionEngine(
        logger: Logger('test'),
        seenMessageStore: _FakeSeenStore(),
        currentNodeId: 'me',
        topologyAnalyzer: _FakeTopology(31),
      );
      expect(engine.isSmallNetworkBroadcast, isFalse);
    });

    test('relay probability is 1.0 for ≤30 peers (flood all)', () {
      engine = RelayDecisionEngine(
        logger: Logger('test'),
        seenMessageStore: _FakeSeenStore(),
        currentNodeId: 'me',
        topologyAnalyzer: _FakeTopology(25),
      );
      expect(engine.calculateRelayProbability(), 1.0);
    });

    test('relay probability drops below 1.0 for >30 peers', () {
      engine = RelayDecisionEngine(
        logger: Logger('test'),
        seenMessageStore: _FakeSeenStore(),
        currentNodeId: 'me',
        topologyAnalyzer: _FakeTopology(40),
      );
      expect(engine.calculateRelayProbability(), lessThan(1.0));
    });

    test('broadcast recipient combined with stealth envelope hides routing', () {
      final recipientKey = Uint8List(32);
      recipientKey[0] = 42;

      final envelope = StealthAddress.generate(
        recipientScanKey: recipientKey,
      );

      final metadata = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['sender-node'],
        messageHash: 'abc123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: RelayMetadata.sealedSenderPlaceholder,
        finalRecipient: SpecialRecipients.broadcast,
        stealthEnvelope: envelope,
        sealedSender: true,
      );

      // Relay node sees broadcast + sealed — no routing metadata leaked
      expect(metadata.finalRecipient, SpecialRecipients.broadcast);
      expect(metadata.originalSender, 'sealed');
      expect(metadata.usesStealth, isTrue);
      expect(metadata.sealedSender, isTrue);

      // JSON round-trip preserves the stealth envelope while replacing the
      // plaintext recipient with the on-wire stealth placeholder.
      final json = metadata.toJson();
      expect(
        json['finalRecipient'],
        RelayMetadata.stealthRecipientPlaceholder,
      );
      final restored = RelayMetadata.fromJson(json);
      expect(
        restored.finalRecipient,
        RelayMetadata.stealthRecipientPlaceholder,
      );
      expect(restored.sealedSender, isTrue);
      expect(restored.usesStealth, isTrue);
    });

    test('broadcast mode with stealth: non-recipient rejects via view tag', () {
      final recipientKey = Uint8List(32);
      recipientKey[0] = 77;
      recipientKey[1] = 22;

      final envelope = StealthAddress.generate(
        recipientScanKey: recipientKey,
      );

      // Random non-recipient checks — should reject (overwhelmingly likely)
      final wrongKey = Uint8List(32);
      wrongKey[0] = 99;
      final wrongResult = StealthAddress.check(
        scanPrivateKey: wrongKey,
        envelope: envelope,
      );
      expect(wrongResult.isForMe, isFalse);
    });
  });
}

class _FakeSeenStore implements ISeenMessageStore {
  @override
  bool hasDelivered(String messageId) => false;
  @override
  Future<void> markDelivered(String messageId) async {}
  void markDeliveredId(dynamic messageId) {}
  bool hasDeliveredId(dynamic messageId) => false;
  int get size => 0;
  void cleanup() {}
  void dispose() {}
  Map<String, dynamic> getStats() => {};
  @override
  Future<void> initialize() async {}
  @override
  bool hasRead(String messageId) => false;
  @override
  Future<void> markRead(String messageId) async {}
  @override
  Map<String, dynamic> getStatistics() => {};
  @override
  Future<void> clear() async {}
  @override
  Future<void> performMaintenance() async {}
}

class _FakeTopology extends NetworkTopologyAnalyzer {
  final int _size;
  _FakeTopology(this._size);

  @override
  int getNetworkSize() => _size;
}
