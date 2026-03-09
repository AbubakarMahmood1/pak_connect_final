/// Phase 13 — PeerProtocolVersionGuard tests
/// Extracted from outbound_message_sender_phase13b to respect layer boundaries
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/peer_protocol_version_guard.dart';

void main() {
  setUp(() {
    PeerProtocolVersionGuard.clearForTest();
  });

  group('PeerProtocolVersionGuard', () {
    test('isEnabled is true by default', () {
      expect(PeerProtocolVersionGuard.isEnabled, isTrue);
    });

    test('clearForTest resets tracked peers to default floor', () {
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 3,
        peerKey: 'peer-A',
      );
      expect(
        PeerProtocolVersionGuard.floorForPeer('peer-A'),
        greaterThanOrEqualTo(2),
      );

      PeerProtocolVersionGuard.clearForTest();
      expect(
        PeerProtocolVersionGuard.floorForPeer('peer-A'),
        lessThanOrEqualTo(1),
      );
    });

    test('floorForPeer returns default for unknown peer', () {
      expect(
        PeerProtocolVersionGuard.floorForPeer('unknown-peer'),
        lessThanOrEqualTo(1),
      );
    });

    test('trackObservedVersion upgrades floor for v3 message', () {
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 3,
        peerKey: 'peer-B',
      );
      expect(
        PeerProtocolVersionGuard.floorForPeer('peer-B'),
        greaterThanOrEqualTo(2),
      );
    });

    test('trackObservedVersion with v1 does not upgrade floor', () {
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 1,
        peerKey: 'peer-C',
      );
      expect(
        PeerProtocolVersionGuard.floorForPeer('peer-C'),
        lessThanOrEqualTo(1),
      );
    });

    test('multiple version tracks keep highest floor', () {
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 1,
        peerKey: 'peer-D',
      );
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 3,
        peerKey: 'peer-D',
      );
      PeerProtocolVersionGuard.trackObservedVersion(
        messageVersion: 2,
        peerKey: 'peer-D',
      );
      expect(
        PeerProtocolVersionGuard.floorForPeer('peer-D'),
        greaterThanOrEqualTo(2),
      );
    });
  });
}
