import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/stealth_address.dart';
import 'package:pak_connect/core/security/noise/primitives/dh_state.dart';

void main() {
  group('StealthAddress', () {
    late Uint8List recipientPrivateKey;
    late Uint8List recipientPublicKey;

    setUp(() {
      // Generate a stable recipient keypair for tests
      final dh = DHState()..generateKeyPair();
      recipientPrivateKey = dh.getPrivateKey()!;
      recipientPublicKey = dh.getPublicKey()!;
    });

    test('generate produces valid envelope', () {
      final envelope = StealthAddress.generate(
        recipientScanKey: recipientPublicKey,
      );
      expect(envelope.ephemeralPublicKey.length, 32);
      expect(envelope.viewTag, inInclusiveRange(0, 255));
      expect(envelope.stealthAddress.length, 32);
    });

    test('recipient can match their own stealth envelope', () {
      final envelope = StealthAddress.generate(
        recipientScanKey: recipientPublicKey,
      );
      final result = StealthAddress.check(
        scanPrivateKey: recipientPrivateKey,
        envelope: envelope,
      );
      expect(result.isForMe, isTrue);
      expect(result.passedViewTag, isTrue);
    });

    test('non-recipient fails stealth check', () {
      final envelope = StealthAddress.generate(
        recipientScanKey: recipientPublicKey,
      );

      // Different keypair (attacker/relay node)
      final otherDh = DHState()..generateKeyPair();
      final result = StealthAddress.check(
        scanPrivateKey: otherDh.getPrivateKey()!,
        envelope: envelope,
      );
      expect(result.isForMe, isFalse);
    });

    test('different messages to same recipient produce different envelopes', () {
      final e1 = StealthAddress.generate(recipientScanKey: recipientPublicKey);
      final e2 = StealthAddress.generate(recipientScanKey: recipientPublicKey);

      // Ephemeral keys differ (random per message)
      expect(e1.ephemeralPublicKey, isNot(equals(e2.ephemeralPublicKey)));
      // Stealth addresses differ
      expect(e1.stealthAddress, isNot(equals(e2.stealthAddress)));
    });

    test('view tag fast-reject filters most non-recipients', () {
      // Generate many envelopes and check against a non-recipient.
      // Statistically ~1/256 should pass the view tag check.
      final otherDh = DHState()..generateKeyPair();
      final otherPrivKey = otherDh.getPrivateKey()!;

      var viewTagPasses = 0;
      var fullPasses = 0;
      const trials = 1000;

      for (var i = 0; i < trials; i++) {
        final envelope = StealthAddress.generate(
          recipientScanKey: recipientPublicKey,
        );
        final result = StealthAddress.check(
          scanPrivateKey: otherPrivKey,
          envelope: envelope,
        );
        if (result.passedViewTag) viewTagPasses++;
        if (result.isForMe) fullPasses++;
      }

      // Expected: ~3.9 view tag matches per 1000 (1/256)
      // Allow generous range due to randomness
      expect(viewTagPasses, lessThan(30),
          reason: 'View tag false positive rate should be ~0.4%');
      expect(fullPasses, 0,
          reason: 'Full stealth match must never produce false positives');
    });

    test('JSON round-trip preserves envelope', () {
      final envelope = StealthAddress.generate(
        recipientScanKey: recipientPublicKey,
      );
      final json = envelope.toJson();
      final restored = StealthEnvelope.fromJson(json);

      expect(restored.ephemeralPublicKey, equals(envelope.ephemeralPublicKey));
      expect(restored.viewTag, envelope.viewTag);
      expect(restored.stealthAddress, equals(envelope.stealthAddress));

      // Verify restored envelope still works
      final result = StealthAddress.check(
        scanPrivateKey: recipientPrivateKey,
        envelope: restored,
      );
      expect(result.isForMe, isTrue);
    });
  });
}
